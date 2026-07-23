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

/// GetMethod-style trap lookup (spec 10.5.x: `trap ← GetMethod(handler, name)`).
/// Returns the callable trap, `null` when the property is absent/undefined/null
/// (the caller must forward the operation to the target), or throws a TypeError
/// when the property is present but not callable.
pub fn getTrap(arena: std.mem.Allocator, handler: Value, name: []const u8) anyerror!?Value {
    if (handler.bits == 0 or handler.unbox() != .object) return null;
    const ho = handler.toPtr().object;
    // GetMethod uses [[Get]], so a handler that is ITSELF a Proxy must have its
    // own `get` trap consulted for the trap lookup. The raw shape walk below
    // would find nothing on such a handler and silently forward to the target.
    if (ho.internal_kind == .proxy) {
        if (realm_mod.active_context) |ctx| {
            const t = try ctx.getProp(arena, handler, name);
            if (t.bits == 0 or t.isNullish()) return null;
            if (!function_proto.isCallableFn(t)) return throwProxy(arena, "proxy handler trap is not a function");
            return t;
        }
    }
    // GetMethod uses [[Get]]: an accessor trap property must have its getter
    // invoked (side effects and abrupt throws propagate).
    const loc = ho.findProperty(name) orelse return null;
    const raw = if (loc.slot < loc.holder.slots.items.len) loc.holder.slots.items[loc.slot] else Value{};
    const t = blk: {
        if (loc.holder.attrAt(loc.slot).is_accessor) {
            var getter = Value{};
            if (raw.bits != 0 and raw.isHeapPtr() and raw.unbox() == .object)
                getter = raw.toPtr().object.getOwn("get") orelse Value{};
            if (getter.bits == 0 or getter.isNullish()) break :blk Value{}; // no getter → undefined
            break :blk try function_proto.invokeCallback(arena, handler, getter, &[_]Value{});
        }
        break :blk raw;
    };
    if (t.isNullish()) return null;
    if (!function_proto.isCallableFn(t)) return throwProxy(arena, "proxy handler trap is not a function");
    return t;
}

/// Raise the "proxy revoked" TypeError. Every proxy internal method must throw
/// when its `[[ProxyHandler]]`/`[[ProxyTarget]]` have been cleared by revoke().
pub fn throwRevoked(arena: std.mem.Allocator) anyerror {
    return throwProxy(arena, "Cannot perform operation on a proxy that has been revoked");
}

/// True if `v` is a valid property key (String or Symbol).
fn isPropertyKey(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .string, .symbol => true,
        else => false,
    };
}

/// Property-key equality: strings by content, symbols by identity.
fn propKeyEql(a: Value, b: Value) bool {
    if (a.bits == 0 or b.bits == 0) return false;
    const ta = a.unbox();
    const tb = b.unbox();
    if (ta == .symbol and tb == .symbol) return a.bits == b.bits;
    if (ta == .string and tb == .string) return std.mem.eql(u8, a.unbox().string, b.unbox().string);
    return false;
}

/// Collect an object's own property keys (strings, then symbols) as Values —
/// used to forward `[[OwnPropertyKeys]]` to a proxy target and to enforce the
/// ownKeys invariants. Recurses when the target is itself a proxy.
fn targetOwnKeyList(arena: std.mem.Allocator, target: Value) anyerror![]Value {
    var list = std.ArrayListUnmanaged(Value){};
    if (target.bits == 0 or target.unbox() != .object) return list.toOwnedSlice(arena);
    const t = target.toPtr().object;
    if (t.internal_kind == .proxy) {
        return (try proxyOwnKeys(arena, t)) orelse list.toOwnedSlice(arena);
    }
    // Arrays expose a synthetic "length" own key not present in `ownKeys()`.
    var length_emitted = false;
    for (t.ownKeys()) |k| {
        if (t.is_array and !length_emitted and !isArrayIndexKey(k)) {
            try list.append(arena, try val_mod.makeString(arena, "length"));
            length_emitted = true;
        }
        try list.append(arena, try val_mod.makeString(arena, k));
    }
    if (t.is_array and !length_emitted) try list.append(arena, try val_mod.makeString(arena, "length"));
    for (t.symKeys()) |sp| try list.append(arena, sp.key);
    return list.toOwnedSlice(arena);
}

