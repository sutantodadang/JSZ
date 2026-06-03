# Changelog

All notable changes to jsz will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: 0.x — anything may break. 1.0 = strict semver.

---

## [Unreleased] — Phase 9: JIT profiling tier + Cranelift native backend + Phase 8: bytecode caching + snapshot/restore

### Added
- **Phase 9 JIT profiling tier.** `JitCompiler` (`src/jit/jit.zig`) now has real counter infrastructure: `AutoHashMapUnmanaged` per-site hit counters keyed by `(func_id, pc)`, a hot set, `notePcHit`/`isHot`/`hotCount`, plus `JitMode` enum (`.off`/`.count`/`.experimental`), `HotEvent`, and `DeoptFrame` type scaffold. `compile()` always returns `NotImplemented` — Cranelift backend deferred. PC hit counters wired into bc VM loop back-edges (JMP, JMP_IF_TRUE, JMP_IF_FALSE, JSEQ, JGE); `BcVm.jit: ?*JitCompiler` field is null by default (zero hot-path cost when off). `--jit=off|count|experimental` CLI flag added (implies `--interp=bc`); `=== JIT profile ===` block printed after eval when mode != off. `JitMode`/`JitProfile` exported in `src/root.zig`; `Context.setJitMode`/`lastJitProfile` added. 5 unit tests in `jit.zig` + hot-loop integration test in `bc_vm.zig`. `zig build jit` + `zig build test` + `zig build differential` (94/94) all green.
- **Phase 9 Cranelift native backend (isolated proof).** `jit-native/` — a Rust crate wrapping `cranelift-jit` 0.131, built as a **`cdylib`** so the Rust toolchain links all transitive deps (incl. version-pinned `windows.*.lib`) into a self-contained DLL; Zig links only the small import lib. C ABI (`jsz_clif_compile_add`, `jsz_clif_compile_const`, `jsz_clif_available`) returns raw code pointers from a leaked `JITModule` (W^X mapping kept alive). `src/jit/native.zig` wraps them as `callconv(.c)` fn pointers and verifies Cranelift-emitted `add(2,3)==5`, `const(42)()==42`, etc. New `zig build jit-native` step runs `cargo build --release`, links the import lib, and runs FFI tests (green). **Not linked into the main `jsz` binary yet.** `jit-native/target/` gitignored.
- **Phase 9 steps 5+6 — native hot-loop execution wired into the live VM.** `src/jit/loop_jit.zig` `tryFastForwardLoop`: at a hot `JMP` back-edge under `--jit=experimental`, the bc VM recognizes the canonical counter-loop opcode template (`GET_GLOBAL/LOAD_K/LT/JMP_IF_FALSE` + `GET_GLOBAL/INC/SET_GLOBAL/JMP`), type-guards the live induction var + limit as integral numbers, runs the remaining iterations in a count-loop kernel, boxes the result once, writes the global, and jumps to the loop exit. Recognition/guard failure keeps interpreting (graceful deopt; interpreter is the baseline). Wired into the `bc_vm` JMP handler; `JitProfile.compiled` counts fast-forwarded loops. Linked into the CLI behind a new **`-Djit=true`** build option (builds the `jit-native/` cdylib and installs the Cranelift `count_loop` kernel via `root.installNativeCountLoop`); a **pure-Zig kernel fallback** keeps the feature + its tests working without the native backend, so default `zig build`/`test`/`differential`/CI need no Rust toolchain. **~300× on a 50M-iteration counter loop** (`--interp=bc` ~32.6s → `--jit=experimental` ~0.11s, both `50000000`). 2 integration tests (fast-forward correctness + non-matching loops left to the interpreter) + `loop_jit` unit tests; 94/94 differential unchanged.
- **Phase 9 step 4 — monomorphic-int loop IR + type-guard/deopt shape (isolated).** `jsz_clif_compile_count_loop()` emits real Cranelift loop IR — entry → header (`i < limit` guard `brif`) → body (`iadd step`, jump back = the back-edge) → exit — over unboxed `i64`; `loop(0,5000,1)==5000` matches JS `while(i<5000)i=i+1`. `jsz_clif_compile_guarded_iadd()` emits a type-guard `brif` splitting an `ok` block (`a+b`) from a `deopt` block (write `*deopt=1`, return 0). `src/jit/native.zig` adds `compileCountLoop`/`compileGuardedAdd` wrappers + tests (`jit-native` now 5/5). **Finding:** jsz `Value` is pointer-boxed (arena `JsValue` tagged union), not NaN-boxed — so the type guard is a union-tag check and native arithmetic only wins inside unboxed loop regions; an SMI/NaN-box rep is the prerequisite for broad arithmetic JIT (documented in `docs/JIT.md`).


- **Bytecode caching.** `bytecode/snapshot.zig` serializes a compiled
  `BcFunction` tree to a flat, sourceless binary image (`"JSZB"` magic + version,
  then recursively: name, source name, arity, register/local counts, strict
  flag, parameter names, code bytes, source-line table, constant pool, nested
  functions). `deserialize` rebuilds it in an arena with bounds-checked reads
  (`BadMagic`/`UnsupportedVersion`/`Truncated`) and fresh (empty) IC tables.
  Exposed as `Context.compileSnapshot(out_allocator, source)`.
