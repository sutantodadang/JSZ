// SPDX-License-Identifier: Apache-2.0
//! Phase 4b: Array.prototype native functions.
//! push/pop mutate the array. slice/indexOf/join/concat are non-mutating.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;

/// Extract the array object from this_val or return null.
fn getArray(this_val: Value) ?*JsObject {
    // Must be a real heap cell before toPtr(): a boxed primitive `this`
    // (boolean/number/null via Array.prototype.*.call(primitive)) has nonzero
    // non-pointer bits, so a bare `bits == 0` guard let it through and
    // @ptrFromInt() dereferenced garbage (access violation).
    if (!this_val.isHeapPtr()) return null;
    const inner = this_val.toPtr();
    if (inner.* != .object) return null;
    const obj = inner.object;
    if (!obj.is_array) return null;
    return obj;
}

pub fn nativePush(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    for (args) |a| {
        const idx = arr.array_length;
        const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
        try arr.set(key, a);
        // arr.set already bumps array_length when key parses as index
    }
    return val_mod.makeNumber(arena, @floatFromInt(arr.array_length));
}

pub fn nativePop(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (arr.array_length == 0) return val_mod.makeUndefined(arena);
    const idx = arr.array_length - 1;
    const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
    const val = arr.getOwn(key) orelse return val_mod.makeUndefined(arena);
    _ = try arr.deleteOwn(key);
    arr.array_length = idx;
    return val;
}

pub fn nativeSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    const len = arr.array_length;

    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;

    const start_raw: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;

    const end_raw: f64 = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .number => |n| n,
            .undefined_ => @floatFromInt(len),
            else => @floatFromInt(len),
        }
    else
        @floatFromInt(len);

    const start = normalizeIndex(start_raw, len);
    const end_ = normalizeIndex(end_raw, len);

    const new_arr = try JsObject.createArray(arena, arr_proto);
    if (start < end_) {
        var ni: u32 = 0;
        var i: usize = start;
        while (i < end_) : (i += 1) {
            const src_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const dst_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            if (arr.getOwn(src_key)) |elem| {
                try new_arr.set(dst_key, elem);
            } else {
                const undef = try val_mod.makeUndefined(arena);
                try new_arr.set(dst_key, undef);
            }
            ni += 1;
        }
        new_arr.array_length = ni;
    }
    return val_mod.makeObject(arena, new_arr);
}

pub fn nativeIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeNumber(arena, -1.0);
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const search = args[0];
    const len = arr.array_length;

    const from: usize = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .number => |n| blk: {
                if (n < 0.0) {
                    const r = @as(i64, @intCast(len)) + val_mod.f64ToI64Sat(n);
                    break :blk if (r < 0) 0 else @intCast(r);
                }
                break :blk @intCast(val_mod.f64ToI64Sat(n));
            },
            else => 0,
        }
    else
        0;

    var i: usize = from;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        if (arr.getOwn(key)) |elem| {
            if (jsStrictEqual(elem, search)) {
                return val_mod.makeNumber(arena, @floatFromInt(i));
            }
        }
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// ES2016 Array.prototype.includes — SameValueZero (NaN matches NaN), scans holes as undefined.
pub fn nativeIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeBool(arena, false);
    const search = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    const from: usize = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .number => |n| blk: {
                if (n < 0.0) {
                    const r = @as(i64, @intCast(len)) + val_mod.f64ToI64Sat(n);
                    break :blk if (r < 0) 0 else @intCast(r);
                }
                break :blk @intCast(val_mod.f64ToI64Sat(n));
            },
            else => 0,
        }
    else
        0;
    const undef = try val_mod.makeUndefined(arena);
    var i: usize = from;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse undef;
        if (sameValueZero(elem, search)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

/// Recursively append src's elements into dst, flattening nested arrays up to `depth`.
fn flattenInto(arena: std.mem.Allocator, dst: *JsObject, src: *JsObject, depth: i64, ni: *u32) anyerror!void {
    var i: usize = 0;
    while (i < src.array_length) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = src.getOwn(key) orelse continue;
        if (depth > 0 and elem.bits != 0 and elem.unbox() == .object and elem.toPtr().object.is_array) {
            try flattenInto(arena, dst, elem.toPtr().object, depth - 1, ni);
        } else {
            const dk = try std.fmt.allocPrint(arena, "{d}", .{ni.*});
            try dst.set(dk, elem);
            ni.* += 1;
        }
    }
}

/// ES2019 Array.prototype.flat — default depth 1.
pub fn nativeFlat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const depth: i64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| blk: {
                if (std.math.isNan(n)) break :blk 0;
                const t = @trunc(n);
                // Clamp ±Infinity / out-of-range before the int cast (no panic).
                if (t >= 9.2233720368547758e18) break :blk std.math.maxInt(i64);
                if (t <= -9.2233720368547758e18) break :blk std.math.minInt(i64);
                break :blk @intFromFloat(t);
            },
            else => 1,
        }
    else
        1;
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var ni: u32 = 0;
    try flattenInto(arena, new_arr, arr, depth, &ni);
    new_arr.array_length = ni;
    return val_mod.makeObject(arena, new_arr);
}

