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

/// Throw a TypeError with `msg`, setting realm_mod.pending_exception so the
/// caught value is a real Error object (not empty).
fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// Throw a RangeError with `msg`, setting realm_mod.pending_exception.
fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = try JsObject.create(arena, realm_mod.error_proto_RangeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// §7.2.1 RequireObjectCoercible — Array.prototype instance methods must throw
/// on a null/undefined `this` (incl. explicit `.call(null)` / `.call(undefined)`).
fn requireCoercible(arena: std.mem.Allocator, this_val: Value) !void {
    if (this_val.bits == 0) return throwTypeError(arena, "Array.prototype method called on null or undefined");
    switch (this_val.unbox()) {
        .undefined_, .null_ => return throwTypeError(arena, "Array.prototype method called on null or undefined"),
        else => {},
    }
}

/// Mirrors the isCallable pattern used throughout the runtime (realm.zig
/// isCallableVal/isCallableValue, es2015_collections.zig isCallable, etc.):
/// function/native_function/bc_function are callable, or a plain object that
/// exposes an internal "__call__" slot.
fn isCallable(v: Value) bool {
    // Delegate to the canonical IsCallable so bound functions and callable
    // proxies (objects without a literal `__call__` slot) are recognized too.
    return @import("../builtins/function_proto.zig").isCallableFn(v);
}

/// Throw TypeError when `cb` is not callable (used for every callback arg:
/// forEach/map/filter/some/every/find*/reduce*/flatMap/sort comparator).
fn requireCallable(arena: std.mem.Allocator, cb: Value) !void {
    if (isCallable(cb)) return;
    return throwTypeError(arena, "callback is not a function");
}

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

/// Set(O, "length", n): updates a real array's [[ArrayLength]] via the exotic
/// [[Set]] path, or writes a plain "length" property on an array-like.
fn setLength(arena: std.mem.Allocator, O: Value, n: usize) !void {
    // Set(O, "length", n, true): the mutating array methods (push/pop/shift/
    // unshift/splice/…) use the throwing form, so a non-writable/frozen length
    // or an immutable receiver (a String) raises TypeError.
    if (realm_mod.active_context) |ctx| {
        try ctx.setPropThrow(arena, O, "length", try val_mod.makeNumber(arena, @floatFromInt(n)));
    } else if (O.isHeapPtr() and O.toPtr().* == .object) {
        O.toPtr().object.array_length = @intCast(n);
    }
}

pub fn nativePush(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    var len = try genLength(arena, O);
    if (@as(f64, @floatFromInt(len)) + @as(f64, @floatFromInt(args.len)) > 9007199254740991.0)
        return throwTypeError(arena, "Array length exceeds 2^53 - 1");
    for (args) |a| {
        try genSet(arena, O, len, a);
        len += 1;
    }
    try setLength(arena, O, len);
    return val_mod.makeNumber(arena, @floatFromInt(len));
}

pub fn nativePop(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len == 0) {
        try setLength(arena, O, 0);
        return val_mod.makeUndefined(arena);
    }
    const idx = len - 1;
    const val = try genGet(arena, O, idx);
    try genDelete(arena, O, idx);
    try setLength(arena, O, idx);
    return val;
}

pub fn nativeSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);

    // §23.1.3.27: relativeStart = ToIntegerOrInfinity(start); relativeEnd is the
    // length only when `end` is undefined (absent) — every other value (null,
    // boolean, string, …) is coerced via ToIntegerOrInfinity (e.g. null → 0).
    const start = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_)
        genRelClamp(try genInteger(arena, args[0]), len)
    else
        0;
    const end_ = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        genRelClamp(try genInteger(arena, args[1]), len)
    else
        len;

    const count: usize = if (start < end_) end_ - start else 0;
    const A = try arraySpeciesCreate(arena, O, count);
    var ni: usize = 0;
    var i: usize = start;
    while (i < end_) : (i += 1) {
        if (try genHas(arena, O, i)) try genCreate(arena, A, ni, try genGet(arena, O, i));
        ni += 1;
    }
    try setLength(arena, A, count);
    return A;
}

