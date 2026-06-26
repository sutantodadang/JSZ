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
/// Map.prototype — stored so registerSymbols can wire @@toStringTag / @@iterator.
pub var active_map_proto: ?*JsObject = null;
/// Set.prototype — stored so registerSymbols can wire @@toStringTag / @@iterator.
pub var active_set_proto: ?*JsObject = null;
/// Map iterator prototype — stored for @@toStringTag wiring.
pub var active_map_iter_proto: ?*JsObject = null;
/// Set iterator prototype — stored for @@toStringTag wiring.
pub var active_set_iter_proto: ?*JsObject = null;

/// R1: install Map/Set/WeakMap/WeakSet prototypes + constructors and bind globals.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const object_proto = ctx.object_proto;

    // ---- Map ----
    const map_proto = try JsObject.create(arena, object_proto);
    const mm: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const mn: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try map_proto.defineOwnData("set", try val_mod.makeNativeFunctionNamed(arena, nativeMapSet, "set", 2), mm);
    _ = try map_proto.defineOwnData("get", try val_mod.makeNativeFunctionNamed(arena, nativeMapGet, "get", 1), mm);
    _ = try map_proto.defineOwnData("has", try val_mod.makeNativeFunctionNamed(arena, nativeMapHas, "has", 1), mm);
    _ = try map_proto.defineOwnData("delete", try val_mod.makeNativeFunctionNamed(arena, nativeMapDelete, "delete", 1), mm);
    _ = try map_proto.defineOwnData("clear", try val_mod.makeNativeFunctionNamed(arena, nativeMapClear, "clear", 0), mm);
    _ = try map_proto.defineOwnData("forEach", try val_mod.makeNativeFunctionNamed(arena, nativeMapForEach, "forEach", 1), mm);
    _ = try map_proto.defineOwnData("keys", try val_mod.makeNativeFunctionNamed(arena, nativeMapKeys, "keys", 0), mm);
    _ = try map_proto.defineOwnData("values", try val_mod.makeNativeFunctionNamed(arena, nativeMapValues, "values", 0), mm);
    _ = try map_proto.defineOwnData("entries", try val_mod.makeNativeFunctionNamed(arena, nativeMapEntries, "entries", 0), mm);
    // ES2025 upsert methods
    _ = try map_proto.defineOwnData("getOrInsert", try val_mod.makeNativeFunctionNamed(arena, nativeMapGetOrInsert, "getOrInsert", 2), mm);
    _ = try map_proto.defineOwnData("getOrInsertComputed", try val_mod.makeNativeFunctionNamed(arena, nativeMapGetOrInsertComputed, "getOrInsertComputed", 2), mm);
    // size as getter (non-enumerable, configurable per spec)
    try intrinsics.defineGetter(arena, map_proto, "size", nativeMapSize);
    active_map_proto = map_proto;

    // Map iterator prototype (built before makeMapIterator is called)
    const map_iter_proto = try JsObject.create(arena, null); // @@iterator chain wired in registerSymbols
    _ = try map_iter_proto.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeMapIteratorNext, "next", 0), mm);
    active_map_iter_proto = map_iter_proto;

    const map_ctor = try JsObject.create(arena, ctx.function_proto);
    _ = try map_ctor.defineOwnData("name", try val_mod.makeString(arena, "Map"), mn);
    _ = try map_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), mn);
    _ = try map_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, map_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    _ = try map_ctor.defineOwnData("groupBy", try val_mod.makeNativeFunctionNamed(arena, nativeMapGroupBy, "groupBy", 2), mm);
    try map_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeMapCtor));
    _ = try map_proto.defineOwnData("constructor", try val_mod.makeObject(arena, map_ctor), mm);
    try ctx.env.define("Map", try val_mod.makeObject(arena, map_ctor));

    // ---- Set ----
    const set_proto = try JsObject.create(arena, object_proto);
    const sm: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try set_proto.defineOwnData("add", try val_mod.makeNativeFunctionNamed(arena, nativeSetAdd, "add", 1), sm);
    _ = try set_proto.defineOwnData("has", try val_mod.makeNativeFunctionNamed(arena, nativeSetHas, "has", 1), sm);
    _ = try set_proto.defineOwnData("delete", try val_mod.makeNativeFunctionNamed(arena, nativeSetDelete, "delete", 1), sm);
    _ = try set_proto.defineOwnData("clear", try val_mod.makeNativeFunctionNamed(arena, nativeSetClear, "clear", 0), sm);
    _ = try set_proto.defineOwnData("forEach", try val_mod.makeNativeFunctionNamed(arena, nativeSetForEach, "forEach", 1), sm);
    const set_values_fn = try val_mod.makeNativeFunctionNamed(arena, nativeSetValues, "values", 0);
    _ = try set_proto.defineOwnData("values", set_values_fn, sm);
    _ = try set_proto.defineOwnData("keys", set_values_fn, sm); // keys === values per spec
    _ = try set_proto.defineOwnData("entries", try val_mod.makeNativeFunctionNamed(arena, nativeSetEntries, "entries", 0), sm);
    // New ES2025 Set methods
    _ = try set_proto.defineOwnData("union", try val_mod.makeNativeFunctionNamed(arena, nativeSetUnion, "union", 1), sm);
    _ = try set_proto.defineOwnData("intersection", try val_mod.makeNativeFunctionNamed(arena, nativeSetIntersection, "intersection", 1), sm);
    _ = try set_proto.defineOwnData("difference", try val_mod.makeNativeFunctionNamed(arena, nativeSetDifference, "difference", 1), sm);
    _ = try set_proto.defineOwnData("symmetricDifference", try val_mod.makeNativeFunctionNamed(arena, nativeSetSymmetricDifference, "symmetricDifference", 1), sm);
    _ = try set_proto.defineOwnData("isSubsetOf", try val_mod.makeNativeFunctionNamed(arena, nativeSetIsSubsetOf, "isSubsetOf", 1), sm);
    _ = try set_proto.defineOwnData("isSupersetOf", try val_mod.makeNativeFunctionNamed(arena, nativeSetIsSupersetOf, "isSupersetOf", 1), sm);
    _ = try set_proto.defineOwnData("isDisjointFrom", try val_mod.makeNativeFunctionNamed(arena, nativeSetIsDisjointFrom, "isDisjointFrom", 1), sm);
    // size as getter
    try intrinsics.defineGetter(arena, set_proto, "size", nativeSetSize);
    active_set_proto = set_proto;

    // Set iterator prototype
    const set_iter_proto = try JsObject.create(arena, null); // @@iterator chain wired in registerSymbols
    _ = try set_iter_proto.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeSetIteratorNext, "next", 0), sm);
    active_set_iter_proto = set_iter_proto;

    const sn: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    const set_ctor = try JsObject.create(arena, ctx.function_proto);
    _ = try set_ctor.defineOwnData("name", try val_mod.makeString(arena, "Set"), sn);
    _ = try set_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), sn);
    _ = try set_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, set_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try set_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeSetCtor));
    _ = try set_proto.defineOwnData("constructor", try val_mod.makeObject(arena, set_ctor), sm);
    try ctx.env.define("Set", try val_mod.makeObject(arena, set_ctor));

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

