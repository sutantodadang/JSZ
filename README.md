# jsz

A JavaScript engine written from scratch in Zig. Production-ready embedding API, JIT scaffolding operational.

![CI](https://github.com/your-handle/jsz/actions/workflows/ci.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)

**Status: Phase 9 in progress. JIT count-loop kernel operational (~300x). 70.7% Test262 pass.**

---

## Hello world (embed jsz in your Zig program)

```zig
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var iso = try jsz.Isolate.init(gpa.allocator());
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    switch (ctx.eval("1 + 2", "<inline>")) {
        .ok => |v| std.debug.print("{}\n", .{v.toI32()}),
        .exception => |e| std.debug.print("err: {s}\n", .{e.message}),
        .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
    }
}
```

---

## Install

Requires Zig 0.15.2.

```sh
git clone https://github.com/your-handle/jsz
cd jsz
zig build
```

The CLI binary lands at `zig-out/bin/jsz`.

---

## CLI usage

```
jsz --version
jsz --help
jsz -e "1 + 1"
jsz script.js
jsz -i          # REPL (Phase 1)
```

---

## Build steps

| Command | Description |
|---|---|
| `zig build` | Build the CLI |
| `zig build run -- [args]` | Build + run CLI |
| `zig build test` | Run all unit tests |
| `zig build fuzz` | Run fuzz harnesses (add `--fuzz` for fuzzing mode) |
| `zig build conformance` | Run Test262 conformance suite |
| `zig build conformance-summary` | Run Test262 with per-category bucket summary |
| `zig build conformance-delta` | CI gate: fail on unexpected pass/fail flips |
| `zig build conformance-dashboard` | Write `docs/CONFORMANCE_DASHBOARD.md` |
| `zig build differential` | Run Node.js differential harness |
| `zig build example-hello` | Build + run examples/hello.zig |
| `zig build example-embed` | Build + run examples/embed.zig (demonstrates native fn + cross-eval persistence) |
| `zig build docs` | Generate API docs to zig-out/docs/ |
| `zig build bench-phase6` | Run Phase 6 shape/IC property benchmarks |

---

## Documentation

- [EMBEDDING.md](docs/EMBEDDING.md) — Tutorial: embed jsz in a Zig host
- [API.md](docs/API.md) — Public API reference
- [COOKBOOK.md](docs/COOKBOOK.md) — Recipes
- [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute

---

## Roadmap

See [PLAN.md](PLAN.md) for the full phased roadmap. Short version:

- **Phase 0-7**: Complete (ES2015+)
- **Phase 8**: Complete (ES2022, TCO, snapshot, source maps)
- **Phase 9**: In progress (JIT scaffolding - count-loop ~300x, Cranelift native backend)
- **Phase 10+**: See [PRODUCTION_ROADMAP.md](PRODUCTION_ROADMAP.md) (async/await, full JIT, 95% conformance)

---

## License

MIT. See [LICENSE](LICENSE).