/// ES2019 Array.prototype.flatMap — map then flatten one level.
pub fn nativeFlatMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const len = arr.array_length;
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var ni: u32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const mapped = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (mapped.bits != 0 and mapped.unbox() == .object and mapped.toPtr().object.is_array) {
            try flattenInto(arena, new_arr, mapped.toPtr().object, 1, &ni);
        } else {
            const dk = try std.fmt.allocPrint(arena, "{d}", .{ni});
            try new_arr.set(dk, mapped);
            ni += 1;
        }
    }
    new_arr.array_length = ni;
    return val_mod.makeObject(arena, new_arr);
}

pub fn nativeJoin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeString(arena, "");
    const len = arr.array_length;

    const sep: []const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |s| s,
            .undefined_ => ",",
            .null_ => ",",
            else => ",",
        }
    else
        ",";

    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, sep);
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        if (arr.getOwn(key)) |elem| {
            const s = try elemToString(arena, elem);
            try buf.appendSlice(arena, s);
        }
    }
    return val_mod.makeString(arena, buf.items);
}

pub fn nativeConcat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var ni: u32 = 0;

    // Append this array's elements
    if (getArray(this_val)) |base| {
        var i: usize = 0;
        while (i < base.array_length) : (i += 1) {
            const src_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const dst_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            if (base.getOwn(src_key)) |elem| {
                try new_arr.set(dst_key, elem);
            }
            ni += 1;
        }
    } else {
        // Non-array this: treat as single element
        const key = try std.fmt.allocPrint(arena, "{d}", .{ni});
        try new_arr.set(key, this_val);
        ni += 1;
    }

    // Append each arg
    for (args) |a| {
        if (a.bits != 0 and a.unbox() == .object and a.toPtr().object.is_array) {
            // Spread one level
            const arg_arr = a.toPtr().object;
            var i: usize = 0;
            while (i < arg_arr.array_length) : (i += 1) {
                const src_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                const dst_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
                if (arg_arr.getOwn(src_key)) |elem| {
                    try new_arr.set(dst_key, elem);
                }
                ni += 1;
            }
        } else {
            const key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            try new_arr.set(key, a);
            ni += 1;
        }
    }
    new_arr.array_length = ni;
    return val_mod.makeObject(arena, new_arr);
}

// ------------------------------------------------------------------ Phase 4d callback methods ---

/// Call the callback with (element, index, array). On exception returns error.JsException.
fn callCb(arena: std.mem.Allocator, cb: Value, this_arg: Value, elem: Value, idx: f64, arr_val: Value) anyerror!Value {
    const function_proto_mod = @import("../builtins/function_proto.zig");
    const args = [_]Value{ elem, try val_mod.makeNumber(arena, idx), arr_val };
    return function_proto_mod.invokeCallback(arena, this_arg, cb, &args) catch |e| {
        return e;
    };
}

fn isTruthy(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_ => false,
        .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0.0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
}

pub fn nativeForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        _ = callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val) catch |e| {
            return e;
        };
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const len = arr.array_length;
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        try new_arr.set(key, result);
    }
    return val_mod.makeObject(arena, new_arr);
}

pub fn nativeFilter(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const len = arr.array_length;
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var ni: u32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) {
            const dst_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            try new_arr.set(dst_key, elem);
            ni += 1;
        }
    }
    return val_mod.makeObject(arena, new_arr);
}