fn isArrayIndexKey(k: []const u8) bool {
    if (k.len == 0) return false;
    for (k) |c| if (c < '0' or c > '9') return false;
    if (k.len > 1 and k[0] == '0') return false;
    return true;
}

/// Whether `key` is a non-configurable own property of a (non-proxy) target.
/// `present` reports whether the key exists on the target at all.
fn targetKeyConfig(target: Value, key: Value, present: *bool) bool {
    present.* = false;
    if (target.bits == 0 or target.unbox() != .object) return true;
    const t = target.toPtr().object;
    if (key.bits != 0 and key.unbox() == .symbol) {
        if (t.getOwnSymEntry(key)) |sp| {
            present.* = true;
            return sp.attr.configurable;
        }
        return true;
    }
    if (key.bits == 0 or key.unbox() != .string) return true;
    const ks = key.unbox().string;
    if (t.is_array and std.mem.eql(u8, ks, "length")) {
        present.* = true;
        return false; // array "length" is non-configurable
    }
    if (t.ownAttr(ks)) |a| {
        present.* = true;
        return a.configurable;
    }
    return true;
}

/// Shared invariant for the `has` (reports false) and `deleteProperty` (reports
/// true) traps: if the target has an own property for `key`, that property must
/// be configurable and the target must be extensible, else the trap result
/// contradicts the target. Best-effort: skips proxy targets.
pub fn proxyReportAbsentInvariant(arena: std.mem.Allocator, target: Value, key: Value) anyerror!void {
    if (target.bits == 0 or target.unbox() != .object) return;
    const t = target.toPtr().object;
    if (t.internal_kind == .proxy) return;
    var present = false;
    const configurable = targetKeyConfig(target, key, &present);
    if (!present) return;
    if (!configurable)
        return throwProxy(arena, "proxy cannot report a non-configurable own property as absent");
    if (!t.extensible)
        return throwProxy(arena, "proxy cannot report a property of a non-extensible target as absent");
}

/// Invoke the proxy's `ownKeys` trap (or forward to the target when absent),
/// returning the resulting own-key Values (strings + symbols). Enforces the
/// `[[OwnPropertyKeys]]` invariants (spec 10.5.11): the trap result must be a
/// list of unique property keys, must include every non-configurable own key of
/// the target, and — when the target is non-extensible — must match the target's
/// own keys exactly. Returns null only when the proxy is malformed.
pub fn proxyOwnKeys(arena: std.mem.Allocator, proxy_obj: *JsObject) anyerror!?[]Value {
    const handler = proxyHandler(proxy_obj) orelse return throwRevoked(arena);
    const target = proxyTarget(proxy_obj) orelse return throwRevoked(arena);
    const trap_fn = try getTrap(arena, handler, "ownKeys") orelse {
        // No trap: forward to the target's [[OwnPropertyKeys]].
        return try targetOwnKeyList(arena, target);
    };
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{target});
    // CreateListFromArrayLike(res, «String, Symbol»).
    if (res.bits == 0 or res.unbox() != .object)
        return throwProxy(arena, "proxy ownKeys trap must return an array-like object");
    const arr = res.toPtr().object;
    // CreateListFromArrayLike reads `length` and every index via [[Get]], firing
    // accessor getters / proxy traps on the trap result — observable per spec.
    const ctx = realm_mod.active_context;
    const len = if (arr.is_array) arr.getArrayLength() else blk: {
        const lv = if (ctx) |c| try c.getProp(arena, res, "length") else (arr.get("length") orelse val_mod.Value{});
        break :blk @as(u32, @intCast(try realm_mod.toLengthValue(arena, lv)));
    };
    var list = std.ArrayListUnmanaged(Value){};
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const k = try std.fmt.allocPrint(arena, "{d}", .{i});
        const ev = if (ctx) |c| try c.getProp(arena, res, k) else (arr.get(k) orelse val_mod.Value{});
        if (!isPropertyKey(ev))
            return throwProxy(arena, "proxy ownKeys trap result must contain only Strings and Symbols");
        // Duplicate entries are forbidden.
        for (list.items) |prev| {
            if (propKeyEql(prev, ev))
                return throwProxy(arena, "proxy ownKeys trap result must not contain duplicate keys");
        }
        try list.append(arena, ev);
    }

    // Invariant enforcement against the target's own keys (best-effort: skip when
    // the target is itself a proxy, whose descriptors we do not re-derive here).
    if (target.bits != 0 and target.unbox() == .object and target.toPtr().object.internal_kind != .proxy) {
        const t = target.toPtr().object;
        const extensible = t.extensible;
        const target_keys = try targetOwnKeyList(arena, target);
        // Track which trap-result keys remain unmatched.
        var unchecked = try std.ArrayListUnmanaged(bool).initCapacity(arena, list.items.len);
        for (list.items) |_| unchecked.appendAssumeCapacity(true);
        for (target_keys) |tk| {
            var present = false;
            const configurable = targetKeyConfig(target, tk, &present);
            if (!present) continue;
            const must_appear = (!configurable) or (!extensible);
            if (!must_appear) continue;
            var found = false;
            for (list.items, 0..) |rk, idx| {
                if (unchecked.items[idx] and propKeyEql(rk, tk)) {
                    unchecked.items[idx] = false;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (!configurable)
                    return throwProxy(arena, "proxy ownKeys trap must include all non-configurable target keys");
                return throwProxy(arena, "proxy ownKeys trap must include all target keys of a non-extensible target");
            }
        }
        if (!extensible) {
            for (unchecked.items) |u| {
                if (u) return throwProxy(arena, "proxy ownKeys trap must not add keys to a non-extensible target");
            }
        }
    }
    return try list.toOwnedSlice(arena);
}

