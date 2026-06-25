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
const InternalKind = @TypeOf((@as(JsObject, undefined)).internal_kind);

/// Shared %ArrayIteratorPrototype% — the [[Prototype]] of every iterator
/// returned by Array.prototype.{values,keys,entries}[@@iterator] AND
/// %TypedArray%.prototype.{values,keys,entries}[@@iterator]. Built once at realm
/// init (after the well-known symbols resolve). Its [[Prototype]] is the
/// %IteratorPrototype%.
pub var active_array_iter_proto: ?*JsObject = null;

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
    const weakmap_proto = try JsObject.create(arena, object_proto);
    const weakmap_fns = .{
        .{ "set", nativeMapSet },
        .{ "get", nativeMapGet },
        .{ "has", nativeMapHas },
        .{ "delete", nativeMapDelete },
    };
    inline for (weakmap_fns) |pair| {
        const fn_v = try val_mod.makeNativeFunction(arena, pair[1]);
        try weakmap_proto.set(pair[0], fn_v);
    }
    const weakmap_ctor_obj = try JsObject.create(arena, null);
    try weakmap_ctor_obj.set("prototype", try val_mod.makeObject(arena, weakmap_proto));
    try weakmap_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeWeakMapCtor));
    try ctx.env.define("WeakMap", try val_mod.makeObject(arena, weakmap_ctor_obj));

    // ---- WeakSet ----
    const weakset_proto = try JsObject.create(arena, object_proto);
    const weakset_fns = .{
        .{ "add", nativeSetAdd },
        .{ "has", nativeSetHas },
        .{ "delete", nativeSetDelete },
    };
    inline for (weakset_fns) |pair| {
        const fn_v = try val_mod.makeNativeFunction(arena, pair[1]);
        try weakset_proto.set(pair[0], fn_v);
    }
    const weakset_ctor_obj = try JsObject.create(arena, null);
    try weakset_ctor_obj.set("prototype", try val_mod.makeObject(arena, weakset_proto));
    try weakset_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeWeakSetCtor));
    try ctx.env.define("WeakSet", try val_mod.makeObject(arena, weakset_ctor_obj));
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

pub fn nativeWeakMapCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, null, .weakmap);
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .weakmap;
    obj.internal_slot = d;
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

pub fn nativeWeakSetCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, null, .weakset);
    const obj = out.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_kind = .weakset;
    obj.internal_slot = d;
    return out;
}

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
        const ch = try arena.dupe(u8, s[d.index .. d.index + 1]);
        d.index += 1;
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
    if (d.index >= arr.getArrayLength()) {
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
