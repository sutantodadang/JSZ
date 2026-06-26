// SPDX-License-Identifier: Apache-2.0
//! Phase 7 baseline: Map/Set/WeakMap/WeakSet builtins.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const PropAttr = @import("../../object/object.zig").PropAttr;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const ta_mod = @import("typed_array.zig");
const symbol_mod = @import("symbol.zig");
const InternalKind = @TypeOf((@as(JsObject, undefined)).internal_kind);

/// Shared %ArrayIteratorPrototype% — the [[Prototype]] of every iterator
/// returned by Array.prototype.{values,keys,entries}[@@iterator] AND
/// %TypedArray%.prototype.{values,keys,entries}[@@iterator]. Built once at realm
/// init (after the well-known symbols resolve). Its [[Prototype]] is the
/// %IteratorPrototype%.
pub var active_array_iter_proto: ?*JsObject = null;
/// WeakMap.prototype — stored so registerSymbols can attach @@toStringTag.
pub var active_weakmap_proto: ?*JsObject = null;
/// WeakSet.prototype — stored so registerSymbols can attach @@toStringTag.
pub var active_weakset_proto: ?*JsObject = null;
/// WeakRef.prototype — stored so registerSymbols can attach @@toStringTag.
pub var active_weakref_proto: ?*JsObject = null;
/// FinalizationRegistry.prototype — stored so registerSymbols can attach @@toStringTag.
pub var active_finreg_proto: ?*JsObject = null;

/// R1: install Map/Set/WeakMap/WeakSet prototypes + constructors and bind globals.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const object_proto = ctx.object_proto;

    // ---- Map ----
    const map_proto = try JsObject.create(arena, object_proto);
    const map_fns = .{
        .{ "set", nativeMapSet },
        .{ "get", nativeMapGet },
        .{ "has", nativeMapHas },
        .{ "delete", nativeMapDelete },
        .{ "clear", nativeMapClear },
        .{ "size", nativeMapSize },
        .{ "keys", nativeMapKeys },
        .{ "values", nativeMapValues },
        .{ "entries", nativeMapEntries },
        .{ "@@iterator", nativeMapEntries },
    };
    inline for (map_fns) |pair| {
        const fn_v = try val_mod.makeNativeFunction(arena, pair[1]);
        try map_proto.set(pair[0], fn_v);
    }
    const map_ctor_obj = try JsObject.create(arena, null);
    try map_ctor_obj.set("prototype", try val_mod.makeObject(arena, map_proto));
    try map_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeMapCtor));
    try ctx.env.define("Map", try val_mod.makeObject(arena, map_ctor_obj));

    // ---- Set ----
    const set_proto = try JsObject.create(arena, object_proto);
    const set_fns = .{
        .{ "add", nativeSetAdd },
        .{ "has", nativeSetHas },
        .{ "delete", nativeSetDelete },
        .{ "clear", nativeSetClear },
        .{ "size", nativeSetSize },
        .{ "values", nativeSetValues },
        .{ "@@iterator", nativeSetValues },
    };
    inline for (set_fns) |pair| {
        const fn_v = try val_mod.makeNativeFunction(arena, pair[1]);
        try set_proto.set(pair[0], fn_v);
    }
    const set_ctor_obj = try JsObject.create(arena, null);
    try set_ctor_obj.set("prototype", try val_mod.makeObject(arena, set_proto));
    try set_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeSetCtor));
    try ctx.env.define("Set", try val_mod.makeObject(arena, set_ctor_obj));

    // ---- WeakMap ----
    const wm_proto = try JsObject.create(arena, object_proto);
    const wm_m: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try wm_proto.defineOwnData("set", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapSet, "set", 2), wm_m);
    _ = try wm_proto.defineOwnData("get", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapGet, "get", 1), wm_m);
    _ = try wm_proto.defineOwnData("has", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapHas, "has", 1), wm_m);
    _ = try wm_proto.defineOwnData("delete", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapDelete, "delete", 1), wm_m);
    _ = try wm_proto.defineOwnData("getOrInsert", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapGetOrInsert, "getOrInsert", 2), wm_m);
    _ = try wm_proto.defineOwnData("getOrInsertComputed", try val_mod.makeNativeFunctionNamed(arena, nativeWeakMapGetOrInsertComputed, "getOrInsertComputed", 2), wm_m);

    const wm_ctor = try JsObject.create(arena, ctx.function_proto);
    const wm_nlen: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try wm_ctor.defineOwnData("name", try val_mod.makeString(arena, "WeakMap"), wm_nlen);
    _ = try wm_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), wm_nlen);
    _ = try wm_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, wm_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try wm_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeWeakMapCtor));
    _ = try wm_proto.defineOwnData("constructor", try val_mod.makeObject(arena, wm_ctor), wm_m);
    active_weakmap_proto = wm_proto;
    try ctx.env.define("WeakMap", try val_mod.makeObject(arena, wm_ctor));

    // ---- WeakSet ----
    const ws_proto = try JsObject.create(arena, object_proto);
    const ws_m: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try ws_proto.defineOwnData("add", try val_mod.makeNativeFunctionNamed(arena, nativeWeakSetAdd, "add", 1), ws_m);
    _ = try ws_proto.defineOwnData("has", try val_mod.makeNativeFunctionNamed(arena, nativeWeakSetHas, "has", 1), ws_m);
    _ = try ws_proto.defineOwnData("delete", try val_mod.makeNativeFunctionNamed(arena, nativeWeakSetDelete, "delete", 1), ws_m);

    const ws_ctor = try JsObject.create(arena, ctx.function_proto);
    const ws_nlen: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try ws_ctor.defineOwnData("name", try val_mod.makeString(arena, "WeakSet"), ws_nlen);
    _ = try ws_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), ws_nlen);
    _ = try ws_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, ws_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try ws_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeWeakSetCtor));
    _ = try ws_proto.defineOwnData("constructor", try val_mod.makeObject(arena, ws_ctor), ws_m);
    active_weakset_proto = ws_proto;
    try ctx.env.define("WeakSet", try val_mod.makeObject(arena, ws_ctor));

    // ---- WeakRef ----
    const wr_proto = try JsObject.create(arena, object_proto);
    const wr_m: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try wr_proto.defineOwnData("deref", try val_mod.makeNativeFunctionNamed(arena, nativeWeakRefDeref, "deref", 0), wr_m);

    const wr_ctor = try JsObject.create(arena, ctx.function_proto);
    const wr_nlen: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try wr_ctor.defineOwnData("name", try val_mod.makeString(arena, "WeakRef"), wr_nlen);
    _ = try wr_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), wr_nlen);
    _ = try wr_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, wr_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try wr_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeWeakRefCtor));
    _ = try wr_proto.defineOwnData("constructor", try val_mod.makeObject(arena, wr_ctor), wr_m);
    active_weakref_proto = wr_proto;
    try ctx.env.define("WeakRef", try val_mod.makeObject(arena, wr_ctor));

    // ---- FinalizationRegistry ----
    const fr_proto = try JsObject.create(arena, object_proto);
    const fr_m: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try fr_proto.defineOwnData("register", try val_mod.makeNativeFunctionNamed(arena, nativeFinRegRegister, "register", 2), fr_m);
    _ = try fr_proto.defineOwnData("unregister", try val_mod.makeNativeFunctionNamed(arena, nativeFinRegUnregister, "unregister", 1), fr_m);

    const fr_ctor = try JsObject.create(arena, ctx.function_proto);
    const fr_nlen: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try fr_ctor.defineOwnData("name", try val_mod.makeString(arena, "FinalizationRegistry"), fr_nlen);
    _ = try fr_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), fr_nlen);
    _ = try fr_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, fr_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try fr_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeFinRegCtor));
    _ = try fr_proto.defineOwnData("constructor", try val_mod.makeObject(arena, fr_ctor), fr_m);
    active_finreg_proto = fr_proto;
    try ctx.env.define("FinalizationRegistry", try val_mod.makeObject(arena, fr_ctor));
}

