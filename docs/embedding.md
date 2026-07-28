# Embedding jsz in a Zig Application

jsz is designed to be embedded with minimal ceremony. The public API lives in
`src/root.zig` and is exposed as the `jsz` module in `build.zig`. The runnable
version of every snippet in this tutorial is `examples/embed.zig`
(`zig build example-embed`).

---

## 1. Add jsz to your project

In your `build.zig`, declare a dependency on the jsz source tree (path
reference during development, or a package reference once published) and add
the module to your executable:

```zig
const jsz_dep = b.dependency("jsz", .{ .target = target, .optimize = optimize });
const jsz_mod = jsz_dep.module("jsz");
exe.root_module.addImport("jsz", jsz_mod);
```

Then in your source:

```zig
const jsz = @import("jsz");
```

---

## 2. Hello world — init Isolate → Context → eval → read result

```zig
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One Isolate per process (owns heap, GC, atom table).
    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();

    // One Context per execution environment (owns the global object).
    var ctx = try iso.newContext();
    defer ctx.deinit();

    switch (ctx.eval("1 + 2", "<inline>")) {
        .ok => |v| std.debug.print("result = {d}\n", .{v.toF64()}),
        .exception => |e| std.debug.print("uncaught: {s}\n", .{e.message}),
        .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
    }
}
```

`eval` never returns a Zig error — all JS-level failures come back as
`EvalResult.exception` or `EvalResult.parse_error`. Only `Isolate.init` and
`iso.newContext` can fail with `error.OutOfMemory`.

---

## 3. Exposing a host function with `registerNativeFn`

A `NativeFn` has the signature:

```zig
pub const NativeFn = *const fn (*Context, []const Value) NativeResult;
```

`NativeResult` is a tagged union: `.ok` returns a value to JS, `.throw` raises
a JS exception. Build return values with the `ctx.make*` helpers:

```zig
fn hostAddOne(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    const n = if (args.len > 0) args[0].toF64() else 0;
    return .{ .ok = ctx.makeNumber(n + 1) };
}

// Register before the first eval that needs it.
try ctx.registerNativeFn("addOne", hostAddOne);

const r = ctx.eval("addOne(41)", "<embed>");
// r.ok.toF64() == 42
```

Available make helpers: `makeNumber(f64)`, `makeString([]const u8)`,
`makeBool(bool)`, `makeUndefined()`, `makeNull()`.

To throw from a native function:

```zig
fn hostFail(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    _ = args;
    return .{ .throw = ctx.makeString("something went wrong") };
}
```

Host registrations persist for the lifetime of the Isolate.

---

## 4. Reading globals back from the host

After one or more `eval` calls, read JS globals back into Zig via
`globalObject()` + `getProperty()`:

```zig
_ = ctx.eval("var answer = 42;", "<embed>");

const g = ctx.globalObject();
const v = ctx.getProperty(g, "answer");
std.debug.print("answer = {d}\n", .{v.toF64()});
```

The global object and all `Value` handles it contains are valid until
`ctx.deinit()` is called.

---

## 5. Resource limits via `setLimits`

Cap untrusted JS execution with `setLimits`. Breaches surface as
`EvalResult.exception`, never a crash or hang:

```zig
ctx.setLimits(.{
    .gas     = 1_000_000,  // max bytecode instructions
    .time_ms = 100,        // max wall-clock milliseconds
    .mem_bytes = 8 * 1024 * 1024, // max live heap bytes
});
const r = ctx.eval(untrusted_source, "<sandbox>");
switch (r) {
    .exception => |e| std.debug.print("limited: {s}\n", .{e.message}),
    else => {},
}
```

`0` means unlimited for each field. Limits apply to all subsequent `eval`
calls on that Context; call `setLimits(.{})` to reset.

---

## 6. Memory ownership contract

| Data direction | Ownership |
|---|---|
| Source strings passed **into** `eval` / `registerNativeFn` | Copied by jsz — caller may free immediately |
| `Value` handles returned from `eval` / `getProperty` / `make*` | Valid until `ctx.deinit()` |
| Strings from `Value.toString()` / `valueToDisplayString()` | **Borrowed** — valid until the next `eval` on that Context; copy with `allocator.dupe(u8, s)` to retain |
| `Exception.message`, `Exception.stack`, `ParseError.message` | Borrowed — same lifetime as above |
| `registerNativeFn` registrations | Persist for the Isolate's lifetime |

The recommended pattern for string retention:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

switch (ctx.eval("'hello'", "<embed>")) {
    .ok => |v| {
        const s = try jsz.valueToDisplayString(arena.allocator(), v);
        // `s` is valid for the lifetime of `arena`, independent of further evals.
        std.debug.print("{s}\n", .{s});
    },
    else => {},
}
```

---

## Further reading

- `examples/embed.zig` — full runnable example (`zig build example-embed`)
- [API.md](API.md) — stable vs experimental surface list
- [COOKBOOK.md](COOKBOOK.md) — short recipes
