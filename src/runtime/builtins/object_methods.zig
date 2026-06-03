// SPDX-License-Identifier: MIT
//! Phase 4b: Object static methods and Object.prototype.hasOwnProperty.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;

/// Object.keys(o): returns array of own enumerable string property names.
pub fn nativeObjectKeys(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) {
        return val_mod.makeObject(arena, arr);
    }
    const inner = args[0].toPtr();
    if (inner.* != .object) return val_mod.makeObject(arena, arr);
    const obj = inner.object;

    var i: u32 = 0;
    var it = obj.props.iterator();
    while (it.next()) |entry| {
        const key_val = try val_mod.makeString(arena, entry.key_ptr.*);
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, key_val);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// Object.values(o): returns array of own enumerable property values.
pub fn nativeObjectValues(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) {
        return val_mod.makeObject(arena, arr);
    }
    const inner = args[0].toPtr();
    if (inner.* != .object) return val_mod.makeObject(arena, arr);
    const obj = inner.object;

    var i: u32 = 0;
    var it = obj.props.iterator();
    while (it.next()) |entry| {
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, entry.value_ptr.*);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// ES2017 Object.entries(o): array of [key, value] pairs.
pub fn nativeObjectEntries(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, arr);
    const inner = args[0].toPtr();
    if (inner.* != .object) return val_mod.makeObject(arena, arr);
    const obj = inner.object;

    var i: u32 = 0;
    var it = obj.props.iterator();
    while (it.next()) |entry| {
        const pair = try JsObject.createArray(arena, arr_proto);
        const key_val = try val_mod.makeString(arena, entry.key_ptr.*);
        try pair.set("0", key_val);
        try pair.set("1", entry.value_ptr.*);
        pair.array_length = 2;
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, try val_mod.makeObject(arena, pair));
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// ES2019 Object.fromEntries(iterable): build a plain object from [key,value] array pairs.
pub fn nativeObjectFromEntries(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
    const out = try JsObject.create(arena, obj_proto);

    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, out);
    const inner = args[0].toPtr();
    if (inner.* != .object or !inner.object.is_array) return val_mod.makeObject(arena, out);
    const list = inner.object;

    var i: usize = 0;
    while (i < list.array_length) : (i += 1) {
        const ek = try std.fmt.allocPrint(arena, "{d}", .{i});
        const entry = list.props.get(ek) orelse continue;
        if (entry.bits == 0 or entry.unbox() != .object) continue;
        const pair = entry.toPtr().object;
        const kv = pair.props.get("0") orelse continue;
        const vv = pair.props.get("1") orelse try val_mod.makeUndefined(arena);
        const key: []const u8 = switch (kv.unbox()) {
            .string => |s| s,
            .number => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            else => continue,
        };
        try out.set(key, vv);
    }
    return val_mod.makeObject(arena, out);
}

fn makeDataDescriptor(arena: std.mem.Allocator, value: Value) !Value {
    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
    const desc = try JsObject.create(arena, obj_proto);
    try desc.set("value", value);
    try desc.set("writable", try val_mod.makeBool(arena, true));
    try desc.set("enumerable", try val_mod.makeBool(arena, true));
    try desc.set("configurable", try val_mod.makeBool(arena, true));
    return val_mod.makeObject(arena, desc);
}

/// ES2017 Object.getOwnPropertyDescriptors(o): own keys → data descriptor objects.
pub fn nativeObjectGetOwnPropertyDescriptors(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
    const out = try JsObject.create(arena, obj_proto);

    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, out);
    const inner = args[0].toPtr();
    if (inner.* != .object) return val_mod.makeObject(arena, out);
    const obj = inner.object;

    var it = obj.props.iterator();
    while (it.next()) |entry| {
        const desc_val = try makeDataDescriptor(arena, entry.value_ptr.*);
        try out.set(entry.key_ptr.*, desc_val);
    }
    return val_mod.makeObject(arena, out);
}

/// hasOwnProperty(key): checks if own prop exists (not in proto chain).
pub fn nativeHasOwnProperty(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const key: []const u8 = if (args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        return val_mod.makeBool(arena, false);

    const obj = this_val.toPtr().object;
    return val_mod.makeBool(arena, obj.hasOwn(key));
}