/// Wire @@toStringTag onto WeakMap.prototype and WeakSet.prototype.
/// Called after Symbol well-known values are captured (same lifecycle as
/// typed_array_mod.registerSymbols).
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const tag_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    if (realm_mod.active_sym_to_string_tag) |tag_sym| {
        if (active_weakmap_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakMap"), tag_attr);
        if (active_weakset_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakSet"), tag_attr);
        if (active_weakref_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakRef"), tag_attr);
        if (active_finreg_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "FinalizationRegistry"), tag_attr);
    }
}

const MapData = struct {
    keys: std.ArrayListUnmanaged(Value) = .empty,
    values: std.ArrayListUnmanaged(Value) = .empty,
};

const SetData = struct {
    values: std.ArrayListUnmanaged(Value) = .empty,
};

fn strictEq(a: Value, b: Value) bool {
    if (a.bits == 0 and b.bits == 0) return true;
    if (a.bits == 0 or b.bits == 0) return false;
    const av = a.unbox();
    const bv = b.unbox();
    if (std.meta.activeTag(av) != std.meta.activeTag(bv)) return false;
    return switch (av) {
        .undefined_, .null_ => true,
        .boolean => |x| x == bv.boolean,
        .number => |x| x == bv.number,
        .string => |x| std.mem.eql(u8, x, bv.string),
        else => a.bits == b.bits,
    };
}

fn makeObj(arena: std.mem.Allocator, proto: ?*JsObject, kind: InternalKind) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_kind = kind;
    return val_mod.makeObject(arena, obj);
}

/// A WeakMap/WeakSet key must be held weakly, which the spec restricts to
/// objects (incl. callable objects: ordinary functions and class constructors)
/// and non-registered symbols. Reject primitives. We treat all function value
/// representations as valid keys; a plain primitive is not.
fn canBeWeakKey(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .function, .bc_function, .native_function => true,
        // Unregistered symbols may be used as weak keys (spec: "can be held weakly").
        // Registered symbols (Symbol.for) are excluded.
        .symbol => !symbol_mod.isRegisteredSymbol(v),
        else => false,
    };
}