pub fn nativeIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len == 0) return val_mod.makeNumber(arena, -1.0);
    const search = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);

    // fromIndex = ToIntegerOrInfinity(args[1]); +∞ → no match, -∞ → 0.
    var from: usize = 0;
    if (args.len > 1) {
        const n = try realm_mod.toNumberValue(arena, args[1]);
        if (std.math.isInf(n) and n > 0) return val_mod.makeNumber(arena, -1.0);
        const ni: i64 = if (std.math.isNan(n)) 0 else val_mod.f64ToI64Sat(std.math.trunc(n));
        if (ni >= 0) {
            from = @intCast(ni);
        } else {
            const r = @as(i64, @intCast(len)) + ni;
            from = if (r < 0) 0 else @intCast(r);
        }
    }

    var i: usize = from;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        if (jsStrictEqual(try genGet(arena, O, i), search)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// ES2016 Array.prototype.includes — SameValueZero (NaN matches NaN), scans holes as undefined.
pub fn nativeIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len == 0) return val_mod.makeBool(arena, false);
    const search = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // fromIndex = ToIntegerOrInfinity; +∞ → false, -∞ → 0.
    var from: usize = 0;
    if (args.len > 1) {
        const n = try realm_mod.toNumberValue(arena, args[1]);
        if (std.math.isInf(n) and n > 0) return val_mod.makeBool(arena, false);
        const ni: i64 = if (std.math.isNan(n)) 0 else val_mod.f64ToI64Sat(std.math.trunc(n));
        if (ni >= 0) {
            from = @intCast(ni);
        } else {
            const r = @as(i64, @intCast(len)) + ni;
            from = if (r < 0) 0 else @intCast(r);
        }
    }
    var i: usize = from;
    while (i < len) : (i += 1) {
        // includes visits holes as `undefined` (no HasProperty gate).
        const elem = try genGet(arena, O, i);
        if (sameValueZero(elem, search)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

/// ES FlattenIntoArray: append `source`'s elements into `target` (a Value),
/// flattening nested arrays up to `depth`. `mapper` (flatMap) is applied only at
/// the top level. `ni` is the running target index.
fn flattenInto(
    arena: std.mem.Allocator,
    target: Value,
    source: Value,
    source_len: usize,
    depth: i64,
    ni: *usize,
    mapper: ?Value,
    mapper_this: Value,
) anyerror!void {
    var i: usize = 0;
    while (i < source_len) : (i += 1) {
        if (!try genHas(arena, source, i)) continue;
        var elem = try genGet(arena, source, i);
        if (mapper) |m| elem = try callCb(arena, m, mapper_this, elem, @floatFromInt(i), source);
        const is_arr = elem.bits != 0 and elem.unbox() == .object and elem.toPtr().object.is_array;
        if (depth > 0 and is_arr) {
            const el_len = try genLength(arena, elem);
            try flattenInto(arena, target, elem, el_len, depth - 1, ni, null, mapper_this);
        } else {
            if (@as(f64, @floatFromInt(ni.*)) >= 9007199254740991.0)
                return throwTypeError(arena, "Array length exceeds 2^53 - 1");
            // FlattenIntoArray uses CreateDataPropertyOrThrow (§23.1.3.11.1 step
            // 8.d.iii): a non-extensible/non-configurable target slot throws.
            try genCreate(arena, target, ni.*, elem);
            ni.* += 1;
        }
    }
}

/// ES2019 Array.prototype.flat — default depth 1.
pub fn nativeFlat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    var depth: i64 = 1;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        const n = try genInteger(arena, args[0]);
        depth = if (n >= 9.2233720368547758e18) std.math.maxInt(i64) else if (n <= -9.2233720368547758e18) std.math.minInt(i64) else @intFromFloat(n);
    }
    const A = try arraySpeciesCreate(arena, O, 0);
    var ni: usize = 0;
    const undef = try val_mod.makeUndefined(arena);
    try flattenInto(arena, A, O, len, depth, &ni, null, undef);
    return A;
}

/// ES2019 Array.prototype.flatMap — map then flatten one level.
pub fn nativeFlatMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const A = try arraySpeciesCreate(arena, O, 0);
    var ni: usize = 0;
    try flattenInto(arena, A, O, len, 1, &ni, cb, cb_this);
    return A;
}

pub fn nativeJoin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const len = try genLength(arena, this_val);

    // §23.1.3.18: only `undefined` (or absent) yields the default ",". Every other
    // value (including null → "null") goes through ToString(separator).
    const sep: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_)
        try valueToJsString(arena, args[0])
    else
        ",";

    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, sep);
        const elem = try genGet(arena, this_val, i);
        if (!(elem.bits == 0) and elem.unbox() != .undefined_ and elem.unbox() != .null_) {
            try buf.appendSlice(arena, try elemToString(arena, elem));
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
            // Guard on "still not primitive" rather than "is an ordinary
            // object": a function whose coercion produced nothing would
            // otherwise recurse into this same branch forever.
            if (!coercion.isPrimitive(prim)) break :blk "[object Object]";
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
    try requireCoercible(arena, this_val);
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
    try requireCoercible(arena, this_val);
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
    // §23.1.3.36 step 4: a non-callable `join` falls back to
    // %Object.prototype.toString%, which brands by the RECEIVER — so
    // `Array.prototype.toString.call(true)` is "[object Boolean]".
    return realm_mod.nativeObjectProtoToString(arena, this_val, &[_]Value{});
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
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const n = args.len;
    const old_len = try genLength(arena, O);
    if (n == 0) {
        try setLength(arena, O, old_len);
        return val_mod.makeNumber(arena, @floatFromInt(old_len));
    }
    if (@as(f64, @floatFromInt(old_len)) + @as(f64, @floatFromInt(n)) > 9007199254740991.0)
        return throwTypeError(arena, "Array length exceeds 2^53 - 1");
    // Shift existing elements up by n (high → low to avoid clobbering).
    var i: usize = old_len;
    while (i > 0) : (i -= 1) {
        const from = i - 1;
        const to = from + n;
        if (try genHas(arena, O, from)) try genSet(arena, O, to, try genGet(arena, O, from)) else try genDelete(arena, O, to);
    }
    // Place new items at the front.
    for (args, 0..) |a, j| {
        try genSet(arena, O, j, a);
    }
    const new_len = old_len + n;
    try setLength(arena, O, new_len);
    return val_mod.makeNumber(arena, @floatFromInt(new_len));
}

