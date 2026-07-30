# Embedding jsz

How-to guide for embedding jsz in a Zig application. For a first walkthrough
from an empty project, see [docs/getting-started.md](getting-started.md) —
this document goes deeper on each part of the embedding API.

The public API lives in `src/root.zig` and is exposed as the `jsz` module in
`build.zig`. The runnable version of every snippet below is
`examples/embed.zig` (`zig build example-embed`). API stability is documented
at the top of `src/root.zig`: **STABLE** symbols are frozen for 1.0;
**EXPERIMENTAL** symbols (snapshots, GC tuning, JIT controls, `dumpBytecode`)
may change before 1.0.

---

## Add jsz to your project

In your `build.zig.zon`, add a dependency — either fetched:

```sh
$ zig fetch --save https://github.com/sutantodadang/JSZ/archive/refs/heads/main.tar.gz
```

or, while developing against a local checkout, a path dependency:

```zig
.dependencies = .{
    .jsz = .{ .path = "../jsz" },
},
```

Wire the module into your executable in `build.zig`:

```zig
const jsz_dep = b.dependency("jsz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jsz", jsz_dep.module("jsz"));
```

Then in your source:

```zig
const jsz = @import("jsz");
```

**Verify**: `zig build` succeeds and `@import("jsz")` resolves.

---

## Isolate → Context → eval

One `Isolate` per process (owns the heap, GC, and atom table). One `Context`
per execution environment (owns eval-time state and the global object):

```zig
var iso = try jsz.Isolate.init(allocator);
defer iso.deinit();

var ctx = try iso.newContext();
defer ctx.deinit();

switch (ctx.eval("1 + 2", "<inline>")) {
    .ok => |v| std.debug.print("result = {d}\n", .{v.toF64()}),
    .exception => |e| std.debug.print("uncaught: {s}\n", .{e.message}),
    .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
}
```

`Isolate.init` and `iso.newContext` are the only calls in this snippet that
return a Zig `error.OutOfMemory`. `eval` never does — every JS-level failure
comes back as `EvalResult.exception` or `EvalResult.parse_error`. The
`source_name` argument (`"<inline>"` above) labels the source in parse
errors and stack traces.

