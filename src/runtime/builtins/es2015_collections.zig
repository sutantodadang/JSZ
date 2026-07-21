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
const Heap = @import("../../gc/heap.zig").Heap;
const InternalKind = @TypeOf((@as(JsObject, undefined)).internal_kind);

/// Shared %ArrayIteratorPrototype% — the [[Prototype]] of every iterator
/// returned by Array.prototype.{values,keys,entries}[@@iterator] AND
/// %TypedArray%.prototype.{values,keys,entries}[@@iterator]. Built once at realm
/// init (after the well-known symbols resolve). Its [[Prototype]] is the
/// %IteratorPrototype%.
pub var active_array_iter_proto: ?*JsObject = null;
pub var active_string_iter_proto: ?*JsObject = null;
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
/// Map/Set constructors — stored so registerSymbols can wire @@species getters.
pub var active_map_ctor: ?*JsObject = null;
pub var active_set_ctor: ?*JsObject = null;
/// Map iterator prototype — stored for @@toStringTag wiring.
pub var active_map_iter_proto: ?*JsObject = null;
/// Set iterator prototype — stored for @@toStringTag wiring.
pub var active_set_iter_proto: ?*JsObject = null;
/// %IteratorPrototype% — [[Prototype]] of every iterator protocol chain.
pub var active_iterator_proto: ?*JsObject = null;
/// %IteratorHelperPrototype% — [[Prototype]] of every lazy Iterator helper object.
pub var active_iterator_helper_proto: ?*JsObject = null;
pub var active_iterator_ctor: ?*JsObject = null;
/// %WrapForValidIteratorPrototype% — [[Prototype]] of Iterator.from wrappers.
pub var active_wrap_iter_proto: ?*JsObject = null;

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
    active_map_ctor = map_ctor;
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
    active_set_ctor = set_ctor;
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
    // @@species: an accessor getter on the Map/Set constructors returning `this`.
    if (realm_mod.active_sym_species) |spec_sym| {
        if (active_map_ctor) |c|
            try defineSymGetter(arena, c, spec_sym, nativeSpeciesReturnThis, "get [Symbol.species]");
        if (active_set_ctor) |c|
            try defineSymGetter(arena, c, spec_sym, nativeSpeciesReturnThis, "get [Symbol.species]");
    }
    // Wire @@iterator on Map/Set prototypes and iterator protos
    if (realm_mod.active_sym_iterator) |iter_sym| {
        // Build %IteratorPrototype%-based chain for Map/Set iterators
        const object_proto = realm_mod.active_object_proto;
        const iter_proto = try JsObject.create(arena, object_proto);
        try iter_proto.setSymAttr(iter_sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), iter_attr);

        if (active_map_iter_proto) |p| {
            p.proto = iter_proto;
            p.setProtoBarrier(iter_proto);
            try p.setSymAttr(iter_sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), iter_attr);
        }
        if (active_set_iter_proto) |p| {
            p.proto = iter_proto;
            p.setProtoBarrier(iter_proto);
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

/// get [Symbol.species] — returns the `this` value (the constructor itself).
fn nativeSpeciesReturnThis(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = arena;
    return this_val;
}

/// Install a getter-only accessor under a symbol key on `obj`.
fn defineSymGetter(arena: std.mem.Allocator, obj: *JsObject, sym_key: Value, getter: val_mod.NativeFnPtr, name: []const u8) !void {
    const holder = try JsObject.create(arena, null);
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, name, 0));
    try obj.setSymAttr(sym_key, try val_mod.makeObject(arena, holder), .{ .writable = false, .enumerable = false, .configurable = true, .is_accessor = true });
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
    registerCollection(obj, kind);
    return val_mod.makeObject(arena, obj);
}

/// Register a collection object with the GC so it is traced/weak-processed even
/// after tenuring. Idempotent (dedups via the header). No-op for non-collections.
fn registerCollection(obj: *JsObject, kind: InternalKind) void {
    switch (kind) {
        .map, .set, .weakmap, .weakset, .weakref, .finalization_registry => {
            if (realm_mod.active_heap) |h| h.noteWeakContainer(obj);
        },
        else => {},
    }
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
    registerCollection(obj, .map);
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
    registerCollection(obj, .weakmap);
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
    registerCollection(obj, .set);
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
    registerCollection(obj, .weakset);
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
    return val_mod.toBoolean(v);
}

fn setTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror!void {
    realm_mod.pending_exception = try makeTypeErrorVal(arena, msg);
    return error.JsException;
}

fn closeIterator(arena: std.mem.Allocator, iter: Value) void {
    if (iter.bits == 0 or iter.unbox() != .object) return;
    const ret_fn = iter.toPtr().object.get("return") orelse return;
    if (!isCallable(ret_fn)) return;
    // IteratorClose after an abrupt completion: if return() itself throws, that
    // throw is discarded and the ORIGINAL pending exception propagates (spec
    // 7.4.11 step 5). Preserve pending_exception across the return() call.
    const saved = realm_mod.pending_exception;
    _ = function_proto.invokeCallback(arena, iter, ret_fn, &[_]Value{}) catch {};
    realm_mod.pending_exception = saved;
}

/// IteratorClose(iter, NormalCompletion) for the helper's own `.return()` method.
/// GetMethod(iter, "return") observably (invokes a `return` getter and traverses
/// the prototype chain via jsGet), and — unlike closeIterator's abrupt path —
/// propagates any throw from the getter or the return() call to the caller.
fn iteratorCloseThrowing(arena: std.mem.Allocator, iter: Value) anyerror!void {
    if (iter.bits == 0 or iter.unbox() != .object) return;
    const ret_fn = try jsGet(arena, iter, "return");
    if (ret_fn.bits == 0 or ret_fn.unbox() == .undefined_ or ret_fn.unbox() == .null_) return;
    if (!isCallable(ret_fn)) {
        try setTypeError(arena, "iterator return is not callable");
        unreachable;
    }
    _ = try function_proto.invokeCallback(arena, iter, ret_fn, &[_]Value{});
}

/// JS [[Get]] (runs accessors, proxy traps, traverses the prototype chain),
/// falling back to the internal own-property get if there is no active context.
fn jsGet(arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value {
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, obj_val, key);
    if (obj_val.bits != 0 and obj_val.unbox() == .object)
        return obj_val.toPtr().object.get(key) orelse val_mod.makeUndefined(arena);
    return val_mod.makeUndefined(arena);
}

/// Require that an Iterator-helper receiver is an Object (the first step of every
/// %Iterator.prototype% method, checked before argument validation).
fn requireObjectIter(arena: std.mem.Allocator, this_val: Value) anyerror!void {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Iterator method called on non-object");
        unreachable;
    }
}

/// GetIteratorDirect(obj) (ES 7.4.10): require an Object, then read its `next`
/// method via [[Get]] (getters run, exceptions propagate). No IsCallable check —
/// per spec that happens lazily when `next` is invoked.
fn getIteratorDirect(arena: std.mem.Allocator, this_val: Value) anyerror!SourceIter {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Iterator method called on non-object");
        unreachable;
    }
    const next_fn = try jsGet(arena, this_val, "next");
    return SourceIter{ .source = this_val, .next_fn = next_fn };
}

