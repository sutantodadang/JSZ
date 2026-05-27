// SPDX-License-Identifier: MIT
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
    const av = a.toPtr().*;
    const bv = b.toPtr().*;
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
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != expected) return null;
    if (obj.internal_slot) |s| return @ptrCast(@alignCast(s));
    return null;
}

fn getSetData(this_val: Value, expected: InternalKind) ?*SetData {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != expected) return null;
    if (obj.internal_slot) |s| return @ptrCast(@alignCast(s));
    return null;
}

pub fn nativeMapCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.toPtr().* != .object) {
        out = try makeObj(arena, null, .map);
    }
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .map;
    obj.internal_slot = d;
    return out;
}

pub fn nativeWeakMapCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.toPtr().* != .object) out = try makeObj(arena, null, .weakmap);
    const obj = out.toPtr().object;
    const d = try arena.create(MapData);
    d.* = .{};
    obj.internal_kind = .weakmap;
    obj.internal_slot = d;
    return out;
}

pub fn nativeSetCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.toPtr().* != .object) out = try makeObj(arena, null, .set);
    const obj = out.toPtr().object;
    const d = try arena.create(SetData);
    d.* = .{};
    obj.internal_kind = .set;
    obj.internal_slot = d;
    return out;
}

pub fn nativeWeakSetCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var out = this_val;
    if (out.bits == 0 or out.toPtr().* != .object) out = try makeObj(arena, null, .weakset);
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
    if (weak and (args[0].bits == 0 or args[0].toPtr().* != .object)) return this_val;
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
    if (weak and (args[0].bits == 0 or args[0].toPtr().* != .object)) return this_val;
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