/// SameValue for two JS Values (used by the [[Set]] invariant).
fn sameValueV(x: Value, y: Value) bool {
    if (x.bits == 0 and y.bits == 0) return true;
    if (x.bits == 0 or y.bits == 0) {
        // One is uninitialized (undefined). Treat matching undefined as equal.
        const a = if (x.bits == 0) true else x.unbox() == .undefined_;
        const b = if (y.bits == 0) true else y.unbox() == .undefined_;
        return a and b;
    }
    const xi = x.unbox();
    const yi = y.unbox();
    const Tag = std.meta.Tag(val_mod.JsValue);
    if (@as(Tag, xi) != @as(Tag, yi)) return false;
    return switch (xi) {
        .undefined_, .null_ => true,
        .boolean => |b| b == yi.boolean,
        .number => |n| blk: {
            const m = yi.number;
            if (std.math.isNan(n) and std.math.isNan(m)) break :blk true;
            if (n == 0 and m == 0) break :blk std.math.signbit(n) == std.math.signbit(m);
            break :blk n == m;
        },
        .string => |s| std.mem.eql(u8, s, yi.string),
        .bigint => val_mod.bigIntEql(x, y),
        .symbol => x.bits == y.bits,
        .object, .function, .bc_function, .native_function => x.bits == y.bits,
    };
}

/// [[Get]] invariant (spec 10.5.8 step 10): a `get` trap must return the exact
/// value of a non-configurable, non-writable own data property of the target,
/// and must return undefined for a non-configurable accessor with no getter.
/// Best-effort: skips proxy targets.
pub fn proxyGetInvariant(arena: std.mem.Allocator, target: Value, key: Value, trap_result: Value) anyerror!void {
    if (target.bits == 0 or target.unbox() != .object) return;
    if (target.toPtr().object.internal_kind == .proxy) return;
    const td = targetDescOf(target, key) orelse return;
    if (td.configurable) return;
    if (td.isData() and !td.writable) {
        if (!sameValueV(trap_result, td.value))
            return throwProxy(arena, "proxy get must report the exact value of a non-configurable, non-writable data property");
    } else if (td.isAccessor()) {
        const getter_undef = td.get.bits == 0 or td.get.isNullish();
        if (getter_undef and !(trap_result.bits == 0 or trap_result.unbox() == .undefined_))
            return throwProxy(arena, "proxy get must report undefined for a non-configurable accessor with no getter");
    }
}

