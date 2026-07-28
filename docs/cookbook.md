# jsz Cookbook

Short recipes for common embedding patterns. See `examples/embed.zig` for a
runnable version and `docs/EMBEDDING.md` for the full tutorial.

---

## Expose a Zig function to JS

```zig
fn hostMultiply(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    const a = if (args.len > 0) args[0].toF64() else 0;
    const b = if (args.len > 1) args[1].toF64() else 0;
    return .{ .ok = ctx.makeNumber(a * b) };
}

try ctx.registerNativeFn("multiply", hostMultiply);
// JS: multiply(6, 7)  →  42
```

Available make helpers: `makeNumber`, `makeString`, `makeBool`,
`makeUndefined`, `makeNull`.

---

## Read a JS value from the host

```zig
_ = ctx.eval("var score = 99;", "<embed>");

const g = ctx.globalObject();
const score = ctx.getProperty(g, "score");
std.debug.print("score = {d}\n", .{score.toF64()});

// For string values:
const msg = ctx.getProperty(g, "msg");
std.debug.print("msg = {s}\n", .{msg.toString()});
// toString() is borrowed; copy with allocator.dupe(u8, s) to outlive the next eval.
```

---

## Catch a JS error

```zig
switch (ctx.eval("throw new Error('boom')", "<embed>")) {
    .ok => |v| handleValue(v),
    .exception => |e| {
        std.debug.print("JS threw: {s}\n", .{e.message});
        // e.stack contains StackFrame entries (function_name, source_name, line, col).
    },
    .parse_error => |e| {
        std.debug.print("Syntax error at {d}:{d}: {s}\n", .{ e.line, e.column, e.message });
    },
}
```

---

## Cap execution with resource limits

```zig
ctx.setLimits(.{
    .gas     = 500_000,           // bytecode instruction budget
    .time_ms = 50,                // wall-clock cap in milliseconds
    .mem_bytes = 4 * 1024 * 1024, // live heap cap in bytes
});

switch (ctx.eval(untrusted_code, "<sandbox>")) {
    .exception => |e| std.debug.print("capped: {s}\n", .{e.message}),
    .ok => |v| handleResult(v),
    .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
}
// Reset to unlimited:
ctx.setLimits(.{});
```

`0` means unlimited for each field. Limit breaches always produce
`EvalResult.exception` — never a crash or hang.
