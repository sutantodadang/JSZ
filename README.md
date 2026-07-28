# jsz

A JavaScript engine written in Zig. Zero dependencies, embeddable in a few
lines, and at [V8-level Test262 conformance](#conformance).

[![CI](https://github.com/sutantodadang/JSZ/actions/workflows/ci.yml/badge.svg)](https://github.com/sutantodadang/JSZ/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Zig 0.15.2](https://img.shields.io/badge/zig-0.15.2-orange.svg)](https://ziglang.org/)
[![Test262](https://img.shields.io/badge/test262-99.0%25-brightgreen.svg)](docs/conformance.md)

```sh
zig build
zig-out/bin/jsz -e "[1, 2, 3].map(x => x * 2).join(',')"
# 2,4,6
```

## Why jsz

| | V8 / JavaScriptCore | QuickJS | jsz |
|---|---|---|---|
| Binary size | 30+ MB | ~1 MB | ~4 MB |
| Runtime deps | C++ toolchain, ICU | libc | none |
| Embedding | C++ API, complex isolate setup | C API | Zig-native API, six calls to first eval |
| Test262 (full corpus) | ~97.5% | ~83% | ~97.5% |
| Sandboxing | per-isolate | interrupt handler | gas / memory / time limits built in |

jsz targets workloads where V8 is too heavy and QuickJS gives up too much
conformance: edge runtimes, embedded scripting in systems software, and
applications that ship a single static binary.

## Highlights

- **Modern JavaScript.** ES2024+ language and library coverage: classes with
  private fields, generators, async/await, ES modules and dynamic `import()`,
  Proxy/Reflect, TypedArrays, Iterator helpers, RegExp with Unicode sets and
  lookbehind, `using`/`await using` resource management, Temporal, and Intl
  (DateTimeFormat, NumberFormat, Locale, and friends) — no ICU dependency.
- **Conformance-first.** The full [tc39/test262](https://github.com/tc39/test262)
  corpus runs against every change. Current pass rate is at parity with V8 as
  measured by [test262.fyi](https://test262.fyi/). See
  [conformance](docs/conformance.md).
- **Embeddable.** `Isolate` / `Context` API modeled on what host applications
  actually need: evaluate scripts and modules, register native functions,
  exchange values, set gas/memory/time limits, snapshot compiled bytecode.
  See the [embedding guide](docs/embedding.md).
- **Zero dependencies.** Pure Zig standard library. One static binary. An
  optional Cranelift-based JIT backend (Rust) can be linked with
  `zig build -Djit=true`; the default build contains no code but Zig's.
- **Crash-free on any input.** Generational, non-moving GC with write barriers
  and ephemerons. The engine treats any segfault on any input as a bug — the
  full 53k-test corpus runs clean.

## Getting started

Requires [Zig 0.15.2](https://ziglang.org/download/).

```sh
git clone https://github.com/sutantodadang/JSZ
cd JSZ
zig build
zig-out/bin/jsz -e "1 + 1"     # evaluate an expression
zig-out/bin/jsz script.js      # run a file
zig-out/bin/jsz -i             # REPL
zig-out/bin/jsz --module m.mjs # run an ES module
```

New to the project? The [getting started tutorial](docs/getting-started.md)
walks from a clean machine to an embedded engine with host functions.

## Embedding

jsz is designed to live inside your application. The complete example is at
[`examples/embed.zig`](examples/embed.zig) (`zig build example-embed`):

```zig
const jsz = @import("jsz");

var iso = try jsz.Isolate.init(allocator);
defer iso.deinit();
var ctx = try iso.newContext();
defer ctx.deinit();

try ctx.registerNativeFn("addOne", hostAddOne);

switch (ctx.eval("addOne(41)", "<host>")) {
    .ok => |v| std.debug.print("{d}\n", .{v.toF64()}), // 42
    .exception => |e| std.debug.print("uncaught: {s}\n", .{e.message}),
    .parse_error => |e| std.debug.print("syntax error: {s}\n", .{e.message}),
}
```

Resource limits (`--gas-limit`, `--mem-limit`, `--time-limit` on the CLI,
`Context.setLimits` in the API) bound untrusted scripts. The
[embedding guide](docs/embedding.md) covers host functions, value exchange,
error handling, GC control, and bytecode snapshots; the
[API reference](docs/api.md) documents every public type and function.

## Conformance

Measured against the full tc39/test262 corpus (53,447 tests), the same corpus
[test262.fyi](https://test262.fyi/) runs daily against every major engine:

| Engine | Pass | % |
|---|---:|---:|
| SpiderMonkey | 52,529 | 98.3 |
| LibJS | 52,320 | 97.9 |
| JavaScriptCore | 52,273 | 97.8 |
| **V8** | **52,122** | **97.5** |
| **jsz** | **≈52,120** | **97.5** |
| Boa | 50,966 | 95.4 |
| QuickJS-ng | 44,579 | 83.4 |

<sub>test262.fyi snapshot 2026-07-28; jsz measured locally on the same corpus.
Run-to-run variance is a few tests either way.</sub>

Two CI gates keep it honest: a curated whitelist must stay at 100%, and the
full corpus must produce zero unexpected regressions against a seeded
baseline. [How conformance is measured →](docs/conformance.md)

## Architecture

```
source ──► lexer/parser ──► bytecode compiler ──► BcVm interpreter
                                    │                  │
                                    ▼                  ▼
                            snapshot cache      shapes + inline caches
                                                       │
                                                       ▼
                                              generational GC
                                                       │
                                         (optional) Cranelift JIT
                                          leaf functions + loop OSR
```

- Values are pointer-boxed; objects use shape transitions with monomorphic,
  polymorphic, and megamorphic inline caches for property access.
- The GC is generational and non-moving, with write barriers, ephemeron
  tables for WeakMap/WeakRef, and a configurable nursery/major cadence.
- The optional JIT tier compiles integer-typed leaf functions and hot loop
  bodies (on-stack replacement) to native code via Cranelift, with precise
  deoptimization back to the interpreter.

Design rationale, trade-offs, and subsystem walkthroughs:
[architecture](docs/architecture.md).

## Documentation

| Doc | What it covers |
|---|---|
| [Getting started](docs/getting-started.md) | Zero to running scripts and a first embedding |
| [Embedding guide](docs/embedding.md) | Host functions, values, limits, GC, snapshots |
| [API reference](docs/api.md) | Every public type and function in the embedding API |
| [CLI reference](docs/cli.md) | Every `jsz` command-line flag |
| [Building & testing](docs/building.md) | All build steps, test suites, cross-compiling |
| [Conformance](docs/conformance.md) | Test262 methodology, current standing, reproduction |
| [Architecture](docs/architecture.md) | How the engine works and why |
| [Cookbook](docs/cookbook.md) | Copy-paste recipes for common embedding tasks |

## Contributing

Contributions are welcome — the [contributing guide](CONTRIBUTING.md) covers
setup, the test matrix, and the PR checklist. The short version:

```sh
zig build test                 # unit tests must stay green
zig build conformance-delta    # no conformance regressions
zig fmt src/                   # formatting
```

Bug reports with a reproducing script are gold. An input that crashes the
engine (rather than throwing a JavaScript error) is always a high-priority
bug — please [file it](https://github.com/sutantodadang/JSZ/issues).

## Status

jsz is pre-1.0. The engine core (parser, interpreter, GC, standard library)
is complete and conformance-tested; the public embedding API may still change
between 0.x releases. See [CHANGELOG.md](CHANGELOG.md) for history and
[SECURITY.md](SECURITY.md) for the security policy.

## License

[Apache-2.0](LICENSE). Contributions are accepted under the same license.