/// One step of an iterator: Call(next), require an Object result (else TypeError),
/// then read `done`/`value` via [[Get]]. Returns null when the iterator is done.
fn iterStep(arena: std.mem.Allocator, source: Value, next_fn: Value) anyerror!?Value {
    const result = try function_proto.invokeCallback(arena, source, next_fn, &[_]Value{});
    if (result.bits == 0 or result.unbox() != .object) {
        try setTypeError(arena, "iterator result is not an object");
        unreachable;
    }
    const done_v = try jsGet(arena, result, "done");
    if (isTruthy(done_v)) return null;
    return try jsGet(arena, result, "value");
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
    registerCollection(obj, .weakref);
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
    registerCollection(obj, .finalization_registry);
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

// ---- GC integration (M19) -------------------------------------------------

/// GC mark hook: trace the STRONG internal contents of a marked collection.
/// Ordinary Map/Set keep their keys and values alive (their entries live in an
/// arena-side struct the collector cannot see by walking object slots). Weak
/// containers are deliberately NOT traced here — their reachability is decided
/// by gcProcessWeak after marking. Registered as Heap.strong_trace_fn.
pub fn gcStrongTrace(heap: *Heap, obj: *JsObject) void {
    switch (obj.internal_kind) {
        .map => {
            const d: *MapData = @ptrCast(@alignCast(obj.internal_slot orelse return));
            for (d.keys.items) |k| heap.markValueLive(k);
            for (d.values.items) |v| heap.markValueLive(v);
        },
        .set => {
            const d: *SetData = @ptrCast(@alignCast(obj.internal_slot orelse return));
            for (d.values.items) |v| heap.markValueLive(v);
        },
        .array_iterator => {
            // Keep the array/string being iterated alive for the iterator's
            // lifetime — otherwise a collection mid-`for...of` frees it.
            const d: *SeqIterData = @ptrCast(@alignCast(obj.internal_slot orelse return));
            heap.markValueLive(d.seq);
        },
        .iterator_helper => {
            // Keep the source iterator, cached next method, user callback, and
            // any active inner iterator (flatMap) alive for the helper's lifetime.
            const d: *IterHelperData = @ptrCast(@alignCast(obj.internal_slot orelse return));
            heap.markValueLive(d.source);
            heap.markValueLive(d.next_fn);
            heap.markValueLive(d.callback);
            heap.markValueLive(d.inner_iter);
            heap.markValueLive(d.inner_next_fn);
            // Iterator.concat: keep the captured iterables and their @@iterator
            // methods alive until each is opened and drained. Iterator.zip
            // additionally keeps its padding values and (zipKeyed) result keys.
            for (d.items) |v| heap.markValueLive(v);
            for (d.item_methods) |v| heap.markValueLive(v);
            for (d.padding) |v| heap.markValueLive(v);
            for (d.keys) |v| heap.markValueLive(v);
        },
        .disposable_stack, .async_disposable_stack => {
            @import("disposable_stack.zig").gcTrace(heap, obj);
        },
        else => {},
    }
}

/// GC weak hook: after marking, run ephemeron marking then purge dead weak
/// entries / clear dead WeakRef targets. Registered as Heap.weak_process_fn.
///
/// Ephemeron semantics: a WeakMap value is reachable iff its key is reachable.
/// Marking a value can make further keys reachable, so iterate to a fixpoint.
/// FinalizationRegistry: dead cells are dropped (cleanup callbacks are not yet
/// scheduled — that needs a host job queue and is a separate follow-up).
pub fn gcProcessWeak(heap: *Heap) void {
    while (true) {
        var changed = false;
        var i: usize = 0;
        while (i < heap.weakList().len) : (i += 1) {
            const obj = heap.weakList()[i];
            if (obj.internal_kind != .weakmap) continue;
            const d: *MapData = @ptrCast(@alignCast(obj.internal_slot orelse continue));
            for (d.keys.items, d.values.items) |k, v| {
                if (heap.isValueLive(k) and !heap.isValueLive(v)) {
                    heap.markValueLive(v);
                    changed = true;
                }
            }
        }
        if (!changed) break;
        heap.drainWeak(); // propagate; may append newly-live weak containers
    }

    for (heap.weakList()) |obj| {
        switch (obj.internal_kind) {
            .weakref => {
                const d: *WeakRefData = @ptrCast(@alignCast(obj.internal_slot orelse continue));
                if (d.target.bits != 0 and !heap.isValueLive(d.target)) d.target = Value{};
            },
            .weakmap => {
                const d: *MapData = @ptrCast(@alignCast(obj.internal_slot orelse continue));
                var i: usize = 0;
                while (i < d.keys.items.len) {
                    if (!heap.isValueLive(d.keys.items[i])) {
                        _ = d.keys.swapRemove(i);
                        _ = d.values.swapRemove(i);
                    } else i += 1;
                }
            },
            .weakset => {
                const d: *SetData = @ptrCast(@alignCast(obj.internal_slot orelse continue));
                var i: usize = 0;
                while (i < d.values.items.len) {
                    if (!heap.isValueLive(d.values.items[i])) {
                        _ = d.values.swapRemove(i);
                    } else i += 1;
                }
            },
            .finalization_registry => {
                const d: *FinRegData = @ptrCast(@alignCast(obj.internal_slot orelse continue));
                var i: usize = 0;
                while (i < d.cells.items.len) {
                    if (!heap.isValueLive(d.cells.items[i].target)) {
                        _ = d.cells.swapRemove(i);
                    } else i += 1;
                }
            },
            else => {},
        }
    }
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
    // add() with no argument adds `undefined` (spec: value defaults to undefined).
    const val = try canonKey(arena, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
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
    /// Once the iterator returns done=true, it is permanently exhausted: the
    /// [[Map]] slot is conceptually released, so entries added afterwards are
    /// NOT visible (test262 MapIteratorPrototype/next/iteration-mutable).
    done: bool = false,
};

const SetIterKind = enum { values, entries };

const SetIterData = struct {
    set: *SetData,
    index: usize = 0,
    kind: SetIterKind = .values,
    /// See MapIterData.done — permanent exhaustion latch.
    done: bool = false,
};

fn makeIteratorResult(arena: std.mem.Allocator, value: Value, done: bool) !Value {
    // CreateIterResultObject (ES §7.4.14): OrdinaryObjectCreate(%Object.prototype%)
    // with own enumerable "value" then "done".
    const proto = realm_mod.active_object_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    return val_mod.makeObject(arena, obj);
}

fn makeMapIterator(arena: std.mem.Allocator, data: *MapIterData) !Value {
    const proto = active_map_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = data;
    obj.internal_kind = .map_iterator;
    return val_mod.makeObject(arena, obj);
}

fn makeSetIterator(arena: std.mem.Allocator, data: *SetIterData) !Value {
    const proto = active_set_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = data;
    obj.internal_kind = .set_iterator;
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
    // Step 2: if Type(O) is not Object, throw a TypeError (spec 24.1.5.2.1).
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Map Iterator next called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    // Brand check: %MapIteratorPrototype%.next on a non-iterator receiver (e.g. a
    // Map) must throw TypeError, NOT @ptrCast the wrong internal_slot (type
    // confusion → segfault).
    if (obj.internal_kind != .map_iterator or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a Map Iterator)");
        unreachable;
    }
    const iter: *MapIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (iter.done or iter.index >= iter.map.keys.items.len) {
        iter.done = true; // latch: post-exhaustion insertions stay invisible
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
    // Step 2: if Type(O) is not Object, throw a TypeError (spec 24.2.5.2.1).
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Set Iterator next called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    // Brand check (see nativeMapIteratorNext): non-iterator receiver → TypeError,
    // never a wrong-type @ptrCast.
    if (obj.internal_kind != .set_iterator or obj.internal_slot == null) {
        try setTypeError(arena, "Method called on incompatible receiver (not a Set Iterator)");
        unreachable;
    }
    const iter: *SetIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (iter.done or iter.index >= iter.set.values.items.len) {
        iter.done = true; // latch: post-exhaustion insertions stay invisible
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
    // Step 1: obj must be an Object.
    if (other.bits == 0 or other.unbox() != .object) {
        try setTypeError(arena, "argument must be a Set-like object");
        unreachable;
    }
    const ctx = realm_mod.active_context orelse {
        try setTypeError(arena, "no active context");
        unreachable;
    };
    // Step 2: rawSize = Get(obj, "size"). Observable — invokes accessor getters
    // and walks the prototype chain (class-based set-likes define `size` as a
    // getter, which JsObject.get() would skip).
    const raw_size = try ctx.getProp(arena, other, "size");
    // Step 3: numSize = ToNumber(rawSize). rawSize may be an object with valueOf.
    const num_size = try realm_mod.toNumberValue(arena, raw_size);
    // Step 5: numSize is NaN → TypeError (also covers rawSize === undefined).
    if (std.math.isNan(num_size)) {
        try setTypeError(arena, "Set-like object must have a numeric size");
        unreachable;
    }
    // Step 6: intSize = ToIntegerOrInfinity(numSize) (truncate toward zero).
    const int_size = if (std.math.isInf(num_size)) num_size else std.math.trunc(num_size);
    // Step 7: intSize < 0 → RangeError.
    if (int_size < 0) return realm_mod.throwRangeError(arena, "Set-like object size must be non-negative");
    // Step 8: has = Get(obj, "has"); must be callable.
    const has_v = try ctx.getProp(arena, other, "has");
    if (!isCallable(has_v)) {
        try setTypeError(arena, "Set-like object must have a callable has");
        unreachable;
    }
    // Step 10: keys = Get(obj, "keys"); must be callable.
    const keys_v = try ctx.getProp(arena, other, "keys");
    if (!isCallable(keys_v)) {
        try setTypeError(arena, "Set-like object must have a callable keys");
        unreachable;
    }
    return .{ .obj = other, .has = has_v, .keys = keys_v, .size = int_size };
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

/// CanonicalizeKeyedCollectionKey: normalize -0 → +0 for the value actually
/// stored/returned. SameValueZero already treats -0 and +0 as equal for lookup;
/// this makes iteration output canonical (+0) as the spec requires.
fn canonKey(arena: std.mem.Allocator, v: Value) !Value {
    if (v.bits != 0 and v.unbox() == .number) {
        const n = v.unbox().number;
        if (n == 0 and std.math.signbit(n)) return val_mod.makeNumber(arena, 0);
    }
    return v;
}

/// SetDataHas: SameValueZero membership test against a SetData's live values.
fn setDataHas(d: *SetData, v: Value) bool {
    for (d.values.items) |x| if (sameValueZero(x, v)) return true;
    return false;
}

/// Remove the first SameValueZero match of `v` from a SetData (no-op if absent).
fn setDataRemove(d: *SetData, v: Value) void {
    var j: usize = 0;
    while (j < d.values.items.len) {
        if (sameValueZero(d.values.items[j], v)) {
            _ = d.values.orderedRemove(j);
            return;
        }
        j += 1;
    }
}

/// A keys() iterator with its `next` method cached once (GetIteratorDirect):
/// per spec the `next` property is read a single time at iterator acquisition,
/// then invoked on each step.
const KeysIter = struct { iter: Value, next_fn: Value };

/// GetKeysIterator: Call(rec.[[Keys]], rec.[[SetObject]]) then cache its `next`.
/// Both the keys() call and the `next` read are observable (getters / traps).
fn openKeysIterator(arena: std.mem.Allocator, rec: SetRecord) !KeysIter {
    const iter = try function_proto.invokeCallback(arena, rec.obj, rec.keys, &.{});
    if (iter.bits == 0 or iter.unbox() != .object) {
        try setTypeError(arena, "keys() did not return an object");
        unreachable;
    }
    const next_fn = try readPropObs(arena, iter, "next");
    if (!isCallable(next_fn)) {
        try setTypeError(arena, "keys() iterator has no callable next");
        unreachable;
    }
    return .{ .iter = iter, .next_fn = next_fn };
}

/// One IteratorStepValue on `ki`, reading `done`/`value` observably (fires
/// getters / Proxy traps), returning the canonicalized value or null when done.
/// Closes the iterator on an abrupt completion.
fn keysStep(arena: std.mem.Allocator, ki: KeysIter) !?Value {
    const step = function_proto.invokeCallback(arena, ki.iter, ki.next_fn, &.{}) catch |e| {
        closeIterator(arena, ki.iter);
        return e;
    };
    const done_v = readPropObs(arena, step, "done") catch |e| {
        closeIterator(arena, ki.iter);
        return e;
    };
    if (isTruthy(done_v)) return null;
    const val = readPropObs(arena, step, "value") catch |e| {
        closeIterator(arena, ki.iter);
        return e;
    };
    return try canonKey(arena, val);
}

/// Observable property read (fires accessor getters / Proxy traps) with a
/// non-observable fallback when no VM context is active.
fn readPropObs(arena: std.mem.Allocator, obj: Value, key: []const u8) !Value {
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, obj, key);
    if (obj.bits != 0 and obj.unbox() == .object) return obj.toPtr().object.get(key) orelse val_mod.makeUndefined(arena);
    return val_mod.makeUndefined(arena);
}

pub fn nativeSetUnion(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try newSetFromData(arena, this_data);
    const rd: *SetData = @ptrCast(@alignCast(result.toPtr().object.internal_slot.?));
    // Add other's keys (canonicalized) if not already present.
    const iter = try openKeysIterator(arena, rec);
    while (try keysStep(arena, iter)) |val| {
        if (!setDataHas(rd, val)) try rd.values.append(arena, val);
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
    // Iterate the smaller side: when |this| ≤ |other| walk this and test via
    // other.has (result follows this order); otherwise walk other.keys() and
    // test membership in this (result follows other order, no has calls).
    if (@as(f64, @floatFromInt(this_data.values.items.len)) <= rec.size) {
        var i: usize = 0;
        while (i < this_data.values.items.len) : (i += 1) {
            const e = this_data.values.items[i]; // live re-read: `has` may mutate this
            const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{e});
            if (isTruthy(has_r) and !setDataHas(rd, e)) try rd.values.append(arena, e);
        }
    } else {
        const iter = try openKeysIterator(arena, rec);
        while (try keysStep(arena, iter)) |val| {
            if (setDataHas(this_data, val) and !setDataHas(rd, val)) try rd.values.append(arena, val);
        }
    }
    return result;
}

pub fn nativeSetDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    const result = try newSetFromData(arena, this_data);
    const rd: *SetData = @ptrCast(@alignCast(result.toPtr().object.internal_slot.?));
    // When |this| ≤ |other|, walk this and probe other.has; otherwise walk
    // other.keys() (avoids calling has entirely — a spec-observable difference).
    if (@as(f64, @floatFromInt(this_data.values.items.len)) <= rec.size) {
        var i: usize = 0;
        while (i < this_data.values.items.len) : (i += 1) {
            const e = this_data.values.items[i];
            const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{e});
            if (isTruthy(has_r)) setDataRemove(rd, e);
        }
    } else {
        const iter = try openKeysIterator(arena, rec);
        while (try keysStep(arena, iter)) |val| {
            if (setDataHas(rd, val)) setDataRemove(rd, val);
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
    // For each key in other: toggle relative to the ORIGINAL this membership.
    const iter = try openKeysIterator(arena, rec);
    while (try keysStep(arena, iter)) |val| {
        const in_result = setDataHas(rd, val);
        if (setDataHas(this_data, val)) {
            if (in_result) setDataRemove(rd, val);
        } else {
            if (!in_result) try rd.values.append(arena, val);
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
    // Walk this by live index (has may mutate this) and probe other.has.
    var i: usize = 0;
    while (i < this_data.values.items.len) : (i += 1) {
        const e = this_data.values.items[i];
        const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{e});
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
    const iter = try openKeysIterator(arena, rec);
    while (try keysStep(arena, iter)) |val| {
        if (!setDataHas(this_data, val)) {
            closeIterator(arena, iter.iter);
            return val_mod.makeBool(arena, false);
        }
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeSetIsDisjointFrom(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const this_data = try getSetDataBranded(arena, this_val);
    const other = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const rec = try getSetRecord(arena, other);
    // When |this| ≤ |other|, probe other.has for each element of this;
    // otherwise walk other.keys() and test membership in this.
    if (@as(f64, @floatFromInt(this_data.values.items.len)) <= rec.size) {
        var i: usize = 0;
        while (i < this_data.values.items.len) : (i += 1) {
            const e = this_data.values.items[i];
            const has_r = try function_proto.invokeCallback(arena, rec.obj, rec.has, &.{e});
            if (isTruthy(has_r)) return val_mod.makeBool(arena, false);
        }
    } else {
        const iter = try openKeysIterator(arena, rec);
        while (try keysStep(arena, iter)) |val| {
            if (setDataHas(this_data, val)) {
                closeIterator(arena, iter.iter);
                return val_mod.makeBool(arena, false);
            }
        }
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

/// Kind discriminant for lazy Iterator Helper objects.
pub const IterHelperKind = enum { map, filter, take, drop, flatMap, wrap, concat, zip, zipKeyed };

/// Per-instance state for a lazy Iterator Helper (map/filter/take/drop/flatMap).
/// Heap-allocated and referenced via JsObject.internal_slot.
/// gcStrongTrace must trace all Value fields to prevent UAF on GC collection.
pub const IterHelperData = struct {
    source: Value,        // the upstream iterator
    next_fn: Value,       // cached source.next method (avoids repeated get)
    callback: Value,      // user callback (map / filter / flatMap); Value{} otherwise
    counter: u64 = 0,     // iteration counter (passed to callbacks); drop: skip count
    limit: i64 = 0,       // take: remaining; drop: total to skip
    done: bool = false,
    running: bool = false, // re-entrancy guard (spec: "generator is running")
    kind: IterHelperKind,
    inner_iter: Value,    // flatMap/concat: active inner iterator (Value{} = none)
    inner_next_fn: Value, // flatMap/concat: cached inner.next (Value{} = none)
    // Iterator.concat: the iterable arguments and their @@iterator methods,
    // fetched once up front; `counter` is the index of the next one to open.
    // Iterator.zip/zipKeyed reuse `items` for the open iterators and
    // `item_methods` for their cached `next` methods.
    items: []Value = &.{},
    item_methods: []Value = &.{},
    // Iterator.zip/zipKeyed state.
    zip_mode: u8 = 0, // 0=shortest, 1=longest, 2=strict
    padding: []Value = &.{}, // longest mode: per-iterator pad value (undefined past end)
    done_flags: []bool = &.{}, // per-iterator exhausted flag (longest mode)
    keys: []Value = &.{}, // zipKeyed: property keys for the result objects
};

/// Iterator record: the source iterator and its cached `next` method
/// (GetIteratorDirect result).
const SourceIter = struct { source: Value, next_fn: Value };

/// Wrap an IterHelperData into a branded object whose [[Prototype]] is
/// %IteratorHelperPrototype%. GC will trace the data fields via gcStrongTrace.
fn makeIteratorHelper(arena: std.mem.Allocator, d: *IterHelperData) !Value {
    const proto = active_iterator_helper_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = d;
    obj.internal_kind = .iterator_helper;
    return val_mod.makeObject(arena, obj);
}

/// Get the IterHelperData from an iterator helper `this`. Throws TypeError on
/// wrong receiver (brand check).
fn getIterHelperData(arena: std.mem.Allocator, this_val: Value) anyerror!*IterHelperData {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Iterator Helper method called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .iterator_helper or obj.internal_slot == null) {
        try setTypeError(arena, "Iterator Helper method called on wrong type");
        unreachable;
    }
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// %IteratorPrototype%[@@iterator] and %ArrayIteratorPrototype% reuse: return
/// the `this` iterator itself.
fn nativeIterSelf(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

/// Getter for %IteratorPrototype%.constructor — returns %Iterator%.
fn nativeIterCtorGet(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    if (active_iterator_ctor) |c| return val_mod.makeObject(arena, c);
    return val_mod.makeUndefined(arena);
}

/// Getter for %IteratorPrototype%[@@toStringTag] — returns "Iterator".
fn nativeIterTagGet(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return val_mod.makeString(arena, "Iterator");
}

/// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, p, v): a
/// shared accessor setter that lets subclasses install their own `constructor`
/// / @@toStringTag but forbids mutating the shared %Iterator.prototype%.
fn iterProtoIgnoringSetter(arena: std.mem.Allocator, this_val: Value, v: Value, is_tag: bool) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        try setTypeError(arena, "Iterator.prototype setter called on non-object");
        unreachable;
    }
    const obj = this_val.toPtr().object;
    if (active_iterator_proto) |home| {
        if (obj == home) {
            try setTypeError(arena, "Cannot assign to read-only property of %Iterator.prototype%");
            unreachable;
        }
    }
    const all: PropAttr = .{ .writable = true, .enumerable = true, .configurable = true };
    if (is_tag) {
        const sym = realm_mod.active_sym_to_string_tag orelse return val_mod.makeUndefined(arena);
        if (obj.hasOwnSym(sym)) {
            try obj.setSym(sym, v);
        } else {
            if (!obj.extensible) {
                try setTypeError(arena, "Cannot define property on non-extensible object");
                unreachable;
            }
            _ = try obj.defineOwnDataSym(sym, v, all);
        }
    } else {
        if (obj.hasOwn("constructor")) {
            try obj.set("constructor", v);
        } else {
            if (!obj.extensible) {
                try setTypeError(arena, "Cannot define property on non-extensible object");
                unreachable;
            }
            _ = try obj.defineOwnData("constructor", v, all);
        }
    }
    return val_mod.makeUndefined(arena);
}

fn nativeIterCtorSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return iterProtoIgnoringSetter(arena, this_val, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena), false);
}

fn nativeIterTagSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return iterProtoIgnoringSetter(arena, this_val, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena), true);
}

/// Define a get/set accessor pair (string key) on `obj`.
fn defineAccessorPair(arena: std.mem.Allocator, obj: *JsObject, key: []const u8, getter: val_mod.NativeFnPtr, setter: val_mod.NativeFnPtr) !void {
    const holder = try JsObject.create(arena, null);
    const gname = try std.fmt.allocPrint(arena, "get {s}", .{key});
    const sname = try std.fmt.allocPrint(arena, "set {s}", .{key});
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, gname, 0));
    try holder.set("set", try val_mod.makeNativeFunctionNamed(arena, setter, sname, 1));
    _ = try obj.defineOwnAccessor(key, try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
}

/// Define a get/set accessor pair (symbol key) on `obj`.
fn defineAccessorPairSym(arena: std.mem.Allocator, obj: *JsObject, sym: Value, getter: val_mod.NativeFnPtr, setter: val_mod.NativeFnPtr, name: []const u8) !void {
    const holder = try JsObject.create(arena, null);
    const gname = try std.fmt.allocPrint(arena, "get {s}", .{name});
    const sname = try std.fmt.allocPrint(arena, "set {s}", .{name});
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, gname, 0));
    try holder.set("set", try val_mod.makeNativeFunctionNamed(arena, setter, sname, 1));
    _ = try obj.defineOwnAccessorSym(sym, try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
}

/// %IteratorPrototype%[@@dispose] (ES2025 explicit resource management): call the
/// iterator's `return` method (if any) and return undefined.
fn nativeIterDispose(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ret_fn = try jsGet(arena, this_val, "return");
    if (!(ret_fn.bits == 0 or ret_fn.unbox() == .undefined_ or ret_fn.unbox() == .null_)) {
        _ = try function_proto.invokeCallback(arena, this_val, ret_fn, &[_]Value{});
    }
    return try val_mod.makeUndefined(arena);
}

/// Build the shared %IteratorPrototype% → %ArrayIteratorPrototype% chain, attach
/// all ES2024 Iterator Helper methods, and build %IteratorHelperPrototype%.
/// Call once at realm init, after @@iterator / @@toStringTag are resolved.
pub fn initArrayIteratorProto(arena: std.mem.Allocator, object_proto: *JsObject) !void {
    const cfg: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const tag_cfg: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };

    // %IteratorPrototype%: { [@@iterator]() { return this }, [@@toStringTag]: "Iterator", … }
    const iter_proto = try JsObject.create(arena, object_proto);
    if (realm_mod.active_sym_iterator) |sym|
        try iter_proto.setSymAttr(sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterSelf, "[Symbol.iterator]", 0), cfg);
    // @@toStringTag is an accessor pair (get "Iterator", weird setter) — same
    // anti-monkey-patching rationale as `constructor`.
    if (realm_mod.active_sym_to_string_tag) |tag|
        try defineAccessorPairSym(arena, iter_proto, tag, nativeIterTagGet, nativeIterTagSet, "[Symbol.toStringTag]");

    // ES2024 Iterator Helper methods — all live on %IteratorPrototype%.
    _ = try iter_proto.defineOwnData("map",     try val_mod.makeNativeFunctionNamed(arena, nativeIterMap,     "map",     1), cfg);
    _ = try iter_proto.defineOwnData("filter",  try val_mod.makeNativeFunctionNamed(arena, nativeIterFilter,  "filter",  1), cfg);
    _ = try iter_proto.defineOwnData("take",    try val_mod.makeNativeFunctionNamed(arena, nativeIterTake,    "take",    1), cfg);
    _ = try iter_proto.defineOwnData("drop",    try val_mod.makeNativeFunctionNamed(arena, nativeIterDrop,    "drop",    1), cfg);
    _ = try iter_proto.defineOwnData("flatMap", try val_mod.makeNativeFunctionNamed(arena, nativeIterFlatMap, "flatMap", 1), cfg);
    _ = try iter_proto.defineOwnData("reduce",  try val_mod.makeNativeFunctionNamed(arena, nativeIterReduce,  "reduce",  1), cfg);
    _ = try iter_proto.defineOwnData("toArray", try val_mod.makeNativeFunctionNamed(arena, nativeIterToArray, "toArray", 0), cfg);
    _ = try iter_proto.defineOwnData("forEach", try val_mod.makeNativeFunctionNamed(arena, nativeIterForEach, "forEach", 1), cfg);
    _ = try iter_proto.defineOwnData("some",    try val_mod.makeNativeFunctionNamed(arena, nativeIterSome,    "some",    1), cfg);
    _ = try iter_proto.defineOwnData("every",   try val_mod.makeNativeFunctionNamed(arena, nativeIterEvery,   "every",   1), cfg);
    _ = try iter_proto.defineOwnData("find",    try val_mod.makeNativeFunctionNamed(arena, nativeIterFind,    "find",    1), cfg);
    // %IteratorPrototype%[@@dispose] — closes the iterator via its `return` method.
    if (realm_mod.active_sym_dispose) |sym|
        try iter_proto.setSymAttr(sym, try val_mod.makeNativeFunctionNamed(arena, nativeIterDispose, "[Symbol.dispose]", 0), cfg);

    // %ArrayIteratorPrototype%: { next, [@@toStringTag]: "Array Iterator" }.
    const aip = try JsObject.create(arena, iter_proto);
    _ = try aip.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeSeqIterNext, "next", 0), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try aip.setSymAttr(tag, try val_mod.makeString(arena, "Array Iterator"), tag_cfg);
    active_array_iter_proto = aip;
    active_iterator_proto = iter_proto;

    // %StringIteratorPrototype% (ES §22.1.5): a sibling of %ArrayIteratorPrototype%,
    // not the same object — `Object.prototype.toString` on a string iterator must
    // report "[object String Iterator]". `next` is the shared sequence stepper,
    // which already branches on SeqIterData.is_string.
    const sip = try JsObject.create(arena, iter_proto);
    _ = try sip.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeSeqIterNext, "next", 0), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try sip.setSymAttr(tag, try val_mod.makeString(arena, "String Iterator"), tag_cfg);
    active_string_iter_proto = sip;

    // %IteratorHelperPrototype%: parent = %IteratorPrototype%, own next + return.
    const ihp = try JsObject.create(arena, iter_proto);
    _ = try ihp.defineOwnData("next",   try val_mod.makeNativeFunctionNamed(arena, nativeIterHelperNext,   "next",   0), cfg);
    _ = try ihp.defineOwnData("return", try val_mod.makeNativeFunctionNamed(arena, nativeIterHelperReturn, "return", 1), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try ihp.setSymAttr(tag, try val_mod.makeString(arena, "Iterator Helper"), tag_cfg);
    active_iterator_helper_proto = ihp;

    // %WrapForValidIteratorPrototype%: parent = %IteratorPrototype%, own next +
    // return that forward to the wrapped iterator (used by Iterator.from).
    const wp = try JsObject.create(arena, iter_proto);
    _ = try wp.defineOwnData("next",   try val_mod.makeNativeFunctionNamed(arena, nativeWrapNext,   "next",   0), cfg);
    _ = try wp.defineOwnData("return", try val_mod.makeNativeFunctionNamed(arena, nativeWrapReturn, "return", 0), cfg);
    active_wrap_iter_proto = wp;
}

