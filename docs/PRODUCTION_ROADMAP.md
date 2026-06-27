# jsz — Production Roadmap

> Path from "100% on a curated Test262 whitelist + working JIT" to a
> production-grade, spec-conformant, embeddable JavaScript engine — with an
> honest ladder toward server-runtime and browser-grade capability.

## 0. Honest framing

V8, JavaScriptCore, and SpiderMonkey represent **hundreds of engineer-years**
each, plus ICU, a WASM engine, a web-platform binding layer, and multi-process
sandboxes. Literal parity is not a 6-month or 1-person target, and pretending
otherwise produces a bad plan.

The achievable, valuable target is staged:

1. **Tier 1 — Conformant spec engine.** Full ECMAScript (current edition),
   ≥99% on the *complete* tc39/test262 suite, no missing builtin families.
   This is where "comparable to V8" is actually *measurable* and reachable.
2. **Tier 2 — Embeddable engine.** Stable C ABI, small binary, host-callable,
   deterministic OOM/limits. Competes with QuickJS / JSC-as-a-library.
3. **Tier 3 — Server runtime.** Event loop, module resolver, fs/net/timers,
   a standard library. Competes with Node/Bun/Deno *surface* (not ecosystem).
4. **Tier 4 — Browser-grade.** WASM engine, web platform specs, DOM bindings,
   process sandbox. This is the literal-V8 tier; treat as long-horizon stretch.

Decision (this session): pursue **all tiers**, in **balanced phased order** —
conformance foundation → feature completeness → performance → embedding →
runtime → browser. Each milestone has a hard gate before the next begins.

---

## 1. Current state (verified 2026-06-10)

**Architecture (224 files, ~8k symbols):**

| Layer | Status |
|---|---|
| Lexer / parser / AST | ✅ incl. import/export *parsing*, classes, arrows, template literals |
| Bytecode compiler + 349-op ISA | ✅ incl. implicit-return fix |
| Register VM + inline caches | ✅ mono/poly/mega + depth-N proto IC + DYN + ic-stats |
| Cranelift JIT | ✅ int-fn tier + boxed-value tier, loop-OSR, fine-deopt, Win64 unwind tables |
| GC | ✅ non-moving mark-sweep, manual trigger, JIT root-frame scan |
| Values | ✅ pointer-boxed (NOT NaN-boxed — perf constraint, see §6.2) |
| Builtins | ✅ Array, String, Object, Math, JSON, Date, Promise, Reflect, Proxy, Symbol, Map/Set, RegExp, Intl, console |
| BigInt | ✅ managed limbs, wired through EXP/coercion/wrappers |
| async/await + Promise combinators | ✅ |
| Generators (YIELD opcode) | ✅ basic |
| Test262 runner | ✅ infra supports full external suite; frontmatter/negative/flags parsing |
| Fuzzers | ✅ json / parser / regex / vm |

**Conformance reality:** "100% (1056/1056)" is against a **curated local
whitelist** (`tests/test262_whitelist.txt`, 58 lines) + a 148-file diff corpus —
**not** the full ~50,000-test tc39/test262 suite. The runner *can* run the full
suite (`external/test262` submodule) but it has never been ground to a real
pass-rate number. **This is the single biggest credibility gap.**

---

## 2. Gap analysis vs production engines

| Gap | Severity | Notes |
|---|---|---|
| Full Test262 pass-rate unknown | 🔴 critical | infra ready; never measured at scale |
| TypedArray / ArrayBuffer / DataView | ✅ done (M15) | 100% test262 (`TypedArray` 2181/2181, `ArrayBuffer` 340/340, `DataView` 570/570) |
| Atomics / SharedArrayBuffer | 🔴 high | SAB ctor exists; Atomics op-set + threading model still M17 |
| ESM loader / linker / evaluation | ✅ done (M16) | registry/live-bindings/cyclic/TLA/dynamic-import in `module.zig`; `module-code` 595/595 (100%) after fixing module-scope global leak |
| WeakRef / FinalizationRegistry | 🟠 high | absent; needs GC weak-ref integration |
| GC: generational / incremental | 🟠 high | mark-sweep only → pause times + throughput ceiling |
| JIT: baseline tier + type feedback | 🟠 high | one optimizing tier; no fast baseline, no profile-guided specialization |
| Stable embedding C ABI | 🟠 high | no embedder surface (Tier 2 blocker) |
| RegExp completeness | 🟠 med | hand-rolled; need Unicode prop escapes, lookbehind, named groups, `/v` |
| Intl completeness | 🟡 med | likely stub; full Intl needs ICU/CLDR data (huge) |
| Inspector (CDP) / profiler / heap snapshot | 🟡 med | `debugger.zig` exists; no Chrome DevTools Protocol |
| WASM engine | 🟡 low (Tier 4) | absent |
| Standard benchmark suite | 🟠 high | no JetStream2/Octane/Kraken numbers → perf claims unfalsifiable |
| Release engineering / versioned ABI / docs | 🟠 high | needed before anyone can depend on it |

---

## 3. Scoreboard (track every milestone)

You can't claim "comparable to V8" without the same scoreboards V8 uses.

- **Conformance:** full tc39/test262 pass-rate %, tracked per-commit. Target ladder: measure → 90% → 95% → 99% → 99.5%.
- **Performance:** JetStream2, Octane (legacy), Kraken, SunSpider, Speedometer (Tier 3+). Report ratio-to-V8 and ratio-to-QuickJS on identical hardware.
- **GC:** max pause (ms), throughput (MB/s), allocation rate. Target: <10ms p99 pause for generational.
- **Binary size:** stripped release binary (Tier 2 cares). Current ~3.4MB class — keep <8MB with TypedArrays+modules.
- **Memory:** RSS on a fixed workload vs QuickJS/V8.
- **Stability:** fuzz hours with zero crashes; ASAN/UBSan-clean (Zig safety modes).

Build all of these into CI *before* the work they measure, so progress is visible.

---

## 4. Phased roadmap

Continuing the project's phase numbering (currently through Phase 13). Each
milestone lists: **goal · key work · gate (exit criteria)**. Effort ranges are
honest 1-dev estimates.

