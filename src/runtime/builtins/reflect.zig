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
    try reflect_obj.set("get", try val_mod.makeNativeFunctionNamed(arena, nativeReflectGet, "get", 2));
    try reflect_obj.set("set", try val_mod.makeNativeFunctionNamed(arena, nativeReflectSet, "set", 3));
    try reflect_obj.set("has", try val_mod.makeNativeFunctionNamed(arena, nativeReflectHas, "has", 2));
    try reflect_obj.set("deleteProperty", try val_mod.makeNativeFunctionNamed(arena, nativeReflectDeleteProperty, "deleteProperty", 2));
    try reflect_obj.set("ownKeys", try val_mod.makeNativeFunctionNamed(arena, nativeReflectOwnKeys, "ownKeys", 1));
    try reflect_obj.set("getPrototypeOf", try val_mod.makeNativeFunctionNamed(arena, nativeReflectGetPrototypeOf, "getPrototypeOf", 1));
    try reflect_obj.set("setPrototypeOf", try val_mod.makeNativeFunctionNamed(arena, nativeReflectSetPrototypeOf, "setPrototypeOf", 2));
    try reflect_obj.set("defineProperty", try val_mod.makeNativeFunctionNamed(arena, nativeReflectDefineProperty, "defineProperty", 3));
    try reflect_obj.set("getOwnPropertyDescriptor", try val_mod.makeNativeFunctionNamed(arena, nativeReflectGetOwnPropertyDescriptor, "getOwnPropertyDescriptor", 2));
    try reflect_obj.set("isExtensible", try val_mod.makeNativeFunctionNamed(arena, nativeReflectIsExtensible, "isExtensible", 1));
    try reflect_obj.set("preventExtensions", try val_mod.makeNativeFunctionNamed(arena, nativeReflectPreventExtensions, "preventExtensions", 1));
    try reflect_obj.set("apply", try val_mod.makeNativeFunctionNamed(arena, nativeReflectApply, "apply", 3));
    try reflect_obj.set("construct", try val_mod.makeNativeFunctionNamed(arena, nativeReflectConstruct, "construct", 2));
    // Reflect[@@toStringTag] = "Reflect" (non-writable/enumerable, configurable),
    // so Object.prototype.toString.call(Reflect) yields "[object Reflect]".
    const realm_mod = @import("../realm.zig");
    if (realm_mod.active_sym_to_string_tag) |symv| {
        _ = try reflect_obj.defineOwnDataSym(symv, try val_mod.makeString(arena, "Reflect"), .{ .writable = false, .enumerable = false, .configurable = true });
    }
    try ctx.env.define("Reflect", try val_mod.makeObject(arena, reflect_obj));
}

// ---------------------------------------------------------------- helpers ---

fn isObj(v: Value) bool {
    if (v.bits == 0) return false;
    // Must be a real heap pointer; SMIs and immediates are not objects.
    if (!v.isHeapPtr()) return false;
    // Functions are objects too: `Reflect.apply(fn, thisArg, aFunction)` reads
    // `length`/indices off the arraylist, and Reflect.get/ownKeys/etc. accept any
    // callable. Only primitives (number/string/symbol/…) are non-objects.
    return switch (v.toPtr().*) {
        .object, .bc_function, .native_function => true,
        else => false,
    };
}

/// Type(v) is Object — includes callables (functions / class constructors),
/// which are Objects in the spec even though we tag them separately.
fn isObjectLike(v: Value) bool {
    if (v.bits == 0 or !v.isHeapPtr()) return false;
    return switch (v.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
}

/// The *JsObject a Reflect target denotes, including a function's lazily
/// materialized backing object (a callable IS an object). Null for primitives.
pub fn reflectTargetObjPub(arena: std.mem.Allocator, v: Value) anyerror!?*JsObject {
    return reflectTargetObj(arena, v);
}

fn reflectTargetObj(arena: std.mem.Allocator, v: Value) anyerror!?*JsObject {
    if (v.bits == 0) return null;
    return switch (v.unbox()) {
        .object => v.toPtr().object,
        .bc_function, .function => if (@import("../realm.zig").active_context) |ctx|
            (try ctx.backingObject(arena, v))
        else
            null,
        else => null,
    };
}

fn isSym(v: Value) bool {
    if (v.bits == 0) return false;
    if (!v.isHeapPtr()) return false;
    return v.toPtr().* == .symbol;
}

/// ToPropertyKey(v): an Object argument is coerced via ToPrimitive(string hint),
/// invoking user `Symbol.toPrimitive`/`valueOf`/`toString` — any abrupt
/// completion propagates. A Symbol result stays a Symbol; other primitives are
/// left as-is (the caller's `keyStr`/`isSym` handles the final ToString). This
/// is what makes Reflect's `return-abrupt-from-property-key` behavior correct.
fn toPropertyKey(arena: std.mem.Allocator, v: Value) anyerror!Value {
    const coercion = @import("coercion.zig");
    if (v.bits != 0 and v.unbox() == .object) {
        return (try coercion.toPrimitive(arena, v, .string)) orelse v;
    }
    return v;
}

/// CreateListFromArrayLike(obj) (spec 7.3.18) over String/Symbol/any elements:
/// `obj` must be an Object, `length` is ToLength(Get(obj,"length")) — the getter
/// runs and may throw — and each element is read with [[Get]]. Used by
/// Reflect.apply/construct to unpack the arguments list.
fn createListFromArrayLike(arena: std.mem.Allocator, obj: Value) anyerror![]Value {
    if (obj.bits == 0 or !isObj(obj))
        return throwTypeErrorReflect(arena, "CreateListFromArrayLike called on non-object");
    const realm_mod = @import("../realm.zig");
    const len_v = try nativeReflectGet(arena, .{}, &[_]Value{ obj, try val_mod.makeString(arena, "length") });
    const len = try realm_mod.toLengthValue(arena, len_v);
    const list = try arena.alloc(Value, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx_key = try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{i}));
        list[i] = try nativeReflectGet(arena, .{}, &[_]Value{ obj, idx_key });
    }
    return list;
}

