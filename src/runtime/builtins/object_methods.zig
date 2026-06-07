// SPDX-License-Identifier: MIT
//! Phase 4b: Object static methods and Object.prototype.hasOwnProperty.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const obj_mod = @import("../../object/object.zig");
const JsObject = obj_mod.JsObject;
const PropAttr = obj_mod.PropAttr;
const proxy_mod = @import("proxy.zig");

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

    // Proxy: ownKeys trap (string keys only for Object.keys).
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyOwnKeys(arena, obj)) |keys| {
            var pi: u32 = 0;
            for (keys) |kv| {
                if (kv.bits != 0 and kv.unbox() == .string) {
                    const idx_key = try std.fmt.allocPrint(arena, "{d}", .{pi});
                    try arr.set(idx_key, kv);
                    pi += 1;
                }
            }
            arr.array_length = pi;
        }
        return val_mod.makeObject(arena, arr);
    }

    var i: u32 = 0;
    for (obj.ownKeys()) |k| {
        if (!obj.isEnumerable(k)) continue;
        const key_val = try val_mod.makeString(arena, k);
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
    for (obj.ownKeys()) |k| {
        if (!obj.isEnumerable(k)) continue;
        const v = obj.getOwn(k) orelse continue;
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, v);
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
    for (obj.ownKeys()) |k| {
        if (!obj.isEnumerable(k)) continue;
        const v = obj.getOwn(k) orelse continue;
        const pair = try JsObject.createArray(arena, arr_proto);
        const key_val = try val_mod.makeString(arena, k);
        try pair.set("0", key_val);
        try pair.set("1", v);
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
        const entry = list.getOwn(ek) orelse continue;
        if (entry.bits == 0 or entry.unbox() != .object) continue;
        const pair = entry.toPtr().object;
        const kv = pair.getOwn("0") orelse continue;
        const vv = pair.getOwn("1") orelse try val_mod.makeUndefined(arena);
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

    for (obj.ownKeys()) |k| {
        const v = obj.getOwn(k) orelse continue;
        const desc_val = try makeDataDescriptor(arena, v);
        try out.set(k, desc_val);
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

// ------------------------------------------------------------------ ES5.1 meta-protocol ---

/// Truthiness for descriptor flag values (absent/empty → false).
fn descTruthy(v: ?Value) bool {
    const val = v orelse return false;
    if (val.bits == 0) return false;
    return switch (val.unbox()) {
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .object => true,
        .boolean => |b| b,
        else => false,
    };
}

fn makeTypeErrorObj(arena: std.mem.Allocator, msg: []const u8) !Value {
    const realm_mod = @import("../realm.zig");
    const proto = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    return val_mod.makeObject(arena, obj);
}

fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    realm_mod.pending_exception = try makeTypeErrorObj(arena, msg);
    return error.JsException;
}

/// Coerce a Value to an owned key string. Returns null if not coercible.
fn coerceKey(arena: std.mem.Allocator, v: Value) !?[]const u8 {
    if (v.bits == 0) return null;
    return switch (v.unbox()) {
        .string => |s| s,
        .number => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        else => null,
    };
}

fn makeAccessorHolder(arena: std.mem.Allocator, getter: ?Value, setter: ?Value) !Value {
    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
    const holder = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, obj_proto)
    else
        try JsObject.create(arena, obj_proto);
    try holder.set("get", getter orelse try val_mod.makeUndefined(arena));
    try holder.set("set", setter orelse try val_mod.makeUndefined(arena));
    return val_mod.makeObject(arena, holder);
}

/// Object.getPrototypeOf(o): return proto of o, or null for primitives.
pub fn nativeObjectGetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeNull(arena);
    if (args[0].unbox() != .object) return val_mod.makeNull(arena);
    const obj = args[0].toPtr().object;
    if (obj.proto) |p| return val_mod.makeObject(arena, p);
    return val_mod.makeNull(arena);
}