/// Wire @@toStringTag / @@iterator on Map/Set/WeakMap/WeakSet prototypes.
/// Called after Symbol well-known values are captured (same lifecycle as
/// typed_array_mod.registerSymbols).
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const tag_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    const iter_attr: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    if (realm_mod.active_sym_to_string_tag) |tag_sym| {
        if (active_weakmap_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakMap"), tag_attr);
        if (active_weakset_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakSet"), tag_attr);
        if (active_weakref_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "WeakRef"), tag_attr);
        if (active_finreg_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "FinalizationRegistry"), tag_attr);
        // Map/Set @@toStringTag
        if (active_map_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "Map"), tag_attr);
        if (active_set_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "Set"), tag_attr);
        // Map/Set iterator @@toStringTag
        if (active_map_iter_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "Map Iterator"), tag_attr);
        if (active_set_iter_proto) |p|
            try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "Set Iterator"), tag_attr);
    }
    // Wire @@iterator on Map/Set prototypes and iterator protos
    if (realm_mod.active_sym_iterator) |iter_sym| {
        // Build %IteratorPrototype%-based chain for Map/Set iterators
        const object_proto = realm_mod.active_object_proto;
        const iter_proto = try JsObject.create(arena, object_proto);
        try iter_proto.setSymAttr(iter_sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), iter_attr);

        if (active_map_iter_proto) |p| {
            p.proto = iter_proto;
            try p.setSymAttr(iter_sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), iter_attr);
        }
        if (active_set_iter_proto) |p| {
            p.proto = iter_proto;
            try p.setSymAttr(iter_sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), iter_attr);
        }
        // Map.prototype[@@iterator] = Map.prototype.entries
        if (active_map_proto) |p| {
            if (p.get("entries")) |entries_fn|
                try p.setSymAttr(iter_sym, entries_fn, iter_attr);
        }
        // Set.prototype[@@iterator] = Set.prototype.values
        if (active_set_proto) |p| {
            if (p.get("values")) |values_fn|
                try p.setSymAttr(iter_sym, values_fn, iter_attr);
        }
    }
}