/// %WrapForValidIteratorPrototype%.next — forward to the wrapped iterator's
/// [[NextMethod]] and return its result object unchanged.
fn nativeWrapNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try getIterHelperData(arena, this_val);
    return function_proto.invokeCallback(arena, d.source, d.next_fn, &[_]Value{});
}

/// %WrapForValidIteratorPrototype%.return — call the wrapped iterator's `return`
/// (GetMethod); when absent, return CreateIterResultObject(undefined, true).
fn nativeWrapReturn(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try getIterHelperData(arena, this_val);
    const ret_fn = try jsGet(arena, d.source, "return");
    if (ret_fn.bits == 0 or ret_fn.unbox() == .undefined_ or ret_fn.unbox() == .null_)
        return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    if (!isCallable(ret_fn)) {
        try setTypeError(arena, "return is not callable");
        unreachable;
    }
    return function_proto.invokeCallback(arena, d.source, ret_fn, &[_]Value{});
}

/// Wrap an iterator record in a %WrapForValidIterator% object.
fn makeWrapIterator(arena: std.mem.Allocator, d: *IterHelperData) !Value {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, active_wrap_iter_proto)
    else
        try JsObject.create(arena, active_wrap_iter_proto);
    obj.internal_slot = d;
    obj.internal_kind = .iterator_helper;
    return val_mod.makeObject(arena, obj);
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
    const proto = if (d.is_string) (active_string_iter_proto orelse active_array_iter_proto) else active_array_iter_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_slot = d;
    // Brand so the GC traces `d.seq` (the array/string being iterated) via
    // gcStrongTrace. Without a brand `internal_kind == .none` and scanChildren
    // skips the internal slot, so the iterated array is collected mid-loop →
    // use-after-free. Also lets `next` reject a non-iterator receiver.
    obj.internal_kind = .array_iterator;
    // Fallback when the shared proto is not built (early bootstrap): own next.
    if (proto == null) try obj.set("next", try val_mod.makeNativeFunctionNamed(arena, nativeSeqIterNext, "next", 0));
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