/// OrdinarySetWithOwnDescriptor tail for a symbol key whose data write must land
/// on the Receiver (Receiver ≠ target): create/update the own symbol property on
/// the Receiver, or fail if it is a non-object / non-writable / accessor / a new
/// property on a non-extensible Receiver.
fn ordinarySetSymToReceiver(arena: std.mem.Allocator, receiver: Value, key: Value, value: Value) anyerror!Value {
    const robj = (try reflectTargetObj(arena, receiver)) orelse return val_mod.makeBool(arena, false);
    if (robj.getOwnSymEntry(key)) |sp| {
        if (sp.attr.is_accessor) return val_mod.makeBool(arena, false);
        if (!sp.attr.writable) return val_mod.makeBool(arena, false);
        try robj.setSymAttr(key, value, sp.attr);
        return val_mod.makeBool(arena, true);
    }
    if (!robj.extensible) return val_mod.makeBool(arena, false);
    try robj.setSym(key, value);
    return val_mod.makeBool(arena, true);
}

/// True when `k` is a canonical array index string (no leading zeros).
fn isArrayIndexKeyR(k: []const u8) bool {
    if (k.len == 0) return false;
    if (k.len > 1 and k[0] == '0') return false;
    for (k) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// True when `v` is a primitive (not an Object nor a callable). Reflect's
/// object-operation methods throw a TypeError for such a target.
fn isPrimitiveTarget(v: Value) bool {
    if (v.bits == 0) return true; // undefined
    return switch (v.unbox()) {
        .object, .bc_function, .native_function, .function => false,
        else => true,
    };
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
        .object => |o| if (o.is_callable_intrinsic) true else switch (o.internal_kind) {
            .bound_function => true,
            // A Proxy is callable iff its (possibly nested) target is callable.
            // A revoked proxy has no target → not callable.
            .proxy => if (proxy_mod.proxyTarget(o)) |t| isCallable(t) else false,
            else => false,
        },
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
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
    const target = args[0];
    const key = try toPropertyKey(arena, if (args.len > 1) args[1] else Value{});
    const receiver = if (args.len > 2) args[2] else target;

    // A callable target (class constructor / function) is an object; resolve its
    // lazily-materialized backing object so `Reflect.get(Ctor, "staticMethod")`
    // and super-property reads in static methods work.
    const target_obj = (try reflectTargetObj(arena, target)) orelse return val_mod.makeUndefined(arena);

    // Proxy [[Get]](P, Receiver): dispatch the `get` trap (with the get
    // invariant), else forward to the proxy target's [[Get]] preserving Receiver.
    if (target_obj.internal_kind == .proxy) {
        const handler = proxy_mod.proxyHandler(target_obj) orelse return proxy_mod.throwRevoked(arena);
        const t = proxy_mod.proxyTarget(target_obj) orelse return proxy_mod.throwRevoked(arena);
        const pkey = if (isSym(key)) key else try val_mod.makeString(arena, (try keyStr(arena, key)) orelse "undefined");
        if (try proxy_mod.getTrap(arena, handler, "get")) |trap_fn| {
            const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ t, pkey, receiver });
            try proxy_mod.proxyGetInvariant(arena, t, pkey, res);
            return res;
        }
        return nativeReflectGet(arena, .{}, &[_]Value{ t, pkey, receiver });
    }

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

    // Array exotic "length" is a synthetic own data property.
    if (target_obj.is_array and std.mem.eql(u8, k, "length"))
        return val_mod.makeNumber(arena, @floatFromInt(target_obj.getArrayLength()));

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
        try namespace_mod.triggerForStringKey(arena, target_obj, k); // import-defer: [[Get]]
        if (namespace_mod.isTDZ(target_obj, k)) {
            return throwReferenceErrorReflect(arena, k);
        }
        const b = namespace_mod.backing(target_obj) orelse return val_mod.makeUndefined(arena);
        return b.get(k) orelse val_mod.makeUndefined(arena);
    }

    // Dense array element: a present element is a plain data property; a hole
    // falls through so an inherited index (Array.prototype[i]) still resolves.
    if (target_obj.usesDense()) {
        if (JsObject.canonicalArrayIndex(k)) |_| {
            if (target_obj.getOwn(k)) |v| return v;
        }
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
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
    const target = args[0];
    const key = try toPropertyKey(arena, if (args.len > 1) args[1] else Value{});
    const value = if (args.len > 2) args[2] else Value{};
    const set_recv = if (args.len > 3) args[3] else target;

    // A callable target resolves to its backing object (`super.x = v` in a static
    // member has the superclass *constructor* as its property base).
    const target_obj = (try reflectTargetObj(arena, target)) orelse return val_mod.makeBool(arena, false);

    // Proxy [[Set]](P, V, Receiver): dispatch the `set` trap, else forward to the
    // proxy target's [[Set]] preserving Receiver (defaults to the proxy itself).
    if (target_obj.internal_kind == .proxy) {
        const set_receiver = if (args.len > 3) args[3] else target;
        const handler = proxy_mod.proxyHandler(target_obj) orelse return proxy_mod.throwRevoked(arena);
        const t = proxy_mod.proxyTarget(target_obj) orelse return proxy_mod.throwRevoked(arena);
        if (try proxy_mod.getTrap(arena, handler, "set")) |trap_fn| {
            const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ t, key, value, set_receiver });
            if (!val_mod.toBoolean(res)) return val_mod.makeBool(arena, false);
            try proxy_mod.proxySetInvariant(arena, t, key, value);
            return val_mod.makeBool(arena, true);
        }
        return nativeReflectSet(arena, .{}, &[_]Value{ t, key, value, set_receiver });
    }

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
            // OrdinarySetWithOwnDescriptor: a data write lands on the Receiver.
            if (set_recv.bits != target.bits) return try ordinarySetSymToReceiver(arena, set_recv, key, value);
            try target_obj.setSymAttr(key, value, sp.attr);
            return val_mod.makeBool(arena, true);
        }
        // No own property on the target: create on the Receiver.
        if (set_recv.bits != target.bits) return try ordinarySetSymToReceiver(arena, set_recv, key, value);
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
                        // OrdinarySetWithOwnDescriptor calls the setter with the
                        // Receiver as thisArg (not the holder), so `super.x = v`
                        // invokes the inherited setter bound to the instance.
                        _ = try fp.invokeCallback(arena, receiver, setter, &[_]Value{value});
                        return val_mod.makeBool(arena, true);
                    }
                }
            }
            return val_mod.makeBool(arena, false);
        }
        // Non-writable data property → OrdinarySet fails (return false).
        if (!attr.writable) return val_mod.makeBool(arena, false);
    }

    // OrdinarySetWithOwnDescriptor final step: a data binding (or a fresh one)
    // is created/updated on the *Receiver*, not on the target. When the receiver
    // differs from the target (e.g. `super.x = v`, where target is the home
    // prototype and receiver is the instance), consult the receiver's own
    // descriptor. A Module Namespace receiver runs its exotic [[GetOwnProperty]],
    // which throws ReferenceError for an uninitialized (TDZ) export.
    if (receiver.bits != target.bits) {
        // CreateDataProperty(Receiver, …) requires an Object Receiver — which a
        // callable is, via its backing object (`super.x = v` inside a static
        // member has the class constructor as Receiver).
        const robj = (try reflectTargetObj(arena, receiver)) orelse return val_mod.makeBool(arena, false);
        // A TypedArray receiver routes a canonical numeric index through its
        // exotic [[Set]] (TypedArraySetElement): ToNumber/ToBigInt(V) runs its
        // valueOf side effects BEFORE the bounds check, and an out-of-bounds
        // index is a silent no-op — never an ordinary property.
        if (robj.internal_kind == .typed_array) {
            if (typed_array.canonicalNumericIndexString(k)) |idx_f| {
                const rtd = typed_array.getTd(receiver).?;
                try typed_array.setElementThrowing(arena, rtd, idx_f, value);
                return val_mod.makeBool(arena, true);
            }
        }
        if (robj.internal_kind == .module_namespace) {
            // Receiver.[[GetOwnProperty]](P) (e.g. `super[k] = v` with a namespace
            // receiver) triggers import-defer evaluation before the TDZ check.
            try namespace_mod.triggerForStringKey(arena, robj, k);
            // Receiver.[[GetOwnProperty]](P): throws for a TDZ export.
            if (namespace_mod.isTDZ(robj, k)) {
                return throwReferenceErrorReflect(arena, k);
            }
            // An export's [[DefineOwnProperty]] (writable:false redefinition) and
            // a non-export create on the non-extensible namespace both fail.
            return val_mod.makeBool(arena, false);
        }
        if (robj.resolveOwnSlot(k)) |slot| {
            const rattr = robj.attrAt(slot);
            if (rattr.is_accessor) return val_mod.makeBool(arena, false);
            if (!rattr.writable) return val_mod.makeBool(arena, false);
            try robj.set(k, value);
            return val_mod.makeBool(arena, true);
        }
        if (!robj.extensible) return val_mod.makeBool(arena, false);
        try robj.set(k, value);
        return val_mod.makeBool(arena, true);
    }

    // Array exotic [[Set]] of the own "length": ArraySetLength (RangeError on an
    // invalid Uint32, TypeError for a BigInt/Symbol), matching `arr.length = v`.
    // Reached only for a direct write (Receiver is the target); a foreign
    // Receiver was handled above.
    if (target_obj.is_array and std.mem.eql(u8, k, "length")) {
        const ok = try @import("object_methods.zig").arraySetLengthThrowing(arena, target_obj, value);
        return val_mod.makeBool(arena, ok);
    }
    try target_obj.set(k, value);
    return val_mod.makeBool(arena, true);
}

