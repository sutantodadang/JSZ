# Embedding jsz in a Zig Application

> Stub — full tutorial content arrives in Phase 1.

## Overview

jsz is designed to be embedded with minimal ceremony. The public API lives in `src/root.zig`
and is exposed as the `jsz` module in `build.zig`.

## Hello world

Add jsz as a dependency (or path reference) in your `build.zig.zon`, then:

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

## Memory model

- `Value` is an opaque handle valid until its owning `Context` is destroyed.
- Strings passed **into** jsz (e.g. source code) are **copied** by jsz.
- Strings returned **from** jsz (e.g. error messages) are **borrowed** — valid until the next
  `eval()` call on the same context. Call `toOwnedSlice()` to detach.

## Error propagation contract

| Failure type | How it surfaces |
|---|---|
| JS throw | `EvalResult{ .exception }` with `.value`, `.message`, `.stack` |
| Engine internal error | Zig error union (`error.OutOfMemory`, etc.) |
| Parse / syntax error | `EvalResult{ .parse_error }` — not a Zig error |

## Registering a native function

TODO Phase 1 — see `Context.registerNativeFn` in `src/root.zig`.

## Further reading

- [API.md](API.md) — full API reference
- [COOKBOOK.md](COOKBOOK.md) — recipes