/// __requireObjectCoercible__(v): RequireObjectCoercible — throw a TypeError when
/// `v` is null or undefined (a destructuring pattern cannot be applied to it),
/// otherwise return `v` unchanged. Used by the formal-parameter destructuring
/// desugar before reading a pattern's properties.
pub fn nativeRequireObjectCoercible(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (v.bits == 0 or v.unbox() == .undefined_ or v.unbox() == .null_) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot destructure 'undefined' or 'null'");
        return error.JsException;
    }
    return v;
}

/// __destrIterStep__(iterator, box): one element of array-pattern destructuring.
/// `box.done` tracks iterator exhaustion. Returns the element value, or undefined
/// when the iterator is already/now done (so an absent element binds undefined /
/// triggers a default). A throwing `next()` or `value` getter propagates (the
/// iterator is then considered done — spec sets [[Done]] before the abrupt return).
pub fn nativeDestrIterStep(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse return error.JsException;
    const it = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const box = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .object) args[1].toPtr().object else null;
    if (box) |b| {
        if (b.get("done")) |dv| if (isTruthy(dv)) return val_mod.makeUndefined(arena);
    }
    const r = try nativeIterStep(arena, Value{}, &[_]Value{it});
    if (r.bits == 0 or r.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator result is not an object");
        return error.JsException;
    }
    const done = try ctx.getProp(arena, r, "done");
    if (isTruthy(done)) {
        if (box) |b| try b.set("done", try val_mod.makeBool(arena, true));
        return val_mod.makeUndefined(arena);
    }
    return try ctx.getProp(arena, r, "value");
}

/// __destrIterRest__(iterator, box): collect the remaining iterator values into a
/// fresh Array (the `[...rest]` binding). Sets `box.done` when exhausted.
pub fn nativeDestrIterRest(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse return error.JsException;
    const it = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const box = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .object) args[1].toPtr().object else null;
    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    arr.is_array = true;
    var n: usize = 0;
    while (true) {
        if (box) |b| if (b.get("done")) |dv| if (isTruthy(dv)) break;
        const r = try nativeIterStep(arena, Value{}, &[_]Value{it});
        if (r.bits == 0 or r.unbox() != .object) {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator result is not an object");
            return error.JsException;
        }
        const done = try ctx.getProp(arena, r, "done");
        if (isTruthy(done)) {
            if (box) |b| try b.set("done", try val_mod.makeBool(arena, true));
            break;
        }
        const v = try ctx.getProp(arena, r, "value");
        const key = try std.fmt.allocPrint(arena, "{d}", .{n});
        try arr.set(key, v);
        n += 1;
    }
    try arr.set("length", try val_mod.makeNumber(arena, @floatFromInt(n)));
    return val_mod.makeObject(arena, arr);
}

/// __destrIterClose__(iterator, box): IteratorClose when the pattern finished
/// binding but the iterator was not exhausted (`[a] = [1,2,3]`). Calls
/// `return()` if present; a normal completion swallows a non-throwing return,
/// while a throwing `return()` propagates.
pub fn nativeDestrIterClose(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse return error.JsException;
    const it = if (args.len > 0) args[0] else return val_mod.makeUndefined(arena);
    const box = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .object) args[1].toPtr().object else null;
    if (box) |b| if (b.get("done")) |dv| if (isTruthy(dv)) return val_mod.makeUndefined(arena);
    if (it.bits == 0 or it.unbox() != .object) return val_mod.makeUndefined(arena);
    const ret = try ctx.getProp(arena, it, "return");
    if (ret.bits == 0 or ret.unbox() == .undefined_ or ret.unbox() == .null_) return val_mod.makeUndefined(arena);
    if (!isCallable(ret)) return val_mod.makeUndefined(arena);
    _ = try function_proto.invokeCallback(arena, it, ret, &[_]Value{});
    return val_mod.makeUndefined(arena);
}

/// __destrObjRest__(src, excludeKeys): CopyDataProperties into a fresh plain
/// object from `src`'s own enumerable string-keyed properties, skipping any key
/// present in `excludeKeys` (an Array of strings — the compile-time list of
/// already-destructured keys for this pattern: static keys as literals, and
/// computed keys pre-evaluated once into a temp so they're read exactly once).
/// Used by the object-rest binding pattern (`{a, ...rest} = x`). `src` is
/// non-object (e.g. a primitive) only via unusual call sites — the pattern
/// desugar always runs `__requireObjectCoercible__` first, but that only
/// rejects null/undefined, not other primitives — so a non-object `src` yields
/// an empty result (no own enumerable string keys to copy) rather than a crash.
pub fn nativeDestrObjRest(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const out = try JsObject.create(arena, realm_mod.active_object_proto);
    const src = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (src.bits == 0 or src.unbox() != .object) return val_mod.makeObject(arena, out);
    const src_obj = src.toPtr().object;
    const excl_list: ?*JsObject = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .object) args[1].toPtr().object else null;
    outer: for (src_obj.ownKeys()) |k| {
        if (!src_obj.isEnumerable(k)) continue;
        if (excl_list) |ex| {
            var i: usize = 0;
            while (i < ex.array_length) : (i += 1) {
                const ek = try std.fmt.allocPrint(arena, "{d}", .{i});
                const ev = ex.getOwn(ek) orelse continue;
                if (ev.bits != 0 and ev.unbox() == .string and std.mem.eql(u8, ev.unbox().string, k)) continue :outer;
            }
        }
        const v = src_obj.getOwn(k) orelse continue;
        try out.set(k, v);
    }
    return val_mod.makeObject(arena, out);
}

/// __objSpreadInto__(target, src): CopyDataProperties(target, src, «»)
/// mutating `target` IN PLACE (ES2018 object-literal spread `{...src}`,
/// ECMA-262 13.2.5.5). Differs from `nativeDestrObjRest` above (which builds a
/// FRESH object for object-rest *destructuring*): the object literal's
/// properties compile straight-line in source order, so a spread must write
/// into the object already under construction — a later literal property can
/// override a spread value and vice versa, and `robj` keeps its own identity.
/// - null/undefined `src`: no-op (CopyDataProperties skips non-object sources
///   that are null/undefined; everything else is conceptually ToObject'd).
/// - string `src`: own enumerable indexed properties "0".."len-1", one per
///   raw byte — mirrors this engine's existing byte-indexed
///   String.prototype.charAt/String-iteration model rather than introducing a
///   new UTF-16/code-point convention.
/// - other primitives (number/boolean/symbol/bigint): ToObject wrappers have
///   no own enumerable properties of their own, so nothing is copied.
/// - object `src` (including arrays/TypedArrays, which are ordinary
///   JsObjects here): every own enumerable string key AND symbol key is
///   copied, invoking [[Get]] (so getters run and their return VALUE is
///   copied — CopyDataProperties never copies the accessor itself) via the
///   active `Context`, then written with a plain `set`/`setSym` (a data
///   write, matching CreateDataPropertyOrThrow — target's own accessors, if
///   any, are never invoked).
pub fn nativeObjSpreadInto(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target_val = if (args.len > 0) args[0] else return val_mod.makeUndefined(arena);
    if (target_val.bits == 0 or target_val.unbox() != .object) return val_mod.makeUndefined(arena);
    const target_obj = target_val.toPtr().object;
    const src = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (src.bits == 0 or src.unbox() == .undefined_ or src.unbox() == .null_) return val_mod.makeUndefined(arena);

    if (src.unbox() == .string) {
        const s = src.unbox().string;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const ch = try val_mod.makeString(arena, try arena.dupe(u8, s[i .. i + 1]));
            try target_obj.set(idx_key, ch);
        }
        return val_mod.makeUndefined(arena);
    }
    if (src.unbox() != .object) return val_mod.makeUndefined(arena);

    const src_obj = src.toPtr().object;
    const ctx = realm_mod.active_context;
    for (src_obj.ownKeys()) |k| {
        if (!src_obj.isEnumerable(k)) continue;
        const v = if (ctx) |c| try c.getProp(arena, src, k) else (src_obj.getOwn(k) orelse continue);
        try target_obj.set(k, v);
    }
    for (src_obj.symKeys()) |sp| {
        if (!sp.attr.enumerable) continue;
        const v = if (ctx) |c| try c.getPropSym(arena, src, sp.key) else sp.value;
        try target_obj.setSym(sp.key, v);
    }
    return val_mod.makeUndefined(arena);
}

