# jsz API Reference

> Auto-generated from doc comments via `zig build docs`. This file is a human-readable scaffold.
> Status: Phase 0 — all functions return `error.NotImplemented` or a stub value.

## Module constant

| Name | Value | Description |
|---|---|---|
| `version` | `"0.0.0-phase0"` | Semantic version string. |

## `JszError`

```zig
pub const JszError = error{ NotImplemented, OutOfMemory };
```

Error set for all jsz operations.

---

## `Isolate`

VM root object. Owns the heap, GC, atom table, and symbol registry.

| Method | Signature | Description |
|---|---|---|
| `init` | `(std.mem.Allocator) JszError!Isolate` | Create a new Isolate. Must call `deinit`. |
| `deinit` | `(*Isolate) void` | Free all resources. |
| `newContext` | `(*Isolate) JszError!*Context` | Create a new JS execution context. |

---

## `Context`

A JS execution environment. Owns the global object and intrinsics.

| Method | Signature | Description |
|---|---|---|
| `deinit` | `(*Context) void` | Free the context. |
| `eval` | `(*Context, source: []const u8, source_name: []const u8) EvalResult` | Evaluate JS source. Never returns a Zig error. |
| `registerNativeFn` | `(*Context, name: []const u8, func: NativeFn) JszError!void` | Register a native Zig function as a JS global. |
| `globalObject` | `(*Context) Value` | Return the global object for this context. |

---

## `Value`

Opaque handle to a JS value. NaN-boxed in Phase 1+.

| Method | Signature | Description |
|---|---|---|
| `toI32` | `(Value) i32` | Coerce to i32. Returns 0 in Phase 0. |
| `toF64` | `(Value) f64` | Coerce to f64. Returns 0.0 in Phase 0. |
| `toString` | `(Value) []const u8` | Coerce to string. Returns `"<not implemented>"` in Phase 0. |

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
| `message` | `[]const u8` | Borrowed string. Valid until next eval. |
| `stack` | `[]const StackFrame` | Borrowed stack frames. |

---

## `ParseError`

| Field | Type | Description |
|---|---|---|
| `message` | `[]const u8` | Error description. |
| `line` | `u32` | 0-indexed line number. |
| `column` | `u32` | 0-indexed column number. |

---

## `NativeFn`

```zig
pub const NativeFn = *const fn (*Context, []const Value) NativeResult;
```

Signature for a Zig function callable from JS.

---

## `NativeResult`

```zig
pub const NativeResult = union(enum) {
    ok: Value,
    throw: Value,
};
```