pub const MapData = struct {
    keys: std.ArrayListUnmanaged(Value) = .empty,
    values: std.ArrayListUnmanaged(Value) = .empty,
};

pub const SetData = struct {
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

/// SameValueZero: like strict equality but NaN==NaN and -0==+0. Used for Map/Set keys.
fn sameValueZero(a: Value, b: Value) bool {
    if (a.bits == 0 and b.bits == 0) return true;
    if (a.bits == 0 or b.bits == 0) return false;
    const av = a.unbox();
    const bv = b.unbox();
    if (std.meta.activeTag(av) != std.meta.activeTag(bv)) return false;
    return switch (av) {
        .undefined_, .null_ => true,
        .boolean => |x| x == bv.boolean,
        .number => |x| blk: {
            const y = bv.number;
            // NaN == NaN (SameValueZero)
            if (std.math.isNan(x) and std.math.isNan(y)) break :blk true;
            // -0 == +0
            break :blk x == y;
        },
        .string => |x| std.mem.eql(u8, x, bv.string),
        else => a.bits == b.bits,
    };
}

fn getMapDataBranded(arena: std.mem.Allocator, this_val: Value) anyerror!*MapData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Map method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .map or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a Map)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn getSetDataBranded(arena: std.mem.Allocator, this_val: Value) anyerror!*SetData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Set method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .set or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a Set)");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
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
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Map constructor requires 'new'");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) {
        out = try makeObj(arena, active_map_proto, .map);
    }
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .map;
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
    if (!realm_mod.active_constructing) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Set constructor requires 'new'");
        return error.JsException;
    }
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, active_set_proto, .set);
    const obj = out.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_kind = .set;
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

// ---- Map methods (brand-checked: .map only, SameValueZero keys) ----

pub fn nativeMapSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    if (args.len < 2) {
        // set(key) with missing value is valid; value = undefined
        const key = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
        const val = try val_mod.makeUndefined(arena);
        for (data.keys.items, 0..) |k, i| {
            if (sameValueZero(k, key)) { data.values.items[i] = val; return this_val; }
        }
        try data.keys.append(arena, key);
        try data.values.append(arena, val);
        return this_val;
    }
    const key = args[0];
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, key)) { data.values.items[i] = args[1]; return this_val; }
    }
    try data.keys.append(arena, key);
    try data.values.append(arena, args[1]);
    return this_val;
}

pub fn nativeMapGet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    if (args.len == 0) return val_mod.makeUndefined(arena);
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, args[0])) return data.values.items[i];
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeMapHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items) |k| {
        if (sameValueZero(k, args[0])) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeMapDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, args[0])) {
            _ = data.keys.orderedRemove(i);
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeMapClear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    data.keys.clearRetainingCapacity();
    data.values.clearRetainingCapacity();
    return val_mod.makeUndefined(arena);
}

pub fn nativeMapSize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(data.keys.items.len));
}

pub fn nativeMapForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    if (args.len == 0 or !isCallable(args[0])) {
        try setTypeError(arena, "Map.prototype.forEach: callbackfn is not callable");
        unreachable;
    }
    const cb = args[0];
    const cb_this = if (args.len >= 2) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < data.keys.items.len) : (i += 1) {
        _ = try function_proto.invokeCallback(arena, cb_this, cb, &.{ data.values.items[i], data.keys.items[i], this_val });
    }
    return val_mod.makeUndefined(arena);
}

// ---- Map.prototype.getOrInsert / getOrInsertComputed (ES2025 upsert) ----

/// CanonicalizeKeyedCollectionKey: -0 → +0, everything else unchanged.
fn canonicalKey(arena: std.mem.Allocator, key: Value) !Value {
    if (key.bits != 0 and key.unbox() == .number) {
        const n = key.unbox().number;
        if (n == 0.0 and std.math.signbit(n)) {
            return val_mod.makeNumber(arena, 0.0);
        }
    }
    return key;
}

