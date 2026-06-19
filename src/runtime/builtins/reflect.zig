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
const proxy_mod = @import("proxy.zig");
const namespace_mod = @import("namespace.zig");

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

    // M15: TypedArray integer-indexed exotic [[Get]]: valid index → element,
    // invalid canonical-numeric (non-integer/-0/OOB/detached) → undefined.
    if (target_obj.internal_kind == .typed_array) {
        if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
            const td = typed_array.getTd(target) orelse return val_mod.makeUndefined(arena);
            if (!typed_array.isValidIntegerIndex(td, idx_f)) return val_mod.makeUndefined(arena);
            return typed_array.taLoad(arena, td, @intFromFloat(idx_f));
        }
    }

    // M16: Module Namespace exotic [[Get]] — reads current value from backing exports.
    // Throws ReferenceError for uninitialized (TDZ) bindings.
    if (target_obj.internal_kind == .module_namespace) {
        if (namespace_mod.isTDZ(target_obj, k)) {
            return throwReferenceErrorReflect(arena, k);
        }
        const b = namespace_mod.backing(target_obj) orelse return val_mod.makeUndefined(arena);
        return b.get(k) orelse val_mod.makeUndefined(arena);
    }

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
        // M16: Module Namespace exotic [[Set]] always fails for symbol keys too.
        if (target_obj.internal_kind == .module_namespace) return val_mod.makeBool(arena, false);
        // OrdinarySet for a symbol key: honor accessor setters and the
        // [[Writable]] attribute (a non-writable own data prop → false).
        if (target_obj.getOwnSymEntry(key)) |sp| {
            if (sp.attr.is_accessor) {
                if (sp.value.bits != 0 and sp.value.isHeapPtr() and sp.value.toPtr().* == .object) {
                    const setter = sp.value.toPtr().object.getOwn("set") orelse return val_mod.makeBool(arena, false);
                    if (isCallable(setter)) {
                        _ = try fp.invokeCallback(arena, target, setter, &[_]Value{value});
                        return val_mod.makeBool(arena, true);
                    }
                }
                return val_mod.makeBool(arena, false);
            }
            if (!sp.attr.writable) return val_mod.makeBool(arena, false);
            try target_obj.setSymAttr(key, value, sp.attr);
            return val_mod.makeBool(arena, true);
        }
        try target_obj.setSym(key, value);
        return val_mod.makeBool(arena, true);
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeBool(arena, false);

    // M16: Module Namespace exotic [[Set]] always fails.
    if (target_obj.internal_kind == .module_namespace) return val_mod.makeBool(arena, false);

    // M15: TypedArray integer-indexed exotic [[Set]](P, V, Receiver).
    const receiver = if (args.len > 3) args[3] else target;
    if (target_obj.internal_kind == .typed_array) {
        if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
            const td = typed_array.getTd(target) orelse return val_mod.makeBool(arena, false);
            // If SameValue(O, Receiver): TypedArraySetElement (coerce + store).
            if (receiver.bits == target.bits) {
                try typed_array.setElementThrowing(arena, td, idx_f, value);
                return val_mod.makeBool(arena, true);
            }
            // Different receiver + invalid index → return true WITHOUT coercing V.
            if (!typed_array.isValidIntegerIndex(td, idx_f)) return val_mod.makeBool(arena, true);
            // Valid index + different receiver → OrdinarySet(O, P, V, Receiver):
            // the write lands on Receiver, not O.
            if (!isObj(receiver)) return val_mod.makeBool(arena, false);
            const robj = receiver.toPtr().object;
            if (robj.internal_kind == .typed_array) {
                const rtd = typed_array.getTd(receiver).?;
                if (!typed_array.isValidIntegerIndex(rtd, idx_f)) return val_mod.makeBool(arena, false);
                try typed_array.setElementThrowing(arena, rtd, idx_f, value);
                return val_mod.makeBool(arena, true);
            }
            // Plain object receiver → OrdinarySet(Receiver, P, V): validate the
            // receiver's own descriptor before CreateDataProperty. An own
            // accessor or non-writable own data property fails; a non-extensible
            // receiver lacking the own property cannot have it created.
            if (robj.resolveOwnSlot(k)) |slot| {
                const rattr = robj.attrAt(slot);
                if (rattr.is_accessor) return val_mod.makeBool(arena, false);
                if (!rattr.writable) return val_mod.makeBool(arena, false);
            } else if (!robj.extensible) {
                return val_mod.makeBool(arena, false);
            }
            try robj.set(k, value);
            return val_mod.makeBool(arena, true);
        }
    }

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
        // Non-writable data property → OrdinarySet fails (return false).
        if (!attr.writable) return val_mod.makeBool(arena, false);
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

    // M16: Module Namespace exotic [[HasProperty]] — string keys are exactly the
    // exported names (null prototype, no inherited keys).
    if (target_obj.internal_kind == .module_namespace) {
        return val_mod.makeBool(arena, @import("namespace.zig").hasExport(target_obj, k));
    }

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
        // A Proxy anywhere in the chain (including the root) has its own
        // [[HasProperty]]: dispatch the `has` trap, else forward to the
        // target's [[HasProperty]] (which walks the target's own chain).
        if (o.internal_kind == .proxy) {
            const handler = proxy_mod.proxyHandler(o) orelse return val_mod.makeBool(arena, false);
            const target = proxy_mod.proxyTarget(o) orelse return val_mod.makeBool(arena, false);
            if (proxy_mod.trap(handler, "has")) |trap_fn| {
                const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key });
                return val_mod.makeBool(arena, descTruthy(res));
            }
            return nativeReflectHas(arena, .{}, &[_]Value{ target, key });
        }
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

    // M16: Module Namespace exotic [[Delete]] — export names are non-configurable.
    if (target_obj.internal_kind == .module_namespace) {
        return val_mod.makeBool(arena, !namespace_mod.hasExport(target_obj, k));
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

    // M16: Module Namespace exotic [[OwnPropertyKeys]] — sorted export names then symbol keys.
    if (obj.internal_kind == .module_namespace) {
        const names = try namespace_mod.sortedNames(arena, obj);
        var ni: u32 = 0;
        for (names) |name| {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            try arr.set(idx_key, try val_mod.makeString(arena, name));
            ni += 1;
        }
        for (obj.symKeys()) |sp| {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{ni});
            try arr.set(idx_key, sp.key);
            ni += 1;
        }
        arr.array_length = ni;
        return val_mod.makeObject(arena, arr);
    }

    // M15: TypedArray [[OwnPropertyKeys]] — integer indices first, then ordinary, then symbols.
    var ta_count: u32 = 0;
    if (isObj(args[0])) {
        const robj = args[0].toPtr().object;
        if (robj.internal_kind == .typed_array and robj.internal_slot != null) {
            const td = typed_array.getTd(args[0]).?;
            if (!typed_array.taIsOob(td)) {
                const cur_len = typed_array.taCurrentLen(td);
                var ti: u32 = 0;
                while (ti < cur_len) : (ti += 1) {
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
        // Preserve existing own symbol property's value when the descriptor omits
        // "value" (ES §9.1.6.3 OrdinaryDefineOwnProperty step 4 / §10.4.6.7).
        // Without this, a bare {} descriptor overwrites e.g. Symbol.toStringTag's
        // "Module" value with undefined.
        const sval = if (sdesc.hasOwn("value"))
            (sdesc.getOwn("value") orelse Value{})
        else if (target_obj.getOwnSym(key_arg)) |existing|
            existing
        else
            Value{};
        const sok = try target_obj.defineOwnDataSym(key_arg, sval, .{
            .writable = if (sdesc.hasOwn("writable")) descTruthy(sdesc.getOwn("writable")) else if (target_obj.getOwnSymEntry(key_arg)) |e| e.attr.writable else false,
            .enumerable = if (sdesc.hasOwn("enumerable")) descTruthy(sdesc.getOwn("enumerable")) else if (target_obj.getOwnSymEntry(key_arg)) |e| e.attr.enumerable else false,
            .configurable = if (sdesc.hasOwn("configurable")) descTruthy(sdesc.getOwn("configurable")) else if (target_obj.getOwnSymEntry(key_arg)) |e| e.attr.configurable else false,
        });
        return val_mod.makeBool(arena, sok);
    }

    const k = (try keyStr(arena, key_arg)) orelse return val_mod.makeBool(arena, false);
    const desc = args[2].toPtr().object;

    // M16: Module Namespace exotic [[DefineOwnProperty]] for string keys (§10.4.6.7).
    if (target_obj.internal_kind == .module_namespace) {
        if (!namespace_mod.hasExport(target_obj, k)) return val_mod.makeBool(arena, false);
        if (desc.hasOwn("get") or desc.hasOwn("set")) return val_mod.makeBool(arena, false);
        if (desc.hasOwn("configurable") and descTruthy(desc.getOwn("configurable"))) return val_mod.makeBool(arena, false);
        if (desc.hasOwn("enumerable") and !descTruthy(desc.getOwn("enumerable"))) return val_mod.makeBool(arena, false);
        if (desc.hasOwn("writable") and !descTruthy(desc.getOwn("writable"))) return val_mod.makeBool(arena, false);
        if (desc.hasOwn("value")) {
            const new_val = desc.getOwn("value") orelse Value{};
            const b = namespace_mod.backing(target_obj).?;
            const cur_val = b.get(k) orelse Value{};
            const same = if (new_val.bits == cur_val.bits)
                true
            else if (new_val.bits != 0 and cur_val.bits != 0 and
                new_val.unbox() == .number and cur_val.unbox() == .number)
                new_val.unbox().number == cur_val.unbox().number
            else
                false;
            if (!same) return val_mod.makeBool(arena, false);
        }
        return val_mod.makeBool(arena, true);
    }

    // M15: TypedArray [[DefineOwnProperty]] — integer-indexed exotic (ES2023
    // §10.4.5.3). Reflect returns false (no throw) on rejection.
    if (target_obj.internal_kind == .typed_array) {
        if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
            const td = typed_array.getTd(args[0]).?;
            if (!typed_array.isValidIntegerIndex(td, idx_f)) return val_mod.makeBool(arena, false);
            if (desc.hasOwn("configurable") and !descTruthy(desc.getOwn("configurable"))) return val_mod.makeBool(arena, false);
            if (desc.hasOwn("enumerable") and !descTruthy(desc.getOwn("enumerable"))) return val_mod.makeBool(arena, false);
            if (desc.hasOwn("get") or desc.hasOwn("set")) return val_mod.makeBool(arena, false);
            if (desc.hasOwn("writable") and !descTruthy(desc.getOwn("writable"))) return val_mod.makeBool(arena, false);
            if (desc.hasOwn("value")) try typed_array.setElementThrowing(arena, td, idx_f, desc.getOwn("value").?);
            return val_mod.makeBool(arena, true);
        }
        // Non-canonical key: fall through to ordinary defineOwnData.
    }

    if (desc.hasOwn("get") or desc.hasOwn("set")) {
        const getter: ?Value = if (desc.hasOwn("get")) desc.getOwn("get") else null;
        const setter: ?Value = if (desc.hasOwn("set")) desc.getOwn("set") else null;
        const holder = try makeAccessorHolder(arena, getter, setter);
        // Partial descriptor: fields the descriptor omits default to the
        // EXISTING own property's attributes (redefine) or to false (create) —
        // same merge as Object.defineProperty (object_methods.zig). Without
        // this, a bare {get} silently flips a configurable prop non-configurable.
        var prev_e = false;
        var prev_c = false;
        if (target_obj.findProperty(k)) |loc| {
            if (loc.holder == target_obj) {
                const a = loc.holder.attrAt(loc.slot);
                prev_e = a.enumerable;
                prev_c = a.configurable;
            }
        }
        const attr = PropAttr{
            .is_accessor = true,
            .enumerable = if (desc.hasOwn("enumerable")) descTruthy(desc.getOwn("enumerable")) else prev_e,
            .configurable = if (desc.hasOwn("configurable")) descTruthy(desc.getOwn("configurable")) else prev_c,
        };
        const ok = try target_obj.defineOwnAccessor(k, holder, attr);
        return val_mod.makeBool(arena, ok);
    }

    // Partial descriptor: fields the descriptor omits default to the EXISTING
    // own data property's attributes (redefine) or to false (create new).
    var cur_w = false;
    var cur_e = false;
    var cur_c = false;
    var has_own_data = false;
    var cur_val: ?Value = null;
    if (target_obj.findProperty(k)) |loc| {
        if (loc.holder == target_obj) {
            const a = loc.holder.attrAt(loc.slot);
            if (!a.is_accessor) {
                cur_w = a.writable;
                cur_e = a.enumerable;
                cur_c = a.configurable;
                cur_val = target_obj.getOwn(k);
                has_own_data = true;
            }
        }
    }
    const value = if (desc.hasOwn("value"))
        (desc.getOwn("value") orelse Value{})
    else if (has_own_data and cur_val != null)
        cur_val.?
    else
        Value{};
    const attr = PropAttr{
        .writable = if (desc.hasOwn("writable")) descTruthy(desc.getOwn("writable")) else cur_w,
        .enumerable = if (desc.hasOwn("enumerable")) descTruthy(desc.getOwn("enumerable")) else cur_e,
        .configurable = if (desc.hasOwn("configurable")) descTruthy(desc.getOwn("configurable")) else cur_c,
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

/// Throw a ReferenceError with a descriptive message (used by namespace TDZ).
fn throwReferenceErrorReflect(arena: std.mem.Allocator, name: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    const msg = try std.fmt.allocPrint(arena, "{s} is not defined", .{name});
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.error_proto_ReferenceError)
    else
        try JsObject.create(arena, realm_mod.error_proto_ReferenceError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "ReferenceError"));
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