// ---------------------------------------------------------------- Reflect.has ---

pub fn nativeReflectHas(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
    if (args.len == 0 or !isObjectLike(args[0])) return val_mod.makeBool(arena, false);
    const target_obj = (try reflectTargetObj(arena, args[0])) orelse return val_mod.makeBool(arena, false);
    const key = try toPropertyKey(arena, if (args.len > 1) args[1] else Value{});

    if (isSym(key)) {
        var depth: usize = 0;
        var cur: ?*JsObject = target_obj;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            // A Proxy anywhere in the chain has its own [[HasProperty]] — symbol
            // keys go through the `has` trap exactly like string keys do.
            if (o.internal_kind == .proxy) {
                const handler = proxy_mod.proxyHandler(o) orelse return proxy_mod.throwRevoked(arena);
                const target = proxy_mod.proxyTarget(o) orelse return proxy_mod.throwRevoked(arena);
                if (try proxy_mod.getTrap(arena, handler, "has")) |trap_fn| {
                    const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key });
                    return val_mod.makeBool(arena, descTruthy(res));
                }
                return nativeReflectHas(arena, .{}, &[_]Value{ target, key });
            }
            if (o.getOwnSym(key) != null) return val_mod.makeBool(arena, true);
            cur = o.proto;
        }
        return val_mod.makeBool(arena, false);
    }

    const k = (try keyStr(arena, key)) orelse return val_mod.makeBool(arena, false);

    // Internal slots ([[PrimitiveValue]], …) are spec internal state, never a
    // property visible to [[HasProperty]].
    if (JsObject.isInternalSlotKey(k)) return val_mod.makeBool(arena, false);

    // M16: Module Namespace exotic [[HasProperty]] — string keys are exactly the
    // exported names (null prototype, no inherited keys).
    if (target_obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerForStringKey(arena, target_obj, k); // import-defer: [[HasProperty]]
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
            const handler = proxy_mod.proxyHandler(o) orelse return proxy_mod.throwRevoked(arena);
            const target = proxy_mod.proxyTarget(o) orelse return proxy_mod.throwRevoked(arena);
            if (try proxy_mod.getTrap(arena, handler, "has")) |trap_fn| {
                const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key });
                return val_mod.makeBool(arena, descTruthy(res));
            }
            return nativeReflectHas(arena, .{}, &[_]Value{ target, key });
        }
        // `hasOwn` (not `resolveOwnSlot`) so dense array elements — which live
        // outside the shape's key_to_slot map — are found; `length` on an Array
        // exotic is likewise not a shape key.
        if (o.hasOwn(k) or (o.is_array and std.mem.eql(u8, k, "length")))
            return val_mod.makeBool(arena, true);
        cur = o.proto;
    }
    return val_mod.makeBool(arena, false);
}