pub fn nativeMapGetOrInsert(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    const raw_key = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const value = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const key = try canonicalKey(arena, raw_key);
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, key)) return data.values.items[i];
    }
    try data.keys.append(arena, key);
    try data.values.append(arena, value);
    return value;
}

pub fn nativeMapGetOrInsertComputed(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getMapDataBranded(arena, this_val);
    const raw_key = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const cb = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (!isCallable(cb)) {
        try setTypeError(arena, "Map.prototype.getOrInsertComputed: callbackfn is not callable");
        unreachable;
    }
    const key = try canonicalKey(arena, raw_key);
    // Step 5: if key already present, return existing value (no callback).
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, key)) return data.values.items[i];
    }
    // Step 6: invoke callback.
    const value = try function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &.{key});
    // Step 7: re-scan — callback may have inserted key.
    for (data.keys.items, 0..) |k, i| {
        if (sameValueZero(k, key)) {
            data.values.items[i] = value;
            return value;
        }
    }
    // Step 8: not found — append.
    try data.keys.append(arena, key);
    try data.values.append(arena, value);
    return value;
}

// ---- Set methods (brand-checked: .set only, SameValueZero values) ----

pub fn nativeSetAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    if (args.len == 0) return this_val;
    const val = args[0];
    for (data.values.items) |v| if (sameValueZero(v, val)) return this_val;
    try data.values.append(arena, val);
    return this_val;
}

pub fn nativeSetHas(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items) |v| if (sameValueZero(v, args[0])) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, false);
}

pub fn nativeSetDelete(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    for (data.values.items, 0..) |v, i| {
        if (sameValueZero(v, args[0])) {
            _ = data.values.orderedRemove(i);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeSetClear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    data.values.clearRetainingCapacity();
    return val_mod.makeUndefined(arena);
}

pub fn nativeSetSize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(data.values.items.len));
}

pub fn nativeSetForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    if (args.len == 0 or !isCallable(args[0])) {
        try setTypeError(arena, "Set.prototype.forEach: callbackfn is not callable");
        unreachable;
    }
    const cb = args[0];
    const cb_this = if (args.len >= 2) args[1] else try val_mod.makeUndefined(arena);
    var i: usize = 0;
    while (i < data.values.items.len) : (i += 1) {
        _ = try function_proto.invokeCallback(arena, cb_this, cb, &.{ data.values.items[i], data.values.items[i], this_val });
    }
    return val_mod.makeUndefined(arena);
}

const MapIterKind = enum { keys, values, entries };

const MapIterData = struct {
    map: *MapData,
    index: usize = 0,
    kind: MapIterKind,
};

const SetIterKind = enum { values, entries };

const SetIterData = struct {
    set: *SetData,
    index: usize = 0,
    kind: SetIterKind = .values,
};

fn makeIteratorResult(arena: std.mem.Allocator, value: Value, done: bool) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    return val_mod.makeObject(arena, obj);
}

fn makeMapIterator(arena: std.mem.Allocator, data: *MapIterData) !Value {
    const proto = active_map_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = data;
    return val_mod.makeObject(arena, obj);
}

fn makeSetIterator(arena: std.mem.Allocator, data: *SetIterData) !Value {
    const proto = active_set_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = data;
    return val_mod.makeObject(arena, obj);
}

fn mapIteratorKind(arena: std.mem.Allocator, this_val: Value, kind: MapIterKind) !Value {
    const data = try getMapDataBranded(arena, this_val);
    const iter = try arena.create(MapIterData);
    iter.* = .{ .map = data, .index = 0, .kind = kind };
    return makeMapIterator(arena, iter);
}

pub fn nativeMapKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .keys);
}

pub fn nativeMapValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .values);
}

pub fn nativeMapEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return mapIteratorKind(arena, this_val, .entries);
}

pub fn nativeSetValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    const iter = try arena.create(SetIterData);
    iter.* = .{ .set = data, .index = 0, .kind = .values };
    return makeSetIterator(arena, iter);
}

