// SPDX-License-Identifier: Apache-2.0
//! ES2015 Reflect namespace — thin wrappers over the object meta-protocol.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const obj_mod = @import("../../object/object.zig");
const JsObject = obj_mod.JsObject;
const PropAttr = obj_mod.PropAttr;
const fp = @import("function_proto.zig");
const intrinsics = @import("intrinsics.zig");
const typed_array = @import("typed_array.zig");

/// R1: create the Reflect namespace object and bind the `Reflect` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const reflect_obj = try JsObject.create(arena, ctx.object_proto);
    try reflect_obj.set("get", try val_mod.makeNativeFunction(arena, nativeReflectGet));
    try reflect_obj.set("set", try val_mod.makeNativeFunction(arena, nativeReflectSet));
    try reflect_obj.set("has", try val_mod.makeNativeFunction(arena, nativeReflectHas));
    try reflect_obj.set("deleteProperty", try val_mod.makeNativeFunction(arena, nativeReflectDeleteProperty));
    try reflect_obj.set("ownKeys", try val_mod.makeNativeFunction(arena, nativeReflectOwnKeys));
    try reflect_obj.set("getPrototypeOf", try val_mod.makeNativeFunction(arena, nativeReflectGetPrototypeOf));
    try reflect_obj.set("defineProperty", try val_mod.makeNativeFunction(arena, nativeReflectDefineProperty));
    try reflect_obj.set("getOwnPropertyDescriptor", try val_mod.makeNativeFunction(arena, nativeReflectGetOwnPropertyDescriptor));
    try reflect_obj.set("isExtensible", try val_mod.makeNativeFunction(arena, nativeReflectIsExtensible));
    try reflect_obj.set("preventExtensions", try val_mod.makeNativeFunction(arena, nativeReflectPreventExtensions));
    try reflect_obj.set("apply", try val_mod.makeNativeFunction(arena, nativeReflectApply));
    try reflect_obj.set("construct", try val_mod.makeNativeFunction(arena, nativeReflectConstruct));
    try ctx.env.define("Reflect", try val_mod.makeObject(arena, reflect_obj));
}

// ---------------------------------------------------------------- helpers ---

fn isObj(v: Value) bool {
    if (v.bits == 0) return false;
    // Must be a real heap pointer; SMIs and immediates are not objects.
    if (!v.isHeapPtr()) return false;
    return v.toPtr().* == .object;
}

fn isSym(v: Value) bool {
    if (v.bits == 0) return false;
    if (!v.isHeapPtr()) return false;
    return v.toPtr().* == .symbol;
}

fn keyStr(arena: std.mem.Allocator, v: Value) !?[]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .string => |s| s,
        .number => |n| try val_mod.formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .symbol => null, // caller handles symbol keys separately
        .undefined_ => "undefined",
        .null_ => "null",
        else => "[object Object]",
    };
}

fn descTruthy(v: ?Value) bool {
    const val = v orelse return false;
    if (val.bits == 0) return false;
    return switch (val.unbox()) {
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .object, .symbol => true,
        else => false,
    };
}

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        .object => |o| o.internal_kind == .bound_function,
        else => false,
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

// ---------------------------------------------------------------- Reflect.get ---

