# jsz — Scalability Refactor Plan

> Companion to `PRODUCTION_ROADMAP.md`. The roadmap adds capability (M14→M24);
> this plan keeps the codebase able to *absorb* that capability. Behaviour does
> not change — every step is a pure restructuring gated by the existing test
> suite. Measured 2026-06-10.

## 0. Why now

32,272 LOC across `src/`. The problem is not total size — it is a handful of
**mega-functions** that every new feature has to thread through, so each milestone
makes them worse:

| File | LOC | Worst function | Shape |
|---|---:|---|---|
| `src/vm/bc_vm.zig` | 4899 | `runLoop` **1869** | one opcode-dispatch `switch (op)` |
| `src/parser/parser.zig` | 2830 | `parseClassDeclStmt` 191 | many small fns (healthy; just big in aggregate) |
| `src/bytecode/compiler.zig` | 2313 | `compileStmt` **703** | statement megaswitch |
| `src/runtime/realm.zig` | 1742 | `init` **627** | every builtin constructed inline |
| `src/runtime/builtins/regexp.zig` | 1233 | — | self-contained, lower priority |

`runLoop`, `compileStmt`, and `realm.init` are the three that hurt: a TypedArray
hook lands in `runLoop`, a new builtin lands in `init`, a new statement lands in
`compileStmt`. They are merge-conflict magnets and exceed what one screen / one
reviewer can hold. Parser is large but already decomposed into ~80 small methods —
leave it until last.

## 1. Principles (the guardrails we are buying)

1. **Size budgets** (soft = refactor when crossed, hard = do not merge past):
   - File: soft **800**, hard **1500** LOC.
   - Function: soft **120**, hard **250** LOC. The dispatch `switch` is the *only*
     sanctioned exception, and only because each *arm* must stay ≤ ~30 LOC by
     delegating its body.
2. **One concern per file.** A builtin owns its registration; the VM owns dispatch,
   not builtin policy; the compiler owns lowering, not runtime semantics.
3. **Behaviour-preserving.** No refactor step changes a test result. Gate after
   each: `zig build test` + `conformance-delta` (1056/1056, 0 flips) + diff corpus,
   in **both** default and `-Djit` builds.
4. **No churn stacking.** Never combine a refactor with a feature or a perf change
   (e.g. NaN-box) in the same PR — see roadmap §6.4.

## 2. Zig 0.15 mechanics (the constraint that shapes everything)

`usingnamespace` was **removed** in 0.15 (confirmed: zero uses in the tree). So a
struct's methods cannot be scattered across files and re-injected. The supported
patterns:

- **Free function on a pointer.** Move a method body to another file as
  `pub fn doCall(vm: *BcVm, …) !…` and call it `call_ops.doCall(self, …)` from the
  struct file. The struct keeps its fields in one place; behaviour is identical.
- **Circular import is fine.** `call_ops.zig` does `@import("bc_vm.zig").BcVm`,
  `bc_vm.zig` does `@import("call_ops.zig")`. Zig resolves type+fn cycles as long
  as there is no comptime *value* cycle. (We already cross-import realm↔builtins.)
- **Hot paths stay `inline`.** Arms moved out of `runLoop` that are hot
  (arith, property, the call fast-paths) become `inline fn` so the optimizer still
  folds them into the dispatch loop — no dispatch-perf regression. Verify with the
  JIT/bench gates, not by eye.
- **Dispatch stays put.** Do *not* move opcode arms into other files wholesale; the
  `switch (op)` and its register decode stay in `bc_vm.zig`. We shrink it by moving
  *arm bodies* (the work) into helpers, not the `switch` itself.
- **Optional follow-up:** Zig 0.15 labelled-switch (`sw: switch (op) { … continue :sw next; }`)
  is a computed-goto dispatch that is faster than a `while`+`switch`. Treat as a
  **separate perf experiment** (belongs with roadmap M20), not part of this
  structural refactor.

## 3. Target module layout

```
src/vm/
  bc_vm.zig          ← BcVm struct + fields + runLoop dispatch ONLY (~800 LOC target)
  ops/
    arith.zig        ← ADD/SUB/MUL/… arm bodies (inline fn vm, …)
    property.zig     ← getProp/setProp/getPropSym/setPropSym + IC record/hit
    call.zig         ← doCall/doMethodCall/doConstruct + param/arguments binding
    closure.zig      ← NEW_CLOSURE, NFE, env setup helpers
    iterator.zig     ← for-of / iterator-result / spread
    exception.zig    ← raisePendingException / throw routing
  coroutine.zig      ← buildGenState/buildGenerator/buildAsyncFunction/resume
  jit_bridge.zig     ← tryJitCall/tryOsrLoop/resumeJitFrame/jit*Slow (already cohesive)
  frame.zig, ic.zig, isolate.zig  (unchanged)

src/runtime/
  realm.zig          ← Realm struct + init() that only *calls* registrars (~300 LOC)
  builtins/
    <name>.zig       ← each gains `pub fn register(arena, realm_ctx) !void` that
                       builds its own prototype + constructor + globals
  intrinsics.zig     ← shared helpers (defineGetter, makeCtor, native-fn .name/.length)

src/bytecode/
  compiler.zig       ← Compiler struct + compileStmt/compileExpr dispatch (~700 LOC)
  lower/
    stmt.zig         ← per-statement lowering bodies
    expr.zig         ← per-expression lowering bodies
    fn_lit.zig       ← function/arrow/class lowering (already partly separable)

src/parser/           ← (last) split parser.zig into stmt.zig / expr.zig / class.zig
```