/// __getIterator__(x): obtain an iterator (object with next()) for `x`.
/// Call an @@iterator method and enforce GetIterator's requirement that the
/// result is an Object (a non-object iterator throws a TypeError — §7.4.2).
fn callIteratorMethod(arena: std.mem.Allocator, recv: Value, method: Value) anyerror!Value {
    const it = try function_proto.invokeCallback(arena, recv, method, &[_]Value{});
    if (it.bits == 0 or it.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator method did not return an object");
        return error.JsException;
    }
    return it;
}

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
            if (isCallable(itf)) return callIteratorMethod(arena, x, itf);
        }
        // Iterable — call its @@iterator method.
        if (obj.get("@@iterator")) |itf| {
            if (isCallable(itf)) return callIteratorMethod(arena, x, itf);
        }
        // Observable @@iterator lookup through the prototype chain (fires a getter
        // / Proxy trap, finds an inherited `Array.prototype[Symbol.iterator]`). This
        // also covers plain arrays: their iterator comes from %Array.prototype%, so
        // a deleted/overridden @@iterator is honored (deleting it makes an array
        // non-iterable, per spec) rather than masked by a synthesized fallback.
        if (realm_mod.active_context) |ctx| {
            if (realm_mod.active_sym_iterator) |sym| {
                const m = try ctx.getPropSym(arena, x, sym);
                if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                    if (!isCallable(m)) {
                        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.iterator is not a function");
                        return error.JsException;
                    }
                    return callIteratorMethod(arena, x, m);
                }
            }
        }
        // Last resort: a plain array with no resolvable @@iterator at all (e.g. no
        // active context) still iterates by index, so existing call sites that
        // build arrays internally keep working.
        if (obj.is_array and realm_mod.active_context == null) {
            const d = try arena.create(SeqIterData);
            d.* = .{ .seq = x, .index = 0, .is_string = false };
            return makeSeqIterator(arena, d);
        }
    }
    if (x.bits != 0 and x.unbox() == .string) {
        const d = try arena.create(SeqIterData);
        d.* = .{ .seq = x, .index = 0, .is_string = true };
        return makeSeqIterator(arena, d);
    }
    // Other primitives (boolean/number/bigint/symbol): GetIterator does
    // GetMethod(@@iterator) which ToObjects the primitive for the lookup, then
    // calls the method with the primitive as `this` (e.g. a user-defined
    // `Boolean.prototype[Symbol.iterator]`). undefined/null fall through to the
    // "not iterable" TypeError.
    if (x.bits != 0) switch (x.unbox()) {
        .boolean, .number, .bigint, .symbol => {
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
        },
        else => {},
    };
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

/// __getAsyncIterator__(x): obtain an async iterator for `for await`. Uses the
/// object's @@asyncIterator method if present; otherwise wraps the sync
/// @@iterator as an AsyncFromSyncIterator (each step settled as a promise).
pub fn nativeGetAsyncIterator(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const x = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (x.bits != 0 and x.unbox() == .object) {
        if (realm_mod.active_context) |ctx| {
            if (realm_mod.active_sym_async_iterator) |sym| {
                const m = ctx.getPropSym(arena, x, sym) catch Value{};
                if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                    if (!isCallable(m)) {
                        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.asyncIterator is not a function");
                        return error.JsException;
                    }
                    const it = try function_proto.invokeCallback(arena, x, m, &[_]Value{});
                    if (it.bits == 0 or it.unbox() != .object) {
                        realm_mod.pending_exception = try makeTypeErrorVal(arena, "@@asyncIterator() did not return an object");
                        return error.JsException;
                    }
                    return it;
                }
            }
        }
    }
    // No @@asyncIterator: wrap the sync iterator (AsyncFromSyncIterator).
    const sync_it = try nativeGetIterator(arena, Value{}, args);
    const wrap = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    try wrap.set("__syncit__", sync_it);
    try wrap.set("next", try val_mod.makeNativeFunctionNamed(arena, nativeAsyncFromSyncNext, "next", 0));
    return val_mod.makeObject(arena, wrap);
}

/// next() of an AsyncFromSyncIterator: step the underlying sync iterator and
/// hand back a settled promise of the {value,done} result.
fn nativeAsyncFromSyncNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const promise_mod = @import("promise.zig");
    const p = try promise_mod.newPendingPromise(arena);
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const sync_it = this_val.toPtr().object.get("__syncit__") orelse Value{};
        const result = nativeIterStep(arena, Value{}, &.{sync_it}) catch {
            promise_mod.settleResult(arena, p, realm_mod.pending_exception, false);
            return p;
        };
        // AsyncFromSyncIteratorContinuation: await the produced value so a sync
        // iterable of promises yields resolved values (`for await (x of [p])`).
        if (result.bits != 0 and result.unbox() == .object) {
            const robj = result.toPtr().object;
            if (robj.get("value")) |val| {
                const awaited = promise_mod.awaitValue(arena, val) catch val;
                try robj.set("value", awaited);
            }
        }
        promise_mod.settleResult(arena, p, result, true);
    } else {
        promise_mod.settleResult(arena, p, try makeIteratorResult(arena, try val_mod.makeUndefined(arena), true), true);
    }
    return p;
}

/// __asyncIterStep__(it): call it.next() and return the resulting promise (the
/// for-await lowering awaits it to obtain the {value,done} result).
pub fn nativeAsyncIterStep(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const it = if (args.len > 0) args[0] else return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    if (it.bits == 0 or it.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const nx = it.toPtr().object.get("next") orelse return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    return function_proto.invokeCallback(arena, it, nx, &[_]Value{});
}

/// One `{ value, done, ret }` step record for the `yield*` delegation loop.
/// `ret` true means the outer generator must `return value` (a Return completion
/// forwarded to / produced by the inner iterator).
fn makeYieldStarStep(arena: std.mem.Allocator, value: Value, done: bool, ret: bool, raw: Value) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    // `value`: the yield* completion value (only read from the inner result when
    // done). `raw`: the inner iterator result object, yielded verbatim while
    // delegation continues (spec GeneratorYield passes it through unchanged).
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    try obj.set("ret", try val_mod.makeBool(arena, ret));
    try obj.set("raw", raw);
    return val_mod.makeObject(arena, obj);
}

/// __yieldStarStep__(iterator, resumeType, resumeValue): perform one step of
/// `yield* iterator`. resumeType 0=normal (iterator.next), 1=throw
/// (iterator.throw), 2=return (iterator.return). Forwards the resume value,
/// validates the result is an object, and reports whether to keep yielding,
/// complete the `yield*`, or return from the outer generator.
pub fn nativeYieldStarStep(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse return error.JsException;
    const iterator = if (args.len > 0) args[0] else Value{};
    const rtype: u8 = blk: {
        if (args.len > 1 and args[1].bits != 0) switch (args[1].unbox()) {
            .number => |n| break :blk @intFromFloat(n),
            else => {},
        };
        break :blk 0;
    };
    const rval = if (args.len > 2) args[2] else try val_mod.makeUndefined(arena);
    if (iterator.bits == 0 or iterator.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "yield* requires an iterator");
        return error.JsException;
    }

    var result: Value = undefined;
    if (rtype == 1) {
        // throw: GetMethod(iterator, "throw"). A throwing getter propagates.
        const m = try ctx.getProp(arena, iterator, "throw");
        if (m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_) {
            // No throw method → IteratorClose(iterator, normal completion) before
            // raising the yield* protocol-violation TypeError (spec step b.iii).
            // GetMethod(return) — a throwing getter propagates (rtrn-get-err); a
            // throwing return call propagates (rtrn-call-err); both replace the
            // TypeError. The return result must be an Object.
            const ret_m = try ctx.getProp(arena, iterator, "return");
            if (ret_m.bits != 0 and ret_m.unbox() != .undefined_ and ret_m.unbox() != .null_) {
                if (!isCallable(ret_m)) {
                    realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator 'return' property is not a function");
                    return error.JsException;
                }
                const r = try function_proto.invokeCallback(arena, iterator, ret_m, &[_]Value{});
                if (r.bits == 0 or r.unbox() != .object) {
                    realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator 'return' method returned a non-object value");
                    return error.JsException;
                }
            }
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "The iterator does not provide a 'throw' method");
            return error.JsException;
        }
        if (!isCallable(m)) {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator 'throw' property is not a function");
            return error.JsException;
        }
        result = try function_proto.invokeCallback(arena, iterator, m, &[_]Value{rval});
    } else if (rtype == 2) {
        // return: forward to iterator.return; absent → outer returns rval.
        const m = try ctx.getProp(arena, iterator, "return");
        if (m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_ or !isCallable(m)) {
            return makeYieldStarStep(arena, rval, true, true, try val_mod.makeUndefined(arena));
        }
        result = try function_proto.invokeCallback(arena, iterator, m, &[_]Value{rval});
    } else {
        // normal: iterator.next(rval)
        const m = try ctx.getProp(arena, iterator, "next");
        if (!isCallable(m)) {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator.next is not a function");
            return error.JsException;
        }
        result = try function_proto.invokeCallback(arena, iterator, m, &[_]Value{rval});
    }

    if (result.bits == 0 or result.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator result is not an object");
        return error.JsException;
    }
    const done_v = try ctx.getProp(arena, result, "done");
    const done = isTruthy(done_v);
    if (!done) {
        // Delegation continues: GeneratorYield surfaces the inner result object
        // verbatim. Per spec, `value` is NOT accessed while iteration is incomplete.
        return makeYieldStarStep(arena, try val_mod.makeUndefined(arena), false, false, result);
    }
    // Inner iteration is done → IteratorValue reads `value` exactly once. On the
    // return path this becomes the outer generator's return value.
    const value = try ctx.getProp(arena, result, "value");
    return makeYieldStarStep(arena, value, true, rtype == 2, try val_mod.makeUndefined(arena));
}

