# Architecture

How jsz executes JavaScript, and why it is built the way it is. This is the
"why" document — for the exact public API see the
[API reference](api.md), and for build mechanics see
[Building & testing](building.md).

## The problem

A JavaScript engine has to reconcile three forces that pull in different
directions: spec conformance (tens of thousands of observable edge cases),
embeddability (small binary, deterministic resource usage, a host API that
does not leak engine internals), and speed. V8 resolves this with a
multi-tier JIT and hundreds of megabytes of tooling; QuickJS resolves it by
sacrificing conformance depth. jsz aims at the middle: interpreter-first
execution that passes the same conformance bar as the big engines, in a
single static binary.

## Pipeline overview

```
             ┌────────────┐   ┌──────────────────┐   ┌──────────────────┐
 source ───► │ lexer +    │──►│ bytecode         │──►│ BcVm             │
             │ parser     │   │ compiler         │   │ interpreter      │
             └────────────┘   └──────────────────┘   └──────────────────┘
                   │                  │                   │         │
                   │                  ▼                   ▼         ▼
                   │           snapshot cache      shapes + ICs   gen. GC
                   │                                                │
                   ▼                                                ▼
             module loader                              (optional) Cranelift JIT
             (ESM + CJS)                                leaf fns + loop OSR
```

Each stage is a separate subsystem under `src/`:

| Stage | Location | Job |
|---|---|---|
| Lexer/parser | `src/parser/` | UTF-8 source → AST, all early errors |
| Bytecode compiler | `src/bytecode/` | AST → register bytecode, scope analysis |
| Interpreter | `src/vm/` | Bytecode execution, call stack, exceptions |
| Runtime | `src/runtime/` | Builtins, realms, module loader |
| Values & heap | `src/value/`, GC in `src/vm`/heap | Value repr, allocation, collection |
| JIT (optional) | `src/jit/` + `jit-native/` | Cranelift native tier |

## Values: pointer-boxed, not NaN-boxed

A `Value` is a small tagged struct, not a NaN-boxed double. Numbers are f64;
everything else is a tagged pointer into the GC heap.

The trade-off: NaN-boxing packs every value into 8 bytes and is the classic
high-performance choice, but it couples the value representation to IEEE-754
bit games, complicates a precise GC, and makes an `extern`-compatible
embedding ABI harder. Pointer boxing costs some locality but keeps the GC
exact (every heap reference is a visible pointer field) and lets the
embedding API expose `Value` as a plain struct. Where the interpreter needs
number speed it operates on unboxed f64/i64 lanes internally; the JIT tier
goes further with typed integer lanes and overflow guards.

One consequence worth knowing: exact spec-grade number printing
(`Number.prototype.toString` in arbitrary radix) is done with wide-integer
arithmetic rather than dtoa tables — correctness first, size second.

## Objects: shapes and inline caches

Objects store properties through *shapes* (hidden classes). Adding a property
transitions the object to a new shape; objects created the same way share
shapes. Property access sites in bytecode carry inline caches:

- **Monomorphic** — one shape seen: a single compare + slot load.
- **Polymorphic** — a few shapes: short chain of compares.
- **Megamorphic** — many shapes: shared global cache keyed by (shape, name).
- **Prototype ICs** — hits through the prototype chain cache the holder at
  any depth, with invalidation on prototype mutation.

`--ic-stats` on the CLI (or `Context.lastIcProfile()`) reports hit rates per
tier, which is how IC regressions are caught.

## Garbage collection

The GC is **generational and non-moving**:

- New objects are allocated in a nursery; minor collections scan only the
  nursery plus a remembered set maintained by **write barriers** on object
  slot stores.
- Survivors are promoted; major collections mark-sweep the full heap on a
  configurable period (`Context.gcConfigure`).
- **Ephemerons** give WeakMap/WeakSet/WeakRef/FinalizationRegistry their spec
  semantics: a WeakMap value is reachable only while its key is.
- Non-moving means native code can hold `Value`s across allocations without
  a handle indirection — but it also means anything reachable *only* from a
  native (Zig) stack frame must be registered as a temporary root
  (`Heap.addRoot`/`removeRoot`) while a callback or builtin is mid-
  construction. Getting this wrong is the classic engine bug; the corpus
  runs under `JSZ_GC_STRESS=1` (collect on nearly every allocation) to make
  such bugs deterministic.