## 4. Per-target playbook

### R1 — `realm.init` (627 → ~300 LOC)  *highest ROI, lowest risk, do FIRST*  ✅ DONE 2026-06-11
**Result: realm.zig 1742 → 1421 LOC; init 627 → ~300 LOC. All gates green both modes
(unit exit 0; conformance 1056/1056, 0 flips; default + `-Djit`).**
- `intrinsics.zig` created: `Ctx{arena, env, object_proto, function_proto}` + helpers
  (`setMethods`, `setMethod`, `makeCtor`, `defineGetter`, `defineGlobal`).
- 9 builtins now self-register via `pub fn register(ctx: *const intrinsics.Ctx)` in
  their own files: **date, math, json, regexp, es2015_collections, typed_array,
  reflect, console, promise** (promise returns `*JsObject` proto for `active_promise_proto`).
- `init` now builds shared prototypes (object/function/array/string), constructs
  `reg_ctx`, then calls each `register` in dependency order.
- Dead `registerMath` removed (superseded by `math_mod.register`).
- **Left inline (intentional):** shared-proto hub + Array/String/Number/Boolean/Function
  ctors (interleaved with proto construction) + Symbol (well-known-symbol glue hub:
  `@@iterator`→array, `@@toPrimitive`→date) + Proxy + global fns. These are the
  irreducible core / lower-ROI; the self-registration pattern is established for the rest.

### R2 — `bc_vm.runLoop` (1869 → ~600 LOC dispatch)  *highest impact*  ✅ DONE 2026-06-11
**Result: `bc_vm.zig` 4899 → 3143 LOC (-1756, -36%); `runLoop` 1864 → 103 LOC (pure
dispatch). All gates green BOTH modes (unit exit 0; conf 1056/1056, 0 flips; bench flat
within run-to-run noise).**
- 75 opcode arms extracted to 8 files under `src/vm/ops/`: `load` (13), `arith` (16),
  `compare` (10), `jump` (7), `object` (4), `property` (9), `exception` (5), `call` (11).
- Pattern: each handler is `pub inline fn op*(self: *BcVm, frame: *BcCallFrame) !?RunOutcome`
  (null = continue dispatch, some = `runLoop` returns it). `inline` makes the optimizer
  fold it back into the switch — codegen/perf identical to the old inline arms.
- `runLoop` keeps the loop preamble (gas/deadline/frame fetch), `const code`, the
  `switch (op)`, and one-line arms `.OP => if (try grp.opX(self, frame)) |o| return o,`.
- Realloc rule preserved verbatim: arms calling user code (jsAdd, doCall, getProp/setProp,
  ToPrimitive) re-fetch `self.frames.items[len-1]` after the call instead of stale `frame`.
- ~22 `BcVm` methods promoted `fn`→`pub fn` for cross-module access (doCall, getProp,
  setProp, jsAdd, throwException, doConstruct, hasProperty, …). No signatures/logic changed.
- Keep the `switch (op)` and register decode in `bc_vm.zig`.
- For each arm, extract its body to an `ops/*.zig` free function
  (`inline fn` for hot arms). Arm becomes: decode operands → call helper → continue.
- Group: arith, property (largest after dispatch), call/construct, closure,
  iterator, exception. Move the already-cohesive non-arm helpers
  (`getProp`/`setProp`/`doCall`/generators/async/proxy bridges) wholesale.
- **Perf guard:** after each group, run the bench + `-Djit` conformance. If a hot
  arm regresses, mark its helper `inline` (or leave that arm in place). Dispatch
  shape must not change.
- Sequence the move so `bc_vm.zig` always compiles between groups (move + rewire +
  gate, one group per commit).

### R3 — `compiler.compileStmt` (703) + `compileExpr` (181)  ✅ DONE 2026-06-11
**Result: `compiler.zig` 2313 → 1640 LOC (-673, -29%); `compileStmt` 698 → 25 LOC (pure dispatch).
All gates green (unit exit 0; conf 1056/1056, 0 flips).**
- 17 compileStmt arm bodies extracted to `src/bytecode/lower/stmt.zig` (757 LOC) as
  `pub fn lower*(c: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void`.
- `compileFunctionStrict` promoted to `pub fn` for cross-module access.
- `last_label_error` (file-level var) accessed as `compiler_mod.last_label_error` from stmt.zig.
- `compileStmt` is now a 25-line dispatch-only switch.
- `compileExpr` and all expression lowering remain in compiler.zig (lower/expr.zig deferred —
  compileExpr is already decomposed into ~12 named methods at 181 LOC, under budget).