fn getMapData(this_val: Value, expected: InternalKind) ?*MapData {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != expected) return null;
    if (obj.internal_slot) |s| return @ptrCast(@alignCast(s));
    return null;
}

fn getSetData(this_val: Value, expected: InternalKind) ?*SetData {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != expected) return null;
    if (obj.internal_slot) |s| return @ptrCast(@alignCast(s));
    return null;
}

/// Virtual ES2015 `size` accessor for Map/Set. Returns null for non-collections
/// (WeakMap/WeakSet expose no `size`).
pub fn collectionSize(obj: *JsObject) ?usize {
    return switch (obj.internal_kind) {
        .map => if (obj.internal_slot) |s| (@as(*MapData, @ptrCast(@alignCast(s)))).keys.items.len else 0,
        .set => if (obj.internal_slot) |s| (@as(*SetData, @ptrCast(@alignCast(s)))).values.items.len else 0,
        else => null,
    };
}

pub fn nativeMapCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) {
        out = try makeObj(arena, null, .map);
    }
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .map;
    obj.internal_slot = d;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object and args[0].toPtr().object.is_array) {
        const src = args[0].toPtr().object;
        var i: u32 = 0;
        while (i < src.getArrayLength()) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const ks = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch continue;
            const pair_val = src.get(ks) orelse continue;
            if (pair_val.bits == 0 or pair_val.unbox() != .object) continue;
            const pair = pair_val.toPtr().object;
            const k = pair.get("0") orelse continue;
            const v = pair.get("1") orelse try val_mod.makeUndefined(arena);
            _ = try nativeMapSet(arena, out, &.{ k, v });
        }
    }
    return out;
}

pub fn nativeWeakMapCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "WeakMap constructor requires 'new'");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, null, .weakmap);
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .weakmap;
    obj.internal_slot = d;
    if (args.len > 0) {
        const iterable = args[0];
        if (iterable.bits != 0) {
            const tag = iterable.unbox();
            if (tag != .undefined_ and tag != .null_)
                try iterableWeakInit(arena, out, iterable, true);
        }
    }
    return out;
}

pub fn nativeSetCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, null, .set);
    const obj = out.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_kind = .set;
    obj.internal_slot = d;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object and args[0].toPtr().object.is_array) {
        const src = args[0].toPtr().object;
        var i: u32 = 0;
        while (i < src.getArrayLength()) : (i += 1) {
            var kbuf: [16]u8 = undefined;
            const ks = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch continue;
            const el = src.get(ks) orelse continue;
            _ = try nativeSetAdd(arena, out, &.{el});
        }
    }
    return out;
}

pub fn nativeWeakSetCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "WeakSet constructor requires 'new'");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, null, .weakset);
    const obj = out.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_kind = .weakset;
    obj.internal_slot = d;
    if (args.len > 0) {
        const iterable = args[0];
        if (iterable.bits != 0) {
            const tag = iterable.unbox();
            if (tag != .undefined_ and tag != .null_)
                try iterableWeakInit(arena, out, iterable, false);
        }
    }
    return out;
}

// ---- WeakMap / WeakSet helpers ----

fn isTruthy(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_, .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0.0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
}

fn setTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror!void {
    realm_mod.pending_exception = try makeTypeErrorVal(arena, msg);
    return error.JsException;
}

fn closeIterator(arena: std.mem.Allocator, iter: Value) void {
    if (iter.bits == 0 or iter.unbox() != .object) return;
    const ret_fn = iter.toPtr().object.get("return") orelse return;
    if (!isCallable(ret_fn)) return;
    _ = function_proto.invokeCallback(arena, iter, ret_fn, &[_]Value{}) catch {};
}

fn getWeakMapData(arena: std.mem.Allocator, this_val: Value) anyerror!*MapData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "WeakMap method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .weakmap or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a WeakMap)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn getWeakSetData(arena: std.mem.Allocator, this_val: Value) anyerror!*SetData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "WeakSet method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .weakset or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a WeakSet)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

// ---- WeakMap methods (brand-checked: .weakmap only) ----

pub fn nativeWeakMapSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    if (args.len < 1 or !canBeWeakKey(args[0])) {
        try setTypeError(arena, "Invalid value used as weak map key");
        unreachable;
    }
    const key = args[0];
    const val = if (args.len >= 2) args[1] else try val_mod.makeUndefined(arena);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, key)) { data.values.items[i] = val; return this_val; }
    }
    try data.keys.append(arena, key);
    try data.values.append(arena, val);
    return this_val;
}

pub fn nativeWeakMapGet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, args[0])) return data.values.items[i];
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeWeakMapHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items) |k| if (strictEq(k, args[0])) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, false);
}

