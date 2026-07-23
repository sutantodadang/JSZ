//! Phase 13: AbstractOperation ToPrimitive (ES2015 7.1.1) with `Symbol.toPrimitive`
//! and OrdinaryToPrimitive (`valueOf`/`toString`) support.
//!
//! Implemented as a shared free function so both VM engines and the
//! `String()`/`Number()` builtins can reuse it without circular imports.
//! Calls back into user JS via `function_proto.invokeCallback`, which routes
//! through the active context.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const function_proto = @import("function_proto.zig");

pub const Hint = enum { number, string, default };

/// True for ECMAScript primitive values (undefined, null, boolean, number,
/// string, symbol). Functions and objects are NOT primitive.
pub fn isPrimitive(v: Value) bool {
    if (v.bits == 0) return true; // undefined
    return switch (v.unbox()) {
        .undefined_, .null_, .boolean, .number, .string, .symbol, .bigint => true,
        else => false,
    };
}

/// True if `v` is an ordinary object (excluding callables, which are their own
/// value kinds here but are still objects as far as ECMAScript is concerned).
pub fn isObjectValue(v: Value) bool {
    return v.bits != 0 and v.unbox() == .object;
}

pub fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |obj| obj.is_callable_intrinsic or obj.internal_kind == .bound_function,
        else => false,
    };
}

/// Walk the prototype chain looking for a symbol-keyed own property.
fn getSymMethod(obj: *JsObject, sym: Value) ?Value {
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

fn makeTypeErrorVal(arena: std.mem.Allocator, msg: []const u8) !Value {
    // Proto = TypeError.prototype so `caught instanceof TypeError` holds.
    const proto = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto)
    else
        try JsObject.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}

/// ToPrimitive for the object case only.
///
/// Returns:
///   * `some(primitive)` when a user-defined conversion (`Symbol.toPrimitive`,
///     `valueOf`, or `toString`) yields a primitive value;
///   * `null` when `v` is already a primitive, or when `v` is an object with
///     no applicable user conversion — in which case the caller should fall
///     back to its existing default coercion (e.g. `"[object Object]"`).
///
/// Throws (`error.JsException` + sets `pending_exception`) when a
/// `Symbol.toPrimitive` hook returns a non-primitive.
pub fn toPrimitive(arena: std.mem.Allocator, v: Value, hint: Hint) anyerror!?Value {
    if (isPrimitive(v)) return null;
    // Functions are callable objects, but they are their own Value kinds here
    // (their props and Function.prototype live on a backing object reachable
    // only through the VM). Property lookups below therefore go through the
    // active context, which resolves both representations; the plain-object
    // fast paths are guarded on `is_obj`.
    const is_obj = isObjectValue(v);
    const obj: ?*JsObject = if (is_obj) v.toPtr().object else null;

    // 1. Exotic @@toPrimitive hook.
    if (realm_mod.active_sym_to_primitive) |sym| {
        // GetMethod is a real [[Get]], so an accessor-defined @@toPrimitive must
        // run its getter (and propagate a throw from it). Only without a context
        // to route through does this fall back to reading the raw slot.
        const hook: ?Value = if (realm_mod.active_context) |ctx|
            try ctx.getPropSym(arena, v, sym)
        else if (obj) |o|
            getSymMethod(o, sym)
        else
            null;
        if (hook) |method| {
            // GetMethod: a present @@toPrimitive that is undefined/null is
            // skipped; one that is neither but not callable throws a TypeError.
            const is_nullish = method.bits == 0 or switch (method.unbox()) {
                .undefined_, .null_ => true,
                else => false,
            };
            if (!is_nullish and !isCallable(method)) {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "@@toPrimitive is not a function");
                return error.JsException;
            }
            if (isCallable(method)) {
                const hint_str: []const u8 = switch (hint) {
                    .number => "number",
                    .string => "string",
                    .default => "default",
                };
                const hv = try val_mod.makeString(arena, hint_str);
                const res = try function_proto.invokeCallback(arena, v, method, &[_]Value{hv});
                if (isPrimitive(res)) return res;
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert object to primitive value");
                return error.JsException;
            }
        }
    }

    // 2. OrdinaryToPrimitive: method order depends on hint.
    return ordinaryToPrimitive(arena, v, hint == .string);
}

/// ES OrdinaryToPrimitive (7.1.1.1). `string_first` picks the "string" method
/// order (toString before valueOf). Returns the produced primitive, null when
/// neither method was callable (caller falls back to its default), or throws a
/// TypeError when a callable method ran but no primitive resulted. Exposed so
/// Date.prototype[@@toPrimitive] can invoke it without re-entering ToPrimitive's
/// @@toPrimitive dispatch (which would recurse infinitely).
pub fn ordinaryToPrimitive(arena: std.mem.Allocator, v: Value, string_first: bool) anyerror!?Value {
    const obj: ?*JsObject = if (isObjectValue(v)) v.toPtr().object else null;
    const names: [2][]const u8 = if (string_first)
        .{ "toString", "valueOf" }
    else
        .{ "valueOf", "toString" };
    var had_callable = false;
    for (names) |name| {
        // [[Get]](obj, name): fire accessor getters / proxy traps and walk the
        // prototype chain (a plain `obj.get` returns the raw accessor holder,
        // never invoking a `get valueOf(){…}`). Getter throws propagate.
        const method = if (realm_mod.active_context) |ctx|
            try ctx.getProp(arena, v, name)
        else if (obj) |o|
            (o.get(name) orelse continue)
        else
            // A function value with no active context: its methods live on the
            // VM-side backing object we cannot reach, so no hook applies.
            continue;
        if (!isCallable(method)) continue;
        had_callable = true;
        const res = try function_proto.invokeCallback(arena, v, method, &[_]Value{});
        if (isPrimitive(res)) return res;
    }

    // OrdinaryToPrimitive step 5 throws whenever no method yielded a primitive —
    // including `{valueOf: null, toString: null}`, where neither was callable at
    // all. Both lookups have to have been real [[Get]]s for that to be sound, so
    // the no-context case (a function value whose methods live on a VM-side
    // backing object we cannot reach from here) still falls back to the caller's
    // default instead.
    if (had_callable or (obj != null and realm_mod.active_context != null)) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert object to primitive value");
        return error.JsException;
    }

    // 3. No user-defined conversion applies; caller uses its default.
    return null;
}

/// ES 7.1.4 ToNumber, spec-faithful: runs `@@toPrimitive`/`valueOf`/`toString`
/// on objects and PROPAGATES throws, and rejects Symbol/BigInt with a TypeError
/// instead of silently yielding NaN (which `realm.toNumberValue` does).
pub fn toNumberThrowing(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    if (v.bits == 0) return std.math.nan(f64); // undefined
    switch (v.unbox()) {
        .symbol => {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert a Symbol value to a number");
            return error.JsException;
        },
        .bigint => {
            realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert a BigInt value to a number");
            return error.JsException;
        },
        .object, .function, .native_function, .bc_function => {
            // `null` here means the object exposes no callable valueOf/toString
            // at all, which ToPrimitive reports as a TypeError.
            const prim = (try toPrimitive(arena, v, .number)) orelse {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert object to primitive value");
                return error.JsException;
            };
            if (!isPrimitive(prim)) {
                realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot convert object to primitive value");
                return error.JsException;
            }
            return toNumberThrowing(arena, prim);
        },
        .boolean => |b| return if (b) 1 else 0,
        .number => |n| return n,
        .null_ => return 0,
        .undefined_ => return std.math.nan(f64),
        .string => |s| return val_mod.jsStringToNumber(s),
    }
}
