// SPDX-License-Identifier: Apache-2.0
//! M16 Phase 4: the ShadowRealm API (TC39 Stage 3).
//!
//! A `ShadowRealm` instance owns an isolated global scope: a fresh global
//! Environment with its own `globalThis` object, distinct from the caller's, so
//! global-variable and `globalThis.*` mutations made by code evaluated inside it
//! never leak out (and vice versa). To keep the engine's single-active-realm
//! design intact, shadow realms *share* the caller's intrinsics (Object,
//! Function.prototype, Symbol, …): only the global scope is duplicated. This is
//! invisible to the conformance tests, which either compare identities within a
//! single realm or rely on primitives (which pass through unchanged).
//!
//! Crossing the realm boundary obeys the proposal's wrapping rules
//! (GetWrappedValue): primitives pass through; callables are wrapped in a fresh
//! "wrapped function" exotic (a `JsObject` with `internal_kind == .wrapped_function`
//! whose `[[Prototype]]` is %Function.prototype% and whose `internal_slot` boxes
//! the target callable); anything else throws a TypeError. A wrapped function,
//! when called, wraps its arguments into the target's realm, invokes the target
//! with `undefined` this, and wraps the result back — recursively.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const PropAttr = @import("../../object/object.zig").PropAttr;
const Environment = @import("../execution_context.zig").Environment;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const function_proto = @import("function_proto.zig");
const promise_mod = @import("promise.zig");
const proxy_mod = @import("proxy.zig");
const coercion = @import("coercion.zig");

/// Built-in data-property attributes for a function's `length`/`name`:
/// non-writable, non-enumerable, configurable.
const fn_prop_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };

fn heapOrArena(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
    if (realm_mod.active_heap) |h| return JsObject.createOnHeap(h, proto);
    return JsObject.create(arena, proto);
}

fn makeError(arena: std.mem.Allocator, proto: ?*JsObject, name: []const u8, msg: []const u8) !Value {
    const obj = try heapOrArena(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, name));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}

fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    realm_mod.pending_exception = try makeError(arena, realm_mod.error_proto_TypeError, "TypeError", msg);
    return error.JsException;
}

// ---------------------------------------------------------------- registration ---

/// Build %ShadowRealm.prototype%, the ShadowRealm constructor, and bind the
/// `ShadowRealm` global. `function_proto` is the realm's %Function.prototype%
/// (the constructor's and wrapped functions' [[Prototype]]); `object_proto` is
/// %Object.prototype% (the prototype of each shadow realm's `globalThis`).
pub fn register(arena: std.mem.Allocator, env: *Environment, object_proto: *JsObject, function_proto_obj: *JsObject) !void {
    const proto = try JsObject.create(arena, object_proto);
    _ = try proto.defineOwnData(
        "evaluate",
        try val_mod.makeNativeFunctionNamed(arena, nativeEvaluate, "evaluate", 1),
        intrinsics.method_attr,
    );
    _ = try proto.defineOwnData(
        "importValue",
        try val_mod.makeNativeFunctionNamed(arena, nativeImportValue, "importValue", 2),
        intrinsics.method_attr,
    );
    if (realm_mod.active_sym_to_string_tag) |tag| {
        try proto.setSymAttr(tag, try val_mod.makeString(arena, "ShadowRealm"), .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }

    // Constructor object: [[Prototype]] = %Function.prototype% (so
    // `Object.getPrototypeOf(ShadowRealm) === Function.prototype`).
    const ctor = try JsObject.create(arena, function_proto_obj);
    try ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeShadowRealmCtor));
    _ = try ctor.defineOwnData("prototype", try val_mod.makeObject(arena, proto), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), fn_prop_attr);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "ShadowRealm"), fn_prop_attr);

    const ctor_val = try val_mod.makeObject(arena, ctor);
    _ = try proto.defineOwnData("constructor", ctor_val, .{ .writable = true, .enumerable = false, .configurable = true });
    try env.define("ShadowRealm", ctor_val);
}

// ------------------------------------------------------------------- constructor ---

