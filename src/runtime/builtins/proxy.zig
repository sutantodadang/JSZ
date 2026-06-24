//! Phase 13: ECMAScript `Proxy` (ES2015 26.2).
//!
//! A proxy is a `JsObject` with `internal_kind == .proxy`. Its `[[ProxyTarget]]`
//! and `[[ProxyHandler]]` are stored as symbol-keyed own properties under two
//! private well-known symbols (see realm `active_sym_proxy_*`). They live in
//! `sym_props` rather than `internal_slot` specifically so the mark-sweep GC —
//! which traverses `sym_props` but NOT `internal_slot` — keeps them alive, and
//! so string enumeration never sees them.
//!
//! Trap dispatch for the `get`/`set` handlers happens in the VM property path
//! (`bc_vm` getProp/setProp/getPropSym/setPropSym); this module owns the
//! constructor and the target/handler accessors.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const function_proto = @import("function_proto.zig");

/// True if `v` is a Proxy exotic object.
pub fn isProxy(v: Value) bool {
    return v.bits != 0 and v.unbox() == .object and v.toPtr().object.internal_kind == .proxy;
}

/// `[[ProxyTarget]]` of a proxy object (null if unavailable).
pub fn proxyTarget(obj: *JsObject) ?Value {
    const sym = realm_mod.active_sym_proxy_target orelse return null;
    return obj.getOwnSym(sym);
}

/// `[[ProxyHandler]]` of a proxy object (null if unavailable).
pub fn proxyHandler(obj: *JsObject) ?Value {
    const sym = realm_mod.active_sym_proxy_handler orelse return null;
    return obj.getOwnSym(sym);
}

/// Fetch a callable trap named `name` from the handler object, or null.
pub fn trap(handler: Value, name: []const u8) ?Value {
    if (handler.bits == 0 or handler.unbox() != .object) return null;
    const t = handler.toPtr().object.get(name) orelse return null;
    if (t.bits == 0) return null;
    return switch (t.unbox()) {
        .function, .native_function, .bc_function => t,
        .object => |o| if (o.internal_kind == .bound_function) t else null,
        else => null,
    };
}

/// Invoke the proxy's `ownKeys` trap (or forward to the target when absent),
/// returning the resulting own-key Values (strings + symbols).
/// Returns null only when the proxy is malformed (missing target/handler).
pub fn proxyOwnKeys(arena: std.mem.Allocator, proxy_obj: *JsObject) anyerror!?[]Value {
    const handler = proxyHandler(proxy_obj) orelse return null;
    const target = proxyTarget(proxy_obj) orelse return null;
    var list = std.ArrayListUnmanaged(Value){};
    if (trap(handler, "ownKeys")) |trap_fn| {
        const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{target});
        if (res.bits != 0 and res.unbox() == .object) {
            const arr = res.toPtr().object;
            const n = arr.getArrayLength();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const k = try std.fmt.allocPrint(arena, "{d}", .{i});
                if (arr.get(k)) |ev| try list.append(arena, ev);
            }
        }
        return try list.toOwnedSlice(arena);
    }
    // No trap: forward to the target's own keys (string keys).
    if (target.bits != 0 and target.unbox() == .object) {
        const t = target.toPtr().object;
        for (t.ownKeys()) |k| try list.append(arena, try val_mod.makeString(arena, k));
    }
    return try list.toOwnedSlice(arena);
}

/// Invoke the proxy's `getOwnPropertyDescriptor` trap if present. Returns the
/// trap result (descriptor object or undefined), or null when no trap exists
/// (caller should forward to the target).
pub fn proxyGetOwnPropertyDescriptor(arena: std.mem.Allocator, proxy_obj: *JsObject, key: Value) anyerror!?Value {
    const handler = proxyHandler(proxy_obj) orelse return null;
    const target = proxyTarget(proxy_obj) orelse return null;
    const trap_fn = trap(handler, "getOwnPropertyDescriptor") orelse return null;
    return try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key });
}

fn isObjectLike(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .function, .bc_function, .native_function => true,
        else => false,
    };
}

fn makeTypeErrorVal(arena: std.mem.Allocator, msg: []const u8) !Value {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}

/// `new Proxy(target, handler)` — both must be objects.
pub fn nativeProxyCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 2 or !isObjectLike(args[0]) or !isObjectLike(args[1])) {
        realm_mod.pending_exception = try makeTypeErrorVal(arena, "Cannot create proxy with a non-object as target or handler");
        return error.JsException;
    }
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    obj.internal_kind = .proxy;
    if (realm_mod.active_sym_proxy_target) |s| try obj.setSym(s, args[0]);
    if (realm_mod.active_sym_proxy_handler) |s| try obj.setSym(s, args[1]);
    return val_mod.makeObject(arena, obj);
}

/// True if `proxy_obj` is a revoked Proxy (its `[[ProxyHandler]]`/`[[ProxyTarget]]`
/// have been cleared by the revoke function). Accessing a revoked proxy throws.
pub fn isRevoked(proxy_obj: *JsObject) bool {
    if (proxy_obj.internal_kind != .proxy) return false;
    return proxyHandler(proxy_obj) == null or proxyTarget(proxy_obj) == null;
}

/// `Proxy.revocable(target, handler)` — returns `{ proxy, revoke }` where calling
/// `revoke()` clears the proxy's target/handler so all further operations throw.
pub fn nativeProxyRevocable(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const proxy_val = try nativeProxyCtor(arena, Value{}, args);
    const proxy_obj = proxy_val.toPtr().object;

    // The revoke function: a callable object (no `prototype`, so the call paths
    // pass it as `this`) whose internal_slot back-references the proxy.
    const revoke = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_function_proto)
    else
        try JsObject.create(arena, realm_mod.active_function_proto);
    revoke.internal_slot = @ptrCast(proxy_obj);
    try revoke.set("__call__", try val_mod.makeNativeFunction(arena, nativeProxyRevoke));
    _ = try revoke.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try revoke.defineOwnData("name", try val_mod.makeString(arena, ""), .{ .writable = false, .enumerable = false, .configurable = true });

    const result = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try result.set("proxy", proxy_val);
    try result.set("revoke", try val_mod.makeObject(arena, revoke));
    return val_mod.makeObject(arena, result);
}

/// The revoke function's [[Call]]: clear the associated proxy's internal slots.
fn nativeProxyRevoke(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        if (this_val.toPtr().object.internal_slot) |slot| {
            const proxy_obj: *JsObject = @ptrCast(@alignCast(slot));
            if (realm_mod.active_sym_proxy_target) |s| _ = proxy_obj.deleteOwnSym(s);
            if (realm_mod.active_sym_proxy_handler) |s| _ = proxy_obj.deleteOwnSym(s);
        }
    }
    return val_mod.makeUndefined(arena);
}
