# jsz Phase 9 — Baseline JIT (design sketch)

> Status: **profiling tier shipped** (`src/jit/`, `zig build jit`). PC hit counters at loop back-edges are wired into the bc VM; `--jit=count` profiles hot sites; `--jit=experimental` will attempt native compile once a backend exists. Native codegen (Cranelift) is still deferred.

## Goals

1. **Tier 4 (T4) hot-path compilation** — compile frequently executed bytecode functions to native code while keeping the existing bc VM as the cold/slow path and the tree-walker as a differential oracle.
2. **Type-guard deoptimization** — generated code assumes monomorphic types at guard sites (shapes, IC feedback); on guard failure, bail out to the bc VM frame and resume interpretation.
3. **Learning-first** — study how production engines tier (Ignition → TurboFan) without committing to V8 parity.

## Reference: V8 Ignition → TurboFan

V8’s pipeline is the canonical model to study:

- **Ignition** — bytecode interpreter with inline feedback collection (maps, ICs, type profiles).
- **Sparkplug** — baseline non-optimizing JIT (optional middle tier).
- **TurboFan** — optimizing compiler using sea-of-nodes IR, type speculation, and **deopt frames** that reconstruct interpreter state when assumptions fail.

jsz already has Ignition-like pieces: register bc VM, shape transitions, mono→poly→mega ICs. Phase 9 adds the TurboFan-shaped *slot* — not the full optimizer yet.

## Tiering model (proposed)

```
  Source → Parser → Bytecode compiler → BcFunction
                              │
                              ▼
                    ┌─────────────────┐
                    │  bc VM (T0)     │  always available; oracle in tests
                    └────────┬────────┘
                             │ PC hit counter ≥ threshold
                             ▼
                    ┌─────────────────┐
                    │  JitCompiler    │  emit stub machine code (T4)
                    │  (Cranelift?)   │
                    └────────┬────────┘
                             │ type guard fail
                             ▼
                    deopt → restore bc frame → continue in bc VM
```

## Backend decision: Cranelift vs custom

| Option | Pros | Cons |
|--------|------|------|
| **Cranelift** (pragmatic) | Mature codegen, cross-platform, good for learning JIT *integration* | C API / build complexity in Zig; version pinning |
| **Custom** (educational) | Full control, minimal deps | Large scope; easy to stall the project |

**Recommendation:** prototype with **Cranelift** behind a narrow ABI (ADD, RETURN, LOAD/STORE slot) before investing in a custom backend. Reassess after the first hot-function compiles and deopts correctly.

## Type-guard deopt sketch

1. At compile time, read IC/shape feedback for `GET_PROP` / arithmetic sites.
2. Emit a guard: `cmp shape(obj), expected_shape; jne deopt_trampoline`.
3. **Deopt trampoline** writes live values into a `DeoptFrame` (program counter, register file snapshot) and jumps to `bc_vm.resume(deopt_frame)`.
4. Optionally blacklist the function from JIT for N executions after repeated deopts.

## Native backend: Cranelift via a Rust cdylib (decided + shipped milestone)

Cranelift has no stable C API, and there are no maintained Zig bindings. The
linkage solution that works cleanly on Windows-MSVC:

- `jit-native/` — a small Rust crate (`cranelift-jit` 0.131) built as a
  **`cdylib`**. The Rust toolchain links every transitive dep (including the
  version-pinned `windows.*.lib` import libs) into one self-contained DLL, so
  Zig only links the tiny generated import lib (`jit_native.dll.lib`) — no need
  to reproduce cargo's `native-static-libs` list. (A `staticlib` was tried first
  but forces the foreign linker to resolve `windows.0.52.0.lib` from a
  version-pinned cargo-registry path — fragile.)
- C ABI (`jit-native/src/lib.rs`, `#[unsafe(no_mangle)] extern "C"`):
  `jsz_clif_compile_add()` / `jsz_clif_compile_const(k)` return a raw code
  pointer; `jsz_clif_available()` is a link probe. The emitting `JITModule` is
  leaked so its W^X executable mapping survives for the process.
- Zig side: `src/jit/native.zig` declares the externs, wraps the code pointers
  as `callconv(.c)` function pointers, and tests that the Cranelift-emitted
  `add`/`const` actually compute. `build.zig` `jit-native` step runs `cargo
  build --release`, links the import lib, and puts the DLL on PATH for the test
  run.
- Executable memory / W^X is handled inside `cranelift-jit` (no hand-rolled
  `mmap` needed).

Run the native backend tests: `zig build jit-native` (requires `cargo`).
This step is **not linked into the main `jsz` binary yet** — the bc VM still
runs everything; only the profiling tier (`--jit=count`) is wired into the CLI.

## Risks

- **Scope creep** — a full JIT is a multi-month project; keep milestones tiny (stub ADD, one guard, one deopt).
- **GC safepoints** — native code must poll or trap at allocation/call sites until a complete safepoint story exists.
- **Deopt correctness** — hardest bug class; lean on differential tests (tree vs bc vs jit) early.
- **Maintenance** — Cranelift churn vs hand-written backend trade-off.

## Next implementation steps