pub fn nativeShift(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len == 0) {
        try setLength(arena, O, 0);
        return val_mod.makeUndefined(arena);
    }
    const first = try genGet(arena, O, 0);
    var i: usize = 1;
    while (i < len) : (i += 1) {
        if (try genHas(arena, O, i)) try genSet(arena, O, i - 1, try genGet(arena, O, i)) else try genDelete(arena, O, i - 1);
    }
    try genDelete(arena, O, len - 1);
    try setLength(arena, O, len - 1);
    return first;
}

/// ES IsConcatSpreadable(O): honors @@isConcatSpreadable, else IsArray(O).
fn isConcatSpreadable(arena: std.mem.Allocator, v: Value) !bool {
    if (v.bits == 0 or v.unbox() != .object) return false;
    if (realm_mod.active_sym_is_concat_spreadable) |sym| {
        const spreadable = if (realm_mod.active_context) |ctx|
            try ctx.getPropSym(arena, v, sym)
        else
            v.toPtr().object.getSym(sym) orelse Value{ .bits = 0 };
        const is_undef = spreadable.bits == 0 or spreadable.unbox() == .undefined_;
        if (!is_undef) return val_mod.toBoolean(spreadable);
    }
    return v.toPtr().object.is_array;
}

pub fn nativeConcat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const A = try arraySpeciesCreate(arena, O, 0);
    var ni: usize = 0;

    // items = [O, ...args]; spreadable items are flattened one level.
    var item_idx: usize = 0;
    const total = 1 + args.len;
    while (item_idx < total) : (item_idx += 1) {
        const E = if (item_idx == 0) O else args[item_idx - 1];
        if (try isConcatSpreadable(arena, E)) {
            const len = try genLength(arena, E);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (try genHas(arena, E, i)) try genCreate(arena, A, ni, try genGet(arena, E, i));
                ni += 1;
            }
        } else {
            try genCreate(arena, A, ni, E);
            ni += 1;
        }
    }
    try setLength(arena, A, ni);
    return A;
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
    return val_mod.toBoolean(v);
}

pub fn nativeForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        const elem = try genGet(arena, O, i);
        _ = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const A = try arraySpeciesCreate(arena, O, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue; // map preserves holes
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        try genCreate(arena, A, i, result);
    }
    return A;
}

pub fn nativeFilter(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const A = try arraySpeciesCreate(arena, O, 0);
    var ni: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) {
            try genCreate(arena, A, ni, elem);
            ni += 1;
        }
    }
    return A;
}

pub fn nativeReduce(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    var acc: Value = undefined;
    var start_i: usize = 0;
    if (args.len > 1) {
        acc = args[1];
    } else {
        // No initial value: seed from the first PRESENT element (holes skipped).
        var found = false;
        while (start_i < len) : (start_i += 1) {
            if (try genHas(arena, O, start_i)) {
                acc = try genGet(arena, O, start_i);
                start_i += 1;
                found = true;
                break;
            }
        }
        if (!found) return throwTypeError(arena, "Reduce of empty array with no initial value");
    }
    var i: usize = start_i;
    const undef = try val_mod.makeUndefined(arena);
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        const elem = try genGet(arena, O, i);
        const fpm = @import("../builtins/function_proto.zig");
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), O };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeReduceRight(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    var acc: Value = undefined;
    var i: i64 = @as(i64, @intCast(len)) - 1;
    if (args.len > 1) {
        acc = args[1];
    } else {
        // No initial value: seed from the last PRESENT element (holes skipped).
        var found = false;
        while (i >= 0) : (i -= 1) {
            if (try genHas(arena, O, @intCast(i))) {
                acc = try genGet(arena, O, @intCast(i));
                i -= 1;
                found = true;
                break;
            }
        }
        if (!found) return throwTypeError(arena, "Reduce of empty array with no initial value");
    }
    const undef = try val_mod.makeUndefined(arena);
    const fpm = @import("../builtins/function_proto.zig");
    while (i >= 0) : (i -= 1) {
        if (!try genHas(arena, O, @intCast(i))) continue;
        const elem = try genGet(arena, O, @intCast(i));
        const cb_args = [_]Value{ acc, elem, try val_mod.makeNumber(arena, @floatFromInt(i)), O };
        acc = try fpm.invokeCallback(arena, undef, cb, &cb_args);
    }
    return acc;
}

pub fn nativeSome(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeEvery(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (!try genHas(arena, O, i)) continue;
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (!isTruthy(result)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeFind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeFindIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, O);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = try genGet(arena, O, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// ES2022 Array.prototype.at — negative indices count from the end.
pub fn nativeAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // §23.1.3.1: O = ToObject(this); len = LengthOfArrayLike(O);
    // relativeIndex = ToIntegerOrInfinity(index) (coerces objects via valueOf).
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, this_val);
    const rel = try genInteger(arena, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
    const k: f64 = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    if (k < 0 or k >= @as(f64, @floatFromInt(len))) return val_mod.makeUndefined(arena);
    return genGet(arena, O, @intFromFloat(k));
}

/// ES2022 Array.prototype.findLast — like find, scans from the end.
pub fn nativeFindLast(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const O = try toObject(arena, this_val);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    if (len == 0) return val_mod.makeUndefined(arena);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) return elem;
    }
    return val_mod.makeUndefined(arena);
}