pub fn nativeReflectGet(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeUndefined(arena);
    const target = args[0];
    const key = if (args.len > 1) args[1] else Value{};
    const receiver = if (args.len > 2) args[2] else target;

    const target_obj = target.toPtr().object;

    if (isSym(key)) {
        // Proto-chain walk for symbol-keyed property.
        var depth: usize = 0;
        var cur: ?*JsObject = target_obj;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            if (o.getOwnSym(key)) |v| return v;
            cur = o.proto;
        }
        return val_mod.makeUndefined(arena);
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeUndefined(arena);

    if (target_obj.findProperty(k)) |found| {
        const attr = found.holder.attrAt(found.slot);
        if (attr.is_accessor) {
            // Get the accessor holder value stored in the slot.
            if (found.slot < found.holder.slots.items.len) {
                const holder_val = found.holder.slots.items[found.slot];
                if (holder_val.bits != 0 and holder_val.isHeapPtr() and holder_val.toPtr().* == .object) {
                    const hobj = holder_val.toPtr().object;
                    const getter = hobj.getOwn("get") orelse return val_mod.makeUndefined(arena);
                    if (isCallable(getter)) {
                        return fp.invokeCallback(arena, receiver, getter, &[_]Value{});
                    }
                }
            }
            return val_mod.makeUndefined(arena);
        }
        // Data property.
        if (found.slot < found.holder.slots.items.len) {
            return found.holder.slots.items[found.slot];
        }
    }
    return val_mod.makeUndefined(arena);
}

// ---------------------------------------------------------------- Reflect.set ---

pub fn nativeReflectSet(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeBool(arena, false);
    const target = args[0];
    const key = if (args.len > 1) args[1] else Value{};
    const value = if (args.len > 2) args[2] else Value{};

    const target_obj = target.toPtr().object;

    if (isSym(key)) {
        try target_obj.setSym(key, value);
        return val_mod.makeBool(arena, true);
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeBool(arena, false);

    // Check for accessor in proto chain.
    if (target_obj.findProperty(k)) |found| {
        const attr = found.holder.attrAt(found.slot);
        if (attr.is_accessor) {
            if (found.slot < found.holder.slots.items.len) {
                const holder_val = found.holder.slots.items[found.slot];
                if (holder_val.bits != 0 and holder_val.isHeapPtr() and holder_val.toPtr().* == .object) {
                    const hobj = holder_val.toPtr().object;
                    const setter = hobj.getOwn("set") orelse return val_mod.makeBool(arena, false);
                    if (isCallable(setter)) {
                        _ = try fp.invokeCallback(arena, target, setter, &[_]Value{value});
                        return val_mod.makeBool(arena, true);
                    }
                }
            }
            return val_mod.makeBool(arena, false);
        }
    }

    try target_obj.set(k, value);
    return val_mod.makeBool(arena, true);
}

// ---------------------------------------------------------------- Reflect.has ---

pub fn nativeReflectHas(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeBool(arena, false);
    const target_obj = args[0].toPtr().object;
    const key = if (args.len > 1) args[1] else Value{};

    if (isSym(key)) {
        var depth: usize = 0;
        var cur: ?*JsObject = target_obj;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            if (o.getOwnSym(key) != null) return val_mod.makeBool(arena, true);
            cur = o.proto;
        }
        return val_mod.makeBool(arena, false);
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeBool(arena, false);

    // M15: TypedArray [[HasProperty]] — integer-indexed exotic.
    if (target_obj.internal_kind == .typed_array) {
        if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
            const td = typed_array.getTd(args[0]).?;
            return val_mod.makeBool(arena, typed_array.isValidIntegerIndex(td, idx_f));
        }
        // Non-canonical key: fall through to ordinary prototype walk.
    }

    var depth: usize = 0;
    var cur: ?*JsObject = target_obj;
    while (cur) |o| {
        if (depth >= 64) break;
        depth += 1;
        if (o.resolveOwnSlot(k) != null) return val_mod.makeBool(arena, true);
        cur = o.proto;
    }
    return val_mod.makeBool(arena, false);
}

// ---------------------------------------------------------------- Reflect.deleteProperty ---

pub fn nativeReflectDeleteProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeBool(arena, false);
    const target_obj = args[0].toPtr().object;
    const key = if (args.len > 1) args[1] else Value{};

    if (isSym(key)) {
        return val_mod.makeBool(arena, target_obj.deleteOwnSym(key));
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeBool(arena, false);

    // M15: TypedArray [[Delete]] — integer-indexed exotic.
    if (target_obj.internal_kind == .typed_array) {
        if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
            const td = typed_array.getTd(args[0]).?;
            // Valid index: cannot delete → false. Out-of-range: true.
            return val_mod.makeBool(arena, !typed_array.isValidIntegerIndex(td, idx_f));
        }
        // Non-canonical key: fall through to ordinary deleteOwn.
    }

    return val_mod.makeBool(arena, try target_obj.deleteOwn(k));
}