pub fn nativeWeakMapDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, args[0])) {
            _ = data.keys.orderedRemove(i);
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeWeakMapGetOrInsert(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    if (args.len < 1 or !canBeWeakKey(args[0])) {
        try setTypeError(arena, "Invalid value used as weak map key");
        unreachable;
    }
    const key = args[0];
    const default_val = if (args.len >= 2) args[1] else try val_mod.makeUndefined(arena);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, key)) return data.values.items[i];
    }
    try data.keys.append(arena, key);
    try data.values.append(arena, default_val);
    return default_val;
}

pub fn nativeWeakMapGetOrInsertComputed(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakMapData(arena, this_val);
    // Step 3 (spec): IsCallable check FIRST, even if key is already present.
    const cb = if (args.len >= 2) args[1] else Value{};
    if (!isCallable(cb)) {
        try setTypeError(arena, "callbackfn is not callable");
        unreachable;
    }
    const key = if (args.len >= 1) args[0] else try val_mod.makeUndefined(arena);
    // Step 4: look up key (before weak-key check per spec).
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, key)) return data.values.items[i];
    }
    // Step 5: weak-key check (after lookup per spec).
    if (!canBeWeakKey(key)) {
        try setTypeError(arena, "Invalid value used as weak map key");
        unreachable;
    }
    // Step 6: call callbackfn(key).
    const computed = try function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &.{key});
    // Step 7: re-check after callback — callback may have inserted/modified key.
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, key)) {
            data.values.items[i] = computed;
            return computed;
        }
    }
    // Step 8-9: key still absent, append.
    try data.keys.append(arena, key);
    try data.values.append(arena, computed);
    return computed;
}

// ---- WeakSet methods (brand-checked: .weakset only) ----

pub fn nativeWeakSetAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakSetData(arena, this_val);
    if (args.len == 0 or !canBeWeakKey(args[0])) {
        try setTypeError(arena, "Invalid value used as weak set value");
        unreachable;
    }
    for (data.values.items) |v| if (strictEq(v, args[0])) return this_val;
    try data.values.append(arena, args[0]);
    return this_val;
}

pub fn nativeWeakSetHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakSetData(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items) |v| if (strictEq(v, args[0])) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, false);
}

pub fn nativeWeakSetDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getWeakSetData(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items, 0..) |v, i| {
        if (strictEq(v, args[0])) {
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

// ---- WeakRef internal data ----

const WeakRefData = struct {
    target: Value,
};

fn getWeakRefData(arena: std.mem.Allocator, this_val: Value) anyerror!*WeakRefData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "WeakRef method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .weakref or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a WeakRef)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

pub fn nativeWeakRefCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "WeakRef constructor requires 'new'");
        return error.JsException;
    }
    // CanBeHeldWeakly check on target (step 2)
    const target = if (args.len > 0) args[0] else Value{};
    if (!canBeWeakKey(target)) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "WeakRef target must be an object or unregistered symbol");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, active_weakref_proto, .weakref);
    const obj = out.toPtr().object;
    const d = try arena.create(WeakRefData);
    d.* = .{ .target = target };
    obj.internal_kind = .weakref;
    obj.internal_slot = d;
    return out;
}

pub fn nativeWeakRefDeref(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getWeakRefData(arena, this_val);
    if (data.target.bits == 0) return val_mod.makeUndefined(arena);
    return data.target;
}

// ---- FinalizationRegistry internal data ----

const FinRegCell = struct {
    target: Value,
    held_value: Value,
    /// bits == 0 means "no token" (empty unregister slot)
    unregister_token: Value,
    has_token: bool,
};

const FinRegData = struct {
    /// The cleanup callback (callable). Stored but never invoked (no GC).
    callback: Value,
    cells: std.ArrayListUnmanaged(FinRegCell) = .empty,
};

fn getFinRegData(arena: std.mem.Allocator, this_val: Value) anyerror!*FinRegData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "FinalizationRegistry method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .finalization_registry or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a FinalizationRegistry)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

pub fn nativeFinRegCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "FinalizationRegistry constructor requires 'new'");
        return error.JsException;
    }
    // cleanupCallback must be callable (step 2)
    const cb = if (args.len > 0) args[0] else Value{};
    if (!isCallable(cb)) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "FinalizationRegistry cleanupCallback must be callable");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, active_finreg_proto, .finalization_registry);
    const obj = out.toPtr().object;
    const d = try arena.create(FinRegData);
    d.* = .{ .callback = cb };
    obj.internal_kind = .finalization_registry;
    obj.internal_slot = d;
    return out;
}

pub fn nativeFinRegRegister(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getFinRegData(arena, this_val);
    // Step 3: target must CanBeHeldWeakly
    const target = if (args.len > 0) args[0] else Value{};
    if (!canBeWeakKey(target)) {
        try setTypeError(arena, "Invalid value used as WeakRef target");
        unreachable;
    }
    const held_value = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    // Step 4: SameValue(target, heldValue) must be false
    if (strictEq(target, held_value)) {
        try setTypeError(arena, "target and heldValue must not be the same value");
        unreachable;
    }
    // Step 5: unregisterToken validation
    const token_raw = if (args.len > 2) args[2] else Value{};
    const has_token = token_raw.bits != 0 and token_raw.unbox() != .undefined_;
    if (has_token and !canBeWeakKey(token_raw)) {
        try setTypeError(arena, "Invalid value used as unregisterToken");
        unreachable;
    }
    try data.cells.append(arena, .{
        .target = target,
        .held_value = held_value,
        .unregister_token = if (has_token) token_raw else Value{},
        .has_token = has_token,
    });
    return val_mod.makeUndefined(arena);
}