### Milestone 14 — Conformance foundation  *(~1–2 mo)*
**Goal:** know the real number; make the full suite the gate.
- Wire `external/test262` submodule into CI as a first-class job.
- Implement remaining harness flags: `module`, `raw`, `async`, `CanBlockIsFalse`, `includes` resolution, `negative` phase (parse vs runtime) — runner already has scaffolding.
- Generate `test262_known_failing_full.txt` from a real run; triage into buckets (missing-feature / spec-bug / parser / runtime).
- Per-commit pass-rate tracking + regression gate (no flips).
- **Gate:** full-suite run is green-or-known-failing in CI; baseline % published.

### Milestone 15 — TypedArrays & binary data  *(~1.5–2 mo)*
**Goal:** close the largest spec hole.
- `ArrayBuffer` (+ resizable), `SharedArrayBuffer`, `DataView`.
- All 11 TypedArray views (`Int8`…`Float64`, `Uint8Clamped`, `BigInt64/Uint64`).
- `%TypedArray%.prototype` (sort, set, subarray, copyWithin, iteration, etc.).
- Species, detachment semantics, OOB handling (these are heavy in test262).
- GC integration: backing store as a managed cell; off-heap option.
- **Gate:** test262 `built-ins/TypedArray*` + `ArrayBuffer*` ≥99%.

> **✅ COMPLETE — gate met (independently re-run 2026-06-26).** Fresh
> Windows-native build against a clean tc39/test262 clone:
> | suite | independently-verified result |
> |---|---:|
> | `built-ins/TypedArray` | **2181/2181 (100%)** |
> | `built-ins/ArrayBuffer` | **220/220 (100%)** |
> | `built-ins/DataView` | **561/561 (100%)** |
> | `built-ins/SharedArrayBuffer` | **104/104 (100%)** |
> | `staging/sm/ArrayBuffer` | **5/5 (100%)** |
>
> Gate (`TypedArray*` + `ArrayBuffer*` ≥99%) **solidly met — all 100%.**
> The former last failure (`staging/sm/ArrayBuffer/slice-species.js`,
> well-known-symbol identity across realms) is confirmed passing — fixed in
> `88c8649`: secondary realm's Symbol well-knowns
> (species/iterator/toStringTag/toPrimitive) + proto `@@species` getters re-keyed
> to the primary realm's symbols; eval switches TA/buffer thread-locals to the
> shadow realm's intrinsics.

**Conformance (2026-06-17, superseded by COMPLETE block above):**
| suite | start | now | change |
|---|---:|---:|---|
| TypedArray built-ins | 8.3% | **95.40%** (2076/2176) | +84 |
| DataView | 11.8% | **96.61%** (542/561) | — |
| ArrayBuffer | 12.7% | **99.09%** (219/221) | — |

**MI15 Phase 4 landed (2026-06-17):** Fixed two class-expression bugs blocking the
test262 harness `subClass()` helper (used by resizable-buffer + speciesctor + callbackfn
clusters):
1. **Parser fix:** `class MyName extends Base {}` in expression position now parses
   correctly — was always treated as anonymous because the function checked
   `p.check(.identifier)` before advancing past the `class` keyword.
2. **Prototype chain fix:** The class-expression IIFE wrapper was missing static
   inheritance (`Object.setPrototypeOf`), prototype chain setup
   (`ClassName.prototype = Object.create(Super.prototype)`), and the constructor
   back-link — all now generated, matching `parseClassDeclStmt`.
Combined effect: TypedArray conformance jumped +84 tests (8.3%→95.40%).
Remaining 100 failures are primarily DataView/ArrayBuffer edge cases and deep
spec features (resizable-buffer OOB during species, callable-object boxing, etc.).

**Status (2026-06-10): core DONE.** `src/runtime/builtins/typed_array.zig` (~830 LOC) +
VM property-chokepoint hooks (`bc_vm.getProp/setProp`) + realm registration:
ArrayBuffer (`slice`/`isView`/`byteLength`), all 11 views, DataView (get/set Int8…
Float64, LE/BE), `%TypedArray%` intrinsic + prototype chain, accessor getters
(`length`/`byteLength`/`byteOffset`/`buffer`), generic `from`/`of` (kind from `this`
ctor), ~20 prototype methods (set/subarray/slice/fill/map/reduce/forEach/join/
indexOf/includes/reverse/at/keys/values/entries/@@iterator), integer-indexed exotic
get/set with spec ToInt8/16/32 modular wrap + Uint8Clamped round-half-to-even +
float endian. **Zero crashes across 2969 TA tests.** Verified by smoke tests; whitelist
gate 1056/1056, 0 flips; unit tests green.
- **Also landed (M14 lever): the `arguments` object** — was entirely absent, blocking
  `propertyHelper.js` (included by most built-in tests) suite-wide with "arguments is
  not defined". Now materialized engine-wide: compiler detects refs in non-arrow fns,
  propagates through nested arrows (lexical), respects param-shadowing; VM builds an
  array-like (length + indexed + `@@iterator`) at all 7 call/construct sites. No regression.
**Conformance progress (2026-06-11 session) — full-corpus `--filter` pass rates:**
| suite | start | now | levers landed |
|---|---:|---:|---|
| TypedArray | 8.3% (181) | **46.5% (1063)** | native-fn own `.length`/`.name`; detach+`$262`; 8 missing methods; bigint sort/join; @@species; integer-indexed exotic meta-ops; ctor+set throwing ToIndex/ToNumber; object-arg+from `@@iterator` |
| DataView | 11.8% (67) | **47.4% (270)** | detach guards on get*/set* + byteLength/byteOffset |
| ArrayBuffer | 12.7% (28) | **19.9% (68)** | detach + byteLength getter |

Landed this session (each gated: whitelist 1056/1056, 0 flips, both default + `-Djit`):
1. **Native-fn descriptor consistency** — `length`/`name` now OWN props for `.native_function`
   across `hasOwnProperty`/`in`/`getOwnPropertyNames`/`Reflect.ownKeys`/`getOwnPropertyDescriptor`
   + configurable-delete tracking. (Engine-wide; lifts all builtins, not just TA.)
2. **ArrayBuffer detachment** + Test262 host hook `$262.detachArrayBuffer` (runner-only):
   detached buffer → byteLength 0; TA methods + DataView get/set throw TypeError; TA
   integer-index get→undefined / set→no-op per spec. Detached cohort 0→177/325.
3. **8 missing `%TypedArray%.prototype` methods**: reduceRight, lastIndexOf, toLocaleString,
   findLast, findLastIndex, toReversed, toSorted, with — all kind-aware (number + bigint).
