// SPDX-License-Identifier: Apache-2.0
//! Phase 4b: Object static methods and Object.prototype.hasOwnProperty.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const obj_mod = @import("../../object/object.zig");
const JsObject = obj_mod.JsObject;
const PropAttr = obj_mod.PropAttr;
const proxy_mod = @import("proxy.zig");
const namespace_mod = @import("namespace.zig");

/// Object.keys(o): returns array of own enumerable string property names.
pub fn nativeObjectKeys(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) {
        return val_mod.makeObject(arena, arr);
    }
    const obj = args[0].toPtr().object;

    // M16: Module Namespace — enumerable own string keys are the exported names,
    // sorted by code unit.
    if (obj.internal_kind == .module_namespace) {
        var pi: u32 = 0;
        for (try namespace_mod.sortedNames(arena, obj)) |k| {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{pi});
            try arr.set(idx_key, try val_mod.makeString(arena, k));
            pi += 1;
        }
        arr.array_length = pi;
        return val_mod.makeObject(arena, arr);
    }

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

    // M15: TypedArray integer indices (all enumerable per spec).
    var ta_key_count: u32 = 0;
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        if (!td.ab.detached and !ta_mod.taIsOob(td)) {
            const ta_len: u32 = @intCast(ta_mod.taCurrentLen(td));
            var ti: u32 = 0;
            while (ti < ta_len) : (ti += 1) {
                const k_str = try std.fmt.allocPrint(arena, "{d}", .{ti});
                const idx_key_ta = try std.fmt.allocPrint(arena, "{d}", .{ta_key_count});
                try arr.set(idx_key_ta, try val_mod.makeString(arena, k_str));
                ta_key_count += 1;
            }
        }
    }
    var i: u32 = ta_key_count;
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

    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) {
        return val_mod.makeObject(arena, arr);
    }
    const obj = args[0].toPtr().object;

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
    if (args[0].unbox() != .object) return val_mod.makeObject(arena, arr);
    const obj = args[0].toPtr().object;

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

    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeObject(arena, out);
    const list = args[0].toPtr().object;
    if (!list.is_array) return val_mod.makeObject(arena, out);

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

    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeObject(arena, out);
    const obj = args[0].toPtr().object;

    for (obj.ownKeys()) |k| {
        const v = obj.getOwn(k) orelse continue;
        const desc_val = try makeDataDescriptor(arena, v);
        try out.set(k, desc_val);
    }
    return val_mod.makeObject(arena, out);
}

/// hasOwnProperty(key): checks if own prop exists (not in proto chain).
pub fn nativeHasOwnProperty(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeBool(arena, false);
    // native_function has own "length" and "name" unless deleted (ES spec §10.3).
    if (this_val.bits != 0 and this_val.unbox() == .native_function) {
        const key: []const u8 = if (args[0].bits != 0 and args[0].unbox() == .string)
            args[0].toPtr().string
        else
            return val_mod.makeBool(arena, false);
        const entry = this_val.unbox().native_function;
        if (std.mem.eql(u8, key, "length")) return val_mod.makeBool(arena, !entry.length_deleted);
        if (std.mem.eql(u8, key, "name"))   return val_mod.makeBool(arena, !entry.name_deleted);
        return val_mod.makeBool(arena, false);
    }
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    const obj = this_val.toPtr().object;
    // Symbol key: check sym_props.
    if (args[0].bits != 0 and args[0].unbox() == .symbol) {
        return val_mod.makeBool(arena, obj.getOwnSym(args[0]) != null);
    }
    const key: []const u8 = if (args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        (try coerceKey(arena, args[0])) orelse return val_mod.makeBool(arena, false);

    // TypedArray integer-indexed elements are own iff a valid integer index;
    // a canonical-numeric-but-invalid key ("0.1","-0",OOB) is NOT an own prop.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndexString(key)) |idx_f| {
            const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
            return val_mod.makeBool(arena, ta_mod.isValidIntegerIndex(td, idx_f));
        }
    }

    // M16: Module Namespace own string keys are exactly the exported names.
    if (obj.internal_kind == .module_namespace) {
        return val_mod.makeBool(arena, namespace_mod.hasExport(obj, key));
    }

    return val_mod.makeBool(arena, obj.hasOwn(key));
}