pub fn nativeSetEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const data = try getSetDataBranded(arena, this_val);
    const iter = try arena.create(SetIterData);
    iter.* = .{ .set = data, .index = 0, .kind = .entries };
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
    const v = iter.set.values.items[iter.index];
    iter.index += 1;
    const result: Value = switch (iter.kind) {
        .values => v,
        .entries => blk: {
            const array_proto = realm_mod.active_array_proto;
            const pair = if (realm_mod.active_heap) |h|
                try JsObject.createArrayOnHeap(h, array_proto)
            else
                try JsObject.createArray(arena, array_proto);
            pair.set("0", v) catch return error.OutOfMemory;
            pair.set("1", v) catch return error.OutOfMemory;
            pair.array_length = 2;
            break :blk try val_mod.makeObject(arena, pair);
        },
    };
    return makeIteratorResult(arena, result, false);
}

// ---- GetSetRecord helper for new Set methods ----

const SetRecord = struct {
    obj: Value,
    has: Value,
    keys: Value,
    size: f64,
};

fn getSetRecord(arena: std.mem.Allocator, other: Value) anyerror!SetRecord {
    if (other.bits == 0 or other.unbox() != .object) {
        try setTypeError(arena, "argument must be a Set-like object");
        unreachable;
    }
    const o = other.toPtr().object;
    // Get size (observable) — spec §Set.prototype.union step 2: Get(obj, "size").
    // `size` is an accessor on Set/Map.prototype, so JsObject.get() returns null
    // (it skips accessors). We must invoke the getter explicitly.
    const sz: f64 = blk: {
        // Fast path: actual Map/Set — read live count directly.
        if (collectionSize(o)) |n| break :blk @floatFromInt(n);
        // Generic set-like: walk proto chain, invoke accessor getter if present.
        if (o.findProperty("size")) |loc| {
            const a = loc.holder.attrAt(loc.slot);
            const raw = if (loc.slot < loc.holder.slots.items.len)
                loc.holder.slots.items[loc.slot]
            else
                Value{};
            if (a.is_accessor) {
                // Holder object stores { get: fn, set: fn }.
                const getter = if (raw.bits != 0 and raw.unbox() == .object)
                    raw.toPtr().object.getOwn("get") orelse Value{}
                else
                    Value{};
                if (isCallable(getter)) {
                    const r = try function_proto.invokeCallback(arena, other, getter, &.{});
                    if (r.bits != 0) break :blk switch (r.unbox()) {
                        .number => |n| n,
                        .null_ => 0.0,
                        .boolean => |b| if (b) 1.0 else 0.0,
                        else => std.math.nan(f64),
                    };
                }
                break :blk std.math.nan(f64);
            } else {
                // Data property
                if (raw.bits != 0) break :blk switch (raw.unbox()) {
                    .number => |n| n,
                    .null_ => 0.0,
                    .boolean => |b| if (b) 1.0 else 0.0,
                    else => std.math.nan(f64),
                };
                break :blk std.math.nan(f64);
            }
        }
        break :blk std.math.nan(f64);
    };
    if (std.math.isNan(sz)) {
        try setTypeError(arena, "Set-like object must have a numeric size");
        unreachable;
    }
    // GetMethod "has"
    const has_v = o.get("has") orelse try val_mod.makeUndefined(arena);
    if (!isCallable(has_v)) {
        try setTypeError(arena, "Set-like object must have a callable has");
        unreachable;
    }
    // GetMethod "keys"
    const keys_v = o.get("keys") orelse try val_mod.makeUndefined(arena);
    if (!isCallable(keys_v)) {
        try setTypeError(arena, "Set-like object must have a callable keys");
        unreachable;
    }
    return .{ .obj = other, .has = has_v, .keys = keys_v, .size = sz };
}

/// Create a fresh Set pre-loaded with values from a SetData.
fn newSetFromData(arena: std.mem.Allocator, src: *SetData) !Value {
    const result = try makeObj(arena, active_set_proto, .set);
    const obj = result.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_slot = d;
    for (src.values.items) |v| try d.values.append(arena, v);
    return result;
}

// ---- ES2025 new Set methods ----

pub fn nativeSetUnion(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try newSetFromData(arena, this_data);
    const rd: *SetData = @ptrCast(@alignCast(result.toPtr().object.internal_slot.?));
    // Add other's keys if not already present
    const iter = try function_proto.invokeCallback(arena, rec.obj, rec.keys, &.{});
    while (true) {
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| { closeIterator(arena, iter); return e; };
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("done") orelse Value{} else Value{};
        if (isTruthy(done_v)) break;
        const next_val: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena) else try val_mod.makeUndefined(arena);
        var found = false;
        for (rd.values.items) |v| { if (sameValueZero(v, next_val)) { found = true; break; } }
        if (!found) try rd.values.append(arena, next_val);
    }
    return result;
}

