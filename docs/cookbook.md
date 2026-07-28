# jsz Cookbook

Task-oriented recipes for embedding jsz. Every snippet is checked against the
actual signatures in `src/root.zig` (full reference: [api.md](api.md)). See
`examples/embed.zig` and `examples/hello.zig` for runnable versions, and
[EMBEDDING.md](EMBEDDING.md) for a guided tutorial. Build/run examples with
`zig build example-embed` / `zig build example-hello`.

---

## Evaluate a script

```zig
var iso = try jsz.Isolate.init(allocator);
defer iso.deinit();
var ctx = try iso.newContext();
defer ctx.deinit();

switch (ctx.eval("1 + 2", "<script>")) {
    .ok => |v| std.debug.print("result = {d}\n", .{v.toF64()}), // 3
    .exception => |e| std.debug.print("threw: {s}\n", .{e.message}),
    .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
}
```

`Context.eval` never returns a Zig error for script-level failures —
exceptions and syntax errors are `EvalResult` values, not `error{...}`.

---

## Persist globals across evals

Globals live on the `Context`, not the call — declarations made in one `eval`
are visible in later ones on the same `Context`:

```zig
_ = ctx.eval("var total = 0;", "<embed>");
_ = ctx.eval("total = total + 1;", "<embed>");
const r = ctx.eval("total", "<embed>"); // .ok with total == 1
```

Use a fresh `Context` (via `iso.newContext()`) when you need an isolated
global scope — Contexts sharing an `Isolate` share the heap/GC/atom table but
not globals.

---

## Register a host function

```zig
fn hostMultiply(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    const a = if (args.len > 0) args[0].toF64() else 0;
    const b = if (args.len > 1) args[1].toF64() else 0;
    return .{ .ok = ctx.makeNumber(a * b) };
}

try ctx.registerNativeFn("multiply", hostMultiply);
// JS: multiply(6, 7) -> 42
```

Return `.{ .throw = someValue }` instead of `.ok` to raise a JS exception
from host code — it surfaces to a JS `catch` and, if uncaught, as
`EvalResult.exception`. Value constructors available on `Context`:
`makeNumber`, `makeString`, `makeBool`, `makeUndefined`, `makeNull`.

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

For a value that may be any JS type (object, array, function, symbol...),
use `valueToDisplayString` instead of `toString`/`toF64` — it applies
ECMAScript `ToString` semantics and handles every value kind:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const s = try jsz.valueToDisplayString(arena.allocator(), value);
// s is valid until arena.deinit()
```

---

## Handle errors

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

`e.message` and `e.value` (for `.exception`) are borrowed — valid only until
the next `eval`/`evalModule`/`evalSnapshot` call on that `Context`. Copy
`message` with `allocator.dupe(u8, s)` if you need it past that point.

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

`0` means unlimited for each field of `Limits`. Limit breaches always
produce `EvalResult.exception` — never a crash or hang. `gas` and `time_ms`
are enforced only in the bytecode VM (the only interpreter today, so this is
automatic); `mem_bytes` is enforced regardless of interpreter mode.

---

## Control the GC

```zig
// Trigger a manual collection and read stats:
const stats = ctx.gc();
std.debug.print("alive={d} allocated={d} freed={d}\n", .{
    stats.objects_alive, stats.bytes_allocated, stats.bytes_freed,
});

// Read stats without collecting:
const s2 = ctx.gcStats();
```

Tune the generational collector (EXPERIMENTAL — may change before 1.0):

```zig
// nursery_bytes: young-generation size; major_period: minor collections
// between full majors (0 = every collection is a major, i.e. classic
// non-generational mark-sweep, useful for A/B perf comparison).
ctx.gcConfigure(1 * 1024 * 1024, 8, true /* pause_log */);

_ = ctx.eval(some_allocating_script, "<embed>");

const pauses_ns = ctx.gcPauses();     // per-collection pause durations
const counts = ctx.gcGenCounts();     // .{ .minor = n, .major = m }
```

---

## Bytecode snapshots

Compile once, persist to disk, and skip parsing/compiling on later runs
(EXPERIMENTAL — the on-disk format is not yet stable across jsz versions):

```zig
// Compile and persist:
const image = try ctx.compileSnapshot(allocator, "1 + 2");
defer allocator.free(image);
try std.fs.cwd().writeFile(.{ .sub_path = "out.jbc", .data = image });

// Later (same or different process), load and run:
const loaded = try std.fs.cwd().readFileAlloc(allocator, "out.jbc", 64 * 1024 * 1024);
defer allocator.free(loaded);
switch (ctx2.evalSnapshot(loaded)) {
    .ok => |v| std.debug.print("result = {d}\n", .{v.toF64()}),
    .exception => |e| std.debug.print("threw: {s}\n", .{e.message}),
    .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
}
```

The CLI exposes the same pair as `--emit-bytecode <path>` and
`--run-bytecode <path>` — see [cli.md](cli.md).

---

## Run ES modules

```zig
const r = ctx.evalModule(
    \\ export const answer = 6 * 7;
    \\ export default answer;
, "<mod>");
```

`evalModule` (EXPERIMENTAL) runs the source in strict mode and desugars
`import`/`export` onto the CommonJS `require`/`exports` model internally.
Returns the same `EvalResult` union as `eval`. For a multi-file module graph
loaded from disk, use the CLI (`jsz --module entry.mjs`) or drive
`jsz.module_loader.buildBundle` directly for a custom loader.

---

## Sandboxing patterns

Combine limits, a fresh `Context` per invocation, and a native "reset"
between runs for untrusted-script sandboxing:

```zig
fn runSandboxed(iso: *jsz.Isolate, source: []const u8) jsz.EvalResult {
    var ctx = iso.newContext() catch return .{ .exception = .{
        .value = .{}, .message = "out of memory", .stack = &.{},
    } };
    defer ctx.deinit();

    ctx.setLimits(.{
        .gas = 1_000_000,
        .time_ms = 100,
        .mem_bytes = 8 * 1024 * 1024,
    });

    return ctx.eval(source, "<sandbox>");
}
```

Each `Context` gets independent globals, so one script cannot see another's
state; they still share the `Isolate`'s heap and GC, so budget `mem_bytes`
per Context rather than assuming full process isolation. For true process
isolation, run untrusted scripts in a separate OS process (one `Isolate` per
process) instead.

---

See also: [api.md](api.md) for the complete method reference,
[cli.md](cli.md) for the equivalent command-line flags, and
[architecture.md](architecture.md) for how the GC, bytecode VM, and JIT work
under these calls.