// ---------------------------------------------------------------- Reflect.deleteProperty ---

pub fn nativeReflectDeleteProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
    if (args.len == 0 or !isObjectLike(args[0])) return val_mod.makeBool(arena, false);
    const target_obj = (try reflectTargetObj(arena, args[0])) orelse return val_mod.makeBool(arena, false);
    const key = try toPropertyKey(arena, if (args.len > 1) args[1] else Value{});

    // Proxy [[Delete]](P): dispatch the `deleteProperty` trap (with invariant),
    // else forward to the proxy target's [[Delete]].
    if (target_obj.internal_kind == .proxy) {
        const handler = proxy_mod.proxyHandler(target_obj) orelse return proxy_mod.throwRevoked(arena);
        const t = proxy_mod.proxyTarget(target_obj) orelse return proxy_mod.throwRevoked(arena);
        const pkey = if (isSym(key)) key else try val_mod.makeString(arena, (try keyStr(arena, key)) orelse "undefined");
        if (try proxy_mod.getTrap(arena, handler, "deleteProperty")) |trap_fn| {
            const res = try fp.invokeCallback(arena, handler, trap_fn, &[_]Value{ t, pkey });
            if (!val_mod.toBoolean(res)) return val_mod.makeBool(arena, false);
            try proxy_mod.proxyReportAbsentInvariant(arena, t, pkey);
            return val_mod.makeBool(arena, true);
        }
        return nativeReflectDeleteProperty(arena, .{}, &[_]Value{ t, pkey });
    }

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
        try namespace_mod.triggerForStringKey(arena, target_obj, k); // import-defer: [[Delete]]
        return val_mod.makeBool(arena, !namespace_mod.hasExport(target_obj, k));
    }

    // Array "length" is a non-configurable own property: cannot be deleted.
    if (target_obj.is_array and std.mem.eql(u8, k, "length")) return val_mod.makeBool(arena, false);

    return val_mod.makeBool(arena, try target_obj.deleteOwn(k));
}