/// ES2022 Array.prototype.findLastIndex — like findIndex, scans from the end.
pub fn nativeFindLastIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireCallable(arena, cb);
    const cb_this = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const O = try toObject(arena, this_val);
    try typed_array_mod.validateReceiver(arena, this_val);
    const len = try genLength(arena, this_val);
    if (len == 0) return val_mod.makeNumber(arena, -1.0);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const elem = try genGet(arena, this_val, i);
        const result = try callCb(arena, cb, cb_this, elem, @floatFromInt(i), O);
        if (isTruthy(result)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// Stable insertion sort of `elems` in place per SortCompare (custom comparator
/// or default ToString lexicographic order). Shared by the fast-array and the
/// generic array-like paths.
/// ES SortCompare(x, y): undefined always sorts to the end; otherwise use the
/// comparator (ToNumber of its result, NaN → +0) or default string order.
/// Propagates comparator exceptions.
fn sortCompare(arena: std.mem.Allocator, x: Value, y: Value, cmp_fn: ?Value) !f64 {
    const x_undef = x.bits == 0 or x.unbox() == .undefined_;
    const y_undef = y.bits == 0 or y.unbox() == .undefined_;
    if (x_undef and y_undef) return 0;
    if (x_undef) return 1;
    if (y_undef) return -1;
    if (cmp_fn) |cfn| {
        const fpm = @import("../builtins/function_proto.zig");
        const undef = try val_mod.makeUndefined(arena);
        const cmp_res = try fpm.invokeCallback(arena, undef, cfn, &[_]Value{ x, y });
        const n = try realm_mod.toNumberValue(arena, cmp_res);
        return if (std.math.isNan(n)) 0 else n;
    }
    const sa = try elemToString(arena, x);
    const sb = try elemToString(arena, y);
    return switch (std.mem.order(u8, sa, sb)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn sortValues(arena: std.mem.Allocator, elems: []Value, cmp_fn: ?Value) !void {
    // Stable insertion sort (test262 requires stability).
    var i: usize = 1;
    while (i < elems.len) : (i += 1) {
        const cur = elems[i];
        var j: usize = i;
        while (j > 0) {
            if (try sortCompare(arena, elems[j - 1], cur, cmp_fn) <= 0) break;
            elems[j] = elems[j - 1];
            j -= 1;
        }
        elems[j] = cur;
    }
}

pub fn nativeSort(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    // Comparator (undefined → default order); when supplied it must be callable.
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) try requireCallable(arena, args[0]);
    const cmp_fn: ?Value = if (args.len > 0 and args[0].bits != 0) blk: {
        const v = args[0];
        if (v.unbox() == .undefined_) break :blk null;
        break :blk v;
    } else null;
    // Generic per §23.1.3.30 (SortIndexedProperties): collect only PRESENT
    // elements (holes excluded), sort, write back, then delete the trailing
    // slots so holes migrate to the end. Works on any array-like.
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len < 1) return O;

    var list = std.ArrayList(Value){};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (try genHas(arena, O, i)) try list.append(arena, try genGet(arena, O, i));
    }
    const count = list.items.len;
    try sortValues(arena, list.items, cmp_fn);
    var k: usize = 0;
    while (k < count) : (k += 1) try genSet(arena, O, k, list.items[k]);
    while (k < len) : (k += 1) try genDelete(arena, O, k);
    return O;
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
/// ToLength(v) but with a spec-correct ToNumber that throws for Symbol / BigInt
/// operands (realm_mod.toLengthValue swallows those as NaN → 0).
fn toLengthChecked(arena: std.mem.Allocator, v: Value) !usize {
    const n = try realm_mod.toNumberCheckedRealm(arena, v);
    if (std.math.isNan(n) or n <= 0) return 0;
    const capped = @min(std.math.trunc(n), 9007199254740991.0);
    return @intFromFloat(capped);
}

fn genLength(arena: std.mem.Allocator, this_val: Value) !usize {
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object and this_val.toPtr().object.is_array)
        return this_val.toPtr().object.getArrayLength();
    // Array-likes: ToLength(? Get(O, "length")) with full ToNumber coercion so a
    // `length` whose valueOf/toString yields a number is honored. ToNumber throws
    // a TypeError for a Symbol / BigInt `length` (spec ToLength → ToNumber).
    if (realm_mod.active_context) |ctx| return toLengthChecked(arena, try ctx.getProp(arena, this_val, "length"));
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        return toLengthChecked(arena, this_val.toPtr().object.get("length") orelse Value{ .bits = 0 });
    return 0;
}