/// [[Set]] invariant (spec 10.5.9 step 11): after a `set` trap returns truthy,
/// a non-configurable, non-writable own data property of the target may not be
/// changed to a different value, and a non-configurable own accessor property
/// with no setter may not be written. Best-effort: skips proxy targets.
pub fn proxySetInvariant(arena: std.mem.Allocator, target: Value, key: Value, value: Value) anyerror!void {
    if (target.bits == 0 or target.unbox() != .object) return;
    const t = target.toPtr().object;
    if (t.internal_kind == .proxy) return;
    var present = false;
    var is_accessor = false;
    var writable = true;
    var configurable = true;
    var data_value = Value{};
    var holder = Value{};
    if (key.bits != 0 and key.unbox() == .symbol) {
        if (t.getOwnSymEntry(key)) |sp| {
            present = true;
            is_accessor = sp.attr.is_accessor;
            writable = sp.attr.writable;
            configurable = sp.attr.configurable;
            if (is_accessor) holder = sp.value else data_value = sp.value;
        }
    } else if (key.bits != 0 and key.unbox() == .string) {
        const ks = key.unbox().string;
        if (t.resolveOwnSlot(ks)) |slot| {
            present = true;
            const a = t.attrAt(slot);
            is_accessor = a.is_accessor;
            writable = a.writable;
            configurable = a.configurable;
            const raw = if (slot < t.slots.items.len) t.slots.items[slot] else Value{};
            if (is_accessor) holder = raw else data_value = raw;
        }
    }
    if (!present or configurable) return;
    if (!is_accessor) {
        if (!writable and !sameValueV(value, data_value))
            return throwProxy(arena, "proxy set cannot change a non-configurable, non-writable data property");
        return;
    }
    // Accessor: throw when there is no setter.
    var setter = Value{};
    if (holder.bits != 0 and holder.isHeapPtr() and holder.unbox() == .object)
        setter = holder.toPtr().object.getOwn("set") orelse Value{};
    if (setter.bits == 0 or setter.isNullish())
        return throwProxy(arena, "proxy set cannot write a non-configurable accessor property that has no setter");
}

/// [[DefineOwnProperty]] for a proxy: dispatch the `defineProperty` trap with
/// (target, key, descriptorObject). Returns the ToBoolean trap result, or null
/// when no trap exists (caller forwards to the target).
pub fn proxyDefineProperty(arena: std.mem.Allocator, proxy_obj: *JsObject, key: Value, desc_obj: Value) anyerror!?bool {
    const handler = proxyHandler(proxy_obj) orelse return throwRevoked(arena);
    const target = proxyTarget(proxy_obj) orelse return throwRevoked(arena);
    const trap_fn = try getTrap(arena, handler, "defineProperty") orelse return null;
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key, desc_obj });
    if (!val_mod.toBoolean(res)) return false;

    // Best-effort: skip invariants when the target is itself a proxy.
    if (target.bits != 0 and target.unbox() == .object and target.toPtr().object.internal_kind == .proxy)
        return true;

    // Invariant enforcement (spec 10.5.6 steps 12-16).
    const desc = if (desc_obj.bits != 0 and desc_obj.unbox() == .object) toPropDesc(desc_obj) else PDesc{};
    const target_desc = targetDescOf(target, key);
    const extensible = try isExtensibleValue(arena, target);
    const setting_config_false = desc.has_configurable and !desc.configurable;
    if (target_desc == null) {
        if (!extensible)
            return throwProxy(arena, "proxy defineProperty cannot add a property to a non-extensible target");
        if (setting_config_false)
            return throwProxy(arena, "proxy defineProperty cannot define a non-configurable property absent from the target");
    } else {
        if (!isCompatibleDesc(extensible, desc, target_desc))
            return throwProxy(arena, "proxy defineProperty descriptor is incompatible with the target property");
        if (setting_config_false and target_desc.?.configurable)
            return throwProxy(arena, "proxy defineProperty cannot make a configurable target property non-configurable");
        if (target_desc.?.isData() and !target_desc.?.configurable and target_desc.?.writable) {
            if (desc.has_writable and !desc.writable)
                return throwProxy(arena, "proxy defineProperty cannot make a non-configurable writable target property non-writable");
        }
    }
    return true;
}