1. ✅ Wire `JitCompiler.notePcHit` into `bc_vm` (counter table keyed by function + PC; loop back-edges instrumented for JMP/JMP_IF_TRUE/JMP_IF_FALSE/JSEQ/JGE).
2. ✅ Add `--jit=off|count|experimental` CLI flag (default off); `=== JIT profile ===` printout after eval.
3. ✅ Integrate Cranelift; emit native `add(i64,i64)` + `const()->i64` and call from Zig (`jit-native/` cdylib, `src/jit/native.zig`, `zig build jit-native`).
4. ✅ **IR for a monomorphic-int hot loop + type-guard/deopt shape** (isolated, in `jit-native/`):
   - `jsz_clif_compile_count_loop()` emits real loop IR — entry → header (`i < limit` guard `brif`) → body (`iadd step`, jump back = the **back-edge**) → exit — over **unboxed `i64`**. Verified `loop(0,5000,1)==5000` (matches JS `while(i<5000)i=i+1`).
   - `jsz_clif_compile_guarded_iadd()` emits the speculative-add shape: a guard `brif` splitting into an `ok` block (`a+b`) and a `deopt` block (write `*deopt=1`, return 0). Models guard-fail → deopt without computing.
5. ✅ **Native execution wired into the live VM** (`src/jit/loop_jit.zig`): at a hot loop back-edge under `--jit=experimental`, the bc VM recognizes the canonical counter-loop opcode template, type-guards the live induction var + limit as integral numbers, and runs the remaining iterations in the count-loop kernel — then boxes the result once, writes the global, and jumps to the loop exit. Recognition/guard failure → keep interpreting (the interpreter is the correct baseline, so this is the "deopt" path; no register reconstruction needed because the back-edge is a clean bytecode boundary).
6. ✅ **Linked into the main binary** behind `-Djit=true` (build option) + `--jit=experimental` (runtime). `-Djit=true` builds the `jit-native/` cdylib and installs the Cranelift `count_loop` kernel via `root.installNativeCountLoop`; without it a **pure-Zig kernel** is used so the feature + its tests work cargo-free. Default builds/tests/CI link no Rust.

### Benchmark (first native execution of real JS)
`var i=0; while (i < 50_000_000) { i = i + 1; } i` (hot threshold 1000):

| Mode | Time | Result |
|------|------|--------|
| `--interp=bc` | ~32.6 s | 50000000 |
| `--jit=experimental` (`-Djit=true`, Cranelift) | ~0.11 s | 50000000 |

~**300×** on this loop — the interpreter pays an env-hashmap lookup per `GET_GLOBAL`/`SET_GLOBAL` each iteration; the JIT elides all of it after the loop goes hot. Correctness verified against the interpreter across large / already-past-limit / non-matching / sub-threshold loops, plus integration tests and the 94/94 differential.

### Remaining (broader JIT)
- ✅ Generalized recognition: step ≠ 1, `<=`/`>`/`>=`/descending, **register-local induction vars** (`GET_LOCAL`/`SET_LOCAL`), and **one or more accumulators** carried as `s_k = s_k +|-|* i` (`loop_jit.zig` `IndVar = global|local`, repeated accumulator blocks + `zigMultiAccLoop`; folds run in f64 in interpreter order). The single-`+`/`<` shape is **compiled to native Cranelift IR** (`jsz_clif_compile_accumulate_loop`: `fcvt_from_sint` + `fadd`, induction + f64 accumulator carried, final `i` stored through an out-pointer); `-`/`*`/non-`<` and multi-accumulator shapes run the Zig kernel. Still TODO: native variants for those, accumulator-`const` folds, and translating an **arbitrary** body to IR.
- ✅ **Deopt accounting + per-site blacklist** (`jit.zig` `noteDeopt`/`isBlacklisted`/`deopt_threshold`): hot back-edges now retry the fast-forward on every iteration (so loop **re-entry** and **late type stabilization** are caught, not just the first `became_hot`); a site that fails to fast-forward `deopt_threshold` (8) times is blacklisted and no longer retried, bounding wasted recognizer work. `JitProfile.deopts` is now live.
- **DeoptFrame** register-reconstruction for *mid-region* speculation remains TODO. NOTE: the recognize-and-elide tier does **not** need it — the loop back-edge is a clean bytecode boundary, so a failed attempt just returns null (counted as a deopt) and the interpreter resumes. A real `DeoptFrame` is only required once the JIT compiles **arbitrary** bodies.
- ✅ **Prerequisite shipped:** SMI + full WebKit NaN-box `Value` representation (see below) — numbers (int32 + doubles) and null/bool are now inline/unboxed, so native arithmetic no longer forces a heap allocation per result.

### Value representation: SMI + NaN-box (shipped)
`src/value/value.zig` now supports inline values behind comptime flags
(`enable_smi`, `enable_nanbox`, both ON):
- **SMI / int32** and **inline doubles** (WebKit offset NaN-box: `NumberTag=0xfffe…`,
  `DoubleEncodeOffset=1<<49`), plus **immediate** null/true/false — no allocation.
- `bits==0` is kept as undefined (WebKit `ValueEmpty`), so existing guards are
  unchanged; all reads decode through `unbox()`, and `isHeapPtr()`/`NotCellMask`
  gate the GC. Type guards are now bit tests, not union-tag checks.
- Verified green: `zig build test`, differential 94/94, conformance 70.71% (0 flips).

Run profiling-tier tests: `zig build jit`. Run native-backend tests: `zig build jit-native`.