/// __retComplVal__(x): the value carried by a return-completion sentinel (used by
/// the `yield*` loop to recover Generator.return's argument); `x` unchanged
/// otherwise.
pub fn nativeRetComplVal(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const x = if (args.len > 0) args[0] else return val_mod.makeUndefined(arena);
    if (x.bits != 0 and x.unbox() == .object) {
        const obj = x.toPtr().object;
        if (obj.internal_kind == .return_completion) {
            if (obj.internal_slot) |s| {
                const p: *Value = @ptrCast(@alignCast(s));
                return p.*;
            }
        }
    }
    return x;
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

// ============================================================
// ES2024 Iterator Helpers — lazy (map/filter/take/drop/flatMap)
// ============================================================

/// %IteratorHelperPrototype%.next — advance the lazy pipeline by one step.
fn nativeIterHelperNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try getIterHelperData(arena, this_val);
    // Re-entrancy guard: a callback (map/filter/flatMap) that calls this helper's
    // own next() while it is still running is a TypeError, not infinite recursion.
    if (d.running) {
        try setTypeError(arena, "Iterator helper is already running");
        unreachable;
    }
    if (d.done) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    d.running = true;
    defer d.running = false;
    const undef = try val_mod.makeUndefined(arena);

    switch (d.kind) {
        // Iterator.from wrappers use %WrapForValidIteratorPrototype%.next directly;
        // this arm only satisfies the exhaustive switch (forwards, unchanged).
        .wrap => return function_proto.invokeCallback(arena, d.source, d.next_fn, &[_]Value{}),
        .map => {
            const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                d.done = true;
                return e;
            };
            const value = step orelse {
                d.done = true;
                return makeIteratorResult(arena, undef, true);
            };
            const counter_v = try val_mod.makeNumber(arena, @floatFromInt(d.counter));
            d.counter += 1;
            const mapped = function_proto.invokeCallback(arena, undef, d.callback, &[_]Value{ value, counter_v }) catch |e| {
                closeIterator(arena, d.source);
                d.done = true;
                return e;
            };
            return makeIteratorResult(arena, mapped, false);
        },

        .filter => {
            while (true) {
                const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                    d.done = true;
                    return e;
                };
                const value = step orelse {
                    d.done = true;
                    return makeIteratorResult(arena, undef, true);
                };
                const counter_v = try val_mod.makeNumber(arena, @floatFromInt(d.counter));
                d.counter += 1;
                const passed = function_proto.invokeCallback(arena, undef, d.callback, &[_]Value{ value, counter_v }) catch |e| {
                    closeIterator(arena, d.source);
                    d.done = true;
                    return e;
                };
                if (isTruthy(passed)) return makeIteratorResult(arena, value, false);
            }
        },

        .take => {
            // Spec §27.1.4.10: when remaining reaches 0 the *next* call returns
            // ? IteratorClose(iterated, NormalCompletion) — the return() throw
            // must surface on that call, so close lazily here (not eagerly after
            // the final yield) and propagate any throw.
            if (d.limit <= 0) {
                d.done = true;
                try iteratorCloseThrowing(arena, d.source);
                return makeIteratorResult(arena, undef, true);
            }
            const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                d.done = true;
                return e;
            };
            const value = step orelse {
                d.done = true;
                return makeIteratorResult(arena, undef, true);
            };
            d.limit -= 1;
            return makeIteratorResult(arena, value, false);
        },

        .drop => {
            // Skip the first `limit` items (counter tracks how many skipped).
            const n_skip: u64 = @intCast(d.limit);
            while (d.counter < n_skip) {
                const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                    d.done = true;
                    return e;
                };
                _ = step orelse {
                    d.done = true;
                    return makeIteratorResult(arena, undef, true);
                };
                d.counter += 1;
            }
            // Dropping phase complete — yield the next value.
            const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                d.done = true;
                return e;
            };
            const value = step orelse {
                d.done = true;
                return makeIteratorResult(arena, undef, true);
            };
            return makeIteratorResult(arena, value, false);
        },

        .flatMap => {
            while (true) {
                // If we have an active inner iterator, drain it first.
                if (d.inner_iter.bits != 0) {
                    const inner_step = iterStep(arena, d.inner_iter, d.inner_next_fn) catch |e| {
                        d.done = true;
                        closeIterator(arena, d.source);
                        return e;
                    };
                    if (inner_step) |inner_val| {
                        return makeIteratorResult(arena, inner_val, false);
                    } else {
                        d.inner_iter = Value{ .bits = 0 };
                        d.inner_next_fn = Value{ .bits = 0 };
                        // fall through to fetch next outer value
                    }
                }
                // Fetch the next outer value.
                const step = iterStep(arena, d.source, d.next_fn) catch |e| {
                    d.done = true;
                    return e;
                };
                const value = step orelse {
                    d.done = true;
                    return makeIteratorResult(arena, undef, true);
                };
                const counter_v = try val_mod.makeNumber(arena, @floatFromInt(d.counter));
                d.counter += 1;
                // Call the callback to get a sub-iterable.
                const sub_iterable = function_proto.invokeCallback(arena, undef, d.callback, &[_]Value{ value, counter_v }) catch |e| {
                    closeIterator(arena, d.source);
                    d.done = true;
                    return e;
                };
                // GetIteratorFlattenable(sub, reject-primitives): a primitive
                // mapper result (number/string/etc) throws TypeError even if its
                // wrapper prototype defines @@iterator; only objects are flattened.
                const inner_iter = getIterFlattenable(arena, sub_iterable) catch |e| {
                    closeIterator(arena, d.source);
                    d.done = true;
                    return e;
                };
                // GetIteratorDirect: read `next` observably (may be an accessor).
                const inner_next = jsGet(arena, inner_iter, "next") catch |e| {
                    closeIterator(arena, d.source);
                    d.done = true;
                    return e;
                };
                d.inner_iter = inner_iter;
                d.inner_next_fn = inner_next;
                // Loop back to drain the new inner iterator.
            }
        },

        .concat => {
            while (true) {
                // Open the next iterable lazily (its @@iterator method was
                // captured up front by Iterator.concat).
                if (d.inner_iter.bits == 0) {
                    if (d.counter >= d.items.len) {
                        d.done = true;
                        return makeIteratorResult(arena, undef, true);
                    }
                    const item = d.items[d.counter];
                    const method = d.item_methods[d.counter];
                    d.counter += 1;
                    const it = function_proto.invokeCallback(arena, item, method, &[_]Value{}) catch |e| {
                        d.done = true;
                        return e;
                    };
                    // GetIteratorDirect: the result must be an Object.
                    if (it.bits == 0 or it.unbox() != .object) {
                        d.done = true;
                        try setTypeError(arena, "Iterator.concat: [Symbol.iterator]() returned a non-object");
                        unreachable;
                    }
                    const nf = jsGet(arena, it, "next") catch |e| {
                        d.done = true;
                        return e;
                    };
                    d.inner_iter = it;
                    d.inner_next_fn = nf;
                }
                // Advance the current inner iterator.
                const inner_step = iterStep(arena, d.inner_iter, d.inner_next_fn) catch |e| {
                    d.done = true;
                    return e;
                };
                if (inner_step) |val| return makeIteratorResult(arena, val, false);
                // Exhausted: move on to the next iterable.
                d.inner_iter = Value{ .bits = 0 };
                d.inner_next_fn = Value{ .bits = 0 };
            }
        },

        .zip, .zipKeyed => {
            const n = d.items.len;
            if (n == 0) {
                d.done = true;
                return makeIteratorResult(arena, undef, true);
            }
            // Collect one value per iterator into `row`.
            const row = try arena.alloc(Value, n);
            switch (d.zip_mode) {
                // shortest: finish as soon as any iterator completes.
                0 => {
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const step = iterStep(arena, d.items[i], d.item_methods[i]) catch |e| {
                            d.done = true;
                            try zipCloseIterators(arena, d, i, false, true);
                            return e;
                        };
                        if (step) |v| {
                            row[i] = v;
                        } else {
                            // Iterator i done → close the others and finish.
                            d.done = true;
                            try zipCloseIterators(arena, d, i, false, false);
                            return makeIteratorResult(arena, undef, true);
                        }
                    }
                },
                // longest: continue until every iterator is exhausted; use padding.
                1 => {
                    var all_done = true;
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        if (d.done_flags[i]) {
                            row[i] = if (i < d.padding.len) d.padding[i] else undef;
                            continue;
                        }
                        const step = iterStep(arena, d.items[i], d.item_methods[i]) catch |e| {
                            d.done = true;
                            try zipCloseIterators(arena, d, i, true, true);
                            return e;
                        };
                        if (step) |v| {
                            row[i] = v;
                            all_done = false;
                        } else {
                            d.done_flags[i] = true;
                            row[i] = if (i < d.padding.len) d.padding[i] else undef;
                        }
                    }
                    if (all_done) {
                        d.done = true;
                        return makeIteratorResult(arena, undef, true);
                    }
                },
                // strict: all iterators must complete on the same step.
                else => {
                    var seen_value = false;
                    var seen_done = false;
                    var i: usize = 0;
                    while (i < n) : (i += 1) {
                        const step = iterStep(arena, d.items[i], d.item_methods[i]) catch |e| {
                            d.done = true;
                            try zipCloseIterators(arena, d, i, false, true);
                            return e;
                        };
                        if (step) |v| {
                            if (seen_done) {
                                // A value after an earlier iterator finished → length
                                // mismatch (a Throw completion): set the TypeError,
                                // close the still-open iterators with a Throw
                                // completion (their errors are discarded), and throw.
                                d.done = true;
                                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip strict mode: iterables have different lengths");
                                try zipCloseIterators(arena, d, null, true, true);
                                return error.JsException;
                            }
                            row[i] = v;
                            seen_value = true;
                        } else {
                            if (i < d.done_flags.len) d.done_flags[i] = true;
                            if (seen_value) {
                                // A finished iterator after earlier values → mismatch.
                                d.done = true;
                                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip strict mode: iterables have different lengths");
                                try zipCloseIterators(arena, d, null, true, true);
                                return error.JsException;
                            }
                            seen_done = true;
                        }
                    }
                    if (seen_done) {
                        // Every iterator finished together → done.
                        d.done = true;
                        return makeIteratorResult(arena, undef, true);
                    }
                },
            }
            // Build the result: an Array for zip, a plain object for zipKeyed.
            if (d.kind == .zipKeyed) {
                // The zipKeyed result is a null-prototype ordinary object.
                const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (d.keys[i].bits != 0 and d.keys[i].unbox() == .string)
                        try obj.set(d.keys[i].unbox().string, row[i]);
                }
                return makeIteratorResult(arena, try val_mod.makeObject(arena, obj), false);
            }
            const arr = if (realm_mod.active_heap) |h| try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto) else try JsObject.createArray(arena, realm_mod.active_array_proto);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try arr.set(try std.fmt.allocPrint(arena, "{d}", .{i}), row[i]);
            }
            return makeIteratorResult(arena, try val_mod.makeObject(arena, arr), false);
        },
    }
}

/// IteratorClose the open zip iterators in reverse index order (spec
/// IteratorZip completion). `keep_idx` (if given) is skipped — the iterator that
/// just reported done. When `only_live` is set, iterators already marked done in
/// `done_flags` are skipped (longest mode). If `swallow` is true every abrupt
/// return() is discarded and the caller's pending exception is preserved (Throw
/// completion). Otherwise the FIRST abrupt return() becomes the result and the
/// remaining iterators are closed with a Throw completion.
fn zipCloseIterators(arena: std.mem.Allocator, d: *IterHelperData, keep_idx: ?usize, only_live: bool, swallow: bool) anyerror!void {
    const outer_saved = realm_mod.pending_exception;
    var captured: ?Value = null;
    var i: usize = d.items.len;
    while (i > 0) {
        i -= 1;
        if (keep_idx) |k| if (i == k) continue;
        if (only_live and i < d.done_flags.len and d.done_flags[i]) continue;
        const it = d.items[i];
        if (it.bits == 0 or it.unbox() != .object) continue;
        const ret_fn = it.toPtr().object.get("return") orelse continue;
        if (!isCallable(ret_fn)) continue;
        if (!swallow and captured == null) {
            // Normal completion so far: a throwing return() becomes the result.
            const r = function_proto.invokeCallback(arena, it, ret_fn, &[_]Value{}) catch {
                captured = realm_mod.pending_exception;
                continue;
            };
            // IteratorClose: a non-object return() result is a TypeError.
            if (r.bits == 0 or r.unbox() != .object) {
                captured = try makeTypeErrorVal(arena, "iterator return() did not return an object");
            }
        } else {
            // Throw completion: discard any error, keep the pending one.
            const saved = realm_mod.pending_exception;
            _ = function_proto.invokeCallback(arena, it, ret_fn, &[_]Value{}) catch {};
            realm_mod.pending_exception = saved;
        }
    }
    if (swallow) {
        realm_mod.pending_exception = outer_saved;
        return;
    }
    if (captured) |e| {
        realm_mod.pending_exception = e;
        return error.JsException;
    }
}