/// [[HasProperty]] convenience for callers that already hold the proxy object.
/// Invoke the proxy's `getOwnPropertyDescriptor` trap if present. Returns the
/// trap result (descriptor object or undefined), or null when no trap exists
/// (caller should forward to the target).
pub fn proxyGetOwnPropertyDescriptor(arena: std.mem.Allocator, proxy_obj: *JsObject, key: Value) anyerror!?Value {
    const handler = proxyHandler(proxy_obj) orelse return throwRevoked(arena);
    const target = proxyTarget(proxy_obj) orelse return throwRevoked(arena);
    const trap_fn = try getTrap(arena, handler, "getOwnPropertyDescriptor") orelse {
        // No trap: [[GetOwnProperty]] forwards to the target. `null` tells the
        // caller to do that itself, but only an ordinary target has descriptors
        // it can read directly — a proxy target needs its own trap to run.
        if (target.bits != 0 and target.unbox() == .object and target.toPtr().object.internal_kind == .proxy)
            return proxyGetOwnPropertyDescriptor(arena, target.toPtr().object, key);
        return null;
    };
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, key });

    // Step 8: trap result must be an Object or undefined (null/primitive → throw).
    const res_is_obj = res.bits != 0 and res.unbox() == .object;
    const res_is_undef = res.bits == 0 or res.unbox() == .undefined_;
    if (!res_is_obj and !res_is_undef)
        return throwProxy(arena, "proxy getOwnPropertyDescriptor trap must return an object or undefined");

    // Best-effort: when the target is itself a proxy we do not re-derive its
    // descriptors here; return the raw trap result (undefined stays undefined).
    if (target.bits != 0 and target.unbox() == .object and target.toPtr().object.internal_kind == .proxy)
        return if (res_is_obj) res else try val_mod.makeUndefined(arena);

    const target_desc = targetDescOf(target, key);

    if (res_is_undef) {
        if (target_desc == null) return try val_mod.makeUndefined(arena);
        if (!target_desc.?.configurable)
            return throwProxy(arena, "proxy cannot report a non-configurable target property as non-existent");
        if (!(try isExtensibleValue(arena, target)))
            return throwProxy(arena, "proxy cannot report a property of a non-extensible target as non-existent");
        return try val_mod.makeUndefined(arena);
    }

    // res is an Object: ToPropertyDescriptor + invariant validation.
    const extensible = try isExtensibleValue(arena, target);
    const result_desc = toPropDesc(res);
    if (!isCompatibleDesc(extensible, result_desc, target_desc))
        return throwProxy(arena, "proxy getOwnPropertyDescriptor returned an incompatible descriptor");
    const result_configurable = result_desc.has_configurable and result_desc.configurable;
    if (!result_configurable) {
        if (target_desc == null or target_desc.?.configurable)
            return throwProxy(arena, "proxy cannot report an existing property as non-configurable unless the target's is non-configurable");
        if (result_desc.has_writable and !result_desc.writable) {
            if (target_desc.?.isData() and target_desc.?.writable)
                return throwProxy(arena, "proxy cannot report a writable target property as non-configurable & non-writable");
        }
    }
    return res;
}

/// A partial property descriptor extracted from a trap result object (via
/// ToPropertyDescriptor) or from a concrete target property. `has_*` flags mark
/// which fields are present.
const PDesc = struct {
    has_value: bool = false,
    value: Value = .{},
    has_writable: bool = false,
    writable: bool = false,
    has_get: bool = false,
    get: Value = .{},
    has_set: bool = false,
    set: Value = .{},
    has_enumerable: bool = false,
    enumerable: bool = false,
    has_configurable: bool = false,
    configurable: bool = false,

    fn isData(self: PDesc) bool {
        return self.has_value or self.has_writable;
    }
    fn isAccessor(self: PDesc) bool {
        return self.has_get or self.has_set;
    }
    fn isGeneric(self: PDesc) bool {
        return !self.isData() and !self.isAccessor();
    }
};

/// ToPropertyDescriptor over a trap-result object (own+inherited data fields).
fn toPropDesc(obj_val: Value) PDesc {
    var d = PDesc{};
    const o = obj_val.toPtr().object;
    if (o.get("enumerable")) |v| {
        d.has_enumerable = true;
        d.enumerable = val_mod.toBoolean(v);
    }
    if (o.get("configurable")) |v| {
        d.has_configurable = true;
        d.configurable = val_mod.toBoolean(v);
    }
    if (o.get("value")) |v| {
        d.has_value = true;
        d.value = v;
    }
    if (o.get("writable")) |v| {
        d.has_writable = true;
        d.writable = val_mod.toBoolean(v);
    }
    if (o.get("get")) |v| {
        d.has_get = true;
        d.get = v;
    }
    if (o.get("set")) |v| {
        d.has_set = true;
        d.set = v;
    }
    return d;
}