pub fn nativeFinRegUnregister(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getFinRegData(arena, this_val);
    const token = if (args.len > 0) args[0] else Value{};
    if (!canBeWeakKey(token)) {
        try setTypeError(arena, "Invalid value used as unregisterToken");
        unreachable;
    }
    var removed = false;
    var i: usize = 0;
    while (i < data.cells.items.len) {
        const cell = data.cells.items[i];
        if (cell.has_token and strictEq(cell.unregister_token, token)) {
            _ = data.cells.orderedRemove(i);
            removed = true;
            // do not advance i — element at i is now the next one
        } else {
            i += 1;
        }
    }
    return val_mod.makeBool(arena, removed);
}

/// Shared iterable initialization for WeakMap (is_map=true, expects [key,val] pairs)
/// and WeakSet (is_map=false, expects individual values).
/// Implements ES spec: get adder, GetIterator, loop IteratorStep, call adder,
/// IteratorClose on abrupt completion.
fn iterableWeakInit(
    arena: std.mem.Allocator,
    out: Value,
    iterable: Value,
    is_map: bool,
) !void {
    // Get adder = M["set"] or M["add"]
    const adder_name = if (is_map) "set" else "add";
    const adder: Value = blk: {
        if (realm_mod.active_context) |ctx| {
            break :blk try ctx.getProp(arena, out, adder_name);
        }
        if (out.bits != 0 and out.unbox() == .object) {
            break :blk out.toPtr().object.get(adder_name) orelse try val_mod.makeUndefined(arena);
        }
        break :blk try val_mod.makeUndefined(arena);
    };
    if (!isCallable(adder)) {
        try setTypeError(arena, adder_name ++ " is not callable");
        unreachable;
    }

    // GetIterator(iterable)
    const iter = try nativeGetIterator(arena, Value{}, &.{iterable});

    while (true) {
        // IteratorStep: call iter.next()
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| return e;

        // IteratorComplete
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object)
            step.toPtr().object.get("done") orelse Value{}
        else
            Value{};
        if (isTruthy(done_v)) break;

        // IteratorValue (observable getProp for getter-throw support)
        const item: Value = blk: {
            if (step.bits != 0 and step.unbox() == .object) {
                if (realm_mod.active_context) |ctx| {
                    break :blk ctx.getProp(arena, step, "value") catch |e| {
                        closeIterator(arena, iter);
                        return e;
                    };
                }
                break :blk step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena);
            }
            break :blk try val_mod.makeUndefined(arena);
        };

        if (is_map) {
            // Entry must be an Object
            if (item.bits == 0 or item.unbox() != .object) {
                closeIterator(arena, iter);
                try setTypeError(arena, "Iterator value is not an object");
                unreachable;
            }
            // Get key (index "0") and value (index "1")
            const k: Value = blk: {
                if (realm_mod.active_context) |ctx| {
                    break :blk ctx.getProp(arena, item, "0") catch |e| {
                        closeIterator(arena, iter);
                        return e;
                    };
                }
                break :blk item.toPtr().object.get("0") orelse try val_mod.makeUndefined(arena);
            };
            const v: Value = blk: {
                if (realm_mod.active_context) |ctx| {
                    break :blk ctx.getProp(arena, item, "1") catch |e| {
                        closeIterator(arena, iter);
                        return e;
                    };
                }
                break :blk item.toPtr().object.get("1") orelse try val_mod.makeUndefined(arena);
            };
            _ = function_proto.invokeCallback(arena, out, adder, &.{ k, v }) catch |e| {
                closeIterator(arena, iter);
                return e;
            };
        } else {
            _ = function_proto.invokeCallback(arena, out, adder, &.{item}) catch |e| {
                closeIterator(arena, iter);
                return e;
            };
        }
    }
}

// ---- Map methods (unchanged, Map+WeakMap shared — kept for Map only now) ----

pub fn nativeMapSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse getMapData(this_val, .weakmap) orelse return this_val;
    if (args.len < 2) return this_val;
    const weak = this_val.toPtr().object.internal_kind == .weakmap;
    if (weak and !canBeWeakKey(args[0])) return this_val;
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, args[0])) {
            data.values.items[i] = args[1];
            return this_val;
        }
    }
    try data.keys.append(arena, args[0]);
    try data.values.append(arena, args[1]);
    return this_val;
}

