# jsz

A JavaScript engine built in Zig. Bytecode VM, NaN-boxed values, shape-based inline caches, JIT scaffolding, and a semver-frozen embedding API. Single static binary, zero runtime dependencies.

![CI](https://github.com/your-handle/jsz/actions/workflows/ci.yml/badge.svg)
![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)
![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)

---

## Why jsz

| | V8 / WebKit | QuickJS | jsz |
|---|---|---|---|
| **Binary size** | 30+ MB | ~1 MB | ~3.4 MB |
| **Startup** | Slow (isolate bootstrap) | Fast | Fast |
| **Runtime deps** | C++ toolchain, ICU | libc | None |
| **Memory model** | GC (mark-sweep, generational) | Refcount + GC | Zig allocator (deterministic) |
| **Embedding** | C++ API, complex isolate setup | C API | Zig-native API, 6-call setup |
| **JIT** | Full (TurboFan / FTL) | None | Scaffold (hot-loop native kernel) |

jsz targets workloads where V8 is too heavy and QuickJS lacks a native embedding story: edge runtimes, embedded scripting in systems software, serverless cold starts, and desktop applications that ship a single binary.

---

## Language support

ES2015 through ES2022, with selective ES2023+ features:

- **Declarations**: `let`/`const` with TDZ, destructuring, `for-of`
- **Functions**: arrows, default/rest/spread parameters, tail-call optimization
- **Classes**: `class`/`extends`/`super`, computed methods
- **Modules**: CommonJS (`require`/`module.exports`), ESM export live bindings
- **Async**: Promise microtask queue, `.then`/`.catch`/`.finally` chaining, thenable resolution
- **Collections**: `Map`, `Set`, `WeakMap`, `WeakSet` with iterable constructors
- **Iteration**: generators (tree-mode), `Symbol.iterator`, array/call-arg spread
- **Objects**: `Proxy` (all 8 traps: get/set/has/deleteProperty/ownKeys/getOwnPropertyDescriptor/apply/construct), `Reflect`
- **Strings & RegExp**: template literals, `replaceAll`, `/s` `/y` `/u` flags, lookbehind, `\p{}` property escapes
- **Operators**: `**`, `??`, `?.`, `??=`, `&&=`, `||=`, `in`, `delete`, `typeof` IC
- **Intl**: `NumberFormat`, `DateTimeFormat`, `Collator` (en-US, no ICU dependency)
- **Coercion**: Full `ToPrimitive` with `Symbol.toPrimitive` / `valueOf` / `toString` hooks

---

## Architecture

```
Source → Parser → AST → Compiler → Bytecode → VM
                                         ↓
                                   Shape + IC cache
                                         ↓
                                   JIT (hot-loop kernel)
```

**Value representation**: WebKit-style NaN-boxing. Doubles, int32, and pointer values packed into 64 bits with no heap allocation for numbers or immediates (`null`, `true`, `false`).

**Object model**: Shape graphs with inline caches (monomorphic → polymorphic → megamorphic). Property access resolves through shape transitions; ICs cache the lookup path per call site.

**Memory**: Arena-based allocation with GC mark phase. HandleScope pattern for root management. SMI-safe at both GC mark paths.

**JIT**: Profiling tier detects hot loops. Count-loop kernel compiles to native code via Cranelift backend. Generalized header comparison (LT/LE/GT/GE), body step detection (INC/DEC/LOAD_K+ADD/SUB), and termination guards. Deoptimization falls back to bytecode.

---

## Embedding

The embedding API is semver-frozen at 1.0. Stable surface: `Isolate`, `Context`, `Value`, and result types.

```zig
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var iso = try jsz.Isolate.init(gpa.allocator());
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    // Register a native function callable from JS
    try ctx.registerNativeFn("add", struct {
        fn call(args: []jsz.Value) jsz.Value {
            const a = args[0].toF64();
            const b = args[1].toF64();
            return jsz.makeNumber(a + b);
        }
    }.call);

    // Evaluate JS that calls back into native code
    const result = ctx.eval("add(40, 2)", "<inline>");
    switch (result) {
        .ok => |v| std.debug.print("result: {}\n", .{v.toI32()}),
        .exception => |e| std.debug.print("error: {s}\n", .{e.message}),
        .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
    }
}
```

Globals persist across `eval` calls. Native functions, registered once, remain available for the lifetime of the context. See [EMBEDDING.md](docs/EMBEDDING.md) for the full tutorial and [API.md](docs/API.md) for the reference.

---

## Getting started

Requires **Zig 0.15.2**.

```sh
git clone https://github.com/your-handle/jsz
cd jsz
zig build
```

The CLI binary is produced at `zig-out/bin/jsz`.

### CLI

```
jsz script.js              # Run a file
jsz -e "1 + 2"            # Evaluate an expression
jsz -i                     # Interactive REPL
jsz --time-limit=500 s.js  # Run with a 500ms time limit
jsz --version
```

### As a Zig dependency

Add jsz to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/your-handle/jsz/archive/refs/tags/v0.1.0.tar.gz
```

Then in `build.zig`:

```zig
const jsz = b.dependency("jsz", .{});
exe.root_module.addImport("jsz", jsz.module("jsz"));
```

---

## Build commands

| Command | Description |
|---|---|
| `zig build` | Build the CLI |
| `zig build test` | Run all unit tests |
| `zig build differential` | Run Node.js differential harness |
| `zig build conformance` | Run Test262 conformance suite |
| `zig build conformance-summary` | Per-category conformance summary |
| `zig build conformance-delta` | CI gate: fail on unexpected flips |
| `zig build conformance-dashboard` | Write `docs/CONFORMANCE_DASHBOARD.md` |
| `zig build fuzz` | Run fuzz harnesses |
| `zig build bench-phase6` | Run shape/IC property benchmarks |
| `zig build example-embed` | Build and run the embedding example |
| `zig build docs` | Generate API documentation |

---

## Testing

jsz is validated at three levels:

1. **Unit tests** — `zig build test`. Covers parser, compiler, VM, GC, value representation, builtins, and the embedding API.
2. **Differential testing** — `zig build differential`. 147 programs executed in both jsz and Node.js; outputs must match exactly. Catches semantic divergence that unit tests miss.
3. **Test262 conformance** — `zig build conformance`. Runs the official ECMAScript test suite with per-test resource limits (1s time, 256 MB memory). Current pass rate tracked in [CONFORMANCE_DASHBOARD.md](docs/CONFORMANCE_DASHBOARD.md).

The conformance delta gate (`zig build conformance-delta`) runs in CI and fails the build on any unexpected pass/fail flip against a known baseline, preventing silent regressions.

---

## Documentation

| Document | Description |
|---|---|
| [EMBEDDING.md](docs/EMBEDDING.md) | Embedding tutorial |
| [API.md](docs/API.md) | Public API reference (stable + experimental surface) |
| [COOKBOOK.md](docs/COOKBOOK.md) | Common patterns and recipes |
| [PLAN.md](PLAN.md) | Phased development roadmap |
| [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md) | Production readiness plan |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contribution guidelines |

---

## Roadmap

Phases 0–8 are complete. Active development:

- **Phase 9** — JIT compilation (scaffold operational, Cranelift native backend, hot-loop kernel)
- **Phase 10** — Browser integration target
- **Conformance** — Push from current baseline toward 95% Test262 pass rate
- **Async** — `async`/`await` (ES2017)
- **Generators** — Bytecode-mode generators (currently tree-mode only)

See [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md) for the full competitive roadmap.

---

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

```
Copyright 2026 jsz contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```
