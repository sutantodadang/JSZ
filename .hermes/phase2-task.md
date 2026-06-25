# M16 Phase 4 - Phase 2: Import Binding TDZ

## Context
JSZ at /home/sutanto/JSZ, branch feature/mi16-phase4. Current baseline: 516 pass / 80 fail on module-code full corpus (was 515/81 — Phase 1 namespace fixes).

## The Problem: No Import TDZ (~25 failing tests)

ES spec says import bindings are in Temporal Dead Zone until the source module's evaluation completes. Accessing them before initialization must throw `ReferenceError`.

**Current desugar**: `import {x} from 'm'` → `var __esm_N = require('m'); var x = __esm_N.x;`
This creates a `var x` which is hoisted as `undefined`, not in TDZ. So tests that try to access `x` before the module is evaluated get `undefined` instead of a `ReferenceError`.

## Approach 1: TDZ sentinel flag per binding (recommended)

Add a flag that tracks whether each import binding has been initialized. In the desugar:
1. Replace `var x = __esm_N.x` with `let x;` (let has TDZ) — but this doesn't work because `let` in CJS doesn't have the module TDZ semantics.

Better approach:
1. Store a module-level initialization flag (e.g., `__esm_initialized__` variable that's set to `true` after all module top-level code runs).
2. Before every access to an imported binding, check the flag. If the module hasn't been fully evaluated yet, the binding is in TDZ.
3. For each import, wrap it as an accessor that checks the flag:
   ```
   Object.defineProperty(exports, 'imported_x', { get: function() { 
     if (!__esm_initialized__) throw new ReferenceError("...");
     return __esm_N.x; 
   }});
   ```

Actually, looking at how JSZ handles module evaluation in isolate.zig (evalModule), the desugar runs first, then the module body executes. The issue is that in a cycle, a module A might be half-evaluated when module B (which A imported) tries to access A's bindings.

## Approach 2: Pre-initialization check at point of use

The simplest fix that would address the ~25 TDZ tests:

1. In the parseExportDecl/parseImportDecl desugar, for each imported/exported binding that should be in TDZ, inject a check:
   - Add a sentinel object (e.g., `__esm_tdz_x = {}`) before the module body
   - At the access site (live-binding rewrite), add a runtime check
   
Actually, the best approach for the CJS desugar model:

For `import {x} from 'm'` where x should be in TDZ until module initialization:
- The module environment already stores exports on `exports` (or `__esm_N` for other modules).
- After module evaluation completes, mark it as initialized.
- Before each access to an imported binding, check if the source module is initialized.

But the issue is that `var x = __esm_N.x` is a one-time snapshot. The better approach is:

### Recommended Fix: Getter-based imports with TDZ check

For `import {x} from 'm'`:
```
var __esm_N = require('m');
// Before the module body, x is in TDZ
// After module evaluation completes, __esm_N.x is live

// Option: Replace `var x = __esm_N.x` with:
var __esm_imports = Object.defineProperty({}, 'x', {
  get: function() { 
    var mod = __esm_N.__esModule ? __esm_N : __esm_N;
    // Check if source module is initialized
    return mod.x; 
  },
  set: function(v) { throw new TypeError("Assignment to imported binding 'x'"); },
  configurable: false,
  enumerable: true
});

// But this still doesn't handle TDZ...
```

### Simplest Fix: Module initialization sentinel + TDZ check at use-sites

1. In parser/compiler, after module desugar, add a flag for each module's initialization state.
2. After the module body executes, set the flag.
3. Before accessing any import binding (in the rewritten code), check the flag.

Actually, looking at how the engine works, the simplest approach that addresses most of the failing tests:

The tests check that:
- `instn-iee-bndng-cls.js`: Importing a class before it's initialized throws ReferenceError
- `instn-local-bndng-cls.js`: Local class/const/let in TDZ
- `instn-named-bndng-cls.js`: Named import in TDZ
- `namespace/internals/delete-exported-uninit.js`: Deleting uninitialized binding throws

The root fix should be in the **module environment system**.

For local bindings (let/const/class), JSZ already has TDZ support outside modules. The issue is that module code desugars to `var` instead of using proper `let/const`.

For IE bindings (indirect exports), the value is snapshotted from the target module.

Let me focus on the three most impactful fixes:

### Fix A: Named import bindings should throw before module evaluation

In the module evaluation flow (isolate.zig evalModule):
- Before running the module body, mark all imported bindings as TDZ
- After the module body completes, mark them as initialized
- The specific mechanism: in `applyLiveBindings`, instead of rewriting `x` → `__esm_N.x`, add a guard

### Fix B: Local export bindings should use proper let/const

In parseExportDecl, when we see `export const x = 1;`:
- Keep it as `const x = 1` (not `var x = 1`)
- Then add `exports.x = x` after

When we see `export let x;`:
- Keep as `let x;`
- Then add `exports.x = x` after the let declaration

### Fix C: Indirect import bindings should use getter-based access

For `import {x} from 'm'`, instead of `var x = __esm_N.x` (snapshot), use a getter:
```
Object.defineProperty(exports, 'x', {
  get: () => require('m').x,
  set: v => { throw new TypeError("..."); },
  configurable: false
})
```

## What to do

Look at the specific failing tests first to understand what they expect. Read the test files in:
- external/test262/test/language/module-code/instn-iee-bndng-*.js
- external/test262/test/language/module-code/instn-local-bndng-*.js
- external/test262/test/language/module-code/instn-named-bndng-*.js

Then look at the current desugar implementation in:
- src/parser/stmt.zig (parseImportDecl, parseExportDecl)
- src/parser/parser.zig (parseModule, applyLiveBindings, makeExportLive)
- src/vm/isolate.zig (evalModule)
- src/runtime/realm.zig (evalModule)

Design the simplest fix that makes the most TDZ tests pass. If a full Module Environment Record is too much, use a module-level initialization flag approach.

Focus on making these tests pass first (they're the highest impact):
1. instn-local-bndng-cls.js — local class binding in TDZ
2. instn-local-bndng-const.js — local const binding in TDZ  
3. instn-local-bndng-let.js — local let binding in TDZ
4. instn-named-bndng-cls.js — named import in TDZ
5. instn-named-bndng-const.js — named import const in TDZ
6. instn-iee-bndng-cls.js — indirect export class in TDZ

## Verification
1. `zig build -Doptimize=ReleaseFast`
2. `zig build test`
3. `./zig-out/bin/test262-runner --full --fail-on-flips --filter "language/module-code" 2>&1 | tail -15`
4. Report the pass/fail delta