/// Object.getOwnPropertyNames(o): all own keys including non-enumerable.
pub fn nativeObjectGetOwnPropertyNames(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, arr);
    if (args[0].unbox() != .object) return val_mod.makeObject(arena, arr);
    const obj = args[0].toPtr().object;

    // Proxy: ownKeys trap (all string keys for getOwnPropertyNames).
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyOwnKeys(arena, obj)) |keys| {
            var pi: u32 = 0;
            for (keys) |kv| {
                if (kv.bits != 0 and kv.unbox() == .string) {
                    const idx_key = try std.fmt.allocPrint(arena, "{d}", .{pi});
                    try arr.set(idx_key, kv);
                    pi += 1;
                }
            }
            arr.array_length = pi;
        }
        return val_mod.makeObject(arena, arr);
    }

    var i: u32 = 0;
    for (obj.ownKeys()) |k| {
        const key_val = try val_mod.makeString(arena, k);
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, key_val);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// Object.getOwnPropertyDescriptor(o, key): descriptor object or undefined.
pub fn nativeObjectGetOwnPropertyDescriptor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return val_mod.makeUndefined(arena);
    const obj = args[0].toPtr().object;

    if (args.len < 2) return val_mod.makeUndefined(arena);

    // Proxy: getOwnPropertyDescriptor trap (or forward to target).
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetOwnPropertyDescriptor(arena, obj, args[1])) |desc| {
            return desc;
        }
        if (proxy_mod.proxyTarget(obj)) |target| {
            return try nativeObjectGetOwnPropertyDescriptor(arena, args[0], &[_]Value{ target, args[1] });
        }
        return val_mod.makeUndefined(arena);
    }

    const key = (try coerceKey(arena, args[1])) orelse return val_mod.makeUndefined(arena);

    const a = obj.ownAttr(key) orelse return val_mod.makeUndefined(arena);

    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;

    if (obj.ownAccessorHolder(key)) |holder_val| {
        const desc = try JsObject.create(arena, obj_proto);
        const hobj = holder_val.toPtr().object;
        try desc.set("get", hobj.getOwn("get") orelse try val_mod.makeUndefined(arena));
        try desc.set("set", hobj.getOwn("set") orelse try val_mod.makeUndefined(arena));
        try desc.set("enumerable", try val_mod.makeBool(arena, a.enumerable));
        try desc.set("configurable", try val_mod.makeBool(arena, a.configurable));
        return val_mod.makeObject(arena, desc);
    }

    const v = obj.getOwn(key) orelse try val_mod.makeUndefined(arena);
    const desc = try JsObject.create(arena, obj_proto);
    try desc.set("value", v);
    try desc.set("writable", try val_mod.makeBool(arena, a.writable));
    try desc.set("enumerable", try val_mod.makeBool(arena, a.enumerable));
    try desc.set("configurable", try val_mod.makeBool(arena, a.configurable));
    return val_mod.makeObject(arena, desc);
}

/// Object.defineProperty(o, key, descriptor): define/redefine a data property.
pub fn nativeObjectDefineProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0].bits == 0 or args[0].unbox() != .object) {
        return throwTypeError(arena, "Object.defineProperty called on non-object");
    }
    const obj = args[0].toPtr().object;

    const key_raw = if (args.len >= 2) args[1] else Value{};
    const key = (try coerceKey(arena, key_raw)) orelse "";

    if (args.len < 3 or args[2].bits == 0 or args[2].unbox() != .object) {
        return throwTypeError(arena, "descriptor must be an object");
    }
    const desc = args[2].toPtr().object;

    if (desc.hasOwn("get") or desc.hasOwn("set")) {
        const getter: ?Value = if (desc.hasOwn("get")) desc.getOwn("get") else null;
        const setter: ?Value = if (desc.hasOwn("set")) desc.getOwn("set") else null;
        const holder = try makeAccessorHolder(arena, getter, setter);
        const attr = PropAttr{
            .enumerable = descTruthy(desc.getOwn("enumerable")),
            .configurable = descTruthy(desc.getOwn("configurable")),
        };
        const ok = try obj.defineOwnAccessor(key, holder, attr);
        if (!ok) return throwTypeError(arena, "cannot redefine property");
        return args[0];
    }

    const value = desc.getOwn("value") orelse try val_mod.makeUndefined(arena);
    const attr = PropAttr{
        .writable = descTruthy(desc.getOwn("writable")),
        .enumerable = descTruthy(desc.getOwn("enumerable")),
        .configurable = descTruthy(desc.getOwn("configurable")),
    };
    const ok = try obj.defineOwnData(key, value, attr);
    if (!ok) return throwTypeError(arena, "cannot redefine property");
    return args[0];
}

