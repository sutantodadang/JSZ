//! Phase 13: AbstractOperation ToPrimitive (ES2015 7.1.1) with `Symbol.toPrimitive`
//! and OrdinaryToPrimitive (`valueOf`/`toString`) support.
//!
//! Implemented as a shared free function so both VM engines and the
//! `String()`/`Number()` builtins can reuse it without circular imports.
//! Calls back into user JS via `function_proto.invokeCallback`, which routes
//! through the active context.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const function_proto = @import("function_proto.zig");

pub const Hint = enum { number, string, default };

/// True for ECMAScript primitive values (undefined, null, boolean, number,
/// string, symbol). Functions and objects are NOT primitive.
pub fn isPrimitive(v: Value) bool {
    if (v.bits == 0) return true; // undefined
    return switch (v.unbox()) {
        .undefined_, .null_, .boolean, .number, .string, .symbol => true,
        else => false,
    };
}

/// True if `v` is an object that may carry a user-defined coercion hook.
pub fn isObjectValue(v: Value) bool {
    return v.bits != 0 and v.unbox() == .object;
}

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |obj| obj.internal_kind == .bound_function,
        else => false,
    };
}

/// Walk the prototype chain looking for a symbol-keyed own property.
fn getSymMethod(obj: *JsObject, sym: Value) ?Value {
    var cur: ?*JsObject = obj;
    var depth: usize = 0;
    while (cur) |o| {
        if (depth >= 64) break;
        depth += 1;
        if (o.getOwnSym(sym)) |v| return v;
        cur = o.proto;
    }
    return null;
}

fn makeTypeErrorVal(arena: std.mem.Allocator, msg: []const u8) !Value {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}

/// ToPrimitive for the object case only.
///
/// Returns:
///   * `some(primitive)` when a user-defined conversion (`Symbol.toPrimitive`,
///     `valueOf`, or `toString`) yields a primitive value;
///   * `null` when `v` is already a primitive, or when `v` is an object with
///     no applicable user conversion — in which case the caller should fall
///     back to its existing default coercion (e.g. `"[object Object]"`).
///
/// Throws (`error.JsException` + sets `pending_exception`) when a
/// `Symbol.toPrimitive` hook returns a non-primitive.
pub fn toPrimitive(arena: std.mem.Allocator, v: Value, hint: Hint) anyerror!?Value {
    if (!isObjectValue(v)) return null;
    const obj = v.toPtr().object;

    // 1. Exotic @@toPrimitive hook.
    if (realm_mod.active_sym_to_primitive) |sym| {
        if (getSymMethod(obj, sym)) |method| {
            if (isCallable(method)) {
                const hint_str: []const u8 = switch (hint) {
                    .number => "number",
                    .string => "string",
                    .default => "default",
                };
                const hv = try val_mod.makeString(arena, hint_str);
                const res = try function_proto.invokeCallback(arena, v, method, &[_]Value{hv});
                if (isPrimitive(res)) return res;
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert object to primitive value");
                return error.JsException;
            }
        }
    }

    // 2. OrdinaryToPrimitive: method order depends on hint.
    const names: [2][]const u8 = if (hint == .string)
        .{ "toString", "valueOf" }
    else
        .{ "valueOf", "toString" };
    for (names) |name| {
        const method = obj.get(name) orelse continue;
        if (!isCallable(method)) continue;
        const res = try function_proto.invokeCallback(arena, v, method, &[_]Value{});
        if (isPrimitive(res)) return res;
    }

    // 3. No user-defined conversion applies; caller uses its default.
    return null;
}