// ---------------------------------------------------------------- Reflect.ownKeys ---

pub fn nativeReflectOwnKeys(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
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
    const obj = (try reflectTargetObj(arena, args[0])) orelse {
        return val_mod.makeObject(arena, arr);
    };

    // Proxy [[OwnPropertyKeys]]: dispatch the `ownKeys` trap (all keys, strings
    // and symbols) or forward to the target — never the proxy's own slots.
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyOwnKeys(arena, obj)) |keys| {
            var pi: u32 = 0;
            for (keys) |kv| {
                const idx_key = try std.fmt.allocPrint(arena, "{d}", .{pi});
                try arr.set(idx_key, kv);
                pi += 1;
            }
            arr.array_length = pi;
        }
        return val_mod.makeObject(arena, arr);
    }

    // M16: Module Namespace exotic [[OwnPropertyKeys]] — sorted export names then symbol keys.
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerAll(arena, obj); // import-defer: [[OwnPropertyKeys]]
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
    // Array [[OwnPropertyKeys]]: integer-index keys, then the synthetic "length"
    // (a non-index own data property not present in `ownKeys()`), then remaining
    // non-index string keys — matching OrdinaryOwnPropertyKeys ordering.
    var array_length_emitted = false;
    for (obj.ownKeys()) |k| {
        if (obj.is_array and !array_length_emitted and !isArrayIndexKeyR(k)) {
            const lk = try std.fmt.allocPrint(arena, "{d}", .{i});
            try arr.set(lk, try val_mod.makeString(arena, "length"));
            i += 1;
            array_length_emitted = true;
        }
        if (JsObject.isInternalSlotKey(k)) continue; // internal slots ([[PrimitiveValue]], …)
        const key_val = try val_mod.makeString(arena, k);
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, key_val);
        i += 1;
    }
    if (obj.is_array and !array_length_emitted) {
        const lk = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(lk, try val_mod.makeString(arena, "length"));
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
    if (args.len == 0 or !isObjectLike(args[0]))
        return throwTypeErrorReflect(arena, "Reflect.getPrototypeOf called on non-object");
    // A callable (function/class ctor) is an Object: its [[Prototype]] lives on a
    // native default (%Function.prototype%) or a lazily-created backing object.
    switch (args[0].unbox()) {
        .native_function => {
            if (@import("../realm.zig").active_function_proto) |fproto| return val_mod.makeObject(arena, fproto);
            return val_mod.makeNull(arena);
        },
        .bc_function, .function => {
            if (@import("../realm.zig").active_context) |ctx| {
                if (try ctx.backingObject(arena, args[0])) |bo| {
                    if (bo.proto) |p| return val_mod.makeObjectOrFunction(arena, p);
                }
            }
            if (@import("../realm.zig").active_function_proto) |fproto| return val_mod.makeObject(arena, fproto);
            return val_mod.makeNull(arena);
        },
        else => {},
    }
    const obj = args[0].toPtr().object;
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetPrototypeOf(arena, obj)) |p| return p;
        if (proxy_mod.proxyTarget(obj)) |t| return nativeReflectGetPrototypeOf(arena, Value{}, &[_]Value{t});
    }
    // Same [[GetPrototypeOf]] as Object.getPrototypeOf: a function stored as a
    // prototype must come back as that function, not as its backing object.
    if (obj.proto) |p| return val_mod.makeObjectOrFunction(arena, p);
    return val_mod.makeNull(arena);
}