/// A plain dense array `this` fast-path: returns the object when `this_val` is a
/// real Array still on the dense element path (no Proxy/exotic/accessor concerns),
/// so integer index access can skip decimal-key allocation and the ctx round-trip.
inline fn denseArrayOf(this_val: Value) ?*JsObject {
    if (!this_val.isHeapPtr() or this_val.toPtr().* != .object) return null;
    const o = this_val.toPtr().object;
    return if (o.is_array and o.usesDense()) o else null;
}

/// HasProperty(O, ToString(i)) — used to skip array holes (absent indices) in the
/// intentionally-generic iteration methods.
fn genHas(arena: std.mem.Allocator, this_val: Value, i: usize) !bool {
    // A present dense element implies HasProperty true with no allocation. An
    // absent index still needs the proto walk (string path below).
    if (i <= std.math.maxInt(u32)) if (denseArrayOf(this_val)) |o| {
        if (o.getIndexOwn(@intCast(i)) != null) return true;
    };
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (realm_mod.active_context) |ctx| return ctx.hasProp(arena, this_val, key);
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        return this_val.toPtr().object.get(key) != null;
    return false;
}

/// ? Get(O, ToString(i)) firing exotic/accessor reads.
fn genGet(arena: std.mem.Allocator, this_val: Value, i: usize) !Value {
    if (realm_mod.nativeDeadlineExceeded()) return error.OutOfMemory;
    // Present dense element: return it directly. A hole falls through so the
    // proto chain is consulted (spec [[Get]]), matching the string path.
    if (i <= std.math.maxInt(u32)) if (denseArrayOf(this_val)) |o| {
        if (o.getIndexOwn(@intCast(i))) |val| return val;
    };
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, this_val, key);
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        return this_val.toPtr().object.get(key) orelse val_mod.makeUndefined(arena);
    return val_mod.makeUndefined(arena);
}

/// ? Set(O, ToString(i), v, true) firing exotic/accessor writes.
fn genSet(arena: std.mem.Allocator, this_val: Value, i: usize, v: Value) !void {
    if (realm_mod.nativeDeadlineExceeded()) return error.OutOfMemory;
    // Dense array write: store by integer index, no decimal-key allocation. For a
    // real Array, ctx.setProp bottoms out in the same ordinary [[Set]] anyway.
    if (i <= std.math.maxInt(u32)) if (denseArrayOf(this_val)) |o| {
        try o.setIndex(@intCast(i), v);
        return;
    };
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (realm_mod.active_context) |ctx| {
        // Every element write in this file comes from a spec step of the form
        // Set(O, ToString(i), v, true) — the THROWING form. A read-only or
        // setter-less accessor target must raise TypeError, not fail silently.
        try ctx.setPropThrow(arena, this_val, key, v);
        return;
    }
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        try this_val.toPtr().object.set(key, v);
}

/// CreateDataPropertyOrThrow(O, ToString(i), v) — define a fresh { value,
/// writable, enumerable, configurable: true } data property, throwing TypeError
/// if [[DefineOwnProperty]] fails (non-configurable existing prop, non-extensible
/// target, exotic rejection). Used by concat/map/filter/splice/… which the spec
/// defines with CreateDataProperty, not [[Set]].
pub fn genCreate(arena: std.mem.Allocator, this_val: Value, i: usize, v: Value) !void {
    if (realm_mod.nativeDeadlineExceeded()) return error.OutOfMemory;
    // Fast path: dense real array (elements are always configurable/writable and
    // the array is extensible, so CreateDataProperty always succeeds).
    if (i <= std.math.maxInt(u32)) if (denseArrayOf(this_val)) |o| {
        try o.setIndex(@intCast(i), v);
        return;
    };
    const obj_methods = @import("object_methods.zig");
    const proto: ?*JsObject = realm_mod.active_object_proto;
    const d = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    try d.set("value", v);
    try d.set("writable", try val_mod.makeBool(arena, true));
    try d.set("enumerable", try val_mod.makeBool(arena, true));
    try d.set("configurable", try val_mod.makeBool(arena, true));
    const key_val = try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{i}));
    _ = try obj_methods.nativeObjectDefineProperty(arena, this_val, &[_]Value{ this_val, key_val, val_mod.makeObject(arena, d) catch this_val });
}

/// DeletePropertyOrThrow(O, ToString(i)) — best-effort own-property delete.
fn genDelete(arena: std.mem.Allocator, this_val: Value, i: usize) !void {
    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
    if (this_val.isHeapPtr() and this_val.toPtr().* == .object)
        _ = try this_val.toPtr().object.deleteOwn(key);
}

/// ToIntegerOrInfinity with full ToNumber coercion (objects via valueOf/toString).
/// ToNumber throws a TypeError for Symbol / BigInt operands (spec ToNumber).
fn genInteger(arena: std.mem.Allocator, v: Value) !f64 {
    const n = try realm_mod.toNumberCheckedRealm(arena, v);
    if (std.math.isNan(n)) return 0;
    if (std.math.isInf(n)) return n;
    return std.math.trunc(n);
}