/// %IteratorHelperPrototype%.return — close the helper and its source.
fn nativeIterHelperReturn(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const obj = this_val.toPtr().object;
        if (obj.internal_kind == .iterator_helper and obj.internal_slot != null) {
            const d: *IterHelperData = @ptrCast(@alignCast(obj.internal_slot.?));
            if (d.kind == .concat) {
                // A return() re-entered while the generator is running (e.g. the
                // inner iterator's own return() calls back) is a TypeError.
                if (d.running) {
                    try setTypeError(arena, "Iterator helper is already running");
                    unreachable;
                }
                if (!d.done) {
                    d.done = true;
                    if (d.inner_iter.bits != 0) {
                        const inner = d.inner_iter;
                        d.inner_iter = Value{ .bits = 0 };
                        d.running = true;
                        defer d.running = false;
                        // IteratorClose on the active inner iterator: call return
                        // (if present), letting a re-entrant TypeError propagate.
                        const ret = try jsGet(arena, inner, "return");
                        if (!(ret.bits == 0 or ret.unbox() == .undefined_ or ret.unbox() == .null_)) {
                            _ = try function_proto.invokeCallback(arena, inner, ret, &[_]Value{});
                        }
                    }
                }
            } else if (d.kind == .zip or d.kind == .zipKeyed) {
                if (!d.done) {
                    d.done = true;
                    zipCloseIterators(arena, d, null, true, false) catch {};
                }
            } else if (d.kind == .flatMap) {
                // flatMap: close the active inner (mapper-result) iterator first,
                // then the source. Both closes propagate (yield* forwards return
                // to the inner iterator, then the outer for-of closes the source).
                if (!d.done) {
                    d.done = true;
                    if (d.running) {
                        try setTypeError(arena, "Iterator helper is already running");
                        unreachable;
                    }
                    d.running = true;
                    defer d.running = false;
                    if (d.inner_iter.bits != 0) {
                        const inner = d.inner_iter;
                        d.inner_iter = Value{ .bits = 0 };
                        try iteratorCloseThrowing(arena, inner);
                    }
                    try iteratorCloseThrowing(arena, d.source);
                }
            } else if (!d.done) {
                // map / filter / take / drop: IteratorClose(source) with throw
                // propagation (get-return-method-throws / return-method-throws).
                d.done = true;
                try iteratorCloseThrowing(arena, d.source);
            }
        }
    }
    return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
}

// ---- Lazy factory methods on %IteratorPrototype% ----

fn nativeIterMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.map: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = it.source, .next_fn = it.next_fn, .callback = cb, .kind = .map, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeIteratorHelper(arena, d);
}

fn nativeIterFilter(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.filter: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = it.source, .next_fn = it.next_fn, .callback = cb, .kind = .filter, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeIteratorHelper(arena, d);
}

fn nativeIterTake(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectIter(arena, this_val);
    const limit = try iterLimitArg(arena, this_val, args, "take");
    const it = try getIteratorDirect(arena, this_val);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = it.source, .next_fn = it.next_fn, .callback = Value{ .bits = 0 }, .limit = limit, .kind = .take, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeIteratorHelper(arena, d);
}

/// Validate the numeric `limit` argument for take/drop (ES 27.1.4.10/4.5):
/// ToNumber (abrupt → close), NaN → close + RangeError, negative → close +
/// RangeError. Returns the integer limit (capped at 2^53-1 for ±Infinity).
fn iterLimitArg(arena: std.mem.Allocator, this_val: Value, args: []const Value, comptime name: []const u8) anyerror!i64 {
    const limit_v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // ToNumber(limit): throws TypeError for BigInt/Symbol (must not become the
    // NaN → RangeError path); abrupt completions close the iterator (§27.1.4.x).
    const num = realm_mod.toNumberCheckedRealm(arena, limit_v) catch |e| {
        closeIterator(arena, this_val);
        return e;
    };
    if (std.math.isNan(num)) {
        closeIterator(arena, this_val);
        return realm_mod.throwRangeError(arena, "Iterator.prototype." ++ name ++ ": limit must be a non-negative number");
    }
    // integerLimit = ToIntegerOrInfinity(numLimit): truncate toward zero, THEN
    // reject negatives — so -0.9 → 0 (allowed) while -1 / -Infinity throw.
    const integer = std.math.trunc(num);
    if (integer < 0) {
        closeIterator(arena, this_val);
        return realm_mod.throwRangeError(arena, "Iterator.prototype." ++ name ++ ": limit must be a non-negative number");
    }
    return if (integer >= 9007199254740991.0) 9007199254740991 else @intFromFloat(integer);
}

fn nativeIterDrop(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectIter(arena, this_val);
    const limit = try iterLimitArg(arena, this_val, args, "drop");
    const it = try getIteratorDirect(arena, this_val);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = it.source, .next_fn = it.next_fn, .callback = Value{ .bits = 0 }, .limit = limit, .kind = .drop, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeIteratorHelper(arena, d);
}

fn nativeIterFlatMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.flatMap: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = it.source, .next_fn = it.next_fn, .callback = cb, .kind = .flatMap, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeIteratorHelper(arena, d);
}

// ============================================================
// ES2024 Iterator Helpers — eager (reduce/toArray/forEach/…)
// ============================================================

fn nativeIterReduce(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const reducer = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(reducer)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.reduce: reducer is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    const undef = try val_mod.makeUndefined(arena);
    var acc: Value = undef;
    var has_acc = args.len > 1;
    if (has_acc) acc = args[1];
    var counter: u64 = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        if (!has_acc) {
            acc = value;
            has_acc = true;
        } else {
            const counter_v = try val_mod.makeNumber(arena, @floatFromInt(counter));
            acc = function_proto.invokeCallback(arena, undef, reducer, &[_]Value{ acc, value, counter_v }) catch |e| {
                closeIterator(arena, it.source);
                return e;
            };
        }
        counter += 1;
    }
    if (!has_acc) {
        try setTypeError(arena, "Iterator.prototype.reduce: reduce of empty iterator with no initial value");
        unreachable;
    }
    return acc;
}

fn nativeIterToArray(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const it = try getIteratorDirect(arena, this_val);
    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    arr.is_array = true;
    var n: usize = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        const key = try std.fmt.allocPrint(arena, "{d}", .{n});
        try arr.set(key, value);
        n += 1;
    }
    try arr.set("length", try val_mod.makeNumber(arena, @floatFromInt(n)));
    return val_mod.makeObject(arena, arr);
}

fn nativeIterForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.forEach: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    const undef = try val_mod.makeUndefined(arena);
    var counter: u64 = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        const counter_v = try val_mod.makeNumber(arena, @floatFromInt(counter));
        counter += 1;
        _ = function_proto.invokeCallback(arena, undef, cb, &[_]Value{ value, counter_v }) catch |e| {
            closeIterator(arena, it.source);
            return e;
        };
    }
    return undef;
}

fn nativeIterSome(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.some: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    var counter: u64 = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        const counter_v = try val_mod.makeNumber(arena, @floatFromInt(counter));
        counter += 1;
        const passed = function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &[_]Value{ value, counter_v }) catch |e| {
            closeIterator(arena, it.source);
            return e;
        };
        if (isTruthy(passed)) {
            // Early exit is a NORMAL completion: IteratorClose propagates a throw
            // from the `return` getter or method (unlike the abrupt path above).
            try iteratorCloseThrowing(arena, it.source);
            return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

fn nativeIterEvery(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.every: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    var counter: u64 = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        const counter_v = try val_mod.makeNumber(arena, @floatFromInt(counter));
        counter += 1;
        const passed = function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &[_]Value{ value, counter_v }) catch |e| {
            closeIterator(arena, it.source);
            return e;
        };
        if (!isTruthy(passed)) {
            try iteratorCloseThrowing(arena, it.source);
            return val_mod.makeBool(arena, false);
        }
    }
    return val_mod.makeBool(arena, true);
}

fn nativeIterFind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cb = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try requireObjectIter(arena, this_val);
    if (!isCallable(cb)) {
        closeIterator(arena, this_val);
        try setTypeError(arena, "Iterator.prototype.find: callback is not a function");
        unreachable;
    }
    const it = try getIteratorDirect(arena, this_val);
    var counter: u64 = 0;
    while (true) {
        const step = iterStep(arena, it.source, it.next_fn) catch |e| return e;
        const value = step orelse break;
        const counter_v = try val_mod.makeNumber(arena, @floatFromInt(counter));
        counter += 1;
        const passed = function_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), cb, &[_]Value{ value, counter_v }) catch |e| {
            closeIterator(arena, it.source);
            return e;
        };
        if (isTruthy(passed)) {
            try iteratorCloseThrowing(arena, it.source);
            return value;
        }
    }
    return try val_mod.makeUndefined(arena);
}

// ============================================================
// Iterator global constructor + Iterator.from
// ============================================================

/// Abstract Iterator constructor: direct instantiation is forbidden.
/// Iterator ( ) — ES2025 27.1.3.1. Abstract: throws when called without `new`
/// or when NewTarget is the Iterator constructor itself; a subclass (NewTarget
/// ≠ %Iterator%) constructs an ordinary object whose prototype is derived from
/// NewTarget (the VM applies that post-hoc since we leave pending_new_target).
fn nativeIteratorCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const nt = realm_mod.pending_new_target;
    const direct = nt.bits != 0 and nt.unbox() == .object and
        active_iterator_ctor != null and nt.toPtr().object == active_iterator_ctor.?;
    if (!realm_mod.active_constructing or direct) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Abstract class Iterator not directly constructable");
        return error.JsException;
    }
    return this_val;
}

/// Iterator.from(O): obtain an iterator from any iterable or iterator-like.
/// Per spec: if O already inherits %IteratorPrototype% return it unchanged;
/// otherwise get its @@iterator method and call it, or treat as an iterator
/// directly if it exposes a `next` method.
fn nativeIteratorFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const o = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);

    // GetIteratorFlattenable(O, iterate-string-primitives): objects and string
    // primitives are accepted; any other primitive is a TypeError.
    const is_obj = o.bits != 0 and o.unbox() == .object;
    const is_str = o.bits != 0 and o.unbox() == .string;
    if (!is_obj and !is_str) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.from called on non-iterable value");
        return error.JsException;
    }
    // method = GetMethod(O, @@iterator). If undefined, O itself is the iterator.
    var iterator: Value = o;
    if (realm_mod.active_context) |ctx| {
        if (realm_mod.active_sym_iterator) |sym| {
            const m = try ctx.getPropSym(arena, o, sym);
            if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                if (!isCallable(m)) {
                    realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.iterator is not a function");
                    return error.JsException;
                }
                iterator = try function_proto.invokeCallback(arena, o, m, &[_]Value{});
            }
        }
    }
    if (iterator.bits == 0 or iterator.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.from: value is not iterable");
        return error.JsException;
    }
    const next_fn = try jsGet(arena, iterator, "next");

    // OrdinaryHasInstance(%Iterator%, iterator): if iterator already inherits
    // %Iterator.prototype%, return it directly; otherwise wrap it.
    var p = iterator.toPtr().object.proto;
    while (p) |pp| : (p = pp.proto) {
        if (pp == active_iterator_proto) return iterator;
    }
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{ .source = iterator, .next_fn = next_fn, .callback = Value{ .bits = 0 }, .kind = .wrap, .inner_iter = Value{ .bits = 0 }, .inner_next_fn = Value{ .bits = 0 } };
    return makeWrapIterator(arena, d);
}

/// Iterator.concat(...items) — ES iterator-sequencing proposal. Validates every
/// argument up front (each must be an Object with a callable @@iterator method,
/// fetched exactly once), then returns a lazy iterator that yields the elements
/// of each iterable in order, opening the iterators one at a time on demand.
fn nativeIteratorConcat(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const items = try arena.alloc(Value, args.len);
    const methods = try arena.alloc(Value, args.len);
    for (args, 0..) |item, i| {
        // 3.a. If item is not an Object, throw a TypeError.
        if (item.bits == 0 or item.unbox() != .object) {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.concat: argument is not an object");
            return error.JsException;
        }
        // 3.b. Let method be ? GetMethod(item, @@iterator).
        var method: Value = Value{ .bits = 0 };
        if (realm_mod.active_sym_iterator) |sym| {
            const m = try (realm_mod.active_context orelse {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.concat: no active context");
                return error.JsException;
            }).getPropSym(arena, item, sym);
            if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) method = m;
        }
        // 3.c. If method is undefined, throw a TypeError.
        if (method.bits == 0 or !isCallable(method)) {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.concat: argument is not iterable");
            return error.JsException;
        }
        items[i] = item;
        methods[i] = method;
    }
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{
        .source = Value{ .bits = 0 },
        .next_fn = Value{ .bits = 0 },
        .callback = Value{ .bits = 0 },
        .kind = .concat,
        .inner_iter = Value{ .bits = 0 },
        .inner_next_fn = Value{ .bits = 0 },
        .items = items,
        .item_methods = methods,
    };
    return makeIteratorHelper(arena, d);
}