// ---------------------------------------------------------------- Reflect.setPrototypeOf ---

pub fn nativeReflectSetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObjectLike(args[0]))
        return throwTypeErrorReflect(arena, "Reflect.setPrototypeOf called on non-object");
    const obj = (try reflectTargetObj(arena, args[0])) orelse
        return throwTypeErrorReflect(arena, "Reflect.setPrototypeOf called on non-object");
    const new_proto: ?*JsObject = blk: {
        if (args.len < 2 or args[1].bits == 0) break :blk null;
        break :blk switch (args[1].unbox()) {
            .object => |o| o,
            .null_ => null,
            else => return throwTypeErrorReflect(arena, "Reflect.setPrototypeOf proto must be an object or null"),
        };
    };
    // Module Namespace [[SetPrototypeOf]] is SetImmutablePrototype: succeeds (true)
    // only when the requested prototype equals the current one (null); any other
    // target fails (false). It does NOT trigger import-defer evaluation.
    if (obj.internal_kind == .module_namespace)
        return val_mod.makeBool(arena, new_proto == null);
    if (obj.internal_kind == .proxy) {
        const proto_val = if (new_proto) |p| try val_mod.makeObject(arena, p) else try val_mod.makeNull(arena);
        if (try proxy_mod.proxySetPrototypeOf(arena, obj, proto_val)) |ok| return val_mod.makeBool(arena, ok);
        if (proxy_mod.proxyTarget(obj)) |t| return nativeReflectSetPrototypeOf(arena, Value{}, &[_]Value{ t, if (new_proto) |p| try val_mod.makeObject(arena, p) else try val_mod.makeNull(arena) });
    }
    // OrdinarySetPrototypeOf (spec 10.1.2.1): a no-op when unchanged; fails on a
    // non-extensible target or when the new prototype chain cycles back to O.
    if (new_proto == obj.proto) return val_mod.makeBool(arena, true);
    // %Object.prototype% is an immutable prototype exotic object (§10.4.7.1).
    if (@import("../realm.zig").active_object_proto) |op| {
        if (obj == op) return val_mod.makeBool(arena, false);
    }
    if (!obj.extensible) return val_mod.makeBool(arena, false);
    var p = new_proto;
    var depth: usize = 0;
    while (p) |pp| {
        if (pp == obj) return val_mod.makeBool(arena, false); // prototype cycle
        if (pp.internal_kind == .proxy) break; // an exotic [[GetPrototypeOf]] stops the static walk
        p = pp.proto;
        depth += 1;
        if (depth > 100000) break;
    }
    obj.proto = new_proto;
    obj.setProtoBarrier(new_proto);
    return val_mod.makeBool(arena, true);
}

// ---------------------------------------------------------------- Reflect.defineProperty ---