pub fn nativeMapGet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse getMapData(this_val, .weakmap) orelse return val_mod.makeUndefined(arena);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, args[0])) return data.values.items[i];
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeMapHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse getMapData(this_val, .weakmap) orelse return val_mod.makeBool(arena, false);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items) |k| {
        if (strictEq(k, args[0])) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeMapDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse getMapData(this_val, .weakmap) orelse return val_mod.makeBool(arena, false);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items, 0..) |k, i| {
        if (strictEq(k, args[0])) {
            _ = data.keys.orderedRemove(i);
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeMapClear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse return val_mod.makeUndefined(arena);
    data.keys.clearRetainingCapacity();
    data.values.clearRetainingCapacity();
    return val_mod.makeUndefined(arena);
}

pub fn nativeMapSize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = getMapData(this_val, .map) orelse return val_mod.makeNumber(arena, 0);
    return val_mod.makeNumber(arena, @floatFromInt(data.keys.items.len));
}

pub fn nativeSetAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse getSetData(this_val, .weakset) orelse return this_val;
    if (args.len == 0) return this_val;
    const weak = this_val.toPtr().object.internal_kind == .weakset;
    if (weak and !canBeWeakKey(args[0])) return this_val;
    for (data.values.items) |v| if (strictEq(v, args[0])) return this_val;
    try data.values.append(arena, args[0]);
    return this_val;
}

pub fn nativeSetHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse getSetData(this_val, .weakset) orelse return val_mod.makeBool(arena, false);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items) |v| if (strictEq(v, args[0])) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, false);
}

pub fn nativeSetDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse getSetData(this_val, .weakset) orelse return val_mod.makeBool(arena, false);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items, 0..) |v, i| {
        if (strictEq(v, args[0])) {
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeSetClear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse return val_mod.makeUndefined(arena);
    data.values.clearRetainingCapacity();
    return val_mod.makeUndefined(arena);
}

pub fn nativeSetSize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse return val_mod.makeNumber(arena, 0);
    return val_mod.makeNumber(arena, @floatFromInt(data.values.items.len));
}

const MapIterKind = enum { keys, values, entries };

const MapIterData = struct {
    map: *MapData,
    index: usize = 0,
    kind: MapIterKind,
};

const SetIterData = struct {
    set: *SetData,
    index: usize = 0,
};

fn makeIteratorResult(arena: std.mem.Allocator, value: Value, done: bool) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    return val_mod.makeObject(arena, obj);
}

fn makeMapIterator(arena: std.mem.Allocator, data: *MapIterData) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_slot = data;
    try obj.set("next", try val_mod.makeNativeFunction(arena, nativeMapIteratorNext));
    return val_mod.makeObject(arena, obj);
}

fn makeSetIterator(arena: std.mem.Allocator, data: *SetIterData) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_slot = data;
    try obj.set("next", try val_mod.makeNativeFunction(arena, nativeSetIteratorNext));
    return val_mod.makeObject(arena, obj);
}

fn mapIteratorKind(arena: std.mem.Allocator, this_val: Value, expected: InternalKind, kind: MapIterKind) !Value {
    const data = getMapData(this_val, expected) orelse return val_mod.makeUndefined(arena);
    const iter = try arena.create(MapIterData);
    iter.* = .{ .map = data, .index = 0, .kind = kind };
    return makeMapIterator(arena, iter);
}

pub fn nativeMapKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .map, .keys);
}

pub fn nativeMapValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .map, .values);
}

pub fn nativeMapEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .map, .entries);
}

pub fn nativeSetValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = getSetData(this_val, .set) orelse return val_mod.makeUndefined(arena);
    const iter = try arena.create(SetIterData);
    iter.* = .{ .set = data, .index = 0 };
    return makeSetIterator(arena, iter);
}

pub fn nativeMapIteratorNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const iter: *MapIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (iter.index >= iter.map.keys.items.len) {
        return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    }
    const value: Value = switch (iter.kind) {
        .keys => iter.map.keys.items[iter.index],
        .values => iter.map.values.items[iter.index],
        .entries => blk: {
            const array_proto = realm_mod.active_array_proto;
            const pair = if (realm_mod.active_heap) |h|
                try JsObject.createArrayOnHeap(h, array_proto)
            else
                try JsObject.createArray(arena, array_proto);
            pair.set("0", iter.map.keys.items[iter.index]) catch return error.OutOfMemory;
            pair.set("1", iter.map.values.items[iter.index]) catch return error.OutOfMemory;
            pair.array_length = 2;
            break :blk try val_mod.makeObject(arena, pair);
        },
    };
    iter.index += 1;
    return makeIteratorResult(arena, value, false);
}

pub fn nativeSetIteratorNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const iter: *SetIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (iter.index >= iter.set.values.items.len) {
        return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    }
    const value = iter.set.values.items[iter.index];
    iter.index += 1;
    return makeIteratorResult(arena, value, false);
}

// ---------------------------------------------------------- W2: generic iteration ---
// Used by the bytecode for-of loop. __getIterator__(x) returns an iterator object
// (one exposing next()); __iterStep__(it) calls it.next() and returns the result.

const function_proto = @import("function_proto.zig");
const string_proto = @import("string_proto.zig");

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .native_function, .bc_function, .function => true,
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function,
        else => false,
    };
}