// ---------------------------------------------------------------- Reflect.ownKeys ---

pub fn nativeReflectOwnKeys(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0) return val_mod.makeObject(arena, arr);
    // native_function: own keys are "length" then "name" unless deleted (spec §10.3).
    if (args[0].bits != 0 and args[0].isHeapPtr() and args[0].toPtr().* == .native_function) {
        const entry = args[0].toPtr().native_function;
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
    if (!isObj(args[0])) {
        return val_mod.makeObject(arena, arr);
    }
    const obj = args[0].toPtr().object;

    // M15: TypedArray [[OwnPropertyKeys]] — integer indices first, then ordinary, then symbols.
    var ta_count: u32 = 0;
    if (isObj(args[0])) {
        const robj = args[0].toPtr().object;
        if (robj.internal_kind == .typed_array and robj.internal_slot != null) {
            const td = typed_array.getTd(args[0]).?;
            if (!td.ab.detached) {
                var ti: u32 = 0;
                while (ti < td.length) : (ti += 1) {
                    const k_str = try std.fmt.allocPrint(arena, "{d}", .{ti});
                    const idx_key_ta = try std.fmt.allocPrint(arena, "{d}", .{ta_count});
                    try arr.set(idx_key_ta, try val_mod.makeString(arena, k_str));
                    ta_count += 1;
                }
            }
        }
    }
    var i: u32 = ta_count;
    for (obj.ownKeys()) |k| {
        const key_val = try val_mod.makeString(arena, k);
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, key_val);
        i += 1;
    }
    for (obj.symKeys()) |sp| {
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, sp.key);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

// ---------------------------------------------------------------- Reflect.getPrototypeOf ---

pub fn nativeReflectGetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeNull(arena);
    const obj = args[0].toPtr().object;
    if (obj.proto) |p| return val_mod.makeObject(arena, p);
    return val_mod.makeNull(arena);
}

// ---------------------------------------------------------------- Reflect.defineProperty ---

pub fn nativeReflectDefineProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 1 or !isObj(args[0])) return val_mod.makeBool(arena, false);
    if (args.len < 3 or !isObj(args[2])) return val_mod.makeBool(arena, false);

    const target_obj = args[0].toPtr().object;
    const key_arg = if (args.len > 1) args[1] else Value{};

    // Symbol-keyed [[DefineOwnProperty]]: ordinary symbol property (data or accessor).
    if (isSym(key_arg)) {
        const sdesc = args[2].toPtr().object;
        if (sdesc.hasOwn("get") or sdesc.hasOwn("set")) {
            const getter: ?Value = if (sdesc.hasOwn("get")) sdesc.getOwn("get") else null;
            const setter: ?Value = if (sdesc.hasOwn("set")) sdesc.getOwn("set") else null;
            const holder = try makeAccessorHolder(arena, getter, setter);
            const sok = try target_obj.defineOwnAccessorSym(key_arg, holder, .{
                .enumerable = descTruthy(sdesc.getOwn("enumerable")),
                .configurable = descTruthy(sdesc.getOwn("configurable")),
            });
            return val_mod.makeBool(arena, sok);
        }
        const sval = sdesc.getOwn("value") orelse Value{};
        const sok = try target_obj.defineOwnDataSym(key_arg, sval, .{
            .writable = descTruthy(sdesc.getOwn("writable")),
            .enumerable = descTruthy(sdesc.getOwn("enumerable")),
            .configurable = descTruthy(sdesc.getOwn("configurable")),
        });
        return val_mod.makeBool(arena, sok);
    }

    const k = (try keyStr(arena, key_arg)) orelse return val_mod.makeBool(arena, false);
    const desc = args[2].toPtr().object;

    if (desc.hasOwn("get") or desc.hasOwn("set")) {
        const getter: ?Value = if (desc.hasOwn("get")) desc.getOwn("get") else null;
        const setter: ?Value = if (desc.hasOwn("set")) desc.getOwn("set") else null;
        const holder = try makeAccessorHolder(arena, getter, setter);
        const attr = PropAttr{
            .is_accessor = true,
            .enumerable = descTruthy(desc.getOwn("enumerable")),
            .configurable = descTruthy(desc.getOwn("configurable")),
        };
        const ok = try target_obj.defineOwnAccessor(k, holder, attr);
        return val_mod.makeBool(arena, ok);
    }

    const value = desc.getOwn("value") orelse Value{};
    const attr = PropAttr{
        .writable = descTruthy(desc.getOwn("writable")),
        .enumerable = descTruthy(desc.getOwn("enumerable")),
        .configurable = descTruthy(desc.getOwn("configurable")),
    };
    const ok = try target_obj.defineOwnData(k, value, attr);
    return val_mod.makeBool(arena, ok);
}