pub fn nativeReflectDefineProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target_obj = (try reflectTargetObj(arena, if (args.len > 0) args[0] else Value{})) orelse
        return throwTypeErrorReflect(arena, "Reflect.defineProperty called on non-object");
    // Spec order: ToPropertyKey (step 2) runs before ToPropertyDescriptor (step 3),
    // so a throwing property-key coercion must propagate before the descriptor check.
    const key_arg = try toPropertyKey(arena, if (args.len > 1) args[1] else Value{});
    if (args.len < 3 or !isObj(args[2]))
        return throwTypeErrorReflect(arena, "Reflect.defineProperty descriptor must be an object");

    // Proxy [[DefineOwnProperty]]: dispatch the defineProperty trap.
    if (target_obj.internal_kind == .proxy) {
        const key: Value = if (isSym(key_arg)) key_arg else try val_mod.makeString(arena, try @import("../realm.zig").stringPrimitive(arena, key_arg));
        if (try proxy_mod.proxyDefineProperty(arena, target_obj, key, args[2])) |ok| return val_mod.makeBool(arena, ok);
        if (proxy_mod.proxyTarget(target_obj)) |t| return nativeReflectDefineProperty(arena, Value{}, &[_]Value{ t, key, args[2] });
    }

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
        // ES §10.1.6.3 ValidateAndApplyPropertyDescriptor step 4: a generic
        // descriptor (no fields at all) on an existing property is a no-op → true.
        // A generic descriptor on a non-existing property on a non-extensible
        // object → false (handled below via defineOwnDataSym).
        const is_generic = !sdesc.hasOwn("value") and !sdesc.hasOwn("writable") and
            !sdesc.hasOwn("enumerable") and !sdesc.hasOwn("configurable");
        if (is_generic and target_obj.hasOwnSym(key_arg)) return val_mod.makeBool(arena, true);
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
        try namespace_mod.triggerForStringKey(arena, target_obj, k); // import-defer: [[DefineOwnProperty]]
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

    // Array exotic [[DefineOwnProperty]] on "length" (ES §10.4.2.1 → ArraySetLength):
    // full ArraySetLength semantics. A genuine RangeError (invalid length) or a
    // BigInt/Symbol coercion still throws; every other rejection returns false.
    if (target_obj.is_array and std.mem.eql(u8, k, "length")) {
        const ok = try @import("object_methods.zig").arrayDefineLength(arena, target_obj, try val_mod.makeObject(arena, desc), desc);
        return val_mod.makeBool(arena, ok);
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
        if (target_obj.ownAttr(k)) |a| { // dense-aware own-property attrs
            prev_e = a.enumerable;
            prev_c = a.configurable;
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
    if (target_obj.ownAttr(k)) |a| { // dense-aware own-property attrs
        if (!a.is_accessor) {
            cur_w = a.writable;
            cur_e = a.enumerable;
            cur_c = a.configurable;
            cur_val = target_obj.getOwn(k);
            has_own_data = true;
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
    if (args.len == 0 or isPrimitiveTarget(args[0])) return throwTypeErrorReflect(arena, "Reflect target must be an object");
    // A function target is an ordinary object too: `length`/`name` (and, for a
    // bc closure, everything on its backing object) are own properties.
    // Object.getOwnPropertyDescriptor already synthesizes those, so share it
    // rather than duplicating the native-entry descriptor tables here.
    if (!isObj(args[0]))
        return @import("object_methods.zig").nativeObjectGetOwnPropertyDescriptor(arena, .{}, args);
    const obj = (try reflectTargetObj(arena, args[0])) orelse
        return @import("object_methods.zig").nativeObjectGetOwnPropertyDescriptor(arena, .{}, args);

    if (args.len < 2) return val_mod.makeUndefined(arena);
    const key_arg = try toPropertyKey(arena, args[1]);

    // Proxy [[GetOwnProperty]]: dispatch the trap (with invariants), else forward
    // to the target's [[GetOwnProperty]].
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetOwnPropertyDescriptor(arena, obj, key_arg)) |desc| return desc;
        if (proxy_mod.proxyTarget(obj)) |t| return nativeReflectGetOwnPropertyDescriptor(arena, .{}, &[_]Value{ t, key_arg });
        return val_mod.makeUndefined(arena);
    }

    const realm_mod = @import("../realm.zig");
    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;

    // Symbol-keyed own property: build the descriptor from sym_props.
    if (isSym(key_arg)) {
        const sym_entry = obj.getOwnSymEntry(key_arg) orelse return val_mod.makeUndefined(arena);
        const dsym = try JsObject.create(arena, obj_proto);
        if (sym_entry.attr.is_accessor and sym_entry.value.bits != 0 and sym_entry.value.unbox() == .object) {
            const hobj = sym_entry.value.toPtr().object;
            try dsym.set("get", hobj.getOwn("get") orelse try val_mod.makeUndefined(arena));
            try dsym.set("set", hobj.getOwn("set") orelse try val_mod.makeUndefined(arena));
        } else {
            try dsym.set("value", sym_entry.value);
            try dsym.set("writable", try val_mod.makeBool(arena, sym_entry.attr.writable));
        }
        try dsym.set("enumerable", try val_mod.makeBool(arena, sym_entry.attr.enumerable));
        try dsym.set("configurable", try val_mod.makeBool(arena, sym_entry.attr.configurable));
        return val_mod.makeObject(arena, dsym);
    }

    const k = (try keyStr(arena, key_arg)) orelse return val_mod.makeUndefined(arena);

    // Internal slots ([[PrimitiveValue]], …) are not own properties.
    if (JsObject.isInternalSlotKey(k)) return val_mod.makeUndefined(arena);

    // M16: Module Namespace exotic [[GetOwnProperty]] for a string key — an export
    // yields { value, writable:true, enumerable:true, configurable:false }; a
    // non-export yields undefined. import-defer: triggers evaluation first.
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerForStringKey(arena, obj, k);
        if (!namespace_mod.hasExport(obj, k)) return val_mod.makeUndefined(arena);
        if (namespace_mod.isTDZ(obj, k)) return throwReferenceErrorReflect(arena, k);
        const b = namespace_mod.backing(obj).?;
        const value = b.get(k) orelse try val_mod.makeUndefined(arena);
        const ndesc = try JsObject.create(arena, obj_proto);
        try ndesc.set("value", value);
        try ndesc.set("writable", try val_mod.makeBool(arena, true));
        try ndesc.set("enumerable", try val_mod.makeBool(arena, true));
        try ndesc.set("configurable", try val_mod.makeBool(arena, false));
        return val_mod.makeObject(arena, ndesc);
    }

    // Array exotic "length": synthetic own data property (writable unless the
    // array is non-extensible, non-enumerable, non-configurable).
    if (obj.is_array and std.mem.eql(u8, k, "length")) {
        const dlen = try JsObject.create(arena, obj_proto);
        try dlen.set("value", try val_mod.makeNumber(arena, @floatFromInt(obj.getArrayLength())));
        try dlen.set("writable", try val_mod.makeBool(arena, obj.extensible));
        try dlen.set("enumerable", try val_mod.makeBool(arena, false));
        try dlen.set("configurable", try val_mod.makeBool(arena, false));
        return val_mod.makeObject(arena, dlen);
    }

    const a = obj.ownAttr(k) orelse return val_mod.makeUndefined(arena);

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
    if (args.len == 0 or !isObjectLike(args[0]))
        return throwTypeErrorReflect(arena, "Reflect.isExtensible called on non-object");
    const obj = (try reflectTargetObj(arena, args[0])) orelse
        return throwTypeErrorReflect(arena, "Reflect.isExtensible called on non-object");
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyIsExtensible(arena, obj)) |b| return val_mod.makeBool(arena, b);
        if (proxy_mod.proxyTarget(obj)) |t| return nativeReflectIsExtensible(arena, Value{}, &[_]Value{t});
    }
    return val_mod.makeBool(arena, obj.extensible);
}

