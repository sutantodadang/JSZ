// SPDX-License-Identifier: Apache-2.0
//! Phase 4b: Array.prototype native functions.
//! push/pop mutate the array. slice/indexOf/join/concat are non-mutating.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const coll_mod = @import("es2015_collections.zig");
const typed_array_mod = @import("typed_array.zig");

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

/// ToString of an arbitrary Value (spec ToString), firing valueOf/toString on
/// objects via the VM toPrimitive bridge. Symbols throw TypeError.
pub fn valueToJsString(arena: std.mem.Allocator, v: Value) anyerror![]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try formatNumber(arena, n),
        .string => |s| s,
        .bigint => try val_mod.bigIntToString(arena, v.unbox().bigint),
        .symbol => {
            const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
            try obj.set("message", try val_mod.makeString(arena, "Cannot convert a Symbol value to a string"));
            try obj.set("name", try val_mod.makeString(arena, "TypeError"));
            realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
            return error.JsException;
        },
        else => blk: {
            const coercion = @import("coercion.zig");
            const prim = (try coercion.toPrimitive(arena, v, .string)) orelse v;
            if (prim.bits != 0 and prim.unbox() == .object) break :blk "[object Object]";
            break :blk try valueToJsString(arena, prim);
        },
    };
}

/// One element of the toLocaleString algorithm: undefined/null → "", otherwise
/// ToString(? Invoke(element, "toLocaleString")). Resolves the method through
/// the proto chain (incl. boxed primitives) and fires user overrides.
pub fn elemLocaleString(arena: std.mem.Allocator, elem: Value) anyerror![]const u8 {
    if (elem.bits == 0) return "";
    switch (elem.unbox()) {
        .undefined_, .null_ => return "",
        else => {},
    }
    const fpm = @import("../builtins/function_proto.zig");
    const m: Value = if (realm_mod.active_context) |ctx|
        try ctx.getProp(arena, elem, "toLocaleString")
    else
        Value{};
    const r = try fpm.invokeCallback(arena, elem, m, &[_]Value{});
    return valueToJsString(arena, r);
}

/// ES Array.prototype.toLocaleString: join elements, each via Invoke
/// "toLocaleString", with the implementation-defined list separator ",".
pub fn nativeArrayToLocaleString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, ",");
        const elem = try genGet(arena, this_val, i);
        try buf.appendSlice(arena, try elemLocaleString(arena, elem));
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES Array.prototype.toString: let func = Get(array, "join"); if not callable,
/// fall back to Object.prototype.toString; return func.call(array).
pub fn nativeArrayToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const fpm = @import("../builtins/function_proto.zig");
    const join_fn: Value = if (realm_mod.active_context) |ctx|
        try ctx.getProp(arena, this_val, "join")
    else
        Value{};
    if (join_fn.bits != 0) {
        const cuni = join_fn.unbox();
        const callable = cuni == .native_function or cuni == .bc_function or cuni == .function or
            (cuni == .object and join_fn.toPtr().object.get("__call__") != null);
        if (callable) return fpm.invokeCallback(arena, this_val, join_fn, &[_]Value{});
    }
    // Fallback: "[object Array]"-style tag via the array's own elements is not
    // applicable here; emulate Object.prototype.toString minimal output.
    return val_mod.makeString(arena, "[object Array]");
}

/// ES Object.prototype.toLocaleString: return ? Invoke(this, "toString").
pub fn nativeObjectToLocaleString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const fpm = @import("../builtins/function_proto.zig");
    const m: Value = if (realm_mod.active_context) |ctx|
        try ctx.getProp(arena, this_val, "toString")
    else
        Value{};
    return fpm.invokeCallback(arena, this_val, m, &[_]Value{});
}