/// Walk the prototype chain for the object's Symbol.iterator method, if any.
fn iteratorMethod(obj: *JsObject) ?Value {
    const sym = realm_mod.active_sym_iterator orelse return null;
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

/// CreateArrayIterator kind (22.1.5.1 / 23.2.5.1): value, key, or key+value.
pub const SeqIterKind = enum { value, key, entry };

/// Per-instance state for the unified Array/String/TypedArray iterator.
/// `is_typed` selects the TypedArray element-load path (which reads the live
/// [[ArrayLength]] each step, so resize/detach during iteration is observed).
pub const SeqIterData = struct {
    seq: Value,
    index: usize = 0,
    is_string: bool = false,
    is_typed: bool = false,
    kind: SeqIterKind = .value,
    /// Once the underlying generator-style iterator completes (exhausted or
    /// abrupt), it stays done — a later regrow of a length-tracking TypedArray
    /// must NOT resurrect it.
    done: bool = false,
};

/// %IteratorPrototype%[@@iterator] and %ArrayIteratorPrototype% reuse: return
/// the `this` iterator itself.
fn nativeIterSelf(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

/// Build the shared %IteratorPrototype% → %ArrayIteratorPrototype% chain. Call
/// once at realm init, after @@iterator / @@toStringTag are resolved.
pub fn initArrayIteratorProto(arena: std.mem.Allocator, object_proto: *JsObject) !void {
    const cfg: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    // %IteratorPrototype%: { [@@iterator]() { return this } }.
    const iter_proto = try JsObject.create(arena, object_proto);
    if (realm_mod.active_sym_iterator) |sym|
        try iter_proto.setSymAttr(sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), cfg);
    // %ArrayIteratorPrototype%: { next, [@@toStringTag]: "Array Iterator" }.
    const aip = try JsObject.create(arena, iter_proto);
    _ = try aip.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeSeqIterNext, "next", 0), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try aip.setSymAttr(tag, try val_mod.makeString(arena, "Array Iterator"), .{ .writable = false, .enumerable = false, .configurable = true });
    active_array_iter_proto = aip;
}

/// Array.prototype[Symbol.iterator] (and values()): index iterator over `this`.
pub fn nativeArrayValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const d = try arena.create(SeqIterData);
        d.* = .{ .seq = this_val, .kind = .value };
        return makeSeqIterator(arena, d);
    }
    return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
}

/// String.prototype[Symbol.iterator](): a by-code-point iterator over `this`
/// coerced to a string. `this` may be a primitive string or a String wrapper.
pub fn nativeStringValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var sv = this_val;
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        // Unwrap a String object via its [[PrimitiveValue]] slot.
        if (this_val.toPtr().object.get("[[PrimitiveValue]]")) |pv| {
            if (pv.bits != 0 and pv.unbox() == .string) sv = pv;
        }
    }
    if (sv.bits == 0 or sv.unbox() != .string) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "String.prototype[Symbol.iterator] called on non-string");
        return error.JsException;
    }
    const d = try arena.create(SeqIterData);
    d.* = .{ .seq = sv, .kind = .value, .is_string = true };
    return makeSeqIterator(arena, d);
}

/// Wrap iterator state in an object whose [[Prototype]] is the shared
/// %ArrayIteratorPrototype% (so `next` is inherited, not own).
pub fn makeSeqIterator(arena: std.mem.Allocator, d: *SeqIterData) !Value {
    const proto = active_array_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = d;
    // Fallback when the shared proto is not built (early bootstrap): own next.
    if (proto == null) try obj.set("next", try val_mod.makeNativeFunction(arena, nativeSeqIterNext));
    return val_mod.makeObject(arena, obj);
}

fn entryPair(arena: std.mem.Allocator, idx: usize, value: Value) !Value {
    const pair = try newArrayPair(arena);
    try pair.set("0", try val_mod.makeNumber(arena, @floatFromInt(idx)));
    try pair.set("1", value);
    return val_mod.makeObject(arena, pair);
}

fn newArrayPair(arena: std.mem.Allocator) !*JsObject {
    const pair = try JsObject.create(arena, realm_mod.active_array_proto);
    pair.is_array = true;
    pair.array_length = 2;
    return pair;
}