pub fn nativeSetIntersection(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try makeObj(arena, active_set_proto, .set);
    const obj = result.toPtr().object;
    const rd = try arena.create(SetData);
    rd.* = .{};
    obj.internal_slot = rd;
    for (this_data.values.items) |v| {
        const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{v});
        if (isTruthy(has_r)) try rd.values.append(arena, v);
    }
    return result;
}

pub fn nativeSetDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try newSetFromData(arena, this_data);
    const rd: *SetData = @ptrCast(@alignCast(result.toPtr().object.internal_slot.?));
    // Remove values that appear in other
    var i: usize = 0;
    while (i < rd.values.items.len) {
        const v = rd.values.items[i];
        const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{v});
        if (isTruthy(has_r)) {
            _ = rd.values.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    return result;
}

pub fn nativeSetSymmetricDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try newSetFromData(arena, this_data);
    const rd: *SetData = @ptrCast(@alignCast(result.toPtr().object.internal_slot.?));
    // For each key in other: if in result remove, else add
    const iter = try function_proto.invokeCallback(arena, rec.obj, rec.keys, &.{});
    while (true) {
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| { closeIterator(arena, iter); return e; };
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("done") orelse Value{} else Value{};
        if (isTruthy(done_v)) break;
        const next_val: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena) else try val_mod.makeUndefined(arena);
        var found_idx: ?usize = null;
        for (rd.values.items, 0..) |v, idx| { if (sameValueZero(v, next_val)) { found_idx = idx; break; } }
        if (found_idx) |idx| {
            _ = rd.values.orderedRemove(idx);
        } else {
            try rd.values.append(arena, next_val);
        }
    }
    return result;
}