pub fn nativeUnshift(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeNumber(arena, 0);
    const n = args.len;
    const old_len = arr.array_length;
    if (n == 0) return val_mod.makeNumber(arena, @floatFromInt(old_len));
    // Shift existing elements up by n (high → low to avoid clobbering).
    var i: usize = old_len;
    while (i > 0) : (i -= 1) {
        const from = i - 1;
        const fk = try std.fmt.allocPrint(arena, "{d}", .{from});
        const tk = try std.fmt.allocPrint(arena, "{d}", .{from + n});
        if (arr.getOwn(fk)) |v| try arr.set(tk, v) else _ = try arr.deleteOwn(tk);
    }
    // Place new items at the front.
    for (args, 0..) |a, j| {
        const k = try std.fmt.allocPrint(arena, "{d}", .{j});
        try arr.set(k, a);
    }
    arr.array_length = @intCast(@as(usize, old_len) + n);
    return val_mod.makeNumber(arena, @floatFromInt(arr.array_length));
}

pub fn nativeShift(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    const len = arr.array_length;
    if (len == 0) return val_mod.makeUndefined(arena);
    const first = arr.getOwn("0") orelse try val_mod.makeUndefined(arena);
    var i: usize = 1;
    while (i < len) : (i += 1) {
        const fk = try std.fmt.allocPrint(arena, "{d}", .{i});
        const tk = try std.fmt.allocPrint(arena, "{d}", .{i - 1});
        if (arr.getOwn(fk)) |v| try arr.set(tk, v) else _ = try arr.deleteOwn(tk);
    }
    const lastk = try std.fmt.allocPrint(arena, "{d}", .{len - 1});
    _ = try arr.deleteOwn(lastk);
    arr.array_length = len - 1;
    return first;
}

pub fn nativeConcat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
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
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = try genLength(arena, this_val);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
        _ = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const len = try genLength(arena, this_val);
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        try new_arr.set(key, result);
    }
    return val_mod.makeObject(arena, new_arr);
}

pub fn nativeFilter(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const len = try genLength(arena, this_val);
    const new_arr = try JsObject.createArray(arena, arr_proto);
    var ni: u32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
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
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const len = try genLength(arena, this_val);
    var acc: Value = undefined;
    var start_i: usize = 0;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (len == 0) return error.JsException; // TypeError
        acc = try genGet(arena, this_val, 0);
        start_i = 1;
    }
    var i: usize = start_i;
    const undef = try val_mod.makeUndefined(arena);
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
        const fpm = @import("../builtins/function_proto.zig");
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), this_val };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeReduceRight(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const len = try genLength(arena, this_val);
    var acc: Value = undefined;
    var start_i: i64 = @intCast(len);
    if (args.len > 1) {
        acc = args[1];
        start_i = @intCast(len);
    } else {
        if (len == 0) return error.JsException;
        start_i = @intCast(len - 1);
        acc = try genGet(arena, this_val, len - 1);
        start_i -= 1;
    }
    const undef = try val_mod.makeUndefined(arena);
    const fpm = @import("../builtins/function_proto.zig");
    var i: i64 = start_i - 1;
    while (i >= 0) : (i -= 1) {
        const elem = try genGet(arena, this_val, @intCast(i));
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), this_val };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeSome(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = try genLength(arena, this_val);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeEvery(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeBool(arena, true);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const len = try genLength(arena, this_val);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (!isTruthy(result)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeFind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeFindIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, this_val, i);
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
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    if (len == 0) return val_mod.makeUndefined(arena);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), this_val);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

/// ES2022 Array.prototype.findLastIndex — like findIndex, scans from the end.
pub fn nativeFindLastIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const cb = args[0];
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    if (len == 0) return val_mod.makeNumber(arena, -1.0);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const elem = try genGet(arena, this_val, i);
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

// ----------------------------------------------- generic (ToObject) helpers ---
// These power the methods that ES specifies as "intentionally generic": they
// operate on any array-like via [[Get]]/[[Set]]/length, so they work on real
// Arrays, plain array-likes, Proxies, AND TypedArrays (resizable included —
// length + elements are re-read through the live exotic [[Get]]/[[Set]]).

fn toLen(v: Value) usize {
    if (v.bits == 0) return 0;
    const n = switch (v.unbox()) {
        .number => |x| x,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch 0,
        .boolean => |b| @as(f64, if (b) 1 else 0),
        else => 0,
    };
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n > 9.007199254740991e15) return 9007199254740991;
    return @intFromFloat(@trunc(n));
}