pub fn nativeReduce(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const len = arr.array_length;
    var acc: Value = undefined;
    var start_i: usize = 0;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (len == 0) return error.JsException; // TypeError
        const key0 = try std.fmt.allocPrint(arena, "0", .{});
        acc = arr.getOwn(key0) orelse try val_mod.makeUndefined(arena);
        start_i = 1;
    }
    var i: usize = start_i;
    const undef = try val_mod.makeUndefined(arena);
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse undef;
        const fpm = @import("../builtins/function_proto.zig");
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), this_val };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeReduceRight(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const len = arr.array_length;
    var acc: Value = undefined;
    var start_i: i64 = @intCast(len);
    if (args.len > 1) {
        acc = args[1];
        start_i = @intCast(len);
    } else {
        if (len == 0) return error.JsException;
        start_i = @intCast(len - 1);
        const key_last = try std.fmt.allocPrint(arena, "{d}", .{len - 1});
        acc = arr.getOwn(key_last) orelse try val_mod.makeUndefined(arena);
        start_i -= 1;
    }
    const undef = try val_mod.makeUndefined(arena);
    const fpm = @import("../builtins/function_proto.zig");
    var i: i64 = start_i - 1;
    while (i >= 0) : (i -= 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse undef;
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), this_val };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeSome(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeBool(arena, false);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeEvery(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeBool(arena, true);
    if (args.len == 0) return val_mod.makeBool(arena, true);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (!isTruthy(result)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeFind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeFindIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeNumber(arena, -1.0);
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// ES2022 Array.prototype.at — negative indices count from the end.
pub fn nativeAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    const len = arr.array_length;
    if (len == 0) return val_mod.makeUndefined(arena);
    const idx_raw: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const k = relativeIndex(idx_raw, len);
    if (k >= len) return val_mod.makeUndefined(arena);
    const key = try std.fmt.allocPrint(arena, "{d}", .{k});
    return arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
}

/// ES2022 Array.prototype.findLast — like find, scans from the end.
pub fn nativeFindLast(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    if (len == 0) return val_mod.makeUndefined(arena);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

/// ES2022 Array.prototype.findLastIndex — like findIndex, scans from the end.
pub fn nativeFindLastIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeNumber(arena, -1.0);
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = arr.array_length;
    if (len == 0) return val_mod.makeNumber(arena, -1.0);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = arr.getOwn(key) orelse try val_mod.makeUndefined(arena);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1.0);
}

pub fn nativeSort(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return this_val;
    const len = arr.array_length;
    if (len <= 1) return this_val;

    // Extract elements.
    var elems = try arena.alloc(Value, len);
    const undef = try val_mod.makeUndefined(arena);
    for (0..len) |i| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        elems[i] = arr.getOwn(key) orelse undef;
    }

    // Comparator.
    const cmp_fn: ?Value = if (args.len > 0 and args[0].bits != 0) blk: {
        const v = args[0];
        if (v.unbox() == .undefined_) break :blk null;
        break :blk v;
    } else null;

    // Simple insertion sort (small arrays typical, avoids complex sort closure issue).
    // For correctness with custom comparator.
    var i: usize = 1;
    while (i < len) : (i += 1) {
        const cur = elems[i];
        var j: usize = i;
        while (j > 0) {
            const prev = elems[j - 1];
            const should_swap = blk: {
                if (cmp_fn) |cfn| {
                    const fpm = @import("../builtins/function_proto.zig");
                    const cmp_args = [_]Value{ prev, cur };
                    const cmp_res = fpm.invokeCallback(arena, undef, cfn, &cmp_args) catch break :blk false;
                    const n = switch (cmp_res.unbox()) {
                        .number => |x| x,
                        else => 0.0,
                    };
                    break :blk n > 0.0;
                } else {
                    // Lexicographic string comparison.
                    const sa = try elemToString(arena, prev);
                    const sb = try elemToString(arena, cur);
                    break :blk std.mem.order(u8, sa, sb) == .gt;
                }
            };
            if (!should_swap) break;
            elems[j] = elems[j - 1];
            j -= 1;
        }
        elems[j] = cur;
    }

    // Write back.
    for (0..len) |k| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{k});
        try arr.set(key, elems[k]);
    }
    return this_val;
}

// ------------------------------------------------------------------ helpers ---

fn normalizeIndex(idx: f64, len: usize) usize {
    if (std.math.isNan(idx)) return 0;
    const i: i64 = val_mod.f64ToI64Sat(idx);
    if (i < 0) {
        const pos: i64 = @intCast(len);
        const r = pos + i;
        return if (r < 0) 0 else @intCast(r);
    }
    if (i > @as(i64, @intCast(len))) return len;
    return @intCast(i);
}

/// Relative index for `.at()` — out-of-range indices stay out of range (caller returns undefined).
fn relativeIndex(idx: f64, len: usize) usize {
    if (std.math.isNan(idx)) return std.math.maxInt(usize);
    const i: i64 = val_mod.f64ToI64Sat(idx);
    if (i < 0) {
        const pos: i64 = @intCast(len);
        const r = pos + i;
        return if (r < 0) std.math.maxInt(usize) else @intCast(r);
    }
    return @intCast(i);
}

fn elemToString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "";
    return switch (v.unbox()) {
        .undefined_ => "",
        .null_ => "",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try formatNumber(arena, n),
        .string => |s| s,
        else => "[object Object]",
    };
}

fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == @trunc(n) and @abs(n) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn sameValueZero(x: Value, y: Value) bool {
    if (x.bits != 0 and y.bits != 0 and x.unbox() == .number and y.unbox() == .number) {
        const a = x.unbox().number;
        const b = y.unbox().number;
        if (std.math.isNan(a) and std.math.isNan(b)) return true;
        return a == b;
    }
    return jsStrictEqual(x, y);
}

fn jsStrictEqual(x: Value, y: Value) bool {
    if (x.bits == 0 and y.bits == 0) return true;
    if (x.bits == 0 or y.bits == 0) return false;
    const xi = x.unbox();
    const yi = y.unbox();
    const xt = std.meta.Tag(val_mod.JsValue);
    if (@as(xt, xi) != @as(xt, yi)) return false;
    return switch (xi) {
        .undefined_ => true,
        .null_ => true,
        .boolean => |b| b == yi.boolean,
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isNan(yi.number)) break :blk false;
            break :blk n == yi.number;
        },
        .string => |s| std.mem.eql(u8, s, yi.string),
        .bigint => val_mod.bigIntEql(x, y),
        .object => x.bits == y.bits,
        .function => x.bits == y.bits,
        .bc_function => x.bits == y.bits,
        .native_function => x.bits == y.bits,
        .symbol => x.toPtr().symbol == y.toPtr().symbol,
    };
}