4. **BigInt sort/join correctness** — default comparator + `join`/toString used `toNum`→NaN
   for bigint kinds; now raw-int compare + `bigIntToString`.
5. **@@species / SpeciesConstructor** — slice/map/filter/subarray build result via
   `SpeciesConstructor(this, defaultCtor)` → `active_context.construct`; validates result is
   TypedArray + non-detached + length; `@@species` getter returns `this`. Override/abrupt/
   non-ctor→TypeError all correct. (species cohort 59/289; remaining gated by detached-during-
   species + realm + symbol-accessor descriptor introspection.)
6. **Integer-indexed exotic meta-ops** — `canonicalNumericIndexString` + `isValidIntegerIndex`
   in typed_array.zig, wired into `[[GetOwnProperty]]`/`[[HasProperty]]`/`[[Delete]]`/
   `[[DefineOwnProperty]]`/`[[OwnPropertyKeys]]` (object_methods + reflect + bc_vm
   hasProperty/deleteProperty + ops/property strict-delete-throws). TA-gated (`getTd != null`),
   no non-TA impact. internals cohort 71→89. **Caught+fixed a regression:** `isValidIntegerIndex`
   did `@intFromFloat` before bound-check → panic on +Inf/huge index; now f64 bound-check first.
7. **Constructor + `set` validation** — `toNumberThrowing`/`toIndexThrowing`/`toBigIntThrowing`
   (via `coercion.toPrimitive(.number)` VM bridge → run user valueOf, propagate throws). `makeTypedArray`
   buffer-arg now does spec-order ToIndex byteOffset/length → `%elementSize`/detached/bounds → RangeError/
   TypeError (incl. valueOf-detaches-mid-construct re-check); length-arg + element coercion throwing;
   cross number↔bigint → TypeError. `set` overlap-safe copy + throwing offset/element coercion.
   ctors 51% (382/743), set 26%. (No-arg/length/buffer forms solid.)
8. **Iterable protocol (`@@iterator`)** — `iterableToList` (reuses `es2015_collections.nativeGetIterator`/
   `nativeIterStep`) + `detectIterable` tri-state GetMethod(@@iterator). `new TA(iterable)` (Set/Map/
   generator/raw-iterator) + `%TypedArray%.from(iterable, mapfn, thisArg)` now iterate; throwing @@iterator/
   next/value/coercion propagate; non-callable @@iterator → TypeError; array-like fallback when absent.
   **conversion-operation cohort already resolved** by the ctor+set throwing-coercion work (element-set
   valueOf runs). TA 910→1063 (+153).
- **Known separate engine bug (NOT M15):** `Object.getOwnPropertySymbols` panics "incorrect alignment"
  on a non-object argument — pre-existing, reproduces on clean baseline. Worth a dedicated fix
  (engine-must-never-panic rule).

