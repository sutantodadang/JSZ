# jsz API Reference

Auto-generated from doc comments via `zig build docs`. This file is a
human-readable summary. The authoritative stability annotations are in
`src/root.zig`.

---

## API stability tiers

**STABLE** (frozen for 1.0, semver-governed):

`version`, `Isolate` (`init`/`deinit`/`newContext`), `Context` (`deinit`,
`eval`, `registerNativeFn`, `globalObject`, `getProperty`,
`makeNumber`/`makeString`/`makeBool`/`makeUndefined`/`makeNull`, `gc`,
`gcStats`, `setLimits`), `Value` (`toI32`/`toF64`/`toString`), and the
result/option types (`EvalResult`, `Exception`, `ParseError`, `StackFrame`,
`GcStats`, `Limits`, `NativeFn`, `NativeResult`), plus `valueToDisplayString`.

**EXPERIMENTAL** (may change before 1.0, not semver-governed):

Bytecode snapshot (`compileSnapshot`/`evalSnapshot`/`snapshot`),
`dumpBytecode`, `sourceMap`, `debug`, JIT surface (`JitMode`, `JitProfile`,
`setJitMode`, `lastJitProfile`, `lastFrameHighWater`,
`installNativeCountLoop`/`installNativeAccumulateLoop` and their fn types),
and `_regex`.

---

## Module constant

| Name | Value | Description |
|---|---|---|
| `version` | `"0.0.0-phase9-scaffold"` | Semantic version string. |

---

## `JszError`

```zig
pub const JszError = error{ NotImplemented, OutOfMemory };
```

Error set for all jsz operations.

---

## `Isolate`

VM root object. Owns the heap, GC, atom table, and symbol registry.

| Method | Signature | Stability |
|---|---|---|
| `init` | `(std.mem.Allocator) JszError!Isolate` | STABLE |
| `deinit` | `(*Isolate) void` | STABLE |
| `newContext` | `(*Isolate) JszError!*Context` | STABLE |

---

## `Context`

A JS execution environment. Owns the global object and intrinsics. Globals
persist across `eval` calls on the same Context.

| Method | Signature | Stability |
|---|---|---|
| `deinit` | `(*Context) void` | STABLE |
| `eval` | `(*Context, []const u8, []const u8) EvalResult` | STABLE |
| `registerNativeFn` | `(*Context, []const u8, NativeFn) JszError!void` | STABLE |
| `globalObject` | `(*Context) Value` | STABLE |
| `getProperty` | `(*Context, Value, []const u8) Value` | STABLE |
| `makeNumber` | `(*Context, f64) Value` | STABLE |
| `makeString` | `(*Context, []const u8) Value` | STABLE |
| `makeBool` | `(*Context, bool) Value` | STABLE |
| `makeUndefined` | `(*Context) Value` | STABLE |
| `makeNull` | `(*Context) Value` | STABLE |
| `gc` | `(*Context) GcStats` | STABLE |
| `gcStats` | `(*Context) GcStats` | STABLE |
| `setLimits` | `(*Context, Limits) void` | STABLE |
| `compileSnapshot` | `(*Context, std.mem.Allocator, []const u8) ![]u8` | EXPERIMENTAL |
| `evalSnapshot` | `(*Context, []const u8) EvalResult` | EXPERIMENTAL |
| `setJitMode` | `(*Context, JitMode) void` | EXPERIMENTAL |
| `lastJitProfile` | `(*Context) JitProfile` | EXPERIMENTAL |
| `lastFrameHighWater` | `(*Context) usize` | EXPERIMENTAL |

---

## `Value`

Opaque handle to a JS value. Pointer-boxed internally.

| Method | Signature | Description |
|---|---|---|
| `toI32` | `(Value) i32` | Coerce to i32. |
| `toF64` | `(Value) f64` | Coerce to f64. |
| `toString` | `(Value) []const u8` | Coerce to string (borrowed). |

---

## `EvalResult`

```zig
pub const EvalResult = union(enum) {
    ok: Value,
    exception: Exception,
    parse_error: ParseError,
};
```

---

## `Exception`

| Field | Type | Description |
|---|---|---|
| `value` | `Value` | The thrown JS value. |
| `message` | `[]const u8` | Borrowed — valid until next `eval`. |
| `stack` | `[]const StackFrame` | Borrowed stack frames. |

---

## `ParseError`

| Field | Type | Description |
|---|---|---|
| `message` | `[]const u8` | Error description. |
| `line` | `u32` | 1-indexed line number. |
| `column` | `u32` | 1-indexed column number. |

---

## `Limits`

```zig
pub const Limits = struct {
    mem_bytes: usize = 0,  // 0 = unlimited
    gas: u64 = 0,
    time_ms: u64 = 0,
};
```

---

## `GcStats`

| Field | Type | Description |
|---|---|---|
| `collections` | `usize` | GC cycles run (cumulative). |
| `bytes_allocated` | `usize` | Cumulative bytes allocated (monotone). |
| `bytes_freed` | `usize` | Cumulative bytes freed (monotone). |
| `objects_alive` | `usize` | Currently live GC-managed objects. |

---

## `NativeFn` / `NativeResult`

```zig
pub const NativeFn = *const fn (*Context, []const Value) NativeResult;

pub const NativeResult = union(enum) {
    ok: Value,
    throw: Value,
};
```

---

## `valueToDisplayString`

```zig
pub fn valueToDisplayString(arena: std.mem.Allocator, v: Value) ![]const u8
```

Convert a `Value` to a display string (ECMAScript ToString). Allocated from
`arena`; valid until the arena is freed.