### R4 — `parser.zig` (2830)  *last; it is already method-decomposed*  ✅ DONE 2026-06-11
**Result: `parser.zig` 2830 → 887 LOC (-68%); split into 4 files (887+748+1199+277=3111 total).
All gates green (unit exit 0; differential 148/148, 0 flips).**
- `parser/stmt.zig` (748 LOC): 22 statement-parsing free functions (`parseStatement`,
  `parseImportDecl`, `parseExportDecl`, `parseBlock`, `parseVarDecl*`, `parseFunctionDecl`,
  `parseIfStmt`, `parseWhile/DoWhile/ForStmt`, `parseForTail`, `parseSwitchStmt`,
  `parseReturn/Break/Continue/Throw/TryStmt`, `parseExprStmt`).
- `parser/expr.zig` (1199 LOC): 17 expression-parsing free functions + 6 file-level
  helpers (`tokenToBinaryOp`, `tokenToUnaryOp`, `tokenToAssignOp`, `parseRegexRaw`,
  `isUnparenthesizedAndOr`, `isUnparenthesizedNullish`).
- `parser/class.zig` (277 LOC): `parseClassDeclStmt`, `parseFunctionParams`,
  `parseFunctionBody`.
- `parser.zig` (887 LOC): Parser struct + all primitive helpers + `pub fn hasUseStrict`
  (hoisted to file scope for cross-module use) + thin 1-line stubs for every moved fn.
- All cross-module calls go via `self.*` stubs (no circular `pub`-value cycles).
- ~42 helpers promoted `fn`→`pub fn` for cross-module access. No signatures/logic changed.

### R5 — opportunistic  ✅ PARTIAL DONE 2026-06-11
**`test/integration_test.zig` split complete (unit exit 0; differential 148/148, 0 flips).**
- `integration_test.zig` (1744 → 32 LOC): thin orchestrator, imports 6 sub-files.
- `src/test/integration/helpers.zig` (177 LOC): all shared eval helpers + debugger/JIT helpers.
- `src/test/integration/core.zig` (427): integration, phase3a, gc, phase7 (46 tests).
- `src/test/integration/jit.zig` (343): S6/S7/S8, JIT double, Phase 9 (13 tests).
- `src/test/integration/async.zig` (249): W2, W2-async, W2 unification, await, promise (24 tests).
- `src/test/integration/esm.zig` (182): esm, snapshot (18 tests).
- `src/test/integration/es_features.zig` (384): es2016–2022, tco, debugger, source map (44 tests).
- `src/test/integration/phase13.zig` (285): phase13 (39 tests).
- Zig test discovery via `comptime { _ = @import(...); }` in orchestrator.

**`regexp.zig` (1255):** deferred — self-contained; split into `regexp/parse.zig` +
`regexp/exec.zig` only if M18 expands it.

## 5. Safety protocol (every step)

1. Move code **verbatim** (no logic edits) → compile.
2. Rewire call sites → compile.
3. `zig build test` **and** `zig build conformance-delta` **and** diff corpus, in
   **default + `-Djit`**. All green, 0 flips, or revert.
4. One module/group per commit, each independently revertible.
5. Refactor commits carry **no behaviour change** in their message — if a test moves,
   it is a bug in the move, not an intended change.

## 6. Sequencing vs the roadmap

Refactor the area **just before** the milestone that will expand it, plus two
foundational moves up front:

```
R1 realm split + intrinsics.zig   ← NOW. unblocks every future builtin + helps M15 tail
R2 bc_vm runLoop extraction       ← before M16/M17 (more opcodes) and before M20 (JIT tier-up)
R3 compiler lowering split        ← before M16 (modules add statements) 
R4 parser split                   ← with M16 (modules touch parsing)
R5 regexp/test splits             ← with M18 / anytime
```

Rationale: R1 and R2 are *force multipliers* — they make M15’s descriptor tail, M16
modules, M17 builtins, and M20 tiering each land in a focused file instead of a
mega-function. Doing them first lowers the cost of everything after.

## 7. Risks

1. **Dispatch perf regression (R2).** Mitigation: `inline fn` hot arms; bench +
   `-Djit` gate after each group; dispatch `switch` never leaves `bc_vm.zig`.
2. **Import cycles.** Mitigation: types live with their struct; ops files import the
   struct, never the reverse for *values*. If a cycle bites, hoist the shared type
   to a leaf file.
3. **Silent behaviour drift during a "pure" move.** Mitigation: move verbatim first,
   edit never in the same commit; the conformance + diff gates catch drift.
4. **Refactor competing with feature work.** Mitigation: §1.4 — never stack; a
   refactor PR and a feature PR never touch the same mega-function simultaneously.
5. **Over-splitting.** A 400-LOC cohesive file is fine. Budgets in §1 are triggers,
   not targets; do not shatter cohesion to chase a number.

## 8. Definition of done (per target)

- No file > 1500 LOC, no function > 250 LOC (dispatch arms ≤ 30).
- Every builtin self-registers; `realm.init` is a manifest.
- `runLoop`/`compileStmt` are dispatch-only.
- All gates green in both build modes, before and after, with no flips.
```
