# Wave 24 — Literal elision holes `[1,,3]` + index-key churn optimization

## Objective

Two polish items left over from the Wave 22 dense-array work:

1. **Literal elision holes** — `[1,,3]` compiled the elided slot to an explicit
   `undefined`, so `1 in [1,,3]` was `true` and `[1,,3].hasOwnProperty("1")` was
   `true`. Only the *value* was spec-correct; the *absence* was not.
2. **Index-key churn** — the array append / index-access hot paths converted the
   integer index to a decimal string via `allocPrint("{d}", .{i})` on every
   operation, then re-parsed it back to an integer inside `set()`. On a 1M-element
   build this produced a ~6GB transient allocation and ~2 min wall time.

## Part A — Real elision holes

The dense element layer (`src/object/object.zig`) already modelled holes
correctly: a hole is the empty `Value` (`bits == 0`), and `denseGet`, `hasOwn`,
`isEnumerable`, `ownAttr`, `denseOwnKeys`, and `deleteOwn` all treat it as
genuinely absent. The gap was purely at parse/compile time — the parser erased
elisions into `undefined` literals.

- **AST** (`parser/ast.zig`): new node kind `array_hole` (void payload), distinct
  from `undefined_literal`.
- **Parser** (`parser/expr.zig`): `parseArrayLiteral` emits `array_hole` for an
  elided slot instead of a synthesized `undefined_literal`. The existing loop
  structure already produced the right *count* of hole nodes (trailing comma adds
  none; `[1,,3]` → `[1, hole, 3]`).
- **Elision consumers updated** to key on `array_hole`:
  - iterator-protocol array destructuring `[, x] = rhs` (`parser/expr.zig`)
  - index-based array-pattern destructuring in the compiler (`compiler.zig`)
- **New opcode** `ARRAY_APPEND_HOLE` (`op, Rarr u8, countU8 u8`): extends the
  array by `count` trailing holes (bumps `array_length`, creates no own index).
  Declared at the enum tail for JIT ordinal stability; a run of >255 holes emits
  several ops.
- **`compileArrayLiteral`** rewritten to a single append-based path (append /
  append-hole / spread) for *all* array literals, not just spread ones. This both
  fixes holes and removes the per-element compile-time `allocPrint`.

### Semantics verified

```js
[1,,3].length              === 3
[1,,3].hasOwnProperty("1") === false      [1,,3].hasOwnProperty("0") === true
1 in [1,,3]                === false       0 in [1,,3]                === true
[1,,3][1]                  === undefined
[1, undefined, 3]          // index 1 stays present (hasOwnProperty true)
[1,2,].length === 2   [1,2,,].length === 3   [,].length === 1   [,,,].length === 3
JSON.stringify([1,,3]) === "[1,null,3]"   Object.keys([1,,3]) === ["0","2"]
[1,,3].forEach → indices [0,2]            [1,,3].map preserves the hole
[...[1,2],,5]  // length 4, hole at 2      >255-hole runs coalesce correctly
Object.freeze([1,,3])  // deopt path: 1 in f === false, f[2] === 3
```

## Part B — Integer-key path (kill the churn)

New public methods on `JsObject` that avoid allocating a decimal key on the dense
fast path (`src/object/object.zig`):

- `setIndex(idx: u32, value)` — dense store direct; only a deopt (sparse write) or
  an already-shape-path array falls back to string-keyed `set` (via a stack
  `bufPrint`, no heap alloc).
- `appendElement(value)` — `setIndex(array_length, value)`.
- `appendHoles(count: u32)` — extend length by trailing holes (saturating).
- `getIndexOwn(idx: u32)` — present dense element read, else null (caller takes
  the proto-walking string path).

Hot paths routed through them:

- **VM array literal / spread** (`vm/ops/object.zig`): `opArrayAppend` /
  `opArraySpread` → `appendElement`; new `opArrayAppendHole`.
- **`Array.prototype` generics** (`array_proto.zig`): `genSet` / `genGet` /
  `genHas` take a dense-array fast path (`denseArrayOf`) — covers `push` and every
  generic array method. A real Array's `ctx.setProp` bottoms out in the same
  ordinary element store, so this is behaviour-preserving; a hole/miss falls
  through to the full-semantics string path.
- **Dynamic `a[i]` / `a[i] = v`** (`vm/ops/property.zig`): `opGetPropDyn` /
  `opSetPropDyn` gained a numeric fast path (`canonicalIndexFromValue`). A get
  returns only *present* dense elements (a hole falls through so the prototype is
  consulted); a set is taken only for `is_array && usesDense()` arrays (always
  writable/extensible, so no strict-throw path is needed).

### Measured impact (1M `a[i]=i` + 1M read + 1M `push`)

| build       | before        | after            |
|-------------|---------------|------------------|
| Debug RSS   | ~6 GB         | **~36 MB**       |
| Release     | (n/a)         | **~28 MB, 1.5s** |

Correctness of the loop preserved (`sum === 499999500000`, `a[500000] === 500000`).

## Files touched

- `src/parser/ast.zig` — `array_hole` node kind + union field
- `src/parser/expr.zig` — parse elision as `array_hole`; destructuring elision check
- `src/bytecode/compiler.zig` — unified append-based `compileArrayLiteral`;
  destructuring elision check
- `src/bytecode/opcodes.zig` — `ARRAY_APPEND_HOLE` opcode (+ instrSize)
- `src/bytecode/chunk.zig` — disassembly of `ARRAY_APPEND_HOLE`
- `src/vm/bc_vm.zig` — dispatch arm
- `src/vm/ops/object.zig` — `opArrayAppend`/`opArraySpread` via `appendElement`;
  `opArrayAppendHole`
- `src/vm/ops/property.zig` — `canonicalIndexFromValue` + numeric fast paths
- `src/object/object.zig` — `setIndex`/`appendElement`/`appendHoles`/`getIndexOwn`
- `src/runtime/builtins/array_proto.zig` — `denseArrayOf` fast path in gen*

## Verification

- `zig build test` — pass (433/442; 8 pre-existing skips, 1 flaky-free)
- `zig build differential` — 167/167, 0 mismatches
- `zig build conformance-summary` — 1278/1278 (100.00%), no regression
</content>
</invoke>