**Verify**: `zig build example-embed` prints `total = 2` /
`host sees total = 2` (see [Verification](#verification-with-the-shipped-example) below).

---

## Expose a host function

A `NativeFn` is a plain function pointer with a fixed signature:

```zig
pub const NativeFn = *const fn (*Context, []const Value) NativeResult;
```

`NativeResult` is a tagged union: `.ok` returns a value to JS, `.throw`
raises a JS exception carrying that value.

```zig
fn hostAddOne(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    const n = if (args.len > 0) args[0].toF64() else 0;
    return .{ .ok = ctx.makeNumber(n + 1) };
}

fn hostFail(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    _ = args;
    return .{ .throw = ctx.makeString("something went wrong") };
}

// Register before the first eval that needs it.
try ctx.registerNativeFn("addOne", hostAddOne);
try ctx.registerNativeFn("fail", hostFail);

const r = ctx.eval("addOne(41)", "<embed>");
// r.ok.toF64() == 42
```

Registrations persist for the lifetime of the Isolate, not just the Context
that registered them.

**Verify**: `zig build example-embed` calls `addOne` twice and prints
`total = 2`.

---

## Exchange values between host and JS

Build JS values from Zig with the `make*` helpers on `Context`:

| Helper | JS value |
|---|---|
| `ctx.makeNumber(f64)` | number |
| `ctx.makeString([]const u8)` | string (copied) |
| `ctx.makeBool(bool)` | boolean |
| `ctx.makeUndefined()` | `undefined` |
| `ctx.makeNull()` | `null` |

Read JS values back into Zig with methods on `Value`:

| Method | Result |
|---|---|
| `v.toF64()` | `f64` |
| `v.toI32()` | `i32` |
| `v.toString()` | `[]const u8` (borrowed — see [ownership](#memory-ownership)) |

For a display-quality string of *any* value (objects, arrays, `undefined`,
etc. — the same formatting `console.log` uses), use the free function
`jsz.valueToDisplayString(allocator, value) ![]const u8`.

Read a global variable the script set:

```zig
_ = ctx.eval("var answer = 42;", "<embed>");

const g = ctx.globalObject();
const v = ctx.getProperty(g, "answer");
std.debug.print("answer = {d}\n", .{v.toF64()});
```

`getProperty(obj, name)` walks the prototype chain and returns an
undefined-`Value` (`bits == 0`) if the property is absent or `obj` is not an
object — it does not return a Zig error.

---

## Handle errors

`EvalResult` is a three-armed union — switch on it exhaustively:

```zig
switch (ctx.eval(source, name)) {
    .ok => |v| { /* use v */ },
    .exception => |e| {
        // e.message: []const u8 — human-readable, e.g. from `throw new Error(...)`
        // e.value:   Value      — the thrown value itself (may not be an Error)
        // e.stack:   []const StackFrame — function_name/source_name/line/column
    },
    .parse_error => |e| {
        // e.message, e.line, e.column — a SyntaxError caught before execution starts
    },
}
```

`Exception.stack` is populated for JS-level throws; each `StackFrame` gives
`function_name`, `source_name`, `line`, and `column` for one frame. There is
no separate "crash" case to handle at the API level — a script that would
otherwise crash the process (stack overflow, out-of-memory) is expected to
surface as `.exception` instead; see [Resource limits](#enforce-resource-limits)
to cap execution before that boundary is reached at all.

---

## Enforce resource limits

Cap untrusted JS with `Context.setLimits`. A breach surfaces as
`EvalResult.exception`, never a crash or hang:

```zig
ctx.setLimits(.{
    .gas       = 1_000_000,        // max bytecode instructions
    .time_ms   = 100,               // max wall-clock milliseconds
    .mem_bytes = 8 * 1024 * 1024,   // max live heap+arena bytes
});
const r = ctx.eval(untrusted_source, "<sandbox>");
switch (r) {
    .exception => |e| std.debug.print("limited: {s}\n", .{e.message}),
    else => {},
}
```

`0` (the default) means unlimited for that field. Limits apply to every
subsequent `eval`/`evalModule` call on the Context until you call
`setLimits(.{})` again to reset. `gas` and `time_ms` are enforced by the
bytecode VM (the only interpreter — nothing to opt into); `mem_bytes` caps
live heap across all interpreter modes.

**Scope note**: limits stop a script from running away with CPU, wall-clock
time, or memory. They are not a hardened sandbox for hostile native
callbacks or for isolating scripts from each other within one process — see
[SECURITY.md](../SECURITY.md) for the current threat-model framing.

---

## Control GC

```zig
const stats = ctx.gcStats();   // current cumulative stats, no collection triggered
// stats.collections, .bytes_allocated, .bytes_freed, .objects_alive

const after = ctx.gc();        // force a mark-sweep cycle now, returns stats after
```

EXPERIMENTAL tuning knobs (may change before 1.0):

```zig
// nursery_bytes: fixed young-generation size; major_period: minor collections
// between full majors (0 = every collection is a major, i.e. classic
// non-generational mark-sweep, useful for A/B perf comparisons);
// pause_log: record per-collection pause times.
ctx.gcConfigure(4 * 1024 * 1024, 8, true);

const pauses = ctx.gcPauses();     // []const u64, nanoseconds, since gcConfigure(..., true)
const gens = ctx.gcGenCounts();    // .minor, .major collection counts
```

---

## Precompile with snapshots

EXPERIMENTAL. Compile once, restore many times without re-parsing:

```zig
const image = try ctx.compileSnapshot(allocator, source); // caller-owned, persistable to disk
defer allocator.free(image);

// ... later, possibly in a different process, against a fresh Context:
const r = ctx.evalSnapshot(image);
```

`compileSnapshot` produces a sourceless bytecode image owned by the caller —
write it to disk with `std.fs.cwd().writeFile` and load it back with
`readFileAlloc` before calling `evalSnapshot`. The CLI's
`--emit-bytecode <path>` / `--run-bytecode <path>` flags exercise the same
pair; see [docs/cli.md](cli.md).

---

## Run ES modules

EXPERIMENTAL. `evalModule` runs `source` as strict-mode ES-module code;
`import`/`export` are desugared onto the CommonJS `require`/`exports` model
under the hood:

```zig
const r = ctx.evalModule(module_source, "my-module.mjs");
```

`source_name` becomes the module's canonical specifier (used as the
`ModuleRecord` id and as the source name in errors/stack traces).

---

## Multiple contexts per isolate

`iso.newContext()` can be called more than once. Each call returns an
independent `Context` value with its own `eval`/`gc`/`limits` state:

```zig
var ctx1 = try iso.newContext();
defer ctx1.deinit();
var ctx2 = try iso.newContext();
defer ctx2.deinit();
```

**Verified current behavior**: top-level `var` bindings are visible across
contexts created on the same Isolate — a global declared in `ctx1` is
readable from `ctx2`. Contexts sharing an Isolate are not a global-scope
isolation boundary today. If you need scripts fully isolated from each
other's globals, give each one its own `Isolate` (which also gives each its
own GC heap and atom table, at the cost of a separate `init`/`deinit`).

---

## Memory ownership

| Data direction | Ownership |
|---|---|
| Source strings passed **into** `eval` / `evalModule` / `registerNativeFn` | Copied by jsz — caller may free immediately |
| `Value` handles returned from `eval` / `getProperty` / `make*` | Valid until `ctx.deinit()` |
| Strings from `Value.toString()` / `valueToDisplayString()` | **Borrowed** — valid until the next `eval` on that Context; copy with `allocator.dupe(u8, s)` to retain |
| `Exception.message`, `Exception.stack`, `ParseError.message` | Borrowed — same lifetime as above |
| `registerNativeFn` registrations | Persist for the Isolate's lifetime |
| `compileSnapshot` output | Caller-owned (`out_allocator`) — outlives the Context |

The recommended pattern for retaining a result string past the next `eval`:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

switch (ctx.eval("'hello'", "<embed>")) {
    .ok => |v| {
        const s = try jsz.valueToDisplayString(arena.allocator(), v);
        // `s` is valid for the lifetime of `arena`, independent of further evals.
    },
    else => {},
}
```

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `error.OutOfMemory` from `Isolate.init`/`newContext` | Host allocator exhausted before any JS ran — not a limits issue |
| `eval` returns `.exception` immediately for trivial scripts | Check `setLimits` wasn't left over-tight from a previous call on the same Context |
| A retained string reads as garbage | You held a `Value.toString()`/`valueToDisplayString()` result past the next `eval` without copying it — see [ownership](#memory-ownership) |
| `registerNativeFn` succeeds but the JS call is `undefined` | Register before the `eval` that references the name; the global is bound at registration time |

---

## Verification with the shipped example

```sh
$ zig build example-embed
total = 2
host sees total = 2
```

`examples/embed.zig` exercises `Isolate`/`Context`/`eval`/`registerNativeFn`/
`globalObject`/`getProperty`/`valueToDisplayString` end to end — read it
alongside this document.

## Embedding from C (and Rust, Go, ...)

A C ABI wraps the same Isolate/Context/eval surface for any language with a
C FFI. Build the shared library and header, then link `-ljsz`:

```sh
$ zig build capi          # zig-out: libjsz.{so,dylib} / jsz.dll+jsz.lib, include/jsz.h
$ zig build example-capi  # compile + run examples/embed.c (the CI gate)
```

```c
#include "jsz.h"

jsz_isolate *iso = jsz_isolate_new();
jsz_context *ctx = jsz_context_new(iso);
jsz_context_set_limits(ctx, 64 << 20, 10 * 1000 * 1000, 100); /* untrusted input */
if (jsz_eval(ctx, "6 * 7", NULL) == JSZ_OK)
    printf("%s\n", jsz_last_string(ctx)); /* "42" */
jsz_context_free(ctx);
jsz_isolate_free(iso);
```

Status codes: `JSZ_OK` / `JSZ_EXCEPTION` / `JSZ_PARSE_ERROR` / `JSZ_ERR_NOMEM`.
`jsz_last_string` returns the result's display string (or the error message)
and stays valid until the next `jsz_eval` on that context; `jsz_last_number`
extracts a JS number result. Sources are copied on eval, so the caller may
free them immediately. The full contract is documented in
[include/jsz.h](../include/jsz.h); `examples/embed.c` is the runnable
reference. Native-function registration across the C boundary is not exposed
yet — embed from Zig if you need host callbacks today.

## Further reading

- [docs/getting-started.md](getting-started.md) — zero-to-running tutorial
- `examples/embed.zig` — full runnable example (`zig build example-embed`)
- [docs/api.md](api.md) — stable vs experimental surface list
- [docs/cli.md](cli.md) — CLI flags, including bytecode snapshot and limit flags
- [docs/cookbook.md](cookbook.md) — short recipes