/// Object.defineProperties(o, props): define multiple properties at once.
pub fn nativeObjectDefineProperties(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0].bits == 0 or args[0].unbox() != .object) {
        return throwTypeError(arena, "Object.defineProperties called on non-object");
    }
    const obj = args[0].toPtr().object;

    if (args.len < 2 or args[1].bits == 0 or args[1].unbox() != .object) {
        return args[0];
    }
    const props = args[1].toPtr().object;

    for (props.ownKeys()) |k| {
        if (!props.isEnumerable(k)) continue;
        const desc_val = props.getOwn(k) orelse continue;
        if (desc_val.bits == 0 or desc_val.unbox() != .object) continue;
        const desc = desc_val.toPtr().object;

        if (desc.hasOwn("get") or desc.hasOwn("set")) {
            const getter: ?Value = if (desc.hasOwn("get")) desc.getOwn("get") else null;
            const setter: ?Value = if (desc.hasOwn("set")) desc.getOwn("set") else null;
            const holder = try makeAccessorHolder(arena, getter, setter);
            const attr = PropAttr{
                .enumerable = descTruthy(desc.getOwn("enumerable")),
                .configurable = descTruthy(desc.getOwn("configurable")),
            };
            const ok = try obj.defineOwnAccessor(k, holder, attr);
            if (!ok) return throwTypeError(arena, "cannot redefine property");
            continue;
        }

        const value = desc.getOwn("value") orelse try val_mod.makeUndefined(arena);
        const attr = PropAttr{
            .writable = descTruthy(desc.getOwn("writable")),
            .enumerable = descTruthy(desc.getOwn("enumerable")),
            .configurable = descTruthy(desc.getOwn("configurable")),
        };
        const ok = try obj.defineOwnData(k, value, attr);
        if (!ok) return throwTypeError(arena, "cannot redefine property");
    }
    return args[0];
}

/// Object.freeze(o): freeze the object (non-extensible, all props non-writable/non-configurable).
pub fn nativeObjectFreeze(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    args[0].toPtr().object.freezeSelf();
    return args[0];
}

/// Object.seal(o): seal the object (non-extensible, all props non-configurable).
pub fn nativeObjectSeal(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    args[0].toPtr().object.sealSelf();
    return args[0];
}

/// Object.preventExtensions(o): prevent new own properties from being added.
pub fn nativeObjectPreventExtensions(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    args[0].toPtr().object.preventExtensionsSelf();
    return args[0];
}

/// Object.isFrozen(o): primitives → true; objects → isFrozenSelf().
pub fn nativeObjectIsFrozen(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, true);
    if (args[0].unbox() != .object) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, args[0].toPtr().object.isFrozenSelf());
}

/// Object.isSealed(o): primitives → true; objects → isSealedSelf().
pub fn nativeObjectIsSealed(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, true);
    if (args[0].unbox() != .object) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, args[0].toPtr().object.isSealedSelf());
}

/// Object.isExtensible(o): primitives → false; objects → extensible flag.
pub fn nativeObjectIsExtensible(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, false);
    if (args[0].unbox() != .object) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, args[0].toPtr().object.extensible);
}

/// Object.getOwnPropertySymbols(o): array of own symbol keys.
pub fn nativeObjectGetOwnPropertySymbols(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, arr);
    const inner = args[0].toPtr();
    if (inner.* != .object) return val_mod.makeObject(arena, arr);
    const obj = inner.object;
    var i: u32 = 0;
    for (obj.symKeys()) |sp| {
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, sp.key);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}