/// Clamp a relative index (may be negative → from end; ±Infinity handled) to [0, len].
fn genRelClamp(rel: f64, len: usize) usize {
    if (rel == -std.math.inf(f64)) return 0;
    if (rel < 0) {
        const r = @as(f64, @floatFromInt(len)) + rel;
        return if (r < 0) 0 else @intFromFloat(r);
    }
    const flen: f64 = @floatFromInt(len);
    return if (rel > flen) len else @intFromFloat(rel);
}

/// ToObject(this): box a primitive into its wrapper (Number/Boolean/String/
/// Symbol/BigInt.prototype) so array methods can pass a real object as the
/// callback's 4th argument and `instanceof` holds; objects pass through
/// unchanged. Callers guarantee requireCoercible first, so null/undefined
/// never reach here (and are returned as-is defensively).
fn toObject(arena: std.mem.Allocator, v: Value) !Value {
    if (v.bits == 0) return v;
    if (v.unbox() == .object) return v;
    const proto: ?*JsObject = switch (v.unbox()) {
        .number => realm_mod.active_number_proto,
        .boolean => realm_mod.active_boolean_proto,
        .string => realm_mod.active_string_proto orelse realm_mod.active_object_proto,
        .symbol => realm_mod.active_symbol_proto orelse realm_mod.active_object_proto,
        .bigint => realm_mod.active_bigint_proto orelse realm_mod.active_object_proto,
        else => return v,
    };
    if (proto) |p| {
        const w = if (realm_mod.active_heap) |heap|
            try JsObject.createOnHeap(heap, p)
        else
            try JsObject.create(arena, p);
        try w.set("[[PrimitiveValue]]", v);
        // A String exotic object exposes each code unit as an own index property
        // plus `length`, so array methods can read them (String is byte-indexed).
        if (v.unbox() == .string) {
            const s = v.toPtr().string;
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                try w.set(key, try val_mod.makeString(arena, try arena.dupe(u8, s[i .. i + 1])));
            }
            try w.set("length", try val_mod.makeNumber(arena, @floatFromInt(s.len)));
        }
        return val_mod.makeObject(arena, w);
    }
    return v;
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
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    var k: usize = if (args.len > 1) genRelClamp(try genInteger(arena, args[1]), len) else 0;
    const final: usize = if (args.len > 2 and !(args[2].bits != 0 and args[2].unbox() == .undefined_)) genRelClamp(try genInteger(arena, args[2]), len) else len;
    while (k < final) : (k += 1) try genSet(arena, O, k, value);
    return O;
}

/// 23.1.3.4 Array.prototype.copyWithin — generic; mutates `this`, returns `this`.
pub fn nativeCopyWithin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const to0 = if (args.len > 0) genRelClamp(try genInteger(arena, args[0]), len) else 0;
    const from0 = if (args.len > 1) genRelClamp(try genInteger(arena, args[1]), len) else 0;
    const final: usize = if (args.len > 2 and !(args[2].bits != 0 and args[2].unbox() == .undefined_)) genRelClamp(try genInteger(arena, args[2]), len) else len;
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
            if (try genHas(arena, O, from)) try genSet(arena, O, to, try genGet(arena, O, from)) else try genDelete(arena, O, to);
        }
    } else {
        while (count > 0) : (count -= 1) {
            if (try genHas(arena, O, from)) try genSet(arena, O, to, try genGet(arena, O, from)) else try genDelete(arena, O, to);
            from += 1;
            to += 1;
        }
    }
    return O;
}

/// 23.1.3.26 Array.prototype.reverse — generic in place; returns `this`.
pub fn nativeReverse(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len < 2) return O;
    var lower: usize = 0;
    while (lower < len / 2) : (lower += 1) {
        const upper = len - 1 - lower;
        const lower_exists = try genHas(arena, O, lower);
        const upper_exists = try genHas(arena, O, upper);
        const lv = if (lower_exists) try genGet(arena, O, lower) else undefined;
        const uv = if (upper_exists) try genGet(arena, O, upper) else undefined;
        if (lower_exists and upper_exists) {
            try genSet(arena, O, lower, uv);
            try genSet(arena, O, upper, lv);
        } else if (upper_exists) {
            try genSet(arena, O, lower, uv);
            try genDelete(arena, O, upper);
        } else if (lower_exists) {
            try genSet(arena, O, upper, lv);
            try genDelete(arena, O, lower);
        }
    }
    return O;
}

/// 23.1.3.20 Array.prototype.lastIndexOf — generic; StrictEquality from the end.
pub fn nativeLastIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    if (len == 0) return val_mod.makeNumber(arena, -1);
    const search = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // fromIndex = ToIntegerOrInfinity; default len-1. -∞ → no match.
    var from: i64 = @as(i64, @intCast(len)) - 1;
    if (args.len > 1) {
        const nnum = try realm_mod.toNumberValue(arena, args[1]);
        if (std.math.isInf(nnum) and nnum < 0) return val_mod.makeNumber(arena, -1);
        const n: i64 = if (std.math.isNan(nnum)) 0 else val_mod.f64ToI64Sat(std.math.trunc(nnum));
        if (n >= 0) {
            if (n < from) from = n;
        } else {
            from = @as(i64, @intCast(len)) + n;
        }
    }
    if (from < 0) return val_mod.makeNumber(arena, -1);
    var i: usize = @intCast(from);
    while (true) : (i -= 1) {
        if (try genHas(arena, O, i) and jsStrictEqual(try genGet(arena, O, i), search)) return val_mod.makeNumber(arena, @floatFromInt(i));
        if (i == 0) break;
    }
    return val_mod.makeNumber(arena, -1);
}