/// ToLength(? Get(O, "length")). Real arrays read the [[ArrayLength]] slot.
fn genLength(arena: std.mem.Allocator, this_val: Value) !usize {
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object and this_val.toPtr().object.is_array)
        return this_val.toPtr().object.getArrayLength();
    if (realm_mod.active_context) |ctx| return toLen(try ctx.getProp(arena, this_val, "length"));
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        return toLen(this_val.toPtr().object.get("length") orelse Value{});
    return 0;
}

/// ? Get(O, ToString(i)) firing exotic/accessor reads.
fn genGet(arena: std.mem.Allocator, this_val: Value, i: usize) !Value {
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, this_val, key);
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        return this_val.toPtr().object.get(key) orelse val_mod.makeUndefined(arena);
    return val_mod.makeUndefined(arena);
}

/// ? Set(O, ToString(i), v, true) firing exotic/accessor writes.
fn genSet(arena: std.mem.Allocator, this_val: Value, i: usize, v: Value) !void {
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (realm_mod.active_context) |ctx| {
        try ctx.setProp(arena, this_val, key, v);
        return;
    }
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        try this_val.toPtr().object.set(key, v);
}

fn relIndex(idx: f64, len: usize) usize {
    const i: i64 = val_mod.f64ToI64Sat(idx);
    if (i < 0) {
        const r = @as(i64, @intCast(len)) + i;
        return if (r < 0) 0 else @intCast(r);
    }
    if (i > @as(i64, @intCast(len))) return len;
    return @intCast(i);
}

/// 23.1.3.7 Array.prototype.fill — generic; mutates `this`, returns `this`.
pub fn nativeFill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    var k: usize = if (args.len > 1) relIndex(toNumArg(args[1]), len) else 0;
    const final: usize = if (args.len > 2 and !(args[2].bits != 0 and args[2].unbox() == .undefined_)) relIndex(toNumArg(args[2]), len) else len;
    while (k < final) : (k += 1) try genSet(arena, this_val, k, value);
    return this_val;
}

/// 23.1.3.4 Array.prototype.copyWithin — generic; mutates `this`, returns `this`.
pub fn nativeCopyWithin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    const to0 = if (args.len > 0) relIndex(toNumArg(args[0]), len) else 0;
    const from0 = if (args.len > 1) relIndex(toNumArg(args[1]), len) else 0;
    const final: usize = if (args.len > 2 and !(args[2].bits != 0 and args[2].unbox() == .undefined_)) relIndex(toNumArg(args[2]), len) else len;
    var count: usize = if (final > from0) @min(final - from0, len - to0) else 0;
    // Direction: copy backward when ranges overlap and from < to.
    var to = to0;
    var from = from0;
    if (from < to and to < from + count) {
        from += count;
        to += count;
        while (count > 0) : (count -= 1) {
            from -= 1;
            to -= 1;
            try genSet(arena, this_val, to, try genGet(arena, this_val, from));
        }
    } else {
        while (count > 0) : (count -= 1) {
            try genSet(arena, this_val, to, try genGet(arena, this_val, from));
            from += 1;
            to += 1;
        }
    }
    return this_val;
}

/// 23.1.3.26 Array.prototype.reverse — generic in place; returns `this`.
pub fn nativeReverse(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    if (len < 2) return this_val;
    var lower: usize = 0;
    var upper: usize = len - 1;
    while (lower < upper) : ({ lower += 1; upper -= 1; }) {
        const lv = try genGet(arena, this_val, lower);
        const uv = try genGet(arena, this_val, upper);
        try genSet(arena, this_val, lower, uv);
        try genSet(arena, this_val, upper, lv);
    }
    return this_val;
}

/// 23.1.3.20 Array.prototype.lastIndexOf — generic; StrictEquality from the end.
pub fn nativeLastIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    if (len == 0 or args.len == 0) return val_mod.makeNumber(arena, -1);
    const search = args[0];
    var from: i64 = @as(i64, @intCast(len)) - 1;
    if (args.len > 1) {
        const n: i64 = val_mod.f64ToI64Sat(toNumArg(args[1]));
        if (n >= 0) {
            if (n < from) from = n;
        } else {
            from = @as(i64, @intCast(len)) + n;
        }
    }
    if (from < 0) return val_mod.makeNumber(arena, -1);
    var i: usize = @intCast(from);
    while (true) : (i -= 1) {
        if (jsStrictEqual(try genGet(arena, this_val, i), search)) return val_mod.makeNumber(arena, @floatFromInt(i));
        if (i == 0) break;
    }
    return val_mod.makeNumber(arena, -1);
}

