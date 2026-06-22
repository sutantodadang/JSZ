# M16 Phase 5 — Real ESM Linking

## Current State
- Branch: feature/mi16-phase4, commit 0bd8568
- Module-code: 524 pass / 71 fail (88.06%)
- zig build test: green
- zig build -Doptimize=ReleaseFast: green

## Phase 5 Goal
Implement real ESM linking with proper module environments and live bindings. The CJS `exports.` desugar is fundamentally insufficient for the remaining 71 failures.

## Key Approach
Replace the CJS desugar for module import/export binding resolution with a proper module environment (ModuleEnv) that supports:
1. **Import bindings** as live references (not snapshots)
2. **Export live bindings** (export { x } stays live when x changes)
3. **Star re-exports** (export * from './mod')
4. **TDZ-aware import resolution** (import { x } throws ReferenceError if x is in TDZ in the source module)
5. **Circular dependency handling** with proper instantiation order

## Design Sketch
- Create `src/runtime/module_env.zig` — Module Environment
  - Per-module env frame with import/export binding tracking
  - resolveExport(name) → binding | TDZ | NotDefined
  - resolveImport(name) → value (following the real binding chain)
- Modify `src/runtime/module.zig` buildBundle/evaluate to use ModuleEnv
- Modify namespace.zig to read from ModuleEnv instead of exports object
- Maintain the existing CJS path as fallback

## Remaining Failures (71)
~25 instn-*-bndng-* (binding semantics)
~12 export-default-*, eval-export-*
~8 TLA ordering
~7 namespace edge cases
~19 miscellaneous

## Build & Test
```
zig build -Doptimize=ReleaseFast
./zig-out/bin/test262-runner --full --summary --filter "language/module-code" 2>&1 | grep "^Test262"
zig build test  # must stay green
```

## Pitfalls
- Zig cleanup: always clean rebuild after branch switches
- Commit and push after each meaningful batch
- .class_decl NodeKind doesn't exist
- Unused function params need _ prefix