/// Concrete own-property descriptor of a (non-proxy) target, or null if absent.
/// All present fields are marked `has_* = true`.
fn targetDescOf(target: Value, key: Value) ?PDesc {
    if (target.bits == 0 or target.unbox() != .object) return null;
    const t = target.toPtr().object;
    var d = PDesc{ .has_enumerable = true, .has_configurable = true };
    if (key.bits != 0 and key.unbox() == .symbol) {
        const sp = t.getOwnSymEntry(key) orelse return null;
        d.enumerable = sp.attr.enumerable;
        d.configurable = sp.attr.configurable;
        if (sp.attr.is_accessor) {
            fillAccessor(&d, sp.value);
        } else {
            d.has_value = true;
            d.value = sp.value;
            d.has_writable = true;
            d.writable = sp.attr.writable;
        }
        return d;
    }
    if (key.bits == 0 or key.unbox() != .string) return null;
    const ks = key.unbox().string;
    if (t.is_array and std.mem.eql(u8, ks, "length")) {
        d.enumerable = false;
        d.configurable = false;
        d.has_value = true;
        d.value = Value{}; // array length is writable → value never SameValue-compared
        d.has_writable = true;
        d.writable = true;
        return d;
    }
    const slot = t.resolveOwnSlot(ks) orelse return null;
    const a = t.attrAt(slot);
    const raw = if (slot < t.slots.items.len) t.slots.items[slot] else Value{};
    d.enumerable = a.enumerable;
    d.configurable = a.configurable;
    if (a.is_accessor) {
        fillAccessor(&d, raw);
    } else {
        d.has_value = true;
        d.value = raw;
        d.has_writable = true;
        d.writable = a.writable;
    }
    return d;
}

fn fillAccessor(d: *PDesc, holder: Value) void {
    d.has_get = true;
    d.has_set = true;
    if (holder.bits != 0 and holder.isHeapPtr() and holder.unbox() == .object) {
        const h = holder.toPtr().object;
        d.get = h.getOwn("get") orelse Value{};
        d.set = h.getOwn("set") orelse Value{};
    }
}

/// IsCompatiblePropertyDescriptor: whether `desc` may be applied to a property
/// whose current descriptor is `current` (null = property absent), given the
/// target's extensibility. This is the validity half of
/// ValidateAndApplyPropertyDescriptor (spec 10.1.6.3), no mutation.
fn isCompatibleDesc(extensible: bool, desc: PDesc, current: ?PDesc) bool {
    const cur = current orelse {
        // Absent current property: only creatable on an extensible target.
        return extensible;
    };
    if (cur.configurable) return true;
    // Non-configurable current property.
    if (desc.has_configurable and desc.configurable) return false;
    if (desc.has_enumerable and desc.enumerable != cur.enumerable) return false;
    if (desc.isGeneric()) return true;
    if (desc.isData() != cur.isData()) return false;
    if (cur.isData()) {
        if (!cur.writable) {
            if (desc.has_writable and desc.writable) return false;
            if (desc.has_value and !sameValueV(desc.value, cur.value)) return false;
        }
    } else {
        if (desc.has_get and !sameValueV(desc.get, cur.get)) return false;
        if (desc.has_set and !sameValueV(desc.set, cur.set)) return false;
    }
    return true;
}

fn isObjectLike(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .function, .bc_function, .native_function => true,
        else => false,
    };
}

fn throwProxy(arena: std.mem.Allocator, msg: []const u8) anyerror {
    realm_mod.pending_exception = try makeTypeErrorVal(arena, msg);
    return error.JsException;
}

/// Public TypeError raiser for proxy invariant violations enforced by callers
/// outside this module (e.g. the VM's has/deleteProperty trap dispatch).
pub fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    return throwProxy(arena, msg);
}

/// IsExtensible(target) that dispatches a proxy target's own isExtensible trap
/// (so nested proxies observe the invariant call), else reads the flag.
fn isExtensibleValue(arena: std.mem.Allocator, v: Value) anyerror!bool {
    if (v.bits == 0 or v.unbox() != .object) return false;
    const o = v.toPtr().object;
    if (o.internal_kind == .proxy) {
        if (try proxyIsExtensible(arena, o)) |b| return b;
        if (proxyTarget(o)) |t| return isExtensibleValue(arena, t);
        return false;
    }
    return o.extensible;
}

