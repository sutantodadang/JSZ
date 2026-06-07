// SPDX-License-Identifier: Apache-2.0
//! Phase 7 baseline: Map/Set/WeakMap/WeakSet builtins.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const InternalKind = @TypeOf((@as(JsObject, undefined)).internal_kind);

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
    if (weak and (args[0].bits == 0 or args[0].unbox() != .object)) return this_val;
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
    if (weak and (args[0].bits == 0 or args[0].unbox() != .object)) return this_val;
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

/// Per-instance state for the array/string fallback iterator.
const SeqIterData = struct { seq: Value, index: usize = 0, is_string: bool };

/// Array.prototype[Symbol.iterator] (and values()): index iterator over `this`.
pub fn nativeArrayValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const d = try arena.create(SeqIterData);
        d.* = .{ .seq = this_val, .index = 0, .is_string = false };
        return makeSeqIterator(arena, d);
    }
    return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
}

fn makeSeqIterator(arena: std.mem.Allocator, d: *SeqIterData) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_slot = d;
    try obj.set("next", try val_mod.makeNativeFunction(arena, nativeSeqIterNext));
    return val_mod.makeObject(arena, obj);
}

fn nativeSeqIterNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const obj = this_val.toPtr().object;
    const d: *SeqIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (d.is_string) {
        const s = d.seq.unbox().string;
        if (d.index >= s.len) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
        const ch = try arena.dupe(u8, s[d.index .. d.index + 1]);
        d.index += 1;
        return makeIteratorResult(arena, try val_mod.makeString(arena, ch), false);
    }
    const arr = d.seq.toPtr().object;
    if (d.index >= arr.getArrayLength()) return makeIteratorResult(arena, try val_mod.makeUndefined(arena), true);
    const idx_str = try std.fmt.allocPrint(arena, "{d}", .{d.index});
    const v = arr.get(idx_str) orelse try val_mod.makeUndefined(arena);
    d.index += 1;
    return makeIteratorResult(arena, v, false);
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
    const proto: ?*JsObject = if (realm_mod.active_context) |_| null else null;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}