// ---------------------------------------------------------------- Reflect.getOwnPropertyDescriptor ---

pub fn nativeReflectGetOwnPropertyDescriptor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeUndefined(arena);
    const obj = args[0].toPtr().object;

    if (args.len < 2) return val_mod.makeUndefined(arena);
    const key_arg = args[1];

    // Symbol keys: return undefined (not supported).
    if (isSym(key_arg)) return val_mod.makeUndefined(arena);

    const k = (try keyStr(arena, key_arg)) orelse return val_mod.makeUndefined(arena);

    const a = obj.ownAttr(k) orelse return val_mod.makeUndefined(arena);

    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;

    if (obj.ownAccessorHolder(k)) |holder_val| {
        const desc = try JsObject.create(arena, obj_proto);
        const hobj = holder_val.toPtr().object;
        try desc.set("get", hobj.getOwn("get") orelse try val_mod.makeUndefined(arena));
        try desc.set("set", hobj.getOwn("set") orelse try val_mod.makeUndefined(arena));
        try desc.set("enumerable", try val_mod.makeBool(arena, a.enumerable));
        try desc.set("configurable", try val_mod.makeBool(arena, a.configurable));
        return val_mod.makeObject(arena, desc);
    }

    const v = obj.getOwn(k) orelse try val_mod.makeUndefined(arena);
    const desc = try JsObject.create(arena, obj_proto);
    try desc.set("value", v);
    try desc.set("writable", try val_mod.makeBool(arena, a.writable));
    try desc.set("enumerable", try val_mod.makeBool(arena, a.enumerable));
    try desc.set("configurable", try val_mod.makeBool(arena, a.configurable));
    return val_mod.makeObject(arena, desc);
}

// ---------------------------------------------------------------- Reflect.isExtensible ---

pub fn nativeReflectIsExtensible(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObj(args[0])) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, args[0].toPtr().object.extensible);
}

// ---------------------------------------------------------------- Reflect.preventExtensions ---

pub fn nativeReflectPreventExtensions(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len > 0 and isObj(args[0])) {
        args[0].toPtr().object.preventExtensionsSelf();
    }
    return val_mod.makeBool(arena, true);
}

// ---------------------------------------------------------------- Reflect.apply ---

