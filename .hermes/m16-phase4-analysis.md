# M16 Phase 4 Module-Code Failure Analysis

## Current Baseline: 515 pass, 81 fail out of 596 (86.40%)

## Top Priority Issue Categories

### 1. TDZ (Temporal Dead Zone) — ~25 tests
**Symptoms**: "binding is created but not initialized / Expected a ReferenceError but no exception was thrown at all"

Module bindings should be in TDZ until initialized. Accessing a binding before its initializer runs should throw ReferenceError.

**Failing tests**:
- instn-iee-bndng-cls, const, let
- instn-local-bndng-cls, const, export-cls, export-let, let
- instn-named-bndng-cls, const, dflt-cls, dflt-expr, dflt-named, dflt-star
- namespace/internals: delete-exported-uninit, enumerate-binding-uninit, get-own-property-str-found-uninit, get-str-found-uninit, has-property-str-found-uninit, object-hasOwnProperty-binding-uninit, object-keys-binding-uninit, object-propertyIsEnumerable-binding-uninit, super-access-to-tdz-binding

### 2. Module Namespace Exotic Object Writes — ~6 tests
**Symptoms**: "binding rejects assignment / Expected a TypeError"

Module namespace objects should be immutable (no assignment). Tests check:
- instn-iee-bndng-var — var binding rejects assignment
- instn-named-bndng-trlng-comma — trailing comma binding rejects assignment
- instn-named-bndng-var — var binding rejects assignment
- namespace/internals/set — assignment to namespace property

### 3. Indirect Export Environment (IEE) — ~8 tests
**Symptoms**: "TypeError: undefined is not a function"

When a module re-exports a function/generator from another module, importing and calling it may fail because the IEE binding doesn't properly resolve.

**Failing tests**:
- instn-iee-bndng-fun, gen
- instn-named-bndng-dflt-fun-anon, fun-named, gen-anon, gen-named
- instn-named-bndng-fun, gen

### 4. Module Loading/Evaluation Order — ~6 tests
**Symptoms**: Expected values differ (undefined vs expected), cycle resolution failures

- eval-rqstd-once, eval-self-once, instn-same-global — global property not defined
- eval-rqstd-order — evaluation order wrong
- instn-iee-star-cycle, instn-named-iee-cycle, instn-named-star-cycle, instn-star-iee-cycle, instn-star-star-cycle — cycle resolution
- instn-star-props-circular — circular namespace properties
- instn-star-props-dflt-skip — star export default handling
- instn-star-binding — "binding is initialized prior to module evaluation"

### 5. Export Default Binding — ~6 tests
**Symptoms**: Default export function/class/asyncfunction/generator bindings aren't accessible by the local name

- eval-export-dflt-* — "correct name is assigned" checks
- export-default-asyncfunction-declaration-binding — "A is not defined"
- export-default-function-declaration-binding — "F is not defined"
- export-default-generator-declaration-binding — "G is not defined"

### 6. Ambiguous Export Bindings — ~2 tests
- namespace-unambiguous-if-import-source-and-export — "expected 'from' in import declaration"
- omitted-from-namespace — "Ambiguous export is not present"

### 7. Parser Issues — ~5 tests
- import-attributes/import-attribute-empty — "unexpected token 'kw_with'"
- privatename-valid-no-earlyerr — "expected left_paren but got eq"
- namespace/internals/own-property-keys-sort — "expected identifier but got illegal"
- source-phase-import/reexport-source-binding-namespace-get — "expected 'from' in import declaration"
- top-level-await/new-await-script-code — "unexpected token 'comma'"

### 8. TLA Async Ordering — ~7 tests
- async-module-does-not-block-sibling-modules
- fulfillment-order
- rejection-order
- module-async-import-async-resolution-ticks
- module-sync-import-async-resolution-ticks
- module-self-import-async-resolution-ticks
- unobservable-global-async-evaluation-count-reset

### 9. Namespace Internals — ~4 tests
- define-own-property — "key is not defined"
- get-str-found-uninit — missing TDZ for get access
- get-str-update — "Expected SameValue(«222», «444»)"
- own-property-keys-binding-types — "Expected SameValue(«6», «10»)"
- super-set-to-tdz-binding-with-accessor — TDZ with accessor