Why not refcounting (QuickJS-style)? Cycles are pervasive in real JS
(closures ↔ environments ↔ objects), and cycle collectors give back the
simplicity refcounting promised. A tracing generational GC also gives
throughput on allocation-heavy code (short-lived objects die in the nursery
for near-zero cost), which benchmarked ~4× over the previous mark-sweep
design at sub-4ms p99 pauses.

## Execution: interpreter first

The bytecode VM (`BcVm`) is the source of truth for semantics. Design
choices that follow from conformance-first:

- **Exceptions and completions** are modeled explicitly, including
  try/finally completion-value semantics, generator resumption, and async
  micro-task draining — the areas where "fast path first" engines
  historically diverge from spec.
- **Resource limits** are enforced in the dispatch loop: a gas counter, a
  memory cap on the heap, and a wall-clock deadline that also interrupts
  long-running *native* builtins (a regexp or array loop cannot wedge the
  host). This is what makes the engine usable for untrusted input.
- **Frames are reusable** and the call path is allocation-free in steady
  state; tail calls are eliminated per spec.

### The super desugar

`super.x` and `super()` are desugared during parsing into references to
synthetic bindings (the home-object prototype is captured at method entry).
This keeps the interpreter free of a special super-reference mode, at the
cost of parser-side complexity: every syntactic position where `super` can
appear (destructuring targets, update expressions, `for`-heads, `eval` in
nested arrows) must be anticipated by the rewriter. The spec's "live"
`[[HomeObject]].[[Prototype]]` lookup on every access is approximated by a
per-entry snapshot — a known deviation being incrementally removed.

## The JIT tier (optional)

Built only with `zig build -Djit=true` (requires cargo; links a Rust cdylib
using Cranelift). Two entry points:

- **Leaf-function compilation** at the call boundary: integer-typed
  functions with no calls out get compiled to native code.
- **Loop OSR** (on-stack replacement) at hot back-edges: the remainder of a
  hot loop runs natively, with environment write-back on clean exit.

Every arithmetic op carries an i128 intermediate with a 2^53 overflow guard;
crossing it deoptimizes back to the interpreter mid-function with the real
frame reconstructed — results are bit-exact with the interpreter, which is
verified by running the differential and conformance suites in both modes.
The default build omits the JIT entirely; there is no performance cliff,
just the interpreter.

## Modules

The loader handles both ES modules (`import`/`export`, live bindings,
top-level await, dynamic `import()` with import attributes) and a CommonJS
wrap used by the CLI for plain scripts. Module graphs are resolved from
relative specifiers, bundled, and instantiated per spec ordering
(parse → link → evaluate), including cyclic-import and errored-cycle
semantics.

## Conformance infrastructure

Conformance is an architectural feature, not an afterthought:

- A crash-resilient parallel test262 runner (`src/test/test262_runner.zig`)
  shards the 53k-test corpus across cores with per-shard crash-resume, so a
  single engine bug cannot hide the rest of the results.
- Two seeded baselines (curated whitelist at 100%, full-corpus known-failing
  list) turn "did anything regress?" into a zero-flip CI gate.
- The Node.js differential harness runs the same programs under jsz and Node
  and diffs observable output.

See [Conformance](conformance.md) for how to run all of this locally.

## Trade-offs, honestly

- **Interpreter-first** means raw peak throughput is below JIT engines on
  numeric kernels unless `-Djit` is enabled — and the JIT covers leaf/loop
  shapes, not everything.
- **Non-moving GC** trades compaction (no fragmentation control) for a
  simpler native-code contract.
- **Parse-time super desugar** trades spec-exact live-prototype semantics
  (in rare mutation patterns) for interpreter simplicity; being fixed.
- **Arrays** currently reuse the shape/property machinery rather than a
  dedicated dense-elements store; pathological sparse-array workloads pay
  for it. A dense/sparse element store is planned.

## Related

- [API reference](api.md) — the embedding surface these internals power
- [Embedding guide](embedding.md) — using limits, GC control, snapshots
- [Conformance](conformance.md) — measuring all of the above