pub fn nativeSetIsSubsetOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    if (@as(f64, @floatFromInt(this_data.values.items.len)) > rec.size)
        return val_mod.makeBool(arena, false);
    for (this_data.values.items) |v| {
        const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{v});
        if (!isTruthy(has_r)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeSetIsSupersetOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    if (@as(f64, @floatFromInt(this_data.values.items.len)) < rec.size)
        return val_mod.makeBool(arena, false);
    const iter = try function_proto.invokeCallback(arena, rec.obj, rec.keys, &.{});
    while (true) {
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| { closeIterator(arena, iter); return e; };
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("done") orelse Value{} else Value{};
        if (isTruthy(done_v)) break;
        const next_val: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena) else try val_mod.makeUndefined(arena);
        var found = false;
        for (this_data.values.items) |v| { if (sameValueZero(v, next_val)) { found = true; break; } }
        if (!found) { closeIterator(arena, iter); return val_mod.makeBool(arena, false); }
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeSetIsDisjointFrom(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    for (this_data.values.items) |v| {
        const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{v});
        if (isTruthy(has_r)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

// ---- Map.groupBy and Object.groupBy ----

pub fn nativeMapGroupBy(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Map.groupBy(items, callbackfn)
    if (args.len < 2 or !isCallable(args[1])) {
        try setTypeError(arena, "Map.groupBy: callbackfn must be callable");
        unreachable;
    }
    const items = args[0];
    const cb = args[1];
    // Create result Map
    const result = try makeObj(arena, active_map_proto, .map);
    const robj = result.toPtr().object;
    const rd = try arena.create(MapData);
    rd.* = .{};
    robj.internal_slot = rd;
    // Iterate items
    const iter = try nativeGetIterator(arena, Value{}, &.{items});
    var k: usize = 0;
    while (true) {
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| { closeIterator(arena, iter); return e; };
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("done") orelse Value{} else Value{};
        if (isTruthy(done_v)) break;
        const item: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena) else try val_mod.makeUndefined(arena);
        const key_r = function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &.{ item, try val_mod.makeNumber(arena, @floatFromInt(k)) }) catch |e| { closeIterator(arena, iter); return e; };
        k += 1;
        // Find existing array for key using SameValueZero
        var found_idx: ?usize = null;
        for (rd.keys.items, 0..) |ek, idx| { if (sameValueZero(ek, key_r)) { found_idx = idx; break; } }
        if (found_idx) |idx| {
            // Append to existing array
            const arr_val = rd.values.items[idx];
            if (arr_val.bits != 0 and arr_val.unbox() == .object) {
                const arr = arr_val.toPtr().object;
                const len = arr.getArrayLength();
                var lbuf: [20]u8 = undefined;
                const ls = std.fmt.bufPrint(&lbuf, "{d}", .{len}) catch continue;
                arr.set(ls, item) catch {};
                arr.array_length = len + 1;
            }
        } else {
            const array_proto = realm_mod.active_array_proto;
            const arr = if (realm_mod.active_heap) |h| try JsObject.createArrayOnHeap(h, array_proto) else try JsObject.createArray(arena, array_proto);
            arr.set("0", item) catch {};
            arr.array_length = 1;
            try rd.keys.append(arena, key_r);
            try rd.values.append(arena, try val_mod.makeObject(arena, arr));
        }
    }
    return result;
}

pub fn nativeObjectGroupBy(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Object.groupBy(items, callbackfn)
    if (args.len < 2 or !isCallable(args[1])) {
        try setTypeError(arena, "Object.groupBy: callbackfn must be callable");
        unreachable;
    }
    const items = args[0];
    const cb = args[1];
    // Result is a null-proto object
    const result_obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    const result = try val_mod.makeObject(arena, result_obj);
    const iter = try nativeGetIterator(arena, Value{}, &.{items});
    var k: usize = 0;
    while (true) {
        const step = nativeIterStep(arena, Value{}, &.{iter}) catch |e| { closeIterator(arena, iter); return e; };
        const done_v: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("done") orelse Value{} else Value{};
        if (isTruthy(done_v)) break;
        const item: Value = if (step.bits != 0 and step.unbox() == .object) step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena) else try val_mod.makeUndefined(arena);
        const key_r = function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &.{ item, try val_mod.makeNumber(arena, @floatFromInt(k)) }) catch |e| { closeIterator(arena, iter); return e; };
        k += 1;
        // ToPropertyKey(key) — abrupt completion (throwing toString/valueOf) must
        // close the iterator and propagate (GroupBy step 6.g.ii).
        const key_str: []const u8 = toPropertyKeyString(arena, key_r) catch |e| {
            closeIterator(arena, iter);
            return e;
        };
        if (result_obj.get(key_str)) |existing| {
            if (existing.bits != 0 and existing.unbox() == .object) {
                const arr = existing.toPtr().object;
                const len = arr.getArrayLength();
                var lbuf: [20]u8 = undefined;
                const ls = std.fmt.bufPrint(&lbuf, "{d}", .{len}) catch continue;
                arr.set(ls, item) catch {};
                arr.array_length = len + 1;
            }
        } else {
            const array_proto = realm_mod.active_array_proto;
            const arr = if (realm_mod.active_heap) |h| try JsObject.createArrayOnHeap(h, array_proto) else try JsObject.createArray(arena, array_proto);
            arr.set("0", item) catch {};
            arr.array_length = 1;
            try result_obj.set(key_str, try val_mod.makeObject(arena, arr));
        }
    }
    return result;
}

// ---------------------------------------------------------- W2: generic iteration ---
// Used by the bytecode for-of loop. __getIterator__(x) returns an iterator object
// (one exposing next()); __iterStep__(it) calls it.next() and returns the result.

const function_proto = @import("function_proto.zig");
const string_proto = @import("string_proto.zig");
const coercion = @import("coercion.zig");

/// ToPropertyKey for Object.groupBy: coerce a callback result to a property-key
/// string. Objects go through ToPrimitive(string hint) — invoking
/// toString/valueOf — and any abrupt completion (throwing toString) propagates
/// as error.JsException (ES GroupBy step 6.g.ii). The resulting primitive is
/// then stringified exactly once. Returns the arena-owned key string.
fn toPropertyKeyString(arena: std.mem.Allocator, key_r: Value) anyerror![]const u8 {
    if (key_r.bits == 0) return "undefined";
    // Object: ToPrimitive with string hint (may throw, or yield a primitive).
    var prim = key_r;
    if (key_r.unbox() == .object) {
        if (try coercion.toPrimitive(arena, key_r, .string)) |p| {
            prim = p;
        } else {
            // No user conversion applies → default Object.prototype.toString.
            return "[object Object]";
        }
    }
    return switch (prim.unbox()) {
        .string => |s| s,
        .number => |n| if (n == @floor(n) and !std.math.isInf(n))
            try std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))})
        else
            try std.fmt.allocPrint(arena, "{d}", .{n}),
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        else => "undefined",
    };
}

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