/// `new ShadowRealm()` — create a fresh isolated global scope. Calling without
/// `new` throws a TypeError.
fn nativeShadowRealmCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing)
        return throwTypeError(arena, "Constructor ShadowRealm requires 'new'");

    const caller_env = realm_mod.active_global_env orelse
        return throwTypeError(arena, "ShadowRealm: no active global environment");

    // Fresh global Environment sharing the caller's intrinsic bindings.
    const shadow_env = try Environment.init(arena, null);
    var it = caller_env.bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // globalThis/global get a fresh object below; per-realm module loader
        // state must not bleed across the boundary.
        if (std.mem.eql(u8, name, "globalThis") or std.mem.eql(u8, name, "global")) continue;
        try shadow_env.bindings.put(arena, name, entry.value_ptr.*);
    }

    // A fresh `globalThis` ordinary object mirroring the bindings (configurable,
    // writable, non-enumerable own data properties — matching the host global).
    const global_obj = try heapOrArena(arena, realm_mod.active_object_proto orelse null);
    var it2 = shadow_env.bindings.iterator();
    while (it2.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len >= 2 and name[0] == '_' and name[1] == '_') continue;
        _ = try global_obj.defineOwnData(name, entry.value_ptr.value, .{ .writable = true, .enumerable = false, .configurable = true });
    }
    const global_val = try val_mod.makeObject(arena, global_obj);
    try shadow_env.define("globalThis", global_val);
    try shadow_env.define("global", global_val);

    // Tag the instance (created by the constructor path with
    // [[Prototype]] = %ShadowRealm.prototype%) with its shadow env.
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const inst = this_val.toPtr().object;
        inst.internal_kind = .shadow_realm;
        inst.internal_slot = @ptrCast(shadow_env);
    }
    return this_val;
}

fn shadowEnvOf(this_val: Value) ?*Environment {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .shadow_realm) return null;
    const slot = obj.internal_slot orelse return null;
    return @ptrCast(@alignCast(slot));
}

// --------------------------------------------------------------------- evaluate ---

fn nativeEvaluate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const env = shadowEnvOf(this_val) orelse
        return throwTypeError(arena, "ShadowRealm.prototype.evaluate called on non-ShadowRealm object");
    const src = if (args.len > 0) args[0] else Value{};
    if (src.bits == 0 or src.unbox() != .string)
        return throwTypeError(arena, "ShadowRealm.prototype.evaluate expects a string");
    const source = src.toPtr().string;

    const ctx = realm_mod.active_context orelse
        return throwTypeError(arena, "ShadowRealm.prototype.evaluate: no active context");
    const result = ctx.shadowEval(arena, source, @ptrCast(env)) catch |e| {
        // A parse failure of the sourceText surfaces as a SyntaxError (the
        // pending exception is already a SyntaxError); any other abrupt
        // completion is wrapped into a TypeError in the caller's realm.
        if (e == error.ShadowParseError) return error.JsException;
        return throwTypeError(arena, "ShadowRealm evaluation threw");
    };
    return getWrappedValue(arena, result);
}

// ------------------------------------------------------------------ importValue ---

fn nativeImportValue(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const env = shadowEnvOf(this_val) orelse
        return throwTypeError(arena, "ShadowRealm.prototype.importValue called on non-ShadowRealm object");
    const specifier = if (args.len > 0) args[0] else Value{};
    // ? ToString(specifier) — fires the specifier's coercion hooks; an abrupt
    // completion (e.g. a throwing valueOf/toString/@@toPrimitive) propagates.
    const spec_str = try toStringValue(arena, specifier);

    // If Type(exportName) is not String, throw a TypeError — BEFORE coercing it
    // (so a throwing exportName.toString is never observed).
    const export_name = if (args.len > 1) args[1] else Value{};
    if (export_name.bits == 0 or export_name.unbox() != .string)
        return throwTypeError(arena, "ShadowRealm.prototype.importValue expects a string exportName");

    const promise = try promise_mod.newPendingPromise(arena);
    realmImportValue(arena, env, spec_str, export_name.toPtr().string, promise);
    return promise;
}