pub fn nativeReflectApply(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target = if (args.len > 0) args[0] else Value{};
    const this_arg = if (args.len > 1) args[1] else Value{};
    const args_list = if (args.len > 2) args[2] else Value{};

    // Unpack argsList if it is an array object.
    var call_args: []Value = &[_]Value{};
    if (args_list.bits != 0 and isObj(args_list)) {
        const arr = args_list.toPtr().object;
        if (arr.is_array) {
            const len = arr.getArrayLength();
            call_args = try arena.alloc(Value, len);
            for (0..len) |i| {
                const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                call_args[i] = arr.get(idx_key) orelse Value{};
            }
        } else {
            // Non-array object with numeric length or just treat as empty.
            // If it has a "length" property, treat as array-like.
            if (arr.getOwn("length")) |len_val| {
                if (len_val.bits != 0) {
                    const len_f = len_val.toF64();
                    if (!std.math.isNan(len_f) and len_f >= 0) {
                        const len: u32 = @intFromFloat(len_f);
                        call_args = try arena.alloc(Value, len);
                        for (0..len) |i| {
                            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                            call_args[i] = arr.getOwn(idx_key) orelse Value{};
                        }
                    }
                }
            }
        }
    }

    return fp.invokeCallback(arena, this_arg, target, call_args);
}

// ---------------------------------------------------------------- Reflect.construct ---

/// IsConstructor(v): true iff `v` has a [[Construct]] internal method.
/// Bare native_function values are built-in *methods* (Math.max, etc.) and are
/// NOT constructors. Built-in constructors are JsObjects with a `__call__` slot;
/// user functions (bc_function) construct; bound/proxy mirror their target.
fn isConstructorVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => true,
        .native_function => false,
        .object => |o| o.get("__call__") != null or
            o.internal_kind == .bound_function or
            o.internal_kind == .proxy,
        else => false,
    };
}

fn throwTypeErrorReflect(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.error_proto_TypeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

pub fn nativeReflectConstruct(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    if (args.len < 1) return val_mod.makeUndefined(arena);
    const target = args[0];
    // Reflect.construct(target, argsList[, newTarget]):
    // 1. If IsConstructor(target) is false, throw a TypeError.
    if (!isConstructorVal(target)) return throwTypeErrorReflect(arena, "Reflect.construct target is not a constructor");

    // Unpack argsList (second argument, array-like).
    var arg_list: []Value = &[_]Value{};
    if (args.len >= 2 and args[1].bits != 0 and isObj(args[1])) {
        const arr = args[1].toPtr().object;
        if (arr.is_array) {
            const n = arr.getArrayLength();
            if (n > 0) {
                arg_list = try arena.alloc(Value, n);
                for (0..n) |i| {
                    const idx = try std.fmt.allocPrint(arena, "{d}", .{i});
                    arg_list[i] = arr.get(idx) orelse try val_mod.makeUndefined(arena);
                }
            }
        } else {
            // Array-like with length property.
            if (arr.getOwn("length")) |len_val| {
                if (len_val.bits != 0) {
                    const len_f = len_val.toF64();
                    if (!std.math.isNan(len_f) and len_f >= 0) {
                        const n: u32 = @intFromFloat(len_f);
                        if (n > 0) {
                            arg_list = try arena.alloc(Value, n);
                            for (0..n) |i| {
                                const idx = try std.fmt.allocPrint(arena, "{d}", .{i});
                                arg_list[i] = arr.getOwn(idx) orelse try val_mod.makeUndefined(arena);
                            }
                        }
                    }
                }
            }
        }
    }

    const ctx = realm_mod.active_context orelse {
        realm_mod.pending_exception = try val_mod.makeString(arena, "no active context");
        return error.JsException;
    };
    // Optional 3rd arg newTarget supplies [[Prototype]] via GetPrototypeFromConstructor.
    // 2. If newTarget is present and IsConstructor(newTarget) is false, throw a TypeError.
    const new_target: Value = if (args.len >= 3 and args[2].bits != 0) blk: {
        if (!isConstructorVal(args[2])) return throwTypeErrorReflect(arena, "Reflect.construct newTarget is not a constructor");
        break :blk args[2];
    } else target;
    return ctx.constructNewTarget(arena, target, arg_list, new_target);
}
