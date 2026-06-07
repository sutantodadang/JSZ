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