/// Create a new real Array with the active Array.prototype.
fn newResultArray(arena: std.mem.Allocator) !*JsObject {
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    return try JsObject.createArray(arena, arr_proto);
}

/// IsConstructor over the engine's coarse function model (mirrors typed_array).
fn arrIsConstructor(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        .object => |o| blk: {
            if (o.internal_kind == .proxy) {
                const proxy_mod = @import("proxy.zig");
                if (proxy_mod.proxyTarget(o)) |t| break :blk arrIsConstructor(t);
                break :blk false;
            }
            break :blk o.get("__call__") != null or o.internal_kind == .bound_function;
        },
        else => false,
    };
}

/// ArrayCreate(length): a plain Array with [[ArrayLength]] = length, throwing
/// RangeError when length exceeds 2^32 - 1.
fn arrayCreate(arena: std.mem.Allocator, length: usize) !Value {
    if (length > 0xFFFF_FFFF) return throwRangeError(arena, "Invalid array length");
    const a = try newResultArray(arena);
    a.array_length = @intCast(length);
    return val_mod.makeObject(arena, a);
}

/// ES ArraySpeciesCreate(originalArray, length): create the result array via the
/// original array's constructor[@@species] when overridden, else a plain Array.
fn arraySpeciesCreate(arena: std.mem.Allocator, original: Value, length: usize) !Value {
    const is_array = original.bits != 0 and original.unbox() == .object and original.toPtr().object.is_array;
    if (!is_array) return arrayCreate(arena, length);
    var C: Value = if (realm_mod.active_context) |ctx| try ctx.getProp(arena, original, "constructor") else Value{ .bits = 0 };
    // If C is an Object, C = Get(C, @@species); null → undefined.
    if (C.bits != 0 and C.unbox() == .object) {
        if (realm_mod.active_sym_species) |sym| {
            C = if (realm_mod.active_context) |ctx| try ctx.getPropSym(arena, C, sym) else Value{ .bits = 0 };
            if (C.bits != 0 and C.unbox() == .null_) C = Value{ .bits = 0 };
        } else {
            C = Value{ .bits = 0 };
        }
    }
    // undefined species → default Array.
    if (C.bits == 0 or C.unbox() == .undefined_) return arrayCreate(arena, length);
    if (!arrIsConstructor(C)) return throwTypeError(arena, "Array species is not a constructor");
    const ctx = realm_mod.active_context orelse return throwTypeError(arena, "no active context");
    return ctx.construct(arena, C, &[_]Value{try val_mod.makeNumber(arena, @floatFromInt(length))});
}

/// ES2023 Array.prototype.with — non-mutating, returns a new array with `value`
/// at generic relative index.
pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const len = try genLength(arena, this_val);
    const index_arg = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const value = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    // ToIntegerOrInfinity(index): coerces strings/objects (calling valueOf and
    // propagating any thrown completion) and maps NaN → 0.
    const rel = try genInteger(arena, index_arg);
    const flen: f64 = @floatFromInt(len);
    const actual: f64 = if (rel >= 0) rel else flen + rel;
    if (actual >= flen or actual < 0) return throwRangeError(arena, "Invalid index");
    const k: usize = @intFromFloat(actual);
    // ArrayCreate(len) throws RangeError when len > 2**32 - 1, before any element read.
    if (len > 0xFFFFFFFF) return throwRangeError(arena, "Invalid array length");
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
    try requireCoercible(arena, this_val);
    const len = try genLength(arena, this_val);
    // ArrayCreate(len) throws RangeError when len > 2**32 - 1, before any element read.
    if (len > 0xFFFFFFFF) return throwRangeError(arena, "Invalid array length");
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
    try requireCoercible(arena, this_val);
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) try requireCallable(arena, args[0]);
    const len = try genLength(arena, this_val);
    // ArrayCreate(len) throws RangeError when len > 2**32 - 1, before any element read.
    if (len > 0xFFFFFFFF) return throwRangeError(arena, "Invalid array length");
    const new_arr = try newResultArray(arena);
    const arr_val = try val_mod.makeObject(arena, new_arr);
    var elems = try arena.alloc(Value, len);
    for (0..len) |i| elems[i] = try genGet(arena, this_val, i);

    const cmp_fn: ?Value = if (args.len > 0 and args[0].bits != 0) blk: {
        const v = args[0];
        if (v.unbox() == .undefined_) break :blk null;
        break :blk v;
    } else null;

    // Stable sort with spec SortCompare (undefined sorts last; a throwing
    // comparator or ToString propagates out of toSorted).
    try sortValues(arena, elems, cmp_fn);

    for (0..len) |k| {
        try genSet(arena, arr_val, k, elems[k]);
    }
    return arr_val;
}