/// [[GetPrototypeOf]] for a proxy: dispatch the `getPrototypeOf` trap. Result
/// must be Object or null; when the target is non-extensible it must equal the
/// target's own prototype. Returns null when no trap (caller forwards).
pub fn proxyGetPrototypeOf(arena: std.mem.Allocator, proxy_obj: *JsObject) anyerror!?Value {
    const handler = proxyHandler(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const target = proxyTarget(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const trap_fn = try getTrap(arena, handler, "getPrototypeOf") orelse return null;
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{target});
    if (!(res.bits != 0 and (res.unbox() == .object or res.unbox() == .null_)))
        return throwProxy(arena, "proxy getPrototypeOf must return an object or null");
    // Invariant: IsExtensible(target) is always consulted; a non-extensible
    // target requires the trap result to equal the target's own prototype.
    if (!(try isExtensibleValue(arena, target)) and target.bits != 0 and target.unbox() == .object) {
        const tp = target.toPtr().object.proto;
        const res_matches = if (res.unbox() == .null_) tp == null else (tp != null and res.toPtr().object == tp.?);
        if (!res_matches) return throwProxy(arena, "proxy getPrototypeOf invariant violated on non-extensible target");
    }
    return res;
}

/// [[SetPrototypeOf]] for a proxy: dispatch the `setPrototypeOf` trap. Returns
/// null when no trap (caller forwards); otherwise the ToBoolean trap result.
pub fn proxySetPrototypeOf(arena: std.mem.Allocator, proxy_obj: *JsObject, proto: Value) anyerror!?bool {
    const handler = proxyHandler(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const target = proxyTarget(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const trap_fn = try getTrap(arena, handler, "setPrototypeOf") orelse return null;
    const proto_arg = if (proto.bits == 0) try val_mod.makeNull(arena) else proto;
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{ target, proto_arg });
    if (!val_mod.toBoolean(res)) return false;
    // Invariant: IsExtensible(target) is always consulted; a non-extensible
    // target requires the new proto to equal the target's own prototype.
    if (!(try isExtensibleValue(arena, target)) and target.bits != 0 and target.unbox() == .object) {
        const tp = target.toPtr().object.proto;
        const matches = if (proto.bits == 0 or proto.unbox() == .null_) tp == null else (proto.unbox() == .object and tp != null and proto.toPtr().object == tp.?);
        if (!matches) return throwProxy(arena, "proxy setPrototypeOf invariant violated on non-extensible target");
    }
    return true;
}

/// [[IsExtensible]] for a proxy: dispatch the `isExtensible` trap. Result's
/// ToBoolean must equal the target's extensibility. Returns null when no trap.
pub fn proxyIsExtensible(arena: std.mem.Allocator, proxy_obj: *JsObject) anyerror!?bool {
    const handler = proxyHandler(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const target = proxyTarget(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const trap_fn = try getTrap(arena, handler, "isExtensible") orelse return null;
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{target});
    const b = val_mod.toBoolean(res);
    const target_ext = target.bits != 0 and target.unbox() == .object and target.toPtr().object.extensible;
    if (b != target_ext) return throwProxy(arena, "proxy isExtensible must match the target");
    return b;
}

/// [[PreventExtensions]] for a proxy: dispatch the `preventExtensions` trap. A
/// truthy result requires the target to be non-extensible. Returns null (no trap).
pub fn proxyPreventExtensions(arena: std.mem.Allocator, proxy_obj: *JsObject) anyerror!?bool {
    const handler = proxyHandler(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const target = proxyTarget(proxy_obj) orelse return throwProxy(arena, "proxy revoked");
    const trap_fn = try getTrap(arena, handler, "preventExtensions") orelse return null;
    const res = try function_proto.invokeCallback(arena, handler, trap_fn, &[_]Value{target});
    const b = val_mod.toBoolean(res);
    if (b and target.bits != 0 and target.unbox() == .object and target.toPtr().object.extensible)
        return throwProxy(arena, "proxy preventExtensions cannot report true for an extensible target");
    return b;
}

fn makeTypeErrorVal(arena: std.mem.Allocator, msg: []const u8) !Value {
    // Use the real %TypeError.prototype% so `e instanceof TypeError` and the
    // `e.constructor === TypeError` checks in test harnesses hold.
    const proto = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto)
    else
        try JsObject.create(arena, proto);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
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
