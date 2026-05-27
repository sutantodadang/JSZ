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

/// hasOwnProperty(key): checks if own prop exists (not in proto chain).
pub fn nativeHasOwnProperty(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) {
        return val_mod.makeBool(arena, false);
    }
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const key: []const u8 = if (args[0].bits != 0 and args[0].toPtr().* == .string)
        args[0].toPtr().string
    else
        return val_mod.makeBool(arena, false);

    const obj = this_val.toPtr().object;
    return val_mod.makeBool(arena, obj.hasOwn(key));
}