- **Snapshot/restore (code image).** `Context.evalSnapshot(image)` runs a restored
  image in the bytecode VM against a fresh realm (shared `runMainBc` path). CLI
  `--emit-bytecode <path>` writes an image; `--run-bytecode <path>` loads and runs
  one. Images are portable across isolates.
- Tests: serializer round-trip, bad-magic/truncated rejection, end-to-end
  compile→restore (incl. cross-isolate, strings + closures), corrupt-image →
  exception (no crash), parseArgs for the new flags.

### Notes / limitations
- This is a *code* snapshot (startup image), not a *heap* snapshot: live objects,
  the global environment, and GC state are not captured. A full heap snapshot is
  angle-gated (PLAN §3.5 B/D) and out of scope.
- Constant pools only contain primitives; a non-primitive constant would be
  rejected with `UnsupportedConstant` (cannot occur with the current compiler).

---

## [Unreleased] — Phase 8: source maps + debugger stubs

### Added
- **Source maps.** `runtime/debugger.zig` emits a bytecode→source JSON map
  (`{version,engine,source,functions:[{name,codeSize,mappings:[{pc,line,column}]}]}`)
  by converting each opcode's recorded source byte offset (`Chunk.lines[pc]`) to
  line/column, recursing into nested function literals. Exposed as
  `root.sourceMap(...)` and the CLI `--source-map` flag.
- **Debugger protocol stubs.** `DebugSession` with working breakpoint bookkeeping
  (`setBreakpoint`/`removeBreakpoint`/`listBreakpoints`) and execution-control
  methods (`cont`/`stepOver`/`stepInto`/`stepOut`/`pause`/`stackTrace`) that
  return `error.NotImplemented` (surface only). New `DEBUGGER` opcode compiled
  from the `debugger;` statement fires a global debug hook
  (`debug.installHook`/`clearHook`); CLI `--debug` installs a hook that prints
  the pause location and implies `--interp=bc`.
- `Context`/`root` re-export the debug surface as `jsz.debug`.

### Notes / limitations
- The source map is jsz-native, not Source Map v3 VLQ (there is no generated
  text stream — a bytecode→source position table is what a bytecode debugger
  needs).
- Execution control (stepping, pause, live stack inspection) is not wired into
  the VM yet; only breakpoint bookkeeping and the `debugger;` hook are live.
- Nested-function chunks report the function name as their source name
  (pre-existing chunk quirk), so `--debug` shows e.g. `f:1:28` for inner fns.

---

## [Unreleased] — Phase 8: proper tail calls

### Added
- **Proper tail calls (ES2015 PTC)** in the bytecode VM. New `TAIL_CALL` opcode
  (same encoding as `CALL`). The compiler emits it for `return f(args);` when the
  enclosing function is strict, the call is not inside a `try`/`catch`/`finally`
  region, and the callee is a direct (non-member) expression. For bytecode-function
  callees the VM reuses the current call frame in place, giving **O(1)** call-stack
  growth for tail recursion; native/bound/object callees degrade to a normal call
  plus return. `Context.lastFrameHighWater()` exposes the bc-mode call-frame depth
  high-water mark (test/inspection hook).
- Integration tests covering strict tail recursion (`sum`), mutual tail recursion
  (`isEven`/`isOdd`), the sloppy-mode non-optimized contrast, and the `return`
  inside `try` correctness case.

### Notes / limitations
- Tree-walker is unchanged (kept as the differential oracle; uses native recursion).
- Member-call tails (`return o.m()`) and tails in ternary/logical operands are not
  yet recognized.
- Strictness is per-function (no inheritance from enclosing strict scope), so the
  `'use strict'` directive must be in the tail-recursive function's own body.

---

## [Unreleased] - Phase 0 scaffold complete.

### Added
- `src/root.zig`: public API stubs (`Isolate`, `Context`, `Value`, `EvalResult`, `NativeFn`, `NativeResult`)
- `src/main.zig`: CLI with `--version`, `--help`, `-e <expr>`, `-i`, positional script path
- Full module directory tree: `value/`, `gc/`, `lexer/`, `parser/`, `bytecode/`, `vm/`, `runtime/`, `builtins/`, `regex/`, `test/`
- Fuzz harnesses: `src/test/fuzz/parser_fuzz.zig`, `src/test/fuzz/vm_fuzz.zig`
- Test262 runner stub: `src/test/test262_runner.zig`
- Node.js differential harness stub: `src/test/differential.zig`
- `examples/hello.zig`: embed hello-world, matches README
- `build.zig`: added `fuzz`, `conformance`, `differential`, `example-hello`, `docs`, `bench` steps
- CI workflows: `ci.yml` (matrix: Linux/macOS/Windows x Debug/ReleaseSafe), `fuzz.yml` (nightly)
- Docs scaffold: `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `docs/EMBEDDING.md`, `docs/API.md`, `docs/COOKBOOK.md`, `docs/CONTRIBUTING/adding-a-builtin.md`
- GitHub issue templates + PR template
- `.gitignore`
- `LICENSE` (MIT)