fn nativeSeqIterNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const d: *SeqIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (d.done) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    if (d.is_string) {
        const s = d.seq.unbox().string;
        if (d.index >= s.len) {
            d.done = true;
            return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
        }
        // String iteration is by code point (spec %StringIteratorPrototype%):
        // decode one WTF-8 sequence; a high surrogate immediately followed by a
        // low surrogate is a single code point (yield both units together).
        const dec = string_proto.decodeWtf8At(s, d.index);
        var step = dec.len;
        if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF and d.index + dec.len < s.len) {
            const dec2 = string_proto.decodeWtf8At(s, d.index + dec.len);
            if (dec2.cp >= 0xDC00 and dec2.cp <= 0xDFFF) step += dec2.len;
        }
        const ch = try arena.dupe(u8, s[d.index .. d.index + step]);
        d.index += step;
        return makeIteratorResult(arena, try val_mod.makeString(arena, ch), false);
    }
    if (d.is_typed) {
        const td = ta_mod.getTd(d.seq) orelse return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
        // CreateArrayIterator: each step first throws TypeError if the view is
        // out-of-bounds (fixed-length view over a shrunk/detached buffer), then
        // ends (permanently) once index reaches the live length.
        if (ta_mod.taIsOob(td)) {
            d.done = true;
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "TypedArray is out-of-bounds during iteration");
            return error.JsException;
        }
        if (d.index >= ta_mod.taCurrentLen(td)) {
            d.done = true;
            return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
        }
        const idx = d.index;
        d.index += 1;
        return switch (d.kind) {
            .key => makeIteratorResult(arena, try val_mod.makeNumber(arena, @floatFromInt(idx)), false),
            .value => makeIteratorResult(arena, try ta_mod.taLoad(arena, td, idx), false),
            .entry => makeIteratorResult(arena, try entryPair(arena, idx, try ta_mod.taLoad(arena, td, idx)), false),
        };
    }
    const arr = d.seq.toPtr().object;
    // Array iterator length: a true Array uses its [[ArrayLength]]; a generic
    // array-like (e.g. the `arguments` object) reads its `length` property.
    const arr_len: usize = if (arr.is_array) arr.getArrayLength() else blk: {
        const lv = arr.get("length") orelse break :blk 0;
        if (lv.bits == 0 or lv.unbox() != .number) break :blk 0;
        const n = lv.unbox().number;
        if (!(n > 0)) break :blk 0;
        if (n > 9007199254740991.0) break :blk 9007199254740991;
        break :blk @intFromFloat(n);
    };
    if (d.index >= arr_len) {
        d.done = true;
        return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    }
    const idx = d.index;
    d.index += 1;
    const idx_str = try std.fmt.allocPrint(arena, "{d}", .{idx});
    const v = arr.get(idx_str) orelse try val_mod.makeUndefined(arena);
    return switch (d.kind) {
        .key => makeIteratorResult(arena, try val_mod.makeNumber(arena, @floatFromInt(idx)), false),
        .value => makeIteratorResult(arena, v, false),
        .entry => makeIteratorResult(arena, try entryPair(arena, idx, v), false),
    };
}

/// __getIterator__(x): obtain an iterator (object with next()) for `x`.
pub fn nativeGetIterator(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const x = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (x.bits != 0 and x.unbox() == .object) {
        const obj = x.toPtr().object;
        // Already an iterator (e.g. a generator) — it exposes next().
        if (obj.get("next")) |nx| {
            if (isCallable(nx)) return x;
        }
        // ES2015: obtain the iterator via the object's Symbol.iterator method.
        if (iteratorMethod(obj)) |itf| {
            if (isCallable(itf)) return function_proto.invokeCallback(arena, x, itf, &[_]Value{});
        }
        // Iterable — call its @@iterator method.
        if (obj.get("@@iterator")) |itf| {
            if (isCallable(itf)) return function_proto.invokeCallback(arena, x, itf, &[_]Value{});
        }
        // Array fallback: synthesize an index iterator.
        if (obj.is_array) {
            const d = try arena.create(SeqIterData);
            d.* = .{ .seq = x, .index = 0, .is_string = false };
            return makeSeqIterator(arena, d);
        }
        // Fallback: an accessor-defined @@iterator (a getter) is invisible to the
        // raw slot reads above. Do an observable [[Get]] (fires the getter / a
        // Proxy trap) and, if it yields a callable, drive it as the iterator.
        if (realm_mod.active_context) |ctx| {
            if (realm_mod.active_sym_iterator) |sym| {
                const m = try ctx.getPropSym(arena, x, sym);
                if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                    if (!isCallable(m)) {
                        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.iterator is not a function");
                        return error.JsException;
                    }
                    return function_proto.invokeCallback(arena, x, m, &[_]Value{});
                }
            }
        }
    }
    if (x.bits != 0 and x.unbox() == .string) {
        const d = try arena.create(SeqIterData);
        d.* = .{ .seq = x, .index = 0, .is_string = true };
        return makeSeqIterator(arena, d);
    }
    realm_mod.pending_exception = try makeTypeErrorVal(arena, "value is not iterable");
    return error.JsException;
}

/// __iterStep__(it): call it.next() and return the {value,done} result.
pub fn nativeIterStep(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const it = if (args.len > 0) args[0] else return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    if (it.bits == 0 or it.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const nx = it.toPtr().object.get("next") orelse return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    return function_proto.invokeCallback(arena, it, nx, &[_]Value{});
}

fn makeTypeErrorVal(arena: std.mem.Allocator, msg: []const u8) !Value {
    // Use the realm's TypeError.prototype so `err instanceof TypeError` and
    // `err.constructor === TypeError` hold (assert.throws relies on both).
    const proto: ?*JsObject = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}