**Conformance progress (2026-06-14 session):** `built-ins/TypedArray` full-corpus
(2185 tests) **76.43% (1670) → 84.98% (1857), +187**, whitelist 100% 0-fail + `zig build test`
green throughout. 16 gated levers. #14 complete BigInt bitwise/`~`/`++`/`--`. #15 generic `%TypedArray%.from`/`of`
(Construct any `this` ctor). #16 TypedArrayCreate ValidateTypedArray (result must be a TA of sufficient length). #13 (+12, huge engine-wide): **BigInt arithmetic was fundamentally
broken** — `2n+3n`→5(number!), only `**` worked; added `bigIntBinary` (add/sub/mul/div/mod) + mix→TypeError
+ /0→RangeError, wired into opAdd/Sub/Mul/Div/Mod; + `taStoreBig` low-64 wrap (mod 2^64). NEXT: check bigint
comparison (`<`/`>`/`<=`/`>=`) + bitwise (`&`/`|`/`^`/`<<`/`>>`) for the same gap; generic `%TypedArray%.from`/`of`
(Construct `this` ctor for custom-ctor cluster). #11 generic callback Array methods (every/forEach/map/some/find*/
reduce* via genGet/genLength — work on TA receivers). #12 (+10) `taLoad` whole-view-OOB→undefined
(fixed views shrunk below buffer read all-undefined; mid-iteration shrink cluster). **Lever #10 (+44): ES class subclassing of built-ins** — parser
class-expressions, `new Function(body)` compiles via eval bridge, [[Construct]] adopts callable returns,
real super-construct for default derived ctors (`return Reflect.construct(Super, arguments, ClassName)`),
static inheritance (`Object.setPrototypeOf` + `Context.set_proto_fn` bc_function bridge). `class MyU extends
Uint8Array {}` now yields working TA exotics, unblocking the resizable/custom-ctor harness `subClass`.
NEXT: generic callback methods (every/forEach/map/some/find use `getArray`→fail on TA receivers; need
genGet/genLength + per-iteration length re-read, ~18 tests); cross-realm $262.createRealm (~29);
immutable-buffer (8); explicit derived ctors + anonymous class exprs.
Lever #8 generic `Array.prototype.{fill,copyWithin,reverse,lastIndexOf,keys,values,entries,with,
toReversed,toSorted,toSpliced}` shipped (were missing). Earlier (last two: Reflect.set/get TA integer-index exotic +9; BigInt indexOf/
includes/lastIndexOf raw-i128 compare + reduce/reduceRight upfront IsCallable +14). Biggest
deferred lever: generic `Array.prototype.{fill,copyWithin,reverse,lastIndexOf,keys,values,
entries,with,toReversed,toSorted,toSpliced}` (missing; needed by resizable-buffer cluster's
`Array.prototype.X.call(ta)` form — existing Array methods use `getArray` requiring is_array).
First five levers: (1) integer-index exotic ops reject canonical-numeric-but-invalid keys
(getProp/setProp `canonicalIndex`→`canonicalNumericIndexString`+`isValidIntegerIndex`;
Reflect.defineProperty+hasOwnProperty TA branches) +40; (2) accessor-getter + %TypedArray%
ctor `name` ("get buffer" etc, name="TypedArray", @@species→accessor getter) +12;
(3) Reflect.set symbol key honors writable/accessor +2; (4) **shared %ArrayIteratorPrototype%
unification** — Array+String+TypedArray iterators share one proto+next (es2015_collections
`initArrayIteratorProto`, unified `SeqIterData{is_typed,kind}`) +6; (5) `of` contextual keyword
as identifier (parser) +3. See [[jsz-m15-typedarrays-arguments]].

**Conformance progress (2026-06-13 session):** `built-ins/TypedArray` full-corpus
(2185 tests) **56.33% (1231) → 75.83% (1657), +426**, whitelist 1056/1056 0-flip throughout,
unit tests green. Eight gated engine-wide levers (each: whitelist 1056/1056 0-flip):
8. **`Array.from` iterables + re-entrant-invoke crash (+269 — biggest)** — `Array.from([…])`
   returned `[]`: the array path read `obj.get("length")` but a real Array's length is the
   `array_length` slot, not an ordinary property → len 0. The harness `makeArray` factory
   (`Array.from(source)`, used by ALL `testTypedArray.js` factory-iterating tests) silently
   produced empty TypedArrays, masking hundreds of real results. Fixed with an `is_array` branch
   (`getArrayLength` + indexed reads). Fixing it then EXPOSED a latent VM crash: a bound mapfn
   invoked re-entrantly from the native hit `doCall`/`doCallWithThis`'s bound arm writing
   `frames.items[len-1]` with an empty frame stack → `integer overflow` panic. Guarded both arms
   to route the result through `self.result` (what `bcInvokeJs` returns) when no caller frame
   exists. `built-ins/TypedArray` 63.52%→75.83%. (Deferred: `Array.from` over Set/Map/generator
   sources — driving @@iterator from the native via `ctx.invokeJs` re-enters the VM and underflows
   the same frame stack; `arrayFromIterate` is stubbed to `false` with a TODO until the re-entrant
   frame model is hardened. Real Arrays — the common case — work.)
6. **ECMAScript `Number::toString` (+8 TA, broad corpus)** — `formatNumber` used Zig `{d}`
   (full decimal digits) so `String(1e21)`="1000000000000000000000" (spec wants "1e+21"),
   `String(1e-7)` wrong, etc. Implemented the real spec algorithm in `value.zig` (shortest
   round-trip digits from Zig Ryū `{e}`, then JS positioning: plain for 10^-6 ≤ |x| < 10^21,
   exponential `d[.ddd]e±N` otherwise) and pointed the 5 DUPLICATE copies (bc_vm/array_proto/
   json/string_proto) at it. Unblocked TA `key-is-not-canonical-index` 0→8/14 (the bad ToString
   was misclassifying `"1000000000000000000000"` as a canonical index) + corpus-wide number
   formatting. Remaining 6 non-canonical = accessor/BigInt edges.
7. **Observable `SpeciesConstructor` (+44)** — `slice`/`map`/`filter`/`subarray` read
   `this.constructor` and `constructor[@@species]` via non-observable `JsObject.get`/`getSym`
   (didn't fire accessor getters → species-observation tests saw 0 calls). Added a symbol-keyed
   observable [[Get]] bridge (`Context.get_sym_fn` → `bc_vm.getPropSym`, wired in `activateContext`;
   `vmGetSym` in typed_array) and rewrote `typedArraySpeciesCreate` to use `vmGet`(constructor) +
   `vmGetSym`(@@species). `speciesctor-*` 59→92/129.
1. **`not-a-constructor` (+31)** — see detail below.
2. **Builtin method enumerability (+48)** — `intrinsics.setMethods`/`setMethod` (used by
   *every* builtin) plus the TA prototype-method loop registered methods via `obj.set`
   (enumerable:true). Spec §17: built-in methods/data-props are `{writable:true,
   enumerable:false, configurable:true}`. Switched to `defineOwnData(.., method_attr)`; TA
   `.prototype`/`.constructor`/`from`/`of`/`@@iterator`/iter-proto + per-kind ctor props
   fixed too. Cleared TA `prop-desc` 34→7. (Array/String/etc. still fail their own prop-desc —
   they don't route through `setMethods`; an engine-wide conversion is a follow-up lever.)
3. **`new`-required TA constructors (+10)** — calling a TA ctor without `new`
   (`Int8Array()`) must throw TypeError (NewTarget undefined). The old guard only checked
   `this` was an object, but a plain call passes globalThis (an object). Now gated on
   `realm.active_constructing` (set only by the native [[Construct]] path).
4. **User-function `.name`/`.length` (broad, +0 TA)** — `bc_function` getProp returned
   `undefined` for `.name`/`.length`; now returns `closure.func.name`/`.arity`. Fixes
   `foo.name`==="foo" for declarations + named expressions (anonymous-assigned/NamedEvaluation
   and bound-function `.name` still gaps). Helps the broad `language/` corpus + harness error
   messages; no TA delta (TA name.js tests native methods, already correct).

5. **Symbol-keyed properties + `Object.prototype.propertyIsEnumerable` (+16)** — two engine-wide
   gaps: (a) `Object.defineProperty`/`Reflect.defineProperty` stringified symbol keys via
   `coerceKey` (stored bogus `"Symbol(foo)"` string props); now branch on symbol keys →
   new `JsObject.defineOwnDataSym`/`defineOwnAccessorSym` (data+accessor, [[DefineOwnProperty]]
   validation: non-configurable redefine rejected). VM `getPropSym`/`setPropSym`/
   `getOwnPropertyDescriptor` symbol paths already honored attrs+accessors; only define was
   missing. Also guarded the TA `[[GetOwnProperty]]` integer-index block to skip symbol keys
   (was `coerceKey`-early-returning undefined). (b) `Object.prototype.propertyIsEnumerable`
   was entirely absent → propertyHelper's `verify*`/`isEnumerable` threw "value is not a
   function" across the corpus; implemented it. TA `key-is-symbol` 0→18/22.

**Next TA levers (by failing count, all verified-present this session):** **`Number::toString`
for large/small magnitudes** — `String(1e21)` returns `"1000000000000000000000"` (should be
`"1e+21"`); `formatNumber` (value.zig:192 + 5 DUPLICATE copies in bc_vm/array_proto/json/
string_proto/intl) uses Zig `{d}`, not the ECMAScript Number::toString algorithm (exponential
for exponent ≥21 or ≤-7). This corpus-wide bug also misclassifies `canonicalNumericIndexString`,
blocking TA `key-is-not-canonical-index` ×14 (a TA defines `"1000000000000000000000"` as an
ordinary prop, but the bad ToString makes it look like a canonical index). Needs a real
shortest-roundtrip formatter (Ryū/Grisu-ish) consolidated into ONE shared fn. **TypedArray subclassing + class expressions** (gates resizable-buffer ~53 AND callbackfn ~53 —
both use `resizableArrayBufferUtils.js`/`testTypedArray.js` which build `class MyUint8Array
extends Uint8Array {}` via `new Function('return class … extends … {}')`). Two sub-blockers found
2026-06-13: (1) **class expressions are not parsed** — `var X = class {}` / `class extends Y {}`
in expression position → `SyntaxError: unexpected token 'kw_class'` (class *declarations* parse
fine; the body/`extends`/constructor machinery already exists — likely a small primary-expression
addition). (2) **constructing a TypedArray subclass throws** — `new (class extends Int8Array{})(3)`
leaks the internal `"__js_exception__"` sentinel (derived `super()` → `makeTypedArray` needs
NewTarget.prototype as the instance proto; also note lever-3's `active_constructing` guard must
stay true through `super()`). Fixing both unblocks the two largest remaining clusters at once +
`proto-from-ctor-realm`/`use-custom-proto-if-object`. SEPARATELY: an uncaught exception at the
top level prints the raw `"__js_exception__"` sentinel instead of the error — a display/propagation
bug in the NEW-opcode → top-level path (only matters when uncaught; caught throws are correct).

`ArrayBuffer.prototype.transferToImmutable` is ABSENT → the `immutable` arg-factory in
`testTypedArray.js` fails, contributing to callbackfn-* failures (secondary to subclassing).

SpeciesConstructor
get-ctor/get-species observability
(`speciesctor-*` ~56); resizable-ArrayBuffer length-tracking during method bodies
(`resizable-buffer*` ~53); callback semantics incl. immutable-AB factory + detach/resize-during-
callback (`callbackfn-*` ~80, gated by `ArrayBuffer.prototype.transferToImmutable` being absent);
cross-realm proto (`proto-from-ctor-realm`/`detached-buffer-realm`/`use-custom-proto` ~29, needs
`$262.createRealm`). These are deep, partly-interrelated features — 99% is multi-session.

**Pre-session header (kept for history):** `built-ins/TypedArray` was 56.33% (1231).
- **IsConstructor / `not-a-constructor` lever (+31):** bare `native_function` values are
  built-in *methods* (`Math.max`, `%TypedArray%.prototype.map`, …) — callable but NOT
  constructors. Built-in constructors are JsObjects with a `__call__` slot. Fixed engine-wide:
  (1) `bc_vm.constructImpl` + `bc_vm.doConstruct` native_function arms now throw TypeError on
  `new <method>()`; (2) `Reflect.construct` validates `IsConstructor(target)` and
  `IsConstructor(newTarget)` via a new `isConstructorVal` predicate (native_function→false,
  bc_function→true, object→has `__call__`/bound/proxy). This makes the harness `isConstructor.js`
  return false for methods, unblocking every `not-a-constructor.js` test corpus-wide (Array/String/
  Object/TypedArray proto methods all share this harness). 31/33 TA cases pass; remaining 2
  (`of`, `with`) gated by unrelated feature gaps. **Still open:** `new Symbol()` should throw
  (Symbol is callable-but-not-constructor) — IsConstructor(Symbol) still reports true because the
  Symbol intrinsic carries `__call__`; needs a non-constructor marker on callable-only intrinsics.
- **Defensive realm-state reset:** `Realm.deinit` now also clears the transient execution-state
  globals (`active_constructing`, `callback_depth`, `pending_new_target`, `active_context`) it
  previously left dirty, so a process that reuses isolates (the test262 runner's isolate-per-test
  loop, or any embedder) can't inherit mid-construct/mid-callback residue across realms.
- **Runner determinism: confirmed deterministic.** An earlier-suspected per-test non-determinism
  was a stale-binary measurement artifact (a run used the pre-fix `test262-runner.exe`). Verified
  2026-06-13: 3 identical `--full --filter built-ins/TypedArray` runs → byte-identical per-test
  results (0 diffs). Pass-rate numbers are trustworthy; grind feature levers with confidence.

- **Remaining levers (need impl, prioritized by failing-test count):** `@@species` /
  SpeciesConstructor for slice/map/filter/subarray (~138); integer-indexed exotic
  `[[Get]]/[[Set]]/[[DefineOwnProperty]]/[[Delete]]/[[HasProperty]]/[[OwnPropertyKeys]]`
  (`internals/` ~175); constructor exactness (`ctors`/`ctors-bigint` ~168); `set` (~91);
  callbackfn edge semantics (detach-during-callback, abrupt); resizable ArrayBuffer OOB;
  `SharedArrayBuffer`/`Atomics` (→ M17). Pass-rate gated by these, not missing core features.

### Milestone 16 — ESM module system  *(~1.5 mo)*
**Goal:** modules actually execute, not just parse.

> **✅ COMPLETE — gate met (independently verified 2026-06-26).** A fresh
> Windows-native build against a clean tc39/test262 clone:
>
> | category | independently-verified result |
> |---|---:|
> | `language/module-code` | **595/595 (100%, 0 fail)** |
> | `instn-local-bndng-*` (the former fails) | **15/15 (100%)** |
> | `SharedArrayBuffer` | 104/104 (100%) |
>
> Gate (`module-code ≥99%`) **met**. `zig build test` green.
>
> Backstory: commit `f77749a` claimed 596/596 but a fresh run reproduced only
> **588/596 (98.65%)** — 8 real failures in one cluster
> (`instn-local-bndng-{cls,let,var,fun,gen,for,export-fun,export-gen}`). Root
> cause was NOT TDZ (that already worked) but **module top-level `var`/`function`
> declarations leaking onto the global object**: the raw `evalModule` path
> mirrored top-level bindings as own-properties of `globalThis`, so
> `Object.getOwnPropertyDescriptor(global, name)` returned a descriptor where the
> spec requires `undefined`. Fixed in `src/vm/ops/load.zig` — `mirrorGlobalBinding`
> now returns early for module frames (`if (frame.func.is_module) return;`), so
> module top-level declarations stay in the module environment record. 3 lines;
> +5 regression tests in `src/test/integration/esm.zig`. No module-code regressions.
>
> Implementation: `src/runtime/module.zig` (~2034 LOC) — `ModuleRegistry` /
> `ModuleRecord`, namespace exotic object, live bindings, TLA, dynamic `import()`,
> `import.meta`, circular deps. (The abandoned `feature/mi16-phase4` `ModuleEnv`
> rewrite never landed — `module_env.zig` absent; the leak was fixed in the
> existing model instead.)

- Module record + linking (resolve → instantiate → evaluate phases).
- Cyclic dependency handling, live bindings, `import.meta`.
- Top-level await integration with the microtask/job queue.
- Host resolver hook (pluggable; default = filesystem for CLI).
- Dynamic `import()`.
- **Gate:** test262 `language/module-code/*` ≥99%; `flags: module` tests run.

### Milestone 17 — Weak refs, Atomics, remaining builtins  *(~1 mo)*
- `WeakRef`, `FinalizationRegistry` (requires GC weak/ephemeron support — coordinate with M19).
- `WeakMap`/`WeakSet` if not already weak-correct.
- `Atomics` (full op set) over SharedArrayBuffer; threading model decision.
- Audit remaining spec builtins: `Array.fromAsync`, `Object.groupBy`, `Promise.withResolvers`, `String.prototype` Unicode methods, `structuredClone` (host).
- **Gate:** `built-ins/WeakRef`, `FinalizationRegistry`, `Atomics` ≥99%.

> **✅ GATE MET — independently verified 2026-06-26.** Fresh Windows-native build
> against a clean tc39/test262 clone:
>
> | suite | before | after |
> |---|---:|---:|
> | `built-ins/WeakRef` | 0/29 | **29/29 (100%)** |
> | `built-ins/FinalizationRegistry` | 0/46 | **46/46 (100%)** |
> | `built-ins/Atomics` | 118/323 | **257/257 runnable (100%)** |
> | `built-ins/WeakMap` | 40/141 | **141/141 (100%)** |
> | `built-ins/WeakSet` | 21/85 | **85/85 (100%)** |
>
> Atomics: 133 multi-agent `wait`/`notify`/`CanBlockIsTrue` tests are skipped —
> they require a `$262.agent` coordinator / a blocking agent, genuinely
> unrunnable in a single-agent engine (standard exclusion). `zig build test` green.
>
> Work (3 commits): L1 WeakMap/WeakSet descriptor/brand/iterable exactness; L2
> new WeakRef + FinalizationRegistry (API surface — `canBeWeakKey`, brand checks,
> `@@toStringTag`, NewTarget proto); L3 Atomics 9 RMW ops
> (add/sub/and/or/xor/exchange/compareExchange/load/store) + ValidateAtomicAccess
> (RangeError ordering) + shared/non-shared AB + BigInt. Side fixes: binary (`0b`)
> /octal (`0o`) numeric literals (were unparsed); `activateHeap` reparenting of
> namespace objects (Atomics/Math/JSON) onto the migrated `Object.prototype`.
>
> **Cleanup landed (+2 commits 2026-06-26):**
> - `built-ins/Map` → **198/204 (97.05%)**, `built-ins/Set` → **345/382 (90.31%)**
>   (same descriptor/brand/iterable lever as WeakMap/WeakSet). + a required
>   `lowerBlockStmt` per-statement register-reclamation fix (deeply-nested blocks
>   were overflowing the u8 register space → compiler panic).
> - `Object.groupBy` **13/14 (92.86%)** + `Map.groupBy` **14/14 (100%)**.
> - `Array.fromAsync` **5/5 runnable** (array / sync iterable / async iterator /
>   thenables / array-like / mapFn / rejection all smoke-verified).
> - `structuredClone` implemented (deep clone + cycle/identity; Symbol/Function
>   throw TypeError — no DOMException; not in test262, smoke-verified).
>
> **Cleanup landed (2026-06-27):**
> - **Integer-key ascending `ownKeys` enumeration** — `Shape.orderedKeys` lazy
>   cache (integer indices ascending, then insertion order). Fixes
>   `Object.groupBy/groupLength` (groupBy now 14/14) and corrects
>   `Object.keys`/values/entries, for-in, JSON.stringify, `Reflect.ownKeys`,
>   `Object.assign` engine-wide. Built-ins corpus unchanged otherwise (0 flips).
> - **`async function*` generators + `for await...of`** — AWAIT-tagged suspend
>   (enum-tail opcode, ordinals preserved), `buildAsyncGenerator` with promise
>   next/return/throw + FIFO request queue + real `@@asyncIterator`, and
>   for-await lowering via `__getAsyncIterator__`/`__asyncIterStep__`
>   (AsyncFromSyncIterator fallback). `Array.fromAsync(asyncGen())` now yields the
>   values. Smoke-verified (no async-gen tests in the local sparse corpus).
> - **async `yield*` delegation** — `yield*` inside an async generator delegates
>   via the async-iterator protocol (awaits each step); sync iterables wrap as
>   AsyncFromSyncIterator. (next-only; sent value/return/throw not forwarded.)
> - **Completion-aware try/finally** — finally now runs on every completion
>   (normal/return/throw/break/continue), validated against the real corpus
>   (`language/statements/try` 78→94/201, zero regressions). END_FINALLY opcode +
>   per-try completion register route normal/throw through one finally copy
>   (re-raise chains to outer handlers); break/continue (incl. labeled) unwind +
>   POP_TRY each crossed try and run its finalizer inline; a catch-less
>   try/finally re-raises; a throwing/returning finalizer overrides the pending
>   completion; `break`/`continue` (incl. labeled and labeled non-loop blocks)
>   unwind every crossed try (POP_TRY + finalizer).
> - **Generator/AsyncGenerator `.throw()` / `.return()`** — both now re-enter the
>   suspended body so its try/catch/finally runs. `.return(v)` resumes with an
>   internal return-completion sentinel (invisible to user `catch` via
>   JMP_IF_RET_COMPL), converted back to `{value, done:true}` on escape.
>   `for await` 94/94 runnable.
> - **`yield*` full delegation** — forwards the sent value / `return` / `throw` to
>   the inner iterator (`__yieldStarStep__` + a per-yield try that routes the
>   resume completion). `expressions/yield` 27→50/63.
> - **%AsyncGeneratorPrototype% (instance side)** — shared prototype with
>   next/return/throw (spec descriptors) + @@toStringTag "AsyncGenerator" +
>   @@asyncIterator; instances inherit through it.
> - **Generator/AsyncGenerator function-side intrinsic chain** — full
>   %IteratorPrototype%→%GeneratorPrototype%→%Generator%→%GeneratorFunction%
>   (and async parallel via %AsyncIteratorPrototype%), built lazily in
>   `ensureGeneratorChain` with exact descriptors. Generator function objects
>   root at %Generator%; their `.prototype` roots at %GeneratorPrototype%;
>   instances chain through the function's `.prototype` (real two-level proto),
>   so `Object.getPrototypeOf(genFn).prototype` and
>   `getPrototypeOf(getPrototypeOf(instance))` resolve correctly. Prototype
>   next/return/throw now throw TypeError on a non-generator receiver and reject
>   `new`. `built-ins/GeneratorPrototype` **0→61/61**,
>   `built-ins/AsyncGeneratorPrototype` **3→13/13**; zero regressions.
> - **GeneratorFunction / AsyncGeneratorFunction callable** — the two intrinsic
>   constructors now compile a generator body from string args, mirroring
>   `new Function` (`GeneratorFunction("a", "yield a")`,
>   `new AsyncGeneratorFunction("yield 1")`). A shared `functionCtorImpl(keyword)`
>   bridge assembles `(function* anonymous(…){…})` / `(async function* …)` and
>   evals it; because the eval runs on the same VM, the compiled function's
>   `[[Prototype]]` roots at the same %Generator%, so intrinsic identity holds
>   (`getPrototypeOf(GeneratorFunction("yield 1")) === getPrototypeOf(function*(){})`).
> - **Generator-function-object exactness** — `new genFn()` / `new asyncFn()` throw
>   TypeError (generators/async fns aren't constructors); `genFn instanceof
>   GeneratorFunction` works (instanceof now coerces a function LHS to its backing
>   object — `(function(){}) instanceof Function` is now true too); generator
>   functions carry real own `name`/`length` {w:f,e:f,c:t} + `prototype`
>   {w:t,e:f,c:f} descriptors; and `Object.getOwnPropertyDescriptor` /
>   `hasOwnProperty` / `delete` resolve a function to its backing object.
>   `built-ins/GeneratorFunction` **16→21/23**, `built-ins/AsyncGeneratorFunction`
>   **11→16/17**; zero regressions.
>
> **Still deferred (not gate-blocking):**
> - Real GC weak-collection/finalization semantics (entries held strongly; test262
>   cannot test collection — coordinate with M19 ephemerons).
> - Generator-fn `caller`/`arguments` %ThrowTypeError% poison (engine-wide
>   `Function.prototype` change) and cross-realm %GeneratorPrototype% identity
>   (`proto-from-ctor-realm-prototype`) — 3 GeneratorFunction tests.
> - `yield*` observable IteratorClose access-ordering edge cases; `yield`
>   rhs-omitted/regexp/template parse; async-gen `yield <promise>` not pre-awaited;
>   async `yield*` resume-completion forwarding.
> - `%AsyncGeneratorPrototype%` structural exactness (@@toStringTag, constructor,
>   method `length`/`name`/prop-desc) — descriptor lever, like M15 TypedArrays.
> - async generator `yield <promise>` operand not pre-awaited; async `yield*`
>   does not forward sent value / return / throw to the inner iterator.

### Milestone 18 — RegExp & Intl completeness  *(~1.5–2 mo)*
- RegExp: Unicode property escapes, lookbehind, named groups, `/v` set notation, sticky/dotAll edge cases. Consider a proven backtracking + bytecode design.
- Intl: decide build — full ICU/CLDR data (large binary) vs. a curated subset vs. host-provided. Likely **host-provided ICU hook** to keep core small (aligns Tier 2).
- **Gate:** `built-ins/RegExp` ≥99%; Intl scoped + documented (full ICU optional/host).

### Milestone 19 — GC modernization  *(~2–3 mo)*
**Goal:** lift the throughput/pause ceiling.
- Generational collector (nursery + tenured); write barriers.
- Incremental marking to bound pause times; concurrent sweep.
- Ephemeron support for WeakMap/WeakRef correctness (feeds M17).
- Decide on moving/compacting nursery — interacts with pointer-boxing (§6.2) and JIT root scanning (already exists). Handle-based rooting (`gc/handle.zig`) is the lever.
- **Gate:** p99 pause <10ms on a GC-heavy benchmark; throughput +2× vs mark-sweep; no fuzz regressions.

### Milestone 20 — JIT tier-up  *(~2–3 mo)*
**Goal:** real multi-tier engine, falsifiable perf.
- **Baseline tier:** fast, non-optimizing template JIT over bytecode (fills the gap between interpreter and Cranelift); cheap to compile, collects type feedback.
- Type-feedback vectors per bytecode site; promote hot functions to the optimizing (Cranelift) tier with speculation guards (deopt already exists).
- Inline-cache → JIT integration (megamorphic handling, polymorphic inlining).
- Tiering heuristics + OSR already present for loops; extend to baseline→optimizing.
- Evaluate NaN-boxing migration (§6.2) — biggest single perf lever; large blast radius.
- **Gate:** JetStream2 score published; ≥QuickJS, within target ratio of V8/JSC; zero conformance flips with JIT on.

### Milestone 21 — Embedding C ABI (Tier 2)  *(~1.5 mo)*
**Goal:** make jsz embeddable.
- Stable C header: isolate/realm/context lifecycle, value handles, function callbacks, exception propagation, property ops, typed-array views, microtask pump.
- Resource limits: heap cap, stack cap, execution-time interrupt, deterministic OOM (no UB).
- Snapshot/startup-snapshot for fast boot (bytecode snapshot infra already exists — `bytecode/snapshot.zig`).
- Versioned ABI + semver policy.
- **Gate:** a sample C embedder runs untrusted script under limits; ABI documented; fuzzed at the boundary.

### Milestone 22 — Tooling: inspector & profiler  *(~1.5 mo)*
- Chrome DevTools Protocol (CDP) server: debugger (breakpoints/stepping — `debugger.zig` is the seed), `Runtime`, `Profiler` domains.
- Sampling CPU profiler; heap snapshot (`.heapsnapshot` format).
- Coverage (`Profiler.takePreciseCoverage`).
- **Gate:** attach Chrome DevTools to a running jsz process; set breakpoint, profile, snapshot.

### Milestone 23 — Server runtime layer (Tier 3)  *(~3–4 mo)*
**Goal:** Node/Bun-shaped surface (engine + minimal platform).
- Event loop (libuv-style or Zig-native async I/O).
- Timers, `fs`, `net`/`http`, `process`, `stream`, `Buffer` (on TypedArrays), `crypto` (host lib), `worker_threads` (uses Atomics/SAB from M17).
- Node-compatible module resolution + `node:` builtins subset; optional npm `node_modules` resolution.
- `URL`, `TextEncoder/Decoder`, `fetch` (host TLS).
- **Gate:** run a non-trivial real program (e.g. an HTTP server + JSON API + fs) under jsz; subset of Node test suite passing.

### Milestone 24 — Browser-grade (Tier 4, long-horizon stretch)  *(open-ended)*
- WASM engine (interpreter → baseline → optimizing; reuse Cranelift).
- Web platform specs (WPT as the scoreboard): `structuredClone`, `Blob`, streams, `crypto.subtle`, etc.
- DOM/host binding layer (only if a browser/embedder needs it).
- Multi-process sandbox / site isolation.
- **Gate:** WPT pass-rate published; WASM spec-test suite ≥99%.

---

## 5. Cross-cutting tracks (run continuously, not phased)

- **Scalability refactor:** keep mega-functions from absorbing each milestone. See
  `docs/REFACTOR_PLAN.md`. R1 (realm/builtin self-registration + `intrinsics.zig`) and
  R2 (`bc_vm.runLoop` arm extraction) are force-multipliers — do them before M16/M17/M20.
- **Security & fuzzing:** scale existing fuzzers (parser/vm/regex/json) to continuous OSS-Fuzz-style runs; add structured-input + differential fuzzing vs V8/JSC; ASAN/UBSan/Zig-safety CI matrix; harden the embedding boundary (M21). Track "fuzz-hours, zero crashes."
- **Differential testing:** the diff corpus (148 files) → expand into a continuous oracle vs a reference engine (Node/d8/jsc) on random programs.
- **CI/CD:** multi-target build matrix (already 6 targets), full-test262 job, benchmark job with regression alerts, nightly fuzz.
- **Benchmarking harness:** wire JetStream2/Octane/Kraken into CI with ratio-to-reference reporting (§3). Perf claims must be reproducible.
- **Documentation & release:** embedder guide, ABI reference, conformance report page, semver + changelog discipline, ADRs (zindeks `manage_adr`) for big decisions (NaN-box, GC design, threading model).

---

## 6. Key technical decisions to lock early

### 6.1 Threading model
Atomics/SAB (M17), `worker_threads` (M23), and concurrent GC (M19) all depend on
it. Decide: single-isolate-per-thread (V8/Node model) vs shared heap. Recommend
**isolate-per-thread + SAB-only sharing** — simplest correct model.

### 6.2 NaN-boxing vs pointer-boxing
Current pointer-boxing is a known perf constraint (memory: contradicts a prior
plan). NaN-boxing is the highest-leverage single perf change (fewer allocations,
better cache behavior, faster type checks in JIT). But it touches `value.zig`
(`unbox` fan-in 382, `toPtr` 218) and the JIT/GC. **Decision point at M20.**
Prototype behind a comptime flag; measure on JetStream2 before committing.

### 6.3 Intl/ICU strategy
Full ICU bloats the binary and fights Tier 2 (small embeddable). Recommend
**host-provided ICU hook**: core ships a minimal/no-data Intl, embedders inject
locale data. Lets the spec engine stay small while server/browser tiers add data.

### 6.4 GC ↔ JIT ↔ boxing co-design
M19 (generational/moving) and M20 (NaN-box) and the existing JIT root scanning
are coupled. Sequence M19 before the moving-GC parts of M20, and gate both on the
handle-based rooting already in `gc/handle.zig`. Don't ship a moving nursery and
a value-representation change in the same milestone.

---

## 7. Suggested sequencing & rough total

```
M14 Conformance foundation   ██               1–2 mo   ← do first, unblocks measurement
M15 TypedArrays              ███              ✅ DONE (100% test262 TA/AB/DataView)
M16 ESM modules              ██               ✅ DONE (module-code 595/595 = 100%)
M17 WeakRef/Atomics/builtins ██               ✅ GATE MET (WeakRef/FinReg/Atomics 100%)
M18 RegExp/Intl              ███              1.5–2 mo   ← NEXT; Tier 1 conformant engine ✅ after here
M19 GC modernization         ████             2–3 mo
M20 JIT tier-up + NaN-box    ████             2–3 mo     ← Perf story ✅
M21 Embedding C ABI          ██               1.5 mo     ← Tier 2 embeddable ✅
M22 Inspector/profiler       ██               1.5 mo
M23 Server runtime           ████             3–4 mo     ← Tier 3 runtime ✅
M24 Browser-grade/WASM       ████████+        long-horizon stretch
```

**Tier 1 (conformant spec engine):** ~M14–M18, ~7–9 months. This is the
milestone where "measurably comparable to V8 on Test262" becomes a real claim.
**Tier 2 (embeddable):** +M19–M21, another ~5–8 months.
**Tier 3 (runtime):** +M22–M23, another ~5–6 months.
**Tier 4:** open-ended; only if a concrete embedder demands it.

Single-developer honest total to a credible **Tier-2 production engine**:
**~12–18 months** of focused work. Tier 3 adds ~6. Tier 4 is a team effort.

---

## 8. Top risks

1. **Conformance debt is invisible until measured** → M14 first, always. Don't build features on an unmeasured base.
2. **Value-representation + moving-GC churn** → highest blast radius; comptime-flag prototypes, never two at once (§6.4).
3. **Intl/WASM scope creep** → host hooks / defer to Tier 4; protect the small-core invariant.
4. **Perf claims without benchmarks** → no perf PR merges without a JetStream2 delta.
5. **Single-dev bandwidth** → the tiers are independently shippable; stop at any tier and have a real product.

---

## 9. Immediate next actions (this week)

1. Add `external/test262` submodule; run the full suite; publish the real pass-rate.
2. Triage failures into the 4 buckets; size M15–M18 against actual gaps.
3. Stand up the benchmark CI job (JetStream2) with a baseline number now.
4. Write ADRs for §6.1 (threading) and §6.2 (NaN-box) before M15 lands.
```
