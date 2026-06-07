// SPDX-License-Identifier: Apache-2.0
//! Phase 4d: Function.prototype — call, apply, bind.
//!
//! BoundFunction is stored as a JsObject with internal_kind = .bound_function.
//! The internal_slot points to a BoundData struct (arena-allocated).
//! GC traverses props naturally (no markObject change needed).
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");

/// Data stored inside a bound function object's internal_slot.
pub const BoundData = struct {
    target: Value,
    this_val: Value,
    prefix: []Value,
};

/// Invoke any callable JS value synchronously.
/// Uses the active_context thread-local.
/// On JS exception: sets pending_exception and returns error.JsException.
pub fn invokeCallback(arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
    if (fn_val.bits == 0) {
        // undefined is not a function
        realm_mod.pending_exception = try makeTypeError(arena, "undefined is not a function");
        return error.JsException;
    }
    // Check reentrant depth.
    realm_mod.callback_depth += 1;
    defer realm_mod.callback_depth -= 1;
    if (realm_mod.callback_depth > 1000) {
        realm_mod.pending_exception = try makeRangeError(arena, "Maximum call stack size exceeded");
        return error.JsException;
    }

    const inner = fn_val.unbox();
    switch (inner) {
        .native_function => |fn_ptr| {
            return fn_ptr.invoke(arena, this_val, args) catch |e| {
                if (e == error.JsException) return error.JsException;
                return error.OutOfMemory;
            };
        },
        .function, .bc_function => {
            // Delegate to active_context.
            if (realm_mod.active_context) |ctx| {
                return ctx.invokeJs(arena, this_val, fn_val, args);
            }
            realm_mod.pending_exception = try makeTypeError(arena, "no active context for JS callback");
            return error.JsException;
        },
        .object => |obj| {
            if (obj.internal_kind == .bound_function) {
                // Unpack bound function.
                if (obj.internal_slot) |slot| {
                    const bd: *BoundData = @ptrCast(@alignCast(slot));
                    // Combine prefix + runtime args.
                    const total = bd.prefix.len + args.len;
                    var combined = try arena.alloc(Value, total);
                    for (bd.prefix, 0..) |v, i| combined[i] = v;
                    for (args, 0..) |v, i| combined[bd.prefix.len + i] = v;
                    return invokeCallback(arena, bd.this_val, bd.target, combined);
                }
            }
            // Object with __call__: delegate via active_context.
            if (realm_mod.active_context) |ctx| {
                return ctx.invokeJs(arena, this_val, fn_val, args);
            }
            realm_mod.pending_exception = try makeTypeError(arena, "object is not callable");
            return error.JsException;
        },
        else => {
            realm_mod.pending_exception = try makeTypeError(arena, "value is not a function");
            return error.JsException;
        },
    }
}

fn makeTypeError(arena: std.mem.Allocator, msg: []const u8) !Value {
    const proto = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, msg);
    const name_val = try val_mod.makeString(arena, "TypeError");
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    return val_mod.makeObject(arena, obj);
}

fn makeRangeError(arena: std.mem.Allocator, msg: []const u8) !Value {
    const proto = realm_mod.error_proto_RangeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, msg);
    const name_val = try val_mod.makeString(arena, "RangeError");
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    return val_mod.makeObject(arena, obj);
}

// ------------------------------------------------------------------ Function.prototype methods ---

/// Function.prototype.call(thisArg, ...args)
pub fn nativeFunctionCall(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // `this_val` is the function being called.
    const fn_val = this_val;
    const call_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    return invokeCallback(arena, call_this, fn_val, call_args) catch |e| {
        if (e == error.JsException) return error.JsException;
        return e;
    };
}

/// Function.prototype.apply(thisArg, argArray)
pub fn nativeFunctionApply(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const fn_val = this_val;
    const call_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // Extract argArray.
    var call_args: []Value = &[_]Value{};
    if (args.len > 1 and args[1].bits != 0) {
        const arr_val = args[1];
        if (arr_val.unbox() == .object) {
            const arr = arr_val.toPtr().object;
            if (arr.is_array) {
                const len = arr.getArrayLength();
                call_args = try arena.alloc(Value, len);
                for (0..len) |i| {
                    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                    call_args[i] = arr.get(key) orelse try val_mod.makeUndefined(arena);
                }
            }
        }
    }
    return invokeCallback(arena, call_this, fn_val, call_args) catch |e| {
        if (e == error.JsException) return error.JsException;
        return e;
    };
}

/// Function.prototype.bind(thisArg, ...prefix) -> BoundFunction
pub fn nativeFunctionBind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const fn_val = this_val;
    const bind_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const prefix: []Value = if (args.len > 1) blk: {
        const p = try arena.alloc(Value, args.len - 1);
        for (args[1..], 0..) |v, i| p[i] = v;
        break :blk p;
    } else &[_]Value{};

    // Create bound data.
    const bd = try arena.create(BoundData);
    bd.* = BoundData{ .target = fn_val, .this_val = bind_this, .prefix = prefix };

    // Create bound function object.
    const bound_obj = try JsObject.create(arena, null);
    bound_obj.internal_kind = .bound_function;
    bound_obj.internal_slot = bd;
    return val_mod.makeObject(arena, bound_obj);
}