/// Create a new real Array with the active Array.prototype.
fn newResultArray(arena: std.mem.Allocator) !*JsObject {
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    return try JsObject.createArray(arena, arr_proto);
}

/// ES2023 Array.prototype.with — non-mutating, returns a new array with `value`
/// at generic relative index.
pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    if (args.len < 2) return error.JsException;
    const value = args[1];
    const idx_raw = toNumArg(args[0]);
    const len_i: i64 = @intCast(len);
    const k_signed: i64 = if (std.math.isNan(idx_raw)) len_i + 1 else val_mod.f64ToI64Sat(idx_raw);
    const k: usize = if (k_signed < 0) blk: {
        const r = len_i + k_signed;
        break :blk if (r < 0) @intCast(len_i + 1) else @intCast(r);
    } else @intCast(k_signed);
    if (k >= len) return error.JsException;
    const new_arr = try newResultArray(arena);
    const arr_val = try val_mod.makeObject(arena, new_arr);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = if (i == k) value else try genGet(arena, this_val, i);
        try genSet(arena, arr_val, i, v);
    }
    return arr_val;
}

/// ES2023 Array.prototype.toReversed — non-mutating reverse.
pub fn nativeToReversed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    const new_arr = try newResultArray(arena);
    const arr_val = try val_mod.makeObject(arena, new_arr);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        try genSet(arena, arr_val, i, try genGet(arena, this_val, len - 1 - i));
    }
    return arr_val;
}

/// ES2023 Array.prototype.toSorted — non-mutating sort (insertion sort).
pub fn nativeToSorted(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    const new_arr = try newResultArray(arena);
    const arr_val = try val_mod.makeObject(arena, new_arr);
    var elems = try arena.alloc(Value, len);
    for (0..len) |i| elems[i] = try genGet(arena, this_val, i);

    const cmp_fn: ?Value = if (args.len > 0 and args[0].bits != 0) blk: {
        const v = args[0];
        if (v.unbox() == .undefined_) break :blk null;
        break :blk v;
    } else null;

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
                    const cmp_res = fpm.invokeCallback(arena, try val_mod.makeUndefined(arena), cfn, &cmp_args) catch break :blk false;
                    const n = switch (cmp_res.unbox()) {
                        .number => |x| x,
                        else => 0.0,
                    };
                    break :blk n > 0.0;
                } else {
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

    for (0..len) |k| {
        try genSet(arena, arr_val, k, elems[k]);
    }
    return arr_val;
}

/// ES2023 Array.prototype.toSpliced — non-mutating splice.
pub fn nativeToSpliced(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const len = try genLength(arena, this_val);
    const start0 = if (args.len > 0) relIndex(toNumArg(args[0]), len) else 0;
    const del_count: usize = if (args.len > 1) blk: {
        const n = toNumArg(args[1]);
        if (std.math.isNan(n)) break :blk 0;
        const ni = val_mod.f64ToI64Sat(n);
        if (ni < 0) break :blk 0;
        break :blk @min(@as(usize, @intCast(ni)), len - start0);
    } else len - start0;
    const items = if (args.len > 2) args[2..] else &[_]Value{};
    const new_len = len - del_count + items.len;
    const new_arr = try newResultArray(arena);
    const arr_val = try val_mod.makeObject(arena, new_arr);
    var j: usize = 0;
    var i: usize = 0;
    while (i < start0) : (i += 1) {
        try genSet(arena, arr_val, j, try genGet(arena, this_val, i));
        j += 1;
    }
    for (items) |it| {
        try genSet(arena, arr_val, j, it);
        j += 1;
    }
    i = start0 + del_count;
    while (i < len) : (i += 1) {
        try genSet(arena, arr_val, j, try genGet(arena, this_val, i));
        j += 1;
    }
    new_arr.array_length = @intCast(new_len);
    return arr_val;
}