/// Best-effort RealmImportValue: resolve `specifier` against the shadow realm's
/// module registry, evaluate it, read `export_name` from the resulting namespace,
/// and settle `promise` with the wrapped value. Any failure rejects with a
/// TypeError (from the caller's realm).
fn realmImportValue(arena: std.mem.Allocator, env: *Environment, specifier: []const u8, export_name: []const u8, promise: Value) void {
    const ns = importNamespace(arena, env, specifier) catch {
        promise_mod.settleResult(arena, promise, makeError(arena, realm_mod.error_proto_TypeError, "TypeError", "ShadowRealm.importValue: module failed to load") catch Value{}, false);
        return;
    };
    if (ns.bits == 0 or ns.unbox() != .object) {
        promise_mod.settleResult(arena, promise, makeError(arena, realm_mod.error_proto_TypeError, "TypeError", "ShadowRealm.importValue: module has no namespace") catch Value{}, false);
        return;
    }
    const value = ns.toPtr().object.get(export_name) orelse {
        promise_mod.settleResult(arena, promise, makeError(arena, realm_mod.error_proto_TypeError, "TypeError", "ShadowRealm.importValue: export not found") catch Value{}, false);
        return;
    };
    const wrapped = getWrappedValue(arena, value) catch {
        promise_mod.settleResult(arena, promise, makeError(arena, realm_mod.error_proto_TypeError, "TypeError", "ShadowRealm.importValue: value not wrappable") catch Value{}, false);
        return;
    };
    promise_mod.settleResult(arena, promise, wrapped, true);
}

/// Evaluate the module named `specifier` in the shadow realm and return its
/// namespace (live exports object). Routes through the host `require()` resolver
/// over the realm's `__modules__` registry (the same path static/dynamic imports
/// use), so disk fixtures bundled for a module test are reachable.
fn importNamespace(arena: std.mem.Allocator, env: *Environment, specifier: []const u8) anyerror!Value {
    const saved = realm_mod.active_global_env;
    realm_mod.active_global_env = env;
    defer realm_mod.active_global_env = saved;
    const require_fn = env.lookup("require") catch return error.JsException;
    if (require_fn.bits == 0) return error.JsException;
    const spec_val = try val_mod.makeString(arena, specifier);
    return function_proto.invokeCallback(arena, Value{}, require_fn, &[_]Value{spec_val});
}

// ------------------------------------------------------------ boundary wrapping ---

/// True for a value that crosses the boundary as a wrapped function: any
/// callable, including a callable Proxy (whose target is, recursively, callable)
/// and an existing wrapped function.
fn isBoundaryCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |o| switch (o.internal_kind) {
            .bound_function, .wrapped_function => true,
            .proxy => if (proxy_mod.proxyTarget(o)) |t| isBoundaryCallable(t) else false,
            else => o.get("__call__") != null,
        },
        else => false,
    };
}

/// GetWrappedValue(value): a primitive passes through; a callable is wrapped in a
/// fresh wrapped-function exotic; anything else throws a TypeError.
fn getWrappedValue(arena: std.mem.Allocator, value: Value) anyerror!Value {
    if (coercion.isPrimitive(value)) return value;
    if (isBoundaryCallable(value)) return wrappedFunctionCreate(arena, value);
    return throwTypeError(arena, "ShadowRealm: cannot wrap a non-callable, non-primitive value across the realm boundary");
}