/// GetIterator(obj, sync): call obj's @@iterator method and return the iterator.
/// Throws TypeError when @@iterator is absent/not callable or returns a non-object.
fn getIteratorSpec(arena: std.mem.Allocator, v: Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "no active context");
        return error.JsException;
    };
    const sym = realm_mod.active_sym_iterator orelse {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.iterator unavailable");
        return error.JsException;
    };
    const m = try ctx.getPropSym(arena, v, sym);
    if (m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_ or !isCallable(m)) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "value is not iterable");
        return error.JsException;
    }
    const it = try function_proto.invokeCallback(arena, v, m, &[_]Value{});
    if (it.bits == 0 or it.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "iterator is not an object");
        return error.JsException;
    }
    return it;
}

/// GetIteratorFlattenable(obj, reject-primitives): open an iterator for a
/// sub-iterable (shared by Iterator.zip/zipKeyed and Iterator.prototype.flatMap).
/// GetMethod(obj, @@iterator): if undefined/null the object is its own iterator
/// (fallback `obj.next`); if present-but-not-callable, throw. All non-objects
/// (including strings and other primitives) throw a TypeError.
fn getIterFlattenable(arena: std.mem.Allocator, obj_val: Value) anyerror!Value {
    if (obj_val.bits == 0 or obj_val.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "flatMap/zip: value is not an object");
        return error.JsException;
    }
    var iterator = obj_val;
    if (realm_mod.active_context) |ctx| {
        if (realm_mod.active_sym_iterator) |sym| {
            const m = try ctx.getPropSym(arena, obj_val, sym);
            if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                if (!isCallable(m)) {
                    realm_mod.pending_exception = try makeTypeErrorVal(arena, "Symbol.iterator is not a function");
                    return error.JsException;
                }
                iterator = try function_proto.invokeCallback(arena, obj_val, m, &[_]Value{});
            }
        }
    }
    if (iterator.bits == 0 or iterator.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "[Symbol.iterator]() returned a non-object");
        return error.JsException;
    }
    return iterator;
}

/// Iterate `v` fully and collect its values into an arena slice.
fn collectIterableValues(arena: std.mem.Allocator, v: Value) anyerror![]Value {
    const it = try getIteratorSpec(arena, v);
    const next_fn = try jsGet(arena, it, "next");
    var list = std.ArrayListUnmanaged(Value){};
    while (true) {
        const step = try iterStep(arena, it, next_fn);
        const val = step orelse break;
        try list.append(arena, val);
    }
    return list.toOwnedSlice(arena);
}

/// Shared core for Iterator.zip (keyed = false) and Iterator.zipKeyed (keyed =
/// true). `entries` supplies the open iterators; `keys` (keyed only) supplies
/// the result-object property keys aligned with the iterators.
fn makeZipIterator(arena: std.mem.Allocator, iters: []Value, nexts: []Value, keys: []Value, mode: u8, padding: []Value, keyed: bool) anyerror!Value {
    const done_flags = try arena.alloc(bool, iters.len);
    @memset(done_flags, false);
    const d = try arena.create(IterHelperData);
    d.* = IterHelperData{
        .source = Value{ .bits = 0 },
        .next_fn = Value{ .bits = 0 },
        .callback = Value{ .bits = 0 },
        .kind = if (keyed) .zipKeyed else .zip,
        .inner_iter = Value{ .bits = 0 },
        .inner_next_fn = Value{ .bits = 0 },
        .items = iters,
        .item_methods = nexts,
        .zip_mode = mode,
        .padding = padding,
        .done_flags = done_flags,
        .keys = keys,
    };
    return makeIteratorHelper(arena, d);
}

/// Read the shared { mode, padding } options for zip/zipKeyed. Reads `mode`
/// first, then `padding` (only in longest mode), matching the spec order.
fn readZipOptions(arena: std.mem.Allocator, options: Value, out_mode: *u8, out_padding: *[]Value, collect_padding: bool) anyerror!void {
    out_mode.* = 0;
    out_padding.* = &.{};
    if (options.bits == 0 or options.unbox() == .undefined_) return;
    if (options.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip: options is not an object");
        return error.JsException;
    }
    const ctx = realm_mod.active_context orelse return;
    const mode_v = try ctx.getProp(arena, options, "mode");
    if (!(mode_v.bits == 0 or mode_v.unbox() == .undefined_)) {
        if (mode_v.bits != 0 and mode_v.unbox() == .string) {
            const s = mode_v.unbox().string;
            if (std.mem.eql(u8, s, "shortest")) {
                out_mode.* = 0;
            } else if (std.mem.eql(u8, s, "longest")) {
                out_mode.* = 1;
            } else if (std.mem.eql(u8, s, "strict")) {
                out_mode.* = 2;
            } else {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip: invalid mode");
                return error.JsException;
            }
        } else {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip: invalid mode");
            return error.JsException;
        }
    }
    if (out_mode.* == 1 and collect_padding) {
        const pad_v = try ctx.getProp(arena, options, "padding");
        if (!(pad_v.bits == 0 or pad_v.unbox() == .undefined_)) {
            if (pad_v.unbox() != .object) {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip: padding is not an object");
                return error.JsException;
            }
            out_padding.* = try collectIterableValues(arena, pad_v);
        }
    }
}

/// Iterator.zip(iterables[, options]) — zip an iterable of iterables.
fn nativeIteratorZip(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const iterables = if (args.len > 0) args[0] else Value{};
    if (iterables.bits == 0 or iterables.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zip: iterables is not an object");
        return error.JsException;
    }
    var mode: u8 = 0;
    var padding: []Value = &.{};
    try readZipOptions(arena, if (args.len > 1) args[1] else Value{}, &mode, &padding, true);

    // Open all sub-iterators (after options are read).
    const outer = try getIteratorSpec(arena, iterables);
    const outer_next = try jsGet(arena, outer, "next");
    var iters = std.ArrayListUnmanaged(Value){};
    var nexts = std.ArrayListUnmanaged(Value){};
    while (true) {
        const step = iterStep(arena, outer, outer_next) catch |e| {
            for (iters.items) |it| closeIterator(arena, it);
            return e;
        };
        const val = step orelse break;
        const it = getIterFlattenable(arena, val) catch |e| {
            for (iters.items) |o| closeIterator(arena, o);
            closeIterator(arena, outer);
            return e;
        };
        const nf = jsGet(arena, it, "next") catch |e| {
            for (iters.items) |o| closeIterator(arena, o);
            closeIterator(arena, it);
            closeIterator(arena, outer);
            return e;
        };
        try iters.append(arena, it);
        try nexts.append(arena, nf);
    }
    return makeZipIterator(arena, try iters.toOwnedSlice(arena), try nexts.toOwnedSlice(arena), &.{}, mode, padding, false);
}

/// Iterator.zipKeyed(iterables[, options]) — zip an object of named iterables
/// into an iterator of plain objects with the same keys.
fn nativeIteratorZipKeyed(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const iterables = if (args.len > 0) args[0] else Value{};
    if (iterables.bits == 0 or iterables.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Iterator.zipKeyed: iterables is not an object");
        return error.JsException;
    }
    var mode: u8 = 0;
    var padding_unused: []Value = &.{};
    const options = if (args.len > 1) args[1] else Value{};
    // Read only `mode` here; zipKeyed padding is an object keyed by the same
    // property names, read per key below.
    try readZipOptions(arena, options, &mode, &padding_unused, false);

    const iterables_obj = iterables.toPtr().object;
    // Own enumerable string keys of `iterables`, in order (OwnPropertyKeys +
    // enumerable filter): each maps to an iterable.
    const ctx = realm_mod.active_context orelse {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "no active context");
        return error.JsException;
    };
    var keys = std.ArrayListUnmanaged(Value){};
    var iters = std.ArrayListUnmanaged(Value){};
    var nexts = std.ArrayListUnmanaged(Value){};
    // Padding per key (longest mode).
    var padding = std.ArrayListUnmanaged(Value){};
    const pad_obj: ?Value = if (mode == 1 and options.bits != 0 and options.unbox() == .object) blk: {
        const pv = try ctx.getProp(arena, options, "padding");
        break :blk if (pv.bits != 0 and pv.unbox() == .object) pv else null;
    } else null;

    // Own enumerable string keys, snapshotted up front.
    var key_names = std.ArrayListUnmanaged([]const u8){};
    for (iterables_obj.ownKeys()) |k| {
        if (iterables_obj.isEnumerable(k)) try key_names.append(arena, k);
    }
    for (key_names.items) |k| {
        const iterable = try ctx.getProp(arena, iterables, k);
        // Spec: keys whose value is undefined are skipped entirely.
        if (iterable.bits == 0 or iterable.unbox() == .undefined_) continue;
        const it = getIterFlattenable(arena, iterable) catch |e| {
            for (iters.items) |o| closeIterator(arena, o);
            return e;
        };
        const nf = try jsGet(arena, it, "next");
        try keys.append(arena, try val_mod.makeString(arena, k));
        try iters.append(arena, it);
        try nexts.append(arena, nf);
        if (mode == 1) {
            var pv: Value = try val_mod.makeUndefined(arena);
            if (pad_obj) |po| pv = try ctx.getProp(arena, po, k);
            try padding.append(arena, pv);
        }
    }
    return makeZipIterator(arena, try iters.toOwnedSlice(arena), try nexts.toOwnedSlice(arena), try keys.toOwnedSlice(arena), mode, try padding.toOwnedSlice(arena), true);
}

/// Register the `Iterator` constructor on the global object.
/// Must be called AFTER initArrayIteratorProto (active_iterator_proto must be set).
pub fn registerIteratorGlobal(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const iter_proto = active_iterator_proto orelse return; // guard: not yet built
    const cfg: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const nc: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };

    const iter_ctor = try JsObject.create(arena, ctx.function_proto);
    _ = try iter_ctor.defineOwnData("name", try val_mod.makeString(arena, "Iterator"), nc);
    _ = try iter_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), nc);
    _ = try iter_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, iter_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    _ = try iter_ctor.defineOwnData("from", try val_mod.makeNativeFunctionNamed(arena, nativeIteratorFrom, "from", 1), cfg);
    _ = try iter_ctor.defineOwnData("concat", try val_mod.makeNativeFunctionNamed(arena, nativeIteratorConcat, "concat", 0), cfg);
    _ = try iter_ctor.defineOwnData("zip", try val_mod.makeNativeFunctionNamed(arena, nativeIteratorZip, "zip", 1), cfg);
    _ = try iter_ctor.defineOwnData("zipKeyed", try val_mod.makeNativeFunctionNamed(arena, nativeIteratorZipKeyed, "zipKeyed", 1), cfg);
    try iter_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeIteratorCtor));
    active_iterator_ctor = iter_ctor;
    // %Iterator.prototype%.constructor is an accessor pair (get %Iterator%, weird
    // setter) so the shared prototype cannot be monkey-patched but subclasses can
    // install their own `constructor`.
    try defineAccessorPair(arena, iter_proto, "constructor", nativeIterCtorGet, nativeIterCtorSet);
    try ctx.env.define("Iterator", try val_mod.makeObject(arena, iter_ctor));
}