/// Array.prototype.splice(start, deleteCount, ...items) — mutating: removes
/// `deleteCount` elements at `start`, inserts `items`, returns the removed
/// elements as a new array, and updates `length`.
/// ponytail: real-array path only (getArray); array-like/proxy receivers are
/// out of scope — the only thing that exercises a non-array receiver is
/// `Array.prototype.splice.call(arrayLike)`, which no current test needs.
pub fn nativeSplice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const arr = getArray(this_val) orelse return val_mod.makeUndefined(arena);
    const len = arr.array_length;
    const start = if (args.len > 0) relIndex(toNumArg(args[0]), len) else 0;
    // Spec §23.1.3.31: 0 args → delete 0; 1 arg → delete to end; ≥2 → clamp.
    var del_count: usize = 0;
    if (args.len == 1) {
        del_count = len - start;
    } else if (args.len >= 2) {
        const n = toNumArg(args[1]);
        const ni = if (std.math.isNan(n)) @as(i64, 0) else val_mod.f64ToI64Sat(n);
        del_count = if (ni < 0) 0 else @min(@as(usize, @intCast(ni)), len - start);
    }
    const items = if (args.len > 2) args[2..] else &[_]Value{};

    // Removed elements → result array.
    const removed = try newResultArray(arena);
    {
        var r: usize = 0;
        while (r < del_count) : (r += 1) {
            const sk = try std.fmt.allocPrint(arena, "{d}", .{start + r});
            if (arr.getOwn(sk)) |v| {
                const dk = try std.fmt.allocPrint(arena, "{d}", .{r});
                try removed.set(dk, v);
            }
        }
        removed.array_length = @intCast(del_count);
    }

    const insert = items.len;
    const new_len = len - del_count + insert;
    if (insert < del_count) {
        // Shift the tail down (low → high is safe when moving toward 0).
        var i: usize = start + del_count;
        while (i < len) : (i += 1) {
            const fk = try std.fmt.allocPrint(arena, "{d}", .{i});
            const tk = try std.fmt.allocPrint(arena, "{d}", .{i - del_count + insert});
            if (arr.getOwn(fk)) |v| try arr.set(tk, v) else _ = try arr.deleteOwn(tk);
        }
        // Delete now-vacated trailing slots [new_len, len).
        var d: usize = new_len;
        while (d < len) : (d += 1) {
            const dk = try std.fmt.allocPrint(arena, "{d}", .{d});
            _ = try arr.deleteOwn(dk);
        }
    } else if (insert > del_count) {
        // Shift the tail up (high → low to avoid clobbering).
        var i: usize = len;
        while (i > start + del_count) : (i -= 1) {
            const from = i - 1;
            const fk = try std.fmt.allocPrint(arena, "{d}", .{from});
            const tk = try std.fmt.allocPrint(arena, "{d}", .{from - del_count + insert});
            if (arr.getOwn(fk)) |v| try arr.set(tk, v) else _ = try arr.deleteOwn(tk);
        }
    }

    // Write inserted items at `start`.
    for (items, 0..) |it, j| {
        const k = try std.fmt.allocPrint(arena, "{d}", .{start + j});
        try arr.set(k, it);
    }
    arr.array_length = @intCast(new_len);
    return val_mod.makeObject(arena, removed);
}

fn toNumArg(v: Value) f64 {
    if (v.bits == 0) return 0;
    return switch (v.unbox()) {
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch std.math.nan(f64),
        .boolean => |b| if (b) 1 else 0,
        .undefined_ => std.math.nan(f64),
        .null_ => 0,
        else => std.math.nan(f64),
    };
}

// -- Array iterators: keys/entries (values is nativeArrayValues in es2015) --

pub fn nativeArrayKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const is_typed = typed_array_mod.getTd(this_val) != null;
        const d = try arena.create(coll_mod.SeqIterData);
        d.* = .{ .seq = this_val, .kind = .key, .is_typed = is_typed };
        return coll_mod.makeSeqIterator(arena, d);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeArrayEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const is_typed = typed_array_mod.getTd(this_val) != null;
        const d = try arena.create(coll_mod.SeqIterData);
        d.* = .{ .seq = this_val, .kind = .entry, .is_typed = is_typed };
        return coll_mod.makeSeqIterator(arena, d);
    }
    return val_mod.makeUndefined(arena);
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
    return val_mod.formatNumber(arena, n);
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
