# M16 Phase 4 - Phase 1: Quick Namespace Fixes

## Context
JSZ is a Zig JavaScript engine. Module system uses CJS desugar. Branch: `feature/mi16-phase4`. Current baseline: 515 pass / 81 fail on module-code tests.

## Task 1: Fix Reflect.ownKeys for Module Namespace Exotic Objects

**Problem**: `Reflect.ownKeys()` (in `src/runtime/builtins/reflect.zig`, around line 381) has no special case for `internal_kind == .module_namespace`. It falls through to the ordinary `obj.ownKeys()` path, which returns the namespace's own properties (empty, since exports live in the backing object) + symbol keys (@@toStringTag). The spec says it should return sorted export names + symbol keys.

**Fix**: Add a module_namespace branch. For module namespace objects, return:
1. The sorted export names (from `sortedNames(namespace)` function in `src/runtime/builtins/namespace.zig`)
2. Plus any symbol keys (like @@toStringTag)

Reference: `namespace.zig` has `sortedNames()` function.

Also, check `namespace/internals/own-property-keys-binding-types.js` which expects 10 keys but gets 6 - this might be the same bug.

## Task 2: Fix Object.defineProperty for Module Namespace Exotic Objects

**Problem**: `Object.defineProperty()` (in `src/runtime/builtins/object_methods.zig`, around line 631) has no module_namespace guard. Spec says [[DefineOwnProperty]] for module namespace objects should return `false` (rejecting all definition attempts, leading to TypeError in strict mode).

**Fix**: Add a check at the top of the defineOwnProperty function - if the object's internal_kind is `.module_namespace`, return `false`.

## Task 3: Fix [[Set]] for Symbol Keys on Module Namespace

**Problem**: `setPropSym` handler in `src/vm/bc_vm.zig` (around line 1070) has no module_namespace check, so symbol-keyed properties can be set on namespace objects. The spec says ALL [[Set]] operations should return false.

**Fix**: Add a module_namespace check in the setPropSym handler similar to the string-key [[Set]] check.

## Verification
After each change:
1. `zig build -Doptimize=ReleaseFast`
2. `./zig-out/bin/test262-runner --full --fail-on-flips --filter "language/module-code" 2>&1 | tail -15`
3. The specific tests that should flip to pass: namespace/internals/own-property-keys-binding-types.js, namespace/internals/own-property-keys-sort.js, namespace/internals/define-own-property.js, namespace/internals/set.js