/// Object.prototype.propertyIsEnumerable(V): true iff V is an OWN, enumerable
/// property of ToObject(this). Missing / inherited → false.
pub fn nativePropertyIsEnumerable(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    const obj = this_val.toPtr().object;
    const key_arg = if (args.len > 0) args[0] else Value{};
    // Symbol key: consult sym_props.
    if (key_arg.bits != 0 and key_arg.unbox() == .symbol) {
        if (obj.getOwnSymEntry(key_arg)) |sp| return val_mod.makeBool(arena, sp.attr.enumerable);
        return val_mod.makeBool(arena, false);
    }
    const key = (try coerceKey(arena, key_arg)) orelse "";
    // TypedArray integer-indexed elements are own + enumerable when in-bounds.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndexString(key)) |idx_f| {
            const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
            return val_mod.makeBool(arena, ta_mod.isValidIntegerIndex(td, idx_f));
        }
    }
    // M16: Module Namespace exported names are own + enumerable.
    if (obj.internal_kind == .module_namespace) {
        return val_mod.makeBool(arena, namespace_mod.hasExport(obj, key));
    }
    if (!obj.hasOwn(key)) return val_mod.makeBool(arena, false);
    const a = obj.ownAttr(key) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, a.enumerable);
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

/// Primitive ToNumber for TypedArray element coercion (no valueOf/toString calls).
fn strToNumCoerce(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch std.math.nan(f64),
        else => std.math.nan(f64),
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

/// Object.setPrototypeOf(o, proto): set o's [[Prototype]]. Handles plain
/// objects and bc_function ctors (sets the backing object's proto, so static
/// members inherit along the constructor chain — needed for class subclassing).
pub fn nativeObjectSetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    const target = args[0];
    const new_proto: ?*JsObject = blk: {
        if (args.len < 2 or args[1].bits == 0) break :blk null;
        break :blk switch (args[1].unbox()) {
            .object => |o| o,
            .null_ => null,
            // A class used as a proto (`class B extends A` → setPrototypeOf(B, A))
            // is a bc_function value; its static members live on a lazily-created
            // backing object. Resolve to that so the constructor static chain links
            // (needed for multi-level subclasses: @@species etc. inherit through it).
            .bc_function, .function => if (@import("../realm.zig").active_context) |ctx|
                (try ctx.backingObject(arena, args[1]))
            else
                null,
            else => null,
        };
    };
    // M16: Module Namespace [[SetPrototypeOf]] is SetImmutablePrototype — only a
    // no-op to null succeeds; any other target throws (Object.setPrototypeOf).
    if (target.bits != 0 and target.unbox() == .object and
        target.toPtr().object.internal_kind == .module_namespace)
    {
        if (new_proto == null) return target;
        return throwTypeError(arena, "cannot set prototype of a module namespace object");
    }
    if (target.bits != 0) {
        if (target.unbox() == .object) {
            target.toPtr().object.proto = new_proto;
        } else if (@import("../realm.zig").active_context) |ctx| {
            try ctx.setProto(arena, target, new_proto); // bc_function ctor (static inheritance)
        }
    }
    return target;
}