/// WrappedFunctionCreate(target): a callable exotic object whose [[Prototype]] is
/// %Function.prototype% and whose `name`/`length` are copied from the target
/// (CopyNameAndLength). A throwing `name`/`length` getter maps to a TypeError.
fn wrappedFunctionCreate(arena: std.mem.Allocator, target: Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse
        return throwTypeError(arena, "ShadowRealm: no active context");

    // CopyNameAndLength step 3: HasOwnProperty(Target, "length") then "name" —
    // both invoke the target's [[GetOwnProperty]]. For a callable Proxy this fires
    // its `getOwnPropertyDescriptor` trap, whose abrupt completion maps to a
    // TypeError. (For ordinary objects [[Get]] below already covers the lookup.)
    if (target.bits != 0 and target.unbox() == .object and target.toPtr().object.internal_kind == .proxy) {
        const pobj = target.toPtr().object;
        const len_key = try val_mod.makeString(arena, "length");
        _ = proxy_mod.proxyGetOwnPropertyDescriptor(arena, pobj, len_key) catch
            return throwTypeError(arena, "ShadowRealm: wrapped function length descriptor threw");
        const name_key = try val_mod.makeString(arena, "name");
        _ = proxy_mod.proxyGetOwnPropertyDescriptor(arena, pobj, name_key) catch
            return throwTypeError(arena, "ShadowRealm: wrapped function name descriptor threw");
    }

    // CopyNameAndLength: read name/length via [[Get]] (fires getters/proxy traps).
    const name_v = ctx.getProp(arena, target, "name") catch
        return throwTypeError(arena, "ShadowRealm: wrapped function name getter threw");
    const name_str: []const u8 = if (name_v.bits != 0 and name_v.unbox() == .string) name_v.toPtr().string else "";

    const len_v = ctx.getProp(arena, target, "length") catch
        return throwTypeError(arena, "ShadowRealm: wrapped function length getter threw");
    const length = clampLength(len_v);

    const wrapper = try heapOrArena(arena, realm_mod.active_function_proto orelse null);
    wrapper.internal_kind = .wrapped_function;
    const boxed = try arena.create(Value);
    boxed.* = target;
    wrapper.internal_slot = @ptrCast(boxed);
    _ = try wrapper.defineOwnData("length", try val_mod.makeNumber(arena, length), fn_prop_attr);
    _ = try wrapper.defineOwnData("name", try val_mod.makeString(arena, name_str), fn_prop_attr);
    // The callable slot: invisible to enumeration and not deletable.
    _ = try wrapper.defineOwnData("__call__", try val_mod.makeNativeFunction(arena, nativeWrappedCall), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    return val_mod.makeObject(arena, wrapper);
}

fn clampLength(len_v: Value) f64 {
    if (len_v.bits == 0 or len_v.unbox() != .number) return 0;
    const n = len_v.toF64();
    if (std.math.isPositiveInf(n)) return std.math.inf(f64);
    if (std.math.isNan(n) or n <= 0) return 0;
    return @trunc(n);
}

/// [[Call]] for a wrapped function: wrap each argument into the target's realm,
/// invoke the target with `undefined` this, then wrap the result back. Any abrupt
/// completion (a throwing target, or an unwrappable argument/result) becomes a
/// TypeError in the wrapped function's (caller's) realm.
fn nativeWrappedCall(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.internal_kind != .wrapped_function)
        return throwTypeError(arena, "wrapped function call on non-wrapped-function");
    const slot = this_val.toPtr().object.internal_slot orelse
        return throwTypeError(arena, "wrapped function has no target");
    const target: *Value = @ptrCast(@alignCast(slot));

    const wrapped_args = try arena.alloc(Value, args.len);
    for (args, 0..) |a, i| wrapped_args[i] = try getWrappedValue(arena, a);

    const ctx = realm_mod.active_context orelse
        return throwTypeError(arena, "ShadowRealm: no active context");
    const undef = try val_mod.makeUndefined(arena);
    const result = ctx.invokeJs(arena, undef, target.*, wrapped_args) catch
        return throwTypeError(arena, "wrapped function target threw");
    return getWrappedValue(arena, result);
}

// ----------------------------------------------------------------------- ToString ---

/// ? ToString(v): coerces an object via ToPrimitive(string) then stringifies the
/// primitive. Propagates a throwing coercion hook unchanged.
fn toStringValue(arena: std.mem.Allocator, v: Value) anyerror![]const u8 {
    var prim = v;
    if (coercion.isObjectValue(v)) {
        prim = (try coercion.toPrimitive(arena, v, .string)) orelse
            return "[object Object]";
    }
    if (prim.bits == 0) return "undefined";
    return switch (prim.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .string => |s| s,
        .number => |n| val_mod.formatNumber(arena, n),
        .symbol => throwTypeError(arena, "Cannot convert a Symbol value to a string"),
        else => "[object Object]",
    };
}