// ---------------------------------------------------------------- Reflect.preventExtensions ---

pub fn nativeReflectPreventExtensions(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or !isObjectLike(args[0]))
        return throwTypeErrorReflect(arena, "Reflect.preventExtensions called on non-object");
    const obj = (try reflectTargetObj(arena, args[0])) orelse
        return throwTypeErrorReflect(arena, "Reflect.preventExtensions called on non-object");
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyPreventExtensions(arena, obj)) |b| return val_mod.makeBool(arena, b);
        if (proxy_mod.proxyTarget(obj)) |t| return nativeReflectPreventExtensions(arena, Value{}, &[_]Value{t});
    }
    obj.preventExtensionsSelf();
    return val_mod.makeBool(arena, true);
}

// ---------------------------------------------------------------- Reflect.apply ---

pub fn nativeReflectApply(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target = if (args.len > 0) args[0] else Value{};
    const this_arg = if (args.len > 1) args[1] else Value{};
    const args_list = if (args.len > 2) args[2] else Value{};

    if (!isCallable(target)) return throwTypeErrorReflect(arena, "Reflect.apply target must be callable");
    const call_args = try createListFromArrayLike(arena, args_list);
    return fp.invokeCallback(arena, this_arg, target, call_args);
}

// ---------------------------------------------------------------- Reflect.construct ---

/// IsConstructor(v): true iff `v` has a [[Construct]] internal method.
/// Bare native_function values are built-in *methods* (Math.max, etc.) and are
/// NOT constructors. Built-in constructors are JsObjects with a `__call__` slot;
/// user functions (bc_function) construct; bound/proxy mirror their target.
pub fn isConstructorVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => |cl| cl.isConstructor(),
        .native_function => false,
        .object => |o| blk: {
            // A bound function is a constructor iff its target is (§10.4.1.2).
            if (o.internal_kind == .bound_function) {
                if (o.internal_slot) |slot| {
                    const bd: *fp.BoundData = @ptrCast(@alignCast(slot));
                    break :blk isConstructorVal(bd.target);
                }
                break :blk false;
            }
            // A Promise resolving function and a Proxy revoke function are callable
            // but not constructors.
            if (o.internal_kind == .promise_resolver or o.internal_kind == .proxy_revoke) break :blk false;
            // A proxy is a constructor iff its (non-revoked) target is (§10.5.14):
            // ProxyCreate only installs [[Construct]] when the target has one.
            if (o.internal_kind == .proxy) {
                if (proxy_mod.proxyTarget(o)) |t| break :blk isConstructorVal(t);
                break :blk false;
            }
            break :blk o.get("__call__") != null;
        },
        else => false,
    };
}

fn throwTypeErrorReflect(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.typeErrorProto())
    else
        try JsObject.create(arena, realm_mod.typeErrorProto());
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
        try JsObject.createOnHeap(heap, realm_mod.referenceErrorProto())
    else
        try JsObject.create(arena, realm_mod.referenceErrorProto());
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

    // Unpack argsList (second argument) via CreateListFromArrayLike: reads
    // "length" and each index through [[Get]], propagating any abrupt completion
    // and throwing a TypeError when the list is not an object.
    const arg_list: []Value = if (args.len >= 2)
        try createListFromArrayLike(arena, args[1])
    else
        &[_]Value{};

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
