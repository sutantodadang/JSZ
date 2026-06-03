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
4. Translate a real hot `BcFunction`'s arithmetic (`ADD`/`SUB`/`MUL`) to Cranelift IR with NaN-box unwrap + int/double type guards (next).
5. Implement one deopt path: guard fail → reconstruct bc registers from a `DeoptFrame` → jump to fallback PC in the bc VM.
6. Link the native backend into the main binary behind `--jit=experimental`; benchmark vs bc-only on `bench/fib20.zig` and Phase 6 IC benches; track regression in CI.

Run profiling-tier tests: `zig build jit`. Run native-backend tests: `zig build jit-native`.