/// ES2023 Array.prototype.toSpliced — non-mutating splice.
pub fn nativeToSpliced(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    const len = try genLength(arena, this_val);
    const start0 = if (args.len > 0) genRelClamp(try genInteger(arena, args[0]), len) else 0;
    // Spec §23.1.3.35: start absent → delete 0 (full copy); deleteCount absent
    // (but start present) → delete to end; otherwise clamp deleteCount to [0, len-start].
    const del_count: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - start0
    else blk: {
        const n = try genInteger(arena, args[1]);
        if (n <= 0) break :blk 0;
        break :blk @min(@as(usize, @intFromFloat(@min(n, @as(f64, @floatFromInt(len))))), len - start0);
    };
    const items = if (args.len > 2) args[2..] else &[_]Value{};
    const new_len = len - del_count + items.len;
    // §23.1.3.35 step 12: newLen > 2**53 - 1 is a TypeError (checked before
    // ArrayCreate, which then throws RangeError for newLen > 2**32 - 1).
    if (new_len > 9007199254740991) return throwTypeError(arena, "Invalid array length");
    if (new_len > 0xFFFFFFFF) return throwRangeError(arena, "Invalid array length");
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
    try requireCoercible(arena, this_val);
    const O = try toObject(arena, this_val);
    const len = try genLength(arena, O);
    const start = if (args.len > 0) genRelClamp(try genInteger(arena, args[0]), len) else 0;
    // Spec §23.1.3.31: 0 args → delete 0; 1 arg → delete to end; ≥2 → clamp.
    var del_count: usize = 0;
    if (args.len == 1) {
        del_count = len - start;
    } else if (args.len >= 2) {
        const dc = try genInteger(arena, args[1]);
        del_count = if (dc <= 0) 0 else @min(@as(usize, @intFromFloat(@min(dc, @as(f64, @floatFromInt(len))))), len - start);
    }
    const items = if (args.len > 2) args[2..] else &[_]Value{};

    // Removed elements → result array (holes preserved) via species create.
    const removed = try arraySpeciesCreate(arena, O, del_count);
    {
        var r: usize = 0;
        while (r < del_count) : (r += 1) {
            if (try genHas(arena, O, start + r))
                try genCreate(arena, removed, r, try genGet(arena, O, start + r));
        }
        try setLength(arena, removed, del_count);
    }

    const insert = items.len;
    const new_len = len - del_count + insert;
    if (insert < del_count) {
        // Shift the tail down (low → high is safe when moving toward 0).
        var i: usize = start + del_count;
        while (i < len) : (i += 1) {
            const to = i - del_count + insert;
            if (try genHas(arena, O, i)) try genSet(arena, O, to, try genGet(arena, O, i)) else try genDelete(arena, O, to);
        }
        // Delete now-vacated trailing slots [new_len, len).
        var d: usize = len;
        while (d > new_len) : (d -= 1) try genDelete(arena, O, d - 1);
    } else if (insert > del_count) {
        // Shift the tail up (high → low to avoid clobbering).
        var i: usize = len;
        while (i > start + del_count) : (i -= 1) {
            const from = i - 1;
            const to = from - del_count + insert;
            if (try genHas(arena, O, from)) try genSet(arena, O, to, try genGet(arena, O, from)) else try genDelete(arena, O, to);
        }
    }

    // Write inserted items at `start`.
    for (items, 0..) |it, j| {
        try genSet(arena, O, start + j, it);
    }
    // Set length last (real arrays update [[ArrayLength]]; array-likes get a prop).
    if (realm_mod.active_context) |ctx| {
        try ctx.setProp(arena, O, "length", try val_mod.makeNumber(arena, @floatFromInt(new_len)));
    } else if (O.isHeapPtr() and O.toPtr().* == .object) {
        O.toPtr().object.array_length = @intCast(new_len);
    }
    return removed;
}

fn toNumArg(v: Value) f64 {
    if (v.bits == 0) return 0;
    return switch (v.unbox()) {
        .number => |n| n,
        // Full ES StringToNumber (radix prefixes, Infinity, "") so slice/indexOf
        // index coercion agrees with unary `+` (e.g. "0b1110" → 14).
        .string => |s| val_mod.jsStringToNumber(s),
        .boolean => |b| if (b) 1 else 0,
        .undefined_ => std.math.nan(f64),
        .null_ => 0,
        else => std.math.nan(f64),
    };
}

// -- Array iterators: keys/entries (values is nativeArrayValues in es2015) --

pub fn nativeArrayKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const is_typed = typed_array_mod.getTd(this_val) != null;
        const d = try arena.create(coll_mod.SeqIterData);
        d.* = .{ .seq = this_val, .kind = .key, .is_typed = is_typed };
        return coll_mod.makeSeqIterator(arena, d);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeArrayEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireCoercible(arena, this_val);
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
    // §23.1.3.18 join: undefined/null elements → empty string; everything else
    // is ToString(element), which for objects fires toString/valueOf (so a
    // nested array stringifies via its own join, not "[object Object]").
    if (v.bits == 0) return "";
    switch (v.unbox()) {
        .undefined_, .null_ => return "",
        else => return valueToJsString(arena, v),
    }
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