/// Object.getOwnPropertyNames(o): all own keys including non-enumerable.
pub fn nativeObjectGetOwnPropertyNames(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) return val_mod.makeObject(arena, arr);
    // native_function: own string keys are "length" and "name" unless deleted (spec §10.3).
    if (args[0].unbox() == .native_function) {
        const entry = args[0].unbox().native_function;
        var idx: u32 = 0;
        if (!entry.length_deleted) {
            const k = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(k, try val_mod.makeString(arena, "length"));
            idx += 1;
        }
        if (!entry.name_deleted) {
            const k = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(k, try val_mod.makeString(arena, "name"));
            idx += 1;
        }
        arr.array_length = idx;
        return val_mod.makeObject(arena, arr);
    }
    if (args[0].unbox() != .object) return val_mod.makeObject(arena, arr);
    const obj = args[0].toPtr().object;

    // M16: Module Namespace [[OwnPropertyKeys]] — exported names sorted by code
    // unit (symbol keys are excluded from getOwnPropertyNames).
    if (obj.internal_kind == .module_namespace) {
        var pi: u32 = 0;
        for (try namespace_mod.sortedNames(arena, obj)) |k| {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{pi});
            try arr.set(idx_key, try val_mod.makeString(arena, k));
            pi += 1;
        }
        arr.array_length = pi;
        return val_mod.makeObject(arena, arr);
    }

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

    // M15: TypedArray [[OwnPropertyKeys]] — integer indices first.
    var ta_key_count: u32 = 0;
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        if (!ta_mod.taIsOob(td)) {
            const cur_len = ta_mod.taCurrentLen(td);
            var ti: u32 = 0;
            while (ti < cur_len) : (ti += 1) {
                const k_str = try std.fmt.allocPrint(arena, "{d}", .{ti});
                const idx_key_ta = try std.fmt.allocPrint(arena, "{d}", .{ta_key_count});
                try arr.set(idx_key_ta, try val_mod.makeString(arena, k_str));
                ta_key_count += 1;
            }
        }
    }
    var i: u32 = ta_key_count;
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
    const arg0_unboxed = args[0].unbox();
    // Handle native_function: synthesize descriptors for .name/.length (respecting deletion).
    if (arg0_unboxed == .native_function) {
        if (args.len < 2) return val_mod.makeUndefined(arena);
        const key = (try coerceKey(arena, args[1])) orelse return val_mod.makeUndefined(arena);
        const entry = arg0_unboxed.native_function;
        const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
        const desc = try JsObject.create(arena, obj_proto);
        if (std.mem.eql(u8, key, "name")) {
            if (entry.name_deleted) return val_mod.makeUndefined(arena);
            const name_val = if (entry.name) |n|
                try val_mod.makeString(arena, n)
            else
                try val_mod.makeString(arena, "");
            try desc.set("value", name_val);
            try desc.set("writable", try val_mod.makeBool(arena, false));
            try desc.set("enumerable", try val_mod.makeBool(arena, false));
            try desc.set("configurable", try val_mod.makeBool(arena, true));
            return val_mod.makeObject(arena, desc);
        } else if (std.mem.eql(u8, key, "length")) {
            if (entry.length_deleted) return val_mod.makeUndefined(arena);
            try desc.set("value", try val_mod.makeNumber(arena, @floatFromInt(entry.length)));
            try desc.set("writable", try val_mod.makeBool(arena, false));
            try desc.set("enumerable", try val_mod.makeBool(arena, false));
            try desc.set("configurable", try val_mod.makeBool(arena, true));
            return val_mod.makeObject(arena, desc);
        }
        return val_mod.makeUndefined(arena);
    }
    if (arg0_unboxed != .object) return val_mod.makeUndefined(arena);
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

    // M15: TypedArray [[GetOwnProperty]] — integer-indexed exotic. Symbol keys are
    // never integer indices: skip to the ordinary symbol-property branch below.
    if (obj.internal_kind == .typed_array and !(args[1].bits != 0 and args[1].unbox() == .symbol)) {
        const ta_mod = @import("typed_array.zig");
        const key2 = (try coerceKey(arena, args[1])) orelse return val_mod.makeUndefined(arena);
        if (ta_mod.canonicalNumericIndexString(key2)) |idx_f| {
            const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
            if (!ta_mod.isValidIntegerIndex(td, idx_f)) return val_mod.makeUndefined(arena);
            const i: usize = @intFromFloat(idx_f);
            const realm_mod2 = @import("../realm.zig");
            const obj_proto3: ?*JsObject = if (realm_mod2.active_object_proto) |p| p else null;
            const desc3 = try JsObject.create(arena, obj_proto3);
            const elem = try ta_mod.taLoad(arena, td, i);
            try desc3.set("value", elem);
            try desc3.set("writable", try val_mod.makeBool(arena, true));
            try desc3.set("enumerable", try val_mod.makeBool(arena, true));
            try desc3.set("configurable", try val_mod.makeBool(arena, true));
            return val_mod.makeObject(arena, desc3);
        }
        // Non-canonical-numeric key: fall through to ordinary property lookup.
    }

    // M16: Module Namespace exotic [[GetOwnProperty]] for a string key — an
    // exported name yields { value, writable: true, enumerable: true,
    // configurable: false }; a non-export yields undefined. (Symbol keys fall
    // through to the ordinary sym_props branch below — e.g. @@toStringTag.)
    if (obj.internal_kind == .module_namespace and !(args[1].bits != 0 and args[1].unbox() == .symbol)) {
        const nkey = (try coerceKey(arena, args[1])) orelse return val_mod.makeUndefined(arena);
        if (!namespace_mod.hasExport(obj, nkey)) return val_mod.makeUndefined(arena);
        const realm_mod3 = @import("../realm.zig");
        const b = namespace_mod.backing(obj).?;
        const value = if (realm_mod3.active_context) |ctx|
            try ctx.getProp(arena, try val_mod.makeObject(arena, b), nkey)
        else
            (b.get(nkey) orelse try val_mod.makeUndefined(arena));
        const np: ?*JsObject = if (realm_mod3.active_object_proto) |p| p else null;
        const ndesc = try JsObject.create(arena, np);
        try ndesc.set("value", value);
        try ndesc.set("writable", try val_mod.makeBool(arena, true));
        try ndesc.set("enumerable", try val_mod.makeBool(arena, true));
        try ndesc.set("configurable", try val_mod.makeBool(arena, false));
        return val_mod.makeObject(arena, ndesc);
    }

    // Symbol-keyed lookup: check sym_props first.
    if (args[1].bits != 0 and args[1].unbox() == .symbol) {
        const sym_val = args[1];
        const sym_entry = obj.getOwnSymEntry(sym_val) orelse return val_mod.makeUndefined(arena);
        const obj_proto2: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
        const desc2 = try JsObject.create(arena, obj_proto2);
        if (sym_entry.attr.is_accessor and sym_entry.value.bits != 0 and sym_entry.value.unbox() == .object) {
            const hobj = sym_entry.value.toPtr().object;
            try desc2.set("get", hobj.getOwn("get") orelse try val_mod.makeUndefined(arena));
            try desc2.set("set", hobj.getOwn("set") orelse try val_mod.makeUndefined(arena));
        } else {
            try desc2.set("value", sym_entry.value);
            try desc2.set("writable", try val_mod.makeBool(arena, sym_entry.attr.writable));
        }
        try desc2.set("enumerable", try val_mod.makeBool(arena, sym_entry.attr.enumerable));
        try desc2.set("configurable", try val_mod.makeBool(arena, sym_entry.attr.configurable));
        return val_mod.makeObject(arena, desc2);
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

/// Resolve a defineProperty/defineProperties target to its property-bearing
/// JsObject. Plain objects resolve directly; functions resolve via the active
/// context's backing-object bridge (functions are objects). Returns null for
/// primitives / non-property-bearing values.
fn defineTarget(arena: std.mem.Allocator, val: Value) anyerror!?*JsObject {
    if (val.bits == 0) return null;
    if (val.unbox() == .object) return val.toPtr().object;
    const realm_mod = @import("../realm.zig");
    if (realm_mod.active_context) |ctx| return ctx.backingObject(arena, val);
    return null;
}

/// Object.defineProperty(o, key, descriptor): define/redefine a data property.
pub fn nativeObjectDefineProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Functions are objects too: resolve a callable to its backing object so
    // `Object.defineProperty(fn, ...)` works (not just plain objects).
    const obj = try defineTarget(arena, if (args.len >= 1) args[0] else Value{}) orelse
        return throwTypeError(arena, "Object.defineProperty called on non-object");

    const key_raw = if (args.len >= 2) args[1] else Value{};

    // Symbol-keyed [[DefineOwnProperty]]: ordinary, never integer-indexed.
    if (key_raw.bits != 0 and key_raw.unbox() == .symbol) {
        if (args.len < 3 or args[2].bits == 0 or args[2].unbox() != .object)
            return throwTypeError(arena, "descriptor must be an object");
        const sdesc = args[2].toPtr().object;
        if (sdesc.hasOwn("get") or sdesc.hasOwn("set")) {
            const getter: ?Value = if (sdesc.hasOwn("get")) sdesc.getOwn("get") else null;
            const setter: ?Value = if (sdesc.hasOwn("set")) sdesc.getOwn("set") else null;
            const holder = try makeAccessorHolder(arena, getter, setter);
            const sok = try obj.defineOwnAccessorSym(key_raw, holder, .{
                .enumerable = descTruthy(sdesc.getOwn("enumerable")),
                .configurable = descTruthy(sdesc.getOwn("configurable")),
            });
            if (!sok) return throwTypeError(arena, "cannot redefine property");
            return args[0];
        }
        const sval = sdesc.getOwn("value") orelse try val_mod.makeUndefined(arena);
        const sok = try obj.defineOwnDataSym(key_raw, sval, .{
            .writable = descTruthy(sdesc.getOwn("writable")),
            .enumerable = descTruthy(sdesc.getOwn("enumerable")),
            .configurable = descTruthy(sdesc.getOwn("configurable")),
        });
        if (!sok) return throwTypeError(arena, "cannot redefine property");
        return args[0];
    }

    const key = (try coerceKey(arena, key_raw)) orelse "";

    // M15: TypedArray [[DefineOwnProperty]] — integer-indexed exotic.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndexString(key)) |idx_f| {
            const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
            if (!ta_mod.isValidIntegerIndex(td, idx_f))
                return throwTypeError(arena, "TypedArray: cannot define property with non-valid integer index");
            if (args.len >= 3 and args[2].bits != 0 and args[2].unbox() == .object) {
                const desc2 = args[2].toPtr().object;
                if (desc2.hasOwn("get") or desc2.hasOwn("set"))
                    return throwTypeError(arena, "TypedArray: cannot define accessor on integer-indexed property");
                if (desc2.hasOwn("configurable") and !descTruthy(desc2.getOwn("configurable")))
                    return throwTypeError(arena, "TypedArray: cannot define non-configurable integer-indexed property");
                if (desc2.hasOwn("enumerable") and !descTruthy(desc2.getOwn("enumerable")))
                    return throwTypeError(arena, "TypedArray: cannot define non-enumerable integer-indexed property");
                if (desc2.hasOwn("writable") and !descTruthy(desc2.getOwn("writable")))
                    return throwTypeError(arena, "TypedArray: cannot define non-writable integer-indexed property");
                if (desc2.hasOwn("value")) {
                    const val2 = desc2.getOwn("value") orelse Value{};
                    // ToNumber/ToBigInt runs user valueOf (throws propagate).
                    try ta_mod.setElementThrowing(arena, td, idx_f, val2);
                }
            }
            return args[0];
        }
        // Non-canonical-numeric key: fall through to ordinary defineProperty.
    }

    if (args.len < 3 or args[2].bits == 0 or args[2].unbox() != .object) {
        return throwTypeError(arena, "descriptor must be an object");
    }
    const desc = args[2].toPtr().object;

    if (desc.hasOwn("get") or desc.hasOwn("set")) {
        const getter: ?Value = if (desc.hasOwn("get")) desc.getOwn("get") else null;
        const setter: ?Value = if (desc.hasOwn("set")) desc.getOwn("set") else null;
        const holder = try makeAccessorHolder(arena, getter, setter);
        // Partial descriptor: omitted enumerable/configurable keep the EXISTING
        // own attributes (redefine), else default false (create) — same merge as
        // the data path. Without this, redefining a configurable accessor with a
        // bare {get} silently flips it non-configurable and blocks the next redefine.
        var prev_e = false;
        var prev_c = false;
        if (obj.findProperty(key)) |loc| {
            if (loc.holder == obj) {
                const a = loc.holder.attrAt(loc.slot);
                prev_e = a.enumerable;
                prev_c = a.configurable;
            }
        }
        const attr = PropAttr{
            .enumerable = if (desc.hasOwn("enumerable")) descTruthy(desc.getOwn("enumerable")) else prev_e,
            .configurable = if (desc.hasOwn("configurable")) descTruthy(desc.getOwn("configurable")) else prev_c,
        };
        const ok = try obj.defineOwnAccessor(key, holder, attr);
        if (!ok) return throwTypeError(arena, "cannot redefine property");
        return args[0];
    }

    // Partial descriptor: fields the descriptor omits default to the EXISTING own
    // property's attributes (when redefining) or to false (when creating new).
    var cur_w = false;
    var cur_e = false;
    var cur_c = false;
    var has_own_data = false;
    var cur_val: ?Value = null;
    if (obj.findProperty(key)) |loc| {
        if (loc.holder == obj) {
            const a = loc.holder.attrAt(loc.slot);
            if (!a.is_accessor) {
                cur_w = a.writable;
                cur_e = a.enumerable;
                cur_c = a.configurable;
                cur_val = obj.getOwn(key);
                has_own_data = true;
            }
        }
    }
    const value = if (desc.hasOwn("value"))
        (desc.getOwn("value") orelse try val_mod.makeUndefined(arena))
    else if (has_own_data and cur_val != null)
        cur_val.?
    else
        try val_mod.makeUndefined(arena);
    const attr = PropAttr{
        .writable = if (desc.hasOwn("writable")) descTruthy(desc.getOwn("writable")) else cur_w,
        .enumerable = if (desc.hasOwn("enumerable")) descTruthy(desc.getOwn("enumerable")) else cur_e,
        .configurable = if (desc.hasOwn("configurable")) descTruthy(desc.getOwn("configurable")) else cur_c,
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
    return switch (args[0].unbox()) {
        .object => |o| val_mod.makeBool(arena, o.extensible),
        // Functions are ordinary (extensible) objects.
        .native_function, .bc_function, .function => val_mod.makeBool(arena, true),
        else => val_mod.makeBool(arena, false),
    };
}

/// Object.getOwnPropertySymbols(o): array of own symbol keys.
pub fn nativeObjectGetOwnPropertySymbols(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);
    // ToObject(O): undefined/null throw TypeError; other primitives box → no symbols → [].
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    if (args[0].unbox() != .object) return val_mod.makeObject(arena, arr);
    const obj = args[0].toPtr().object;
    var i: u32 = 0;
    for (obj.symKeys()) |sp| {
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, sp.key);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}
