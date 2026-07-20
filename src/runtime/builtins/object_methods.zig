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

/// Object.is(x, y): the SameValue algorithm — like === except NaN equals NaN
/// and +0 is distinct from -0.
pub fn nativeObjectIs(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const x = if (args.len > 0) args[0] else Value{};
    const y = if (args.len > 1) args[1] else Value{};
    return val_mod.makeBool(arena, sameValue(x, y));
}

fn sameValue(x: Value, y: Value) bool {
    if (x.bits == 0 and y.bits == 0) return true;
    if (x.bits == 0 or y.bits == 0) return false;
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
            // +0 and -0 are NOT the same value: distinguish by sign bit.
            if (n == 0 and m == 0) break :blk std.math.signbit(n) == std.math.signbit(m);
            break :blk n == m;
        },
        .string => |s| std.mem.eql(u8, s, yi.string),
        .bigint => val_mod.bigIntEql(x, y),
        .symbol => x.toPtr().symbol == y.toPtr().symbol,
        .object, .function, .bc_function, .native_function => x.bits == y.bits,
    };
}

/// Object.keys(o): returns array of own enumerable string property names.
pub fn nativeObjectKeys(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    const input = if (args.len > 0) args[0] else Value{};
    if (input.bits == 0 or input.unbox() == .undefined_ or input.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    // Primitive string: ToObject exposes each index as an enumerable own key.
    if (input.unbox() == .string) {
        const s = input.unbox().string;
        var si: u32 = 0;
        while (si < s.len) : (si += 1) {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{si});
            try arr.set(idx_key, try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{si})));
        }
        arr.array_length = si;
        return val_mod.makeObject(arena, arr);
    }
    // Functions resolve to their backing object; other primitives → no own keys.
    const obj = (try resolveObject(arena, input)) orelse {
        arr.array_length = 0;
        return val_mod.makeObject(arena, arr);
    };

    // M16: Module Namespace — enumerable own string keys are the exported names,
    // sorted by code unit. [[GetOwnProperty]] is called for each key (per
    // EnumerableOwnProperties step 4.a.i), which throws ReferenceError for
    // uninitialized (TDZ) bindings.
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerAll(arena, obj); // import-defer: [[OwnPropertyKeys]]
        var pi: u32 = 0;
        for (try namespace_mod.sortedNames(arena, obj)) |k| {
            if (namespace_mod.isTDZ(obj, k)) {
                return throwReferenceErrorObj(arena, k);
            }
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
/// EnumerableOwnPropertyNames [[Get]] (ES §7.3.23): return a property's value,
/// running an own accessor's getter with `receiver` as `this`. `getOwn` alone
/// skips accessors, so Object.values/entries would drop getter-backed keys.
fn enumGetValue(arena: std.mem.Allocator, receiver: Value, obj: *JsObject, key: []const u8) anyerror!Value {
    if (obj.ownAccessorHolder(key)) |holder| {
        if (holder.bits != 0 and holder.unbox() == .object) {
            const getter = holder.toPtr().object.get("get") orelse return val_mod.makeUndefined(arena);
            if (getter.bits == 0 or getter.unbox() == .undefined_) return val_mod.makeUndefined(arena);
            return @import("function_proto.zig").invokeCallback(arena, receiver, getter, &[_]Value{});
        }
    }
    return obj.getOwn(key) orelse val_mod.makeUndefined(arena);
}

/// Snapshot an object's own STRING keys into an owned list. The list must be
/// captured before iteration so getters that add/delete keys mid-loop don't
/// change what is visited (ES §7.3.23 collects the key list up front). Key
/// strings live in the shape arena and outlive shape transitions.
fn snapshotOwnKeys(arena: std.mem.Allocator, obj: *JsObject) !std.ArrayListUnmanaged([]const u8) {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    for (obj.ownKeys()) |k| try keys.append(arena, k);
    return keys;
}

pub fn nativeObjectValues(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    const input = if (args.len > 0) args[0] else Value{};
    // ToObject(O): undefined/null (and a missing argument) throw.
    if (input.bits == 0 or input.unbox() == .undefined_ or input.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");

    var i: u32 = 0;
    // Primitive string: ToObject exposes each index (this engine indexes strings
    // by byte, matching charAt) as an enumerable own property.
    if (input.unbox() == .string) {
        const s = input.unbox().string;
        while (i < s.len) : (i += 1) {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            try arr.set(idx_key, try val_mod.makeString(arena, s[i .. i + 1]));
        }
        arr.array_length = i;
        return val_mod.makeObject(arena, arr);
    }
    // Functions are objects: enumerate their backing object's own props. Other
    // primitives box to a wrapper with no enumerable own properties → [].
    const obj = (try resolveObject(arena, input)) orelse {
        arr.array_length = 0;
        return val_mod.makeObject(arena, arr);
    };

    // M15: TypedArray integer-indexed element values come first (all enumerable).
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        if (!td.ab.detached and !ta_mod.taIsOob(td)) {
            const ta_len: u32 = @intCast(ta_mod.taCurrentLen(td));
            var ti: u32 = 0;
            while (ti < ta_len) : (ti += 1) {
                const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                try arr.set(idx_key, try ta_mod.taLoad(arena, td, ti));
                i += 1;
            }
        }
    }
    var keys = try snapshotOwnKeys(arena, obj);
    defer keys.deinit(arena);
    for (keys.items) |k| {
        if (!obj.isEnumerable(k)) continue; // re-checked live: a getter may have flipped it
        const v = try enumGetValue(arena, input, obj, k);
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, v);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// ES2015 Object.assign(target, ...sources): copy enumerable own properties.
pub fn nativeObjectAssign(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const target = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // Step 1: to = ToObject(target) — null/undefined throw.
    if (target.bits == 0 or target.unbox() == .undefined_ or target.unbox() == .null_)
        return throwTypeError(arena, "Object.assign target must be coercible to an object");
    const to_val = try realm_mod.toObjectForThis(arena, target);
    if (to_val.bits == 0 or to_val.unbox() != .object) return to_val;
    const target_obj = to_val.toPtr().object;
    const ctx = realm_mod.active_context;

    if (args.len <= 1) return to_val;
    for (args[1..]) |src| {
        // Skip undefined/null sources.
        if (src.bits == 0 or src.unbox() == .undefined_ or src.unbox() == .null_) continue;

        // A primitive string source contributes its indexed characters (ToObject
        // makes a String exotic whose own enumerable keys are its indices).
        if (src.unbox() == .string) {
            const s = src.toPtr().string;
            for (s, 0..) |_, i| {
                const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                try target_obj.set(key, try val_mod.makeString(arena, s[i .. i + 1]));
            }
            continue;
        }
        const from_val = try realm_mod.toObjectForThis(arena, src);
        if (from_val.bits == 0 or from_val.unbox() != .object) continue;
        const src_obj = from_val.toPtr().object;

        // String property keys in own order, then symbol keys (per OwnPropertyKeys).
        for (src_obj.ownKeys()) |k| {
            if (!src_obj.isEnumerable(k)) continue;
            const v = if (ctx) |c| try c.getProp(arena, from_val, k) else (src_obj.getOwn(k) orelse continue);
            if (ctx) |c| try c.setProp(arena, to_val, k, v) else try target_obj.set(k, v);
        }
        // Copy enumerable symbol-keyed own properties.
        var si: usize = 0;
        while (si < src_obj.sym_props.items.len) : (si += 1) {
            const sp = src_obj.sym_props.items[si];
            if (!sp.attr.enumerable) continue;
            const v = if (ctx) |c| try c.getPropSym(arena, from_val, sp.key) else sp.value;
            try target_obj.setSym(sp.key, v);
        }
    }
    return to_val;
}

/// ES2017 Object.entries(o): array of [key, value] pairs.
pub fn nativeObjectEntries(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    const input = if (args.len > 0) args[0] else Value{};
    if (input.bits == 0 or input.unbox() == .undefined_ or input.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");

    var i: u32 = 0;
    // Primitive string: [index, char] pairs for each byte index.
    if (input.unbox() == .string) {
        const s = input.unbox().string;
        while (i < s.len) : (i += 1) {
            const pair = try JsObject.createArray(arena, arr_proto);
            try pair.set("0", try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{i})));
            try pair.set("1", try val_mod.makeString(arena, s[i .. i + 1]));
            pair.array_length = 2;
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            try arr.set(idx_key, try val_mod.makeObject(arena, pair));
        }
        arr.array_length = i;
        return val_mod.makeObject(arena, arr);
    }
    const obj = (try resolveObject(arena, input)) orelse {
        arr.array_length = 0;
        return val_mod.makeObject(arena, arr);
    };

    // M15: TypedArray integer-indexed [index, value] pairs come first.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        if (!td.ab.detached and !ta_mod.taIsOob(td)) {
            const ta_len: u32 = @intCast(ta_mod.taCurrentLen(td));
            var ti: u32 = 0;
            while (ti < ta_len) : (ti += 1) {
                const pair = try JsObject.createArray(arena, arr_proto);
                try pair.set("0", try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{ti})));
                try pair.set("1", try ta_mod.taLoad(arena, td, ti));
                pair.array_length = 2;
                const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                try arr.set(idx_key, try val_mod.makeObject(arena, pair));
                i += 1;
            }
        }
    }
    var keys = try snapshotOwnKeys(arena, obj);
    defer keys.deinit(arena);
    for (keys.items) |k| {
        if (!obj.isEnumerable(k)) continue;
        const v = try enumGetValue(arena, input, obj, k);
        const pair = try JsObject.createArray(arena, arr_proto);
        try pair.set("0", try val_mod.makeString(arena, k));
        try pair.set("1", v);
        pair.array_length = 2;
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, try val_mod.makeObject(arena, pair));
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}

/// ES2019 Object.fromEntries(iterable) (§20.1.2.7): iterate `iterable`, and for
/// each [key, value] entry create a data property with key = ToPropertyKey(key).
pub fn nativeObjectFromEntries(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const coercion_mod = @import("coercion.zig");
    const fp = @import("function_proto.zig");
    const collections = @import("es2015_collections.zig");

    // RequireObjectCoercible(iterable): undefined/null (or a missing arg) throws.
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .undefined_ or args[0].unbox() == .null_)
        return throwTypeError(arena, "Object.fromEntries requires an iterable argument");
    const iterable = args[0];

    const obj_proto: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
    const out = try JsObject.create(arena, obj_proto);
    const ctx = realm_mod.active_context orelse return val_mod.makeObject(arena, out);

    const iter = try collections.nativeGetIterator(arena, Value{}, &[_]Value{iterable});
    const next_fn = try ctx.getProp(arena, iter, "next");
    while (true) {
        const res = try fp.invokeCallback(arena, iter, next_fn, &[_]Value{});
        if (res.bits == 0 or res.unbox() != .object)
            return throwTypeError(arena, "iterator.next() returned a non-object");
        const done = try ctx.getProp(arena, res, "done");
        if (val_mod.toBoolean(done)) break;
        const entry = try ctx.getProp(arena, res, "value");
        // Each entry must be an Object; otherwise close the iterator (best-effort) and throw.
        if (entry.bits == 0 or entry.unbox() != .object) {
            try iteratorCloseIgnore(arena, ctx, iter);
            return throwTypeError(arena, "Object.fromEntries entry is not an object");
        }
        const key = ctx.getProp(arena, entry, "0") catch |e| {
            try iteratorCloseIgnore(arena, ctx, iter);
            return e;
        };
        const value = ctx.getProp(arena, entry, "1") catch |e| {
            try iteratorCloseIgnore(arena, ctx, iter);
            return e;
        };
        // ToPropertyKey(key): a Symbol stays a symbol key; else ToString it.
        const prim = coercion_mod.toPrimitive(arena, key, .string) catch |e| {
            try iteratorCloseIgnore(arena, ctx, iter);
            return e;
        };
        if (prim != null and prim.?.bits != 0 and prim.?.unbox() == .symbol) {
            try out.setSym(prim.?, value);
        } else {
            const ks = realm_mod.stringPrimitive(arena, if (prim) |p| p else key) catch |e| {
                try iteratorCloseIgnore(arena, ctx, iter);
                return e;
            };
            try out.set(ks, value);
        }
    }
    return val_mod.makeObject(arena, out);
}

/// IteratorClose that swallows any error from the return() call (used on the
/// abrupt-completion path, where the original exception takes precedence).
fn iteratorCloseIgnore(arena: std.mem.Allocator, ctx: anytype, iter: Value) !void {
    const fp = @import("function_proto.zig");
    const ret = ctx.getProp(arena, iter, "return") catch return;
    if (ret.bits == 0 or ret.unbox() == .undefined_ or ret.unbox() == .null_) return;
    _ = fp.invokeCallback(arena, iter, ret, &[_]Value{}) catch {
        @import("../realm.zig").pending_exception = Value{};
    };
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
        if (obj.isPrivate(k)) continue; // private class elements are hidden
        if (JsObject.isInternalSlotKey(k)) continue; // internal slots ([[PrimitiveValue]], …)
        const v = obj.getOwn(k) orelse continue;
        const desc_val = try makeDataDescriptor(arena, v);
        try out.set(k, desc_val);
    }
    return val_mod.makeObject(arena, out);
}

/// Object.hasOwn(O, P) (ES2022 §20.1.2.13): ToObject(O), then HasOwnProperty.
/// Equivalent to `Object.prototype.hasOwnProperty.call(O, P)` but a static method
/// that ToObject-coerces its argument (throwing for null/undefined).
pub fn nativeObjectHasOwn(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target = if (args.len > 0) args[0] else Value{};
    if (target.bits == 0 or target.unbox() == .undefined_ or target.unbox() == .null_) {
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    }
    const key = if (args.len > 1) args[1] else Value{};
    return nativeHasOwnProperty(arena, target, &[_]Value{key});
}

/// hasOwnProperty(key): checks if own prop exists (not in proto chain).
pub fn nativeHasOwnProperty(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeBool(arena, false);
    // Step 1: P = ToPropertyKey(V) — coercion (which may throw) precedes ToObject(this).
    const key_v = try toPropertyKeyValue(arena, args[0]);
    // Step 2: ToObject(this) throws for null/undefined (callables/primitives box).
    if (this_val.isNullish()) return throwTypeError(arena, "Object.prototype.hasOwnProperty called on null or undefined");
    // native_function has own "length" and "name" unless deleted (ES spec §10.3).
    if (this_val.bits != 0 and this_val.unbox() == .native_function) {
        const key: []const u8 = if (key_v.bits != 0 and key_v.unbox() == .string)
            key_v.toPtr().string
        else
            return val_mod.makeBool(arena, false);
        const entry = this_val.unbox().native_function;
        if (std.mem.eql(u8, key, "length")) return val_mod.makeBool(arena, !entry.length_deleted);
        if (std.mem.eql(u8, key, "name"))   return val_mod.makeBool(arena, !entry.name_deleted);
        return val_mod.makeBool(arena, false);
    }
    // bc_function: resolve to backing object (materializes it, adding own name/length/prototype
    // for generators). Without this, hasOwnProperty always returns false for bc functions.
    if (this_val.bits != 0 and this_val.unbox() == .bc_function) {
        const realm_mod2 = @import("../realm.zig");
        const ctx2 = realm_mod2.active_context orelse return val_mod.makeBool(arena, false);
        const bobj = (try ctx2.backingObject(arena, this_val)) orelse return val_mod.makeBool(arena, false);
        const key2: []const u8 = if (key_v.bits != 0 and key_v.unbox() == .string)
            key_v.toPtr().string
        else
            (try coerceKey(arena, key_v)) orelse return val_mod.makeBool(arena, false);
        if (bobj.isPrivate(key2)) return val_mod.makeBool(arena, false);
        return val_mod.makeBool(arena, bobj.hasOwn(key2));
    }
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    const obj = this_val.toPtr().object;
    // Proxy [[GetOwnProperty]]: HasOwnProperty(P) = the descriptor is not undefined.
    if (obj.internal_kind == .proxy) {
        const pkey = if (key_v.bits != 0 and key_v.unbox() == .symbol)
            key_v
        else
            try val_mod.makeString(arena, (try coerceKey(arena, key_v)) orelse "undefined");
        if (try proxy_mod.proxyGetOwnPropertyDescriptor(arena, obj, pkey)) |desc| {
            return val_mod.makeBool(arena, !(desc.bits == 0 or desc.unbox() == .undefined_));
        }
        if (proxy_mod.proxyTarget(obj)) |t| return nativeHasOwnProperty(arena, t, &[_]Value{pkey});
        return val_mod.makeBool(arena, false);
    }
    // Symbol key: check sym_props.
    if (key_v.bits != 0 and key_v.unbox() == .symbol) {
        return val_mod.makeBool(arena, obj.getOwnSym(key_v) != null);
    }
    const key: []const u8 = if (key_v.bits != 0 and key_v.unbox() == .string)
        key_v.toPtr().string
    else
        (try coerceKey(arena, key_v)) orelse return val_mod.makeBool(arena, false);

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
    // [[GetOwnProperty]] calls [[Get]] for the value, which throws ReferenceError
    // for uninitialized (TDZ) bindings (ES §10.4.6.4 step 4).
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerForStringKey(arena, obj, key); // import-defer: [[GetOwnProperty]]
        if (!namespace_mod.hasExport(obj, key)) return val_mod.makeBool(arena, false);
        if (namespace_mod.isTDZ(obj, key)) {
            return throwReferenceErrorObj(arena, key);
        }
        return val_mod.makeBool(arena, true);
    }

    // A private class element (`#x`) is hidden from reflection.
    if (obj.isPrivate(key)) return val_mod.makeBool(arena, false);
    // A string-keyed internal slot ([[PrimitiveValue]], [[OriginalSource]], …) is
    // spec internal state, never an own property.
    if (JsObject.isInternalSlotKey(key)) return val_mod.makeBool(arena, false);
    // Array exotic "length": a synthetic own data property not held in the
    // shape, so `hasOwn` misses it. It is always an own property of an array.
    if (obj.is_array and std.mem.eql(u8, key, "length")) return val_mod.makeBool(arena, true);
    return val_mod.makeBool(arena, obj.hasOwn(key));
}

/// Object.prototype.propertyIsEnumerable(V): true iff V is an OWN, enumerable
/// property of ToObject(this). Missing / inherited → false.
/// Resolve a Value to its backing JsObject, or null for primitives. Ordinary
/// objects return themselves; user closures / class ctors resolve to their
/// lazily-created backing object (so `fn.isPrototypeOf(...)` walks the right
/// object identity).
fn resolveObject(arena: std.mem.Allocator, v: Value) anyerror!?*JsObject {
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

/// Object.prototype.isPrototypeOf(V) — ES §20.1.3.3. RequireObjectCoercible(this);
/// if V is not an object return false; otherwise return true iff O (ToObject(this))
/// appears anywhere in V's [[Prototype]] chain.
pub fn nativeObjectIsPrototypeOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() == .undefined_ or this_val.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    const O = (try resolveObject(arena, this_val)) orelse return val_mod.makeBool(arena, false);
    const v = if (args.len > 0) args[0] else Value{};
    const v_obj = (try resolveObject(arena, v)) orelse return val_mod.makeBool(arena, false);
    var cur: ?*JsObject = v_obj.proto;
    while (cur) |c| {
        if (c == O) return val_mod.makeBool(arena, true);
        cur = c.proto;
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativePropertyIsEnumerable(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Step 1: P = ToPropertyKey(V) — coercion (may throw) precedes ToObject(this).
    const key_arg = try toPropertyKeyValue(arena, if (args.len > 0) args[0] else Value{});
    // Step 2: ToObject(this) throws for null/undefined.
    if (this_val.isNullish()) return throwTypeError(arena, "Object.prototype.propertyIsEnumerable called on null or undefined");
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    const obj = this_val.toPtr().object;
    // Proxy [[GetOwnProperty]]: enumerable iff the descriptor exists and its
    // [[Enumerable]] field is true.
    if (obj.internal_kind == .proxy) {
        const pkey = if (key_arg.bits != 0 and key_arg.unbox() == .symbol)
            key_arg
        else
            try val_mod.makeString(arena, (try coerceKey(arena, key_arg)) orelse "undefined");
        if (try proxy_mod.proxyGetOwnPropertyDescriptor(arena, obj, pkey)) |desc| {
            if (desc.bits == 0 or desc.unbox() == .undefined_) return val_mod.makeBool(arena, false);
            const en = desc.bits != 0 and desc.unbox() == .object and descTruthy(desc.toPtr().object.getOwn("enumerable"));
            return val_mod.makeBool(arena, en);
        }
        if (proxy_mod.proxyTarget(obj)) |t| return nativePropertyIsEnumerable(arena, t, &[_]Value{pkey});
        return val_mod.makeBool(arena, false);
    }
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
    // [[GetOwnProperty]] calls [[Get]] for the value, which throws ReferenceError
    // for uninitialized (TDZ) bindings (ES §10.4.6.4 step 4).
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerForStringKey(arena, obj, key); // import-defer: [[GetOwnProperty]]
        if (!namespace_mod.hasExport(obj, key)) return val_mod.makeBool(arena, false);
        if (namespace_mod.isTDZ(obj, key)) {
            return throwReferenceErrorObj(arena, key);
        }
        return val_mod.makeBool(arena, true);
    }
    if (!obj.hasOwn(key)) return val_mod.makeBool(arena, false);
    const a = obj.ownAttr(key) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, a.enumerable);
}

// ------------------------------------------------------------------ ES5.1 meta-protocol ---

/// Truthiness for descriptor flag values (absent/empty → false).
/// IsCallable(v) — used by ToPropertyDescriptor's get/set validation.
fn descIsCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |o| o.internal_kind == .bound_function or o.get("__call__") != null,
        else => false,
    };
}

fn descTruthy(v: ?Value) bool {
    const val = v orelse return false;
    if (val.bits == 0) return false;
    return switch (val.unbox()) {
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .object, .function, .native_function, .bc_function, .symbol => true,
        .boolean => |b| b,
        .bigint => |b| !b.toConst().eqlZero(),
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

fn makeReferenceErrorObj(arena: std.mem.Allocator, name: []const u8) !Value {
    const realm_mod = @import("../realm.zig");
    const msg = try std.fmt.allocPrint(arena, "{s} is not defined", .{name});
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.error_proto_ReferenceError)
    else
        try JsObject.create(arena, realm_mod.error_proto_ReferenceError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "ReferenceError"));
    return val_mod.makeObject(arena, obj);
}

fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    realm_mod.pending_exception = try makeTypeErrorObj(arena, msg);
    return error.JsException;
}

fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    const proto = realm_mod.error_proto_RangeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// ToNumber for an array-length descriptor value (ArraySetLength). Primitives
/// convert directly; objects go through ToPrimitive(number) (running valueOf).
fn toNumberForLength(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    var pv = v;
    if (pv.bits != 0 and pv.unbox() == .object) {
        pv = (try @import("coercion.zig").toPrimitive(arena, pv, .number)) orelse pv;
    }
    if (pv.bits == 0) return std.math.nan(f64);
    return switch (pv.unbox()) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len == 0) break :blk 0; // ToNumber("") is 0
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        else => std.math.nan(f64),
    };
}

/// ToUint32 (ES §7.1.6): NaN/±Inf/±0 → 0; otherwise truncate toward zero and
/// reduce modulo 2^32.
fn toUint32(n: f64) u32 {
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return 0;
    const t = @trunc(n);
    const m = @mod(t, 4294967296.0);
    const pos = if (m < 0) m + 4294967296.0 else m;
    return @intFromFloat(pos);
}

/// ArraySetLength (ES §10.4.2.4) for an ordinary `[[Set]]`/`[[DefineOwnProperty]]`
/// of an array's own "length": ToPrimitive(number) the value (running a user
/// valueOf/@@toPrimitive), reject a BigInt/Symbol (no Number conversion →
/// TypeError), require the result to be a valid Uint32 (RangeError otherwise),
/// then apply it — `obj.set("length", …)` truncates the array's out-of-range
/// index properties. Shared by `Object`/`Reflect.defineProperty` and `Reflect.set`
/// so every reflective length write matches the plain `arr.length = v` assignment.
pub fn arraySetLengthThrowing(arena: std.mem.Allocator, obj: *JsObject, value: Value) anyerror!void {
    var pv = value;
    if (pv.bits != 0 and pv.unbox() == .object)
        pv = (try @import("coercion.zig").toPrimitive(arena, pv, .number)) orelse pv;
    if (pv.bits != 0) {
        switch (pv.unbox()) {
            .bigint => return throwTypeError(arena, "Cannot convert a BigInt value to a number"),
            .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
            else => {},
        }
    }
    // `pv` is already primitive here, so toNumberForLength does no re-coercion.
    const num = try toNumberForLength(arena, pv);
    const u = toUint32(num);
    if (@as(f64, @floatFromInt(u)) != num)
        return throwRangeError(arena, "Invalid array length");
    try obj.set("length", try val_mod.makeNumber(arena, @floatFromInt(u)));
}

fn throwReferenceErrorObj(arena: std.mem.Allocator, name: []const u8) anyerror {
    const realm_mod = @import("../realm.zig");
    realm_mod.pending_exception = try makeReferenceErrorObj(arena, name);
    return error.JsException;
}

/// Coerce a Value to an owned key string. Returns null if not coercible.
fn coerceKey(arena: std.mem.Allocator, v: Value) !?[]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .string => |s| s,
        // ToString(number) per spec: -0 → "0", integers without a decimal point,
        // etc. Plain "{d}" would yield "-0" and break numeric-key lookups.
        .number => |n| try val_mod.formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .undefined_ => "undefined",
        .null_ => "null",
        else => null, // Symbols are handled by callers before coerceKey.
    };
}

/// HasProperty on a descriptor object (ToPropertyDescriptor uses HasProperty, so
/// an inherited field counts): own or inherited, data or accessor.
fn descHas(dobj: *JsObject, key: []const u8) bool {
    return dobj.findProperty(key) != null;
}

/// [[Get]] a descriptor field: walk the prototype chain and, for an accessor,
/// invoke its getter with `receiver` as `this`. ToPropertyDescriptor reads each
/// field via Get, so descriptor objects with inherited or getter-backed fields
/// (and their observable side effects) are honored.
fn descGet(arena: std.mem.Allocator, receiver: Value, dobj: *JsObject, key: []const u8) anyerror!Value {
    const loc = dobj.findProperty(key) orelse return val_mod.makeUndefined(arena);
    if (loc.holder.attrAt(loc.slot).is_accessor) {
        if (loc.holder.ownAccessorHolder(key)) |holder| {
            if (holder.bits != 0 and holder.unbox() == .object) {
                const getter = holder.toPtr().object.get("get") orelse return val_mod.makeUndefined(arena);
                if (getter.bits == 0 or getter.unbox() == .undefined_) return val_mod.makeUndefined(arena);
                return @import("function_proto.zig").invokeCallback(arena, receiver, getter, &[_]Value{});
            }
        }
        return val_mod.makeUndefined(arena);
    }
    return loc.holder.getOwn(key) orelse val_mod.makeUndefined(arena);
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

/// Object.getPrototypeOf(o): ES2015 §19.1.2.12 — ToObject(o) then [[GetPrototypeOf]].
/// undefined/null (and a missing argument) throw a TypeError; primitives box to
/// their wrapper's prototype; objects return their [[Prototype]] (or null).
pub fn nativeObjectGetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm = @import("../realm.zig");
    if (args.len == 0 or args[0].bits == 0)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    // ToObject on a primitive yields its wrapper, whose [[Prototype]] is the
    // corresponding %Wrapper.prototype% intrinsic.
    switch (args[0].unbox()) {
        .undefined_, .null_ => return throwTypeError(arena, "Cannot convert undefined or null to object"),
        .number => if (realm.active_number_proto) |p| return val_mod.makeObject(arena, p),
        .boolean => if (realm.active_boolean_proto) |p| return val_mod.makeObject(arena, p),
        .string => if (realm.active_string_proto) |p| return val_mod.makeObject(arena, p),
        .bigint => if (realm.active_bigint_proto) |p| return val_mod.makeObject(arena, p),
        else => {},
    }
    // A built-in (native) function's [[Prototype]] is %Function.prototype% (ES
    // §20.2.3). The property-get path already walks Function.prototype for these
    // values; mirror that here so `Object.getPrototypeOf(fn)` is consistent (and
    // so ShadowRealm.prototype.evaluate/importValue report Function.prototype).
    if (args[0].unbox() == .native_function) {
        if (@import("../realm.zig").active_function_proto) |fp| return val_mod.makeObject(arena, fp);
        return val_mod.makeNull(arena);
    }
    // A bc_function (user closure / class constructor) keeps its [[Prototype]] on
    // a lazily-created backing object. Resolve it so `Object.getPrototypeOf(fn)`
    // is consistent with `Object.setPrototypeOf` (needed for class static
    // inheritance: `class B extends A` links B's ctor proto to A).
    if (args[0].unbox() == .bc_function or args[0].unbox() == .function) {
        if (@import("../realm.zig").active_context) |ctx| {
            if (try ctx.backingObject(arena, args[0])) |bo| {
                if (bo.proto) |p| return val_mod.makeObject(arena, p);
            }
        }
        if (@import("../realm.zig").active_function_proto) |fp| return val_mod.makeObject(arena, fp);
        return val_mod.makeNull(arena);
    }
    // A symbol primitive boxes to %Symbol.prototype% (ToObject then
    // [[GetPrototypeOf]]), so `Object.getPrototypeOf(sym) === Symbol.prototype`.
    if (args[0].unbox() == .symbol) {
        if (@import("../realm.zig").active_symbol_proto) |sp| return val_mod.makeObject(arena, sp);
        return val_mod.makeNull(arena);
    }
    if (args[0].unbox() != .object) return val_mod.makeNull(arena);
    const obj = args[0].toPtr().object;
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetPrototypeOf(arena, obj)) |p| return p;
        // No trap: forward to target's [[GetPrototypeOf]].
        if (proxy_mod.proxyTarget(obj)) |t| return nativeObjectGetPrototypeOf(arena, Value{}, &[_]Value{t});
    }
    if (obj.proto) |p| return val_mod.makeObject(arena, p);
    return val_mod.makeNull(arena);
}

/// Object.setPrototypeOf(o, proto): set o's [[Prototype]]. Handles plain
/// objects and bc_function ctors (sets the backing object's proto, so static
/// members inherit along the constructor chain — needed for class subclassing).
pub fn nativeObjectSetPrototypeOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target = if (args.len > 0) args[0] else Value{};
    // 1. RequireObjectCoercible(O): undefined/null (or missing) throw.
    if (target.bits == 0 or target.unbox() == .undefined_ or target.unbox() == .null_)
        return throwTypeError(arena, "Object.setPrototypeOf called on null or undefined");
    // 2. proto must be an Object or null; anything else (undefined, number, …) throws.
    const proto_arg = if (args.len > 1) args[1] else Value{};
    if (proto_arg.bits == 0 or proto_arg.unbox() == .undefined_)
        return throwTypeError(arena, "Object prototype may only be an Object or null");
    const new_proto: ?*JsObject = switch (proto_arg.unbox()) {
        .object => proto_arg.toPtr().object,
        .null_ => null,
        // A class used as a proto (`class B extends A` → setPrototypeOf(B, A))
        // is a bc_function value; its static members live on a lazily-created
        // backing object. Resolve to that so the constructor static chain links
        // (needed for multi-level subclasses: @@species etc. inherit through it).
        .bc_function, .function => if (@import("../realm.zig").active_context) |ctx|
            (try ctx.backingObject(arena, proto_arg))
        else
            null,
        else => return throwTypeError(arena, "Object prototype may only be an Object or null"),
    };
    // 3. If Type(O) is not Object, return O (primitive targets are a no-op).
    if (target.unbox() == .object) {
        const obj = target.toPtr().object;
        // M16: Module Namespace [[SetPrototypeOf]] is SetImmutablePrototype — only a
        // no-op to null succeeds; any other target throws.
        if (obj.internal_kind == .module_namespace) {
            if (new_proto == null) return target;
            return throwTypeError(arena, "cannot set prototype of a module namespace object");
        }
        // Proxy [[SetPrototypeOf]] trap dispatch.
        if (obj.internal_kind == .proxy) {
            const proto_val = if (new_proto) |p| try val_mod.makeObject(arena, p) else try val_mod.makeNull(arena);
            if (try proxy_mod.proxySetPrototypeOf(arena, obj, proto_val)) |ok| {
                if (!ok) return throwTypeError(arena, "proxy setPrototypeOf returned false");
                return target;
            }
            // No trap: forward to the target.
            if (proxy_mod.proxyTarget(obj)) |t| return nativeObjectSetPrototypeOf(arena, Value{}, &.{ t, proto_val });
        }
        // OrdinarySetPrototypeOf (ES §10.1.2): a no-op to the same proto always
        // succeeds; otherwise a non-extensible object, or a change that would
        // create a prototype cycle, fails and Object.setPrototypeOf throws.
        if (obj.proto != new_proto) {
            if (!obj.extensible)
                return throwTypeError(arena, "#<Object> is not extensible");
            var p: ?*JsObject = new_proto;
            while (p) |cur| {
                if (cur == obj) return throwTypeError(arena, "Cyclic __proto__ value");
                // A Proxy in the chain has an exotic [[GetPrototypeOf]]; stop the
                // static cycle walk here (spec: done becomes true).
                if (cur.internal_kind == .proxy) break;
                p = cur.proto;
            }
            obj.proto = new_proto;
            obj.setProtoBarrier(new_proto);
        }
    } else if (@import("../realm.zig").active_context) |ctx| {
        try ctx.setProto(arena, target, new_proto); // bc_function ctor (static inheritance)
    }
    return target;
}

/// get Object.prototype.__proto__ (Annex B §B.2.2.1): ? ToObject(this) then
/// [[GetPrototypeOf]]. RequireObjectCoercible — null/undefined throw.
pub fn nativeObjectProtoGetProto(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() == .undefined_ or this_val.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    return nativeObjectGetPrototypeOf(arena, Value{}, &[_]Value{this_val});
}

/// set Object.prototype.__proto__ (Annex B §B.2.2.1): RequireObjectCoercible(this);
/// if the value is neither Object nor Null, or `this` is not an Object, it is a
/// silent no-op (returns undefined). Otherwise sets `this`'s [[Prototype]].
pub fn nativeObjectProtoSetProto(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() == .undefined_ or this_val.unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    const v = if (args.len > 0) args[0] else Value{};
    // The new value must be an Object or Null; anything else is a no-op.
    const v_ok = v.bits != 0 and switch (v.unbox()) {
        .object, .null_, .bc_function, .function => true,
        else => false,
    };
    if (!v_ok) return val_mod.makeUndefined(arena);
    // Only ordinary objects / function objects have a settable [[Prototype]] here.
    const this_settable = this_val.bits != 0 and switch (this_val.unbox()) {
        .object, .bc_function, .function => true,
        else => false,
    };
    if (!this_settable) return val_mod.makeUndefined(arena);
    _ = try nativeObjectSetPrototypeOf(arena, Value{}, &[_]Value{ this_val, v });
    return val_mod.makeUndefined(arena);
}

/// Object.getOwnPropertyNames(o): all own keys including non-enumerable.
/// True if `key` is a canonical array-index string (a base-10 integer in
/// [0, 2^32-2], no leading zeros). Used to place the synthetic "length" key
/// after an array's integer-index keys in [[OwnPropertyKeys]] order.
fn isArrayIndexKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key.len > 1 and key[0] == '0') return false;
    const idx = std.fmt.parseUnsigned(u32, key, 10) catch return false;
    return idx != std.math.maxInt(u32);
}

pub fn nativeObjectGetOwnPropertyNames(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;
    const arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .undefined_ or args[0].unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    // Primitive string: own keys are each index "0".."n-1" then "length".
    if (args[0].unbox() == .string) {
        const s = args[0].unbox().string;
        var si: u32 = 0;
        while (si < s.len) : (si += 1) {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{si});
            try arr.set(idx_key, try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d}", .{si})));
        }
        const len_key = try std.fmt.allocPrint(arena, "{d}", .{si});
        try arr.set(len_key, try val_mod.makeString(arena, "length"));
        arr.array_length = si + 1;
        return val_mod.makeObject(arena, arr);
    }
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
    const obj = (try resolveObject(arena, args[0])) orelse return val_mod.makeObject(arena, arr);

    // M16: Module Namespace [[OwnPropertyKeys]] — exported names sorted by code
    // unit (symbol keys are excluded from getOwnPropertyNames).
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerAll(arena, obj); // import-defer: [[OwnPropertyKeys]]
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

    // Array [[OwnPropertyKeys]]: integer-index keys (ascending, as stored),
    // then "length" (a synthetic own data property not held in `ownKeys()`),
    // then any remaining non-index string keys in insertion order. Without this,
    // `Object.getOwnPropertyNames(arr)` would omit "length".
    if (obj.is_array) {
        var ai: u32 = 0;
        var length_emitted = false;
        for (obj.ownKeys()) |k| {
            if (!length_emitted and !isArrayIndexKey(k)) {
                const len_key = try std.fmt.allocPrint(arena, "{d}", .{ai});
                try arr.set(len_key, try val_mod.makeString(arena, "length"));
                ai += 1;
                length_emitted = true;
            }
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{ai});
            try arr.set(idx_key, try val_mod.makeString(arena, k));
            ai += 1;
        }
        if (!length_emitted) {
            const len_key = try std.fmt.allocPrint(arena, "{d}", .{ai});
            try arr.set(len_key, try val_mod.makeString(arena, "length"));
            ai += 1;
        }
        arr.array_length = ai;
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
        if (obj.isPrivate(k)) continue; // private class elements are hidden
        if (JsObject.isInternalSlotKey(k)) continue; // internal slots ([[PrimitiveValue]], …)
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
    // ToObject(O): undefined/null (and a missing argument) throw a TypeError.
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .undefined_ or args[0].unbox() == .null_)
        return throwTypeError(arena, "Cannot convert undefined or null to object");
    // ToPropertyKey(P): coerce Object keys via ToPrimitive(string) so e.g.
    // getOwnPropertyDescriptor(obj, [1]) looks up "1" (may throw / yield a Symbol).
    const key_v = try toPropertyKeyValue(arena, if (args.len >= 2) args[1] else Value{});
    const arg0_unboxed = args[0].unbox();
    // Handle native_function: synthesize descriptors for .name/.length (respecting deletion).
    if (arg0_unboxed == .native_function) {
        if (args.len < 2) return val_mod.makeUndefined(arena);
        const key = (try coerceKey(arena, key_v)) orelse return val_mod.makeUndefined(arena);
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
    // Functions are objects: resolve bc_function (and others) to their backing
    // JsObject so Object.getOwnPropertyDescriptor(fn, 'name') etc. work.
    // Same pattern as defineTarget() used by Object.defineProperty.
    const obj: *JsObject = if (arg0_unboxed == .object)
        args[0].toPtr().object
    else blk: {
        const ctx = realm_mod.active_context orelse return val_mod.makeUndefined(arena);
        break :blk (try ctx.backingObject(arena, args[0])) orelse return val_mod.makeUndefined(arena);
    };

    if (args.len < 2) return val_mod.makeUndefined(arena);

    // Proxy: getOwnPropertyDescriptor trap (or forward to target).
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetOwnPropertyDescriptor(arena, obj, key_v)) |desc| {
            return desc;
        }
        if (proxy_mod.proxyTarget(obj)) |target| {
            return try nativeObjectGetOwnPropertyDescriptor(arena, args[0], &[_]Value{ target, key_v });
        }
        return val_mod.makeUndefined(arena);
    }

    // M15: TypedArray [[GetOwnProperty]] — integer-indexed exotic. Symbol keys are
    // never integer indices: skip to the ordinary symbol-property branch below.
    if (obj.internal_kind == .typed_array and !(key_v.bits != 0 and key_v.unbox() == .symbol)) {
        const ta_mod = @import("typed_array.zig");
        const key2 = (try coerceKey(arena, key_v)) orelse return val_mod.makeUndefined(arena);
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
    // [[GetOwnProperty]] calls [[Get]] for the value (step 4), which throws
    // ReferenceError for uninitialized (TDZ) bindings.
    if (obj.internal_kind == .module_namespace and !(key_v.bits != 0 and key_v.unbox() == .symbol)) {
        const nkey = (try coerceKey(arena, key_v)) orelse return val_mod.makeUndefined(arena);
        try namespace_mod.triggerForStringKey(arena, obj, nkey); // import-defer: [[GetOwnProperty]]
        if (!namespace_mod.hasExport(obj, nkey)) return val_mod.makeUndefined(arena);
        if (namespace_mod.isTDZ(obj, nkey)) {
            return throwReferenceErrorObj(arena, nkey);
        }
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
    if (key_v.bits != 0 and key_v.unbox() == .symbol) {
        const sym_val = key_v;
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

    const key = (try coerceKey(arena, key_v)) orelse return val_mod.makeUndefined(arena);
    // Private class elements (`#x`) are hidden from reflection.
    if (obj.isPrivate(key)) return val_mod.makeUndefined(arena);
    // Internal slots ([[PrimitiveValue]], …) are not own properties.
    if (JsObject.isInternalSlotKey(key)) return val_mod.makeUndefined(arena);

    // Array exotic "length": a synthetic own data property that is writable
    // (unless the array is non-extensible), non-enumerable, non-configurable.
    if (obj.is_array and std.mem.eql(u8, key, "length")) {
        const obj_proto_len: ?*JsObject = if (realm_mod.active_object_proto) |p| p else null;
        const dlen = try JsObject.create(arena, obj_proto_len);
        try dlen.set("value", try val_mod.makeNumber(arena, @floatFromInt(obj.getArrayLength())));
        try dlen.set("writable", try val_mod.makeBool(arena, obj.extensible));
        try dlen.set("enumerable", try val_mod.makeBool(arena, false));
        try dlen.set("configurable", try val_mod.makeBool(arena, false));
        return val_mod.makeObject(arena, dlen);
    }

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
/// ToPropertyKey returning a Value: an Object is coerced via ToPrimitive(string
/// hint) — invoking user Symbol.toPrimitive/toString/valueOf, propagating any
/// throw — and a Symbol result stays a Symbol; every other primitive is ToString'd.
fn toPropertyKeyValue(arena: std.mem.Allocator, v: Value) !Value {
    var prim = v;
    if (v.bits != 0 and v.unbox() == .object) {
        prim = (try @import("coercion.zig").toPrimitive(arena, v, .string)) orelse v;
    }
    if (prim.bits != 0 and prim.unbox() == .symbol) return prim;
    const s = try @import("../realm.zig").stringPrimitive(arena, prim);
    return val_mod.makeString(arena, s);
}

pub fn nativeObjectDefineProperty(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Proxy [[DefineOwnProperty]]: dispatch the `defineProperty` trap.
    if (args.len >= 1 and args[0].bits != 0 and args[0].unbox() == .object and
        args[0].toPtr().object.internal_kind == .proxy)
    {
        const pobj = args[0].toPtr().object;
        if (args.len < 3 or args[2].bits == 0 or args[2].unbox() != .object)
            return throwTypeError(arena, "descriptor must be an object");
        const key = try toPropertyKeyValue(arena, if (args.len >= 2) args[1] else Value{});
        if (try proxy_mod.proxyDefineProperty(arena, pobj, key, args[2])) |ok| {
            if (!ok) return throwTypeError(arena, "proxy defineProperty returned false");
            return args[0];
        }
        // No trap: forward to the target.
        if (proxy_mod.proxyTarget(pobj)) |t|
            return nativeObjectDefineProperty(arena, Value{}, &[_]Value{ t, key, args[2] });
    }
    // Functions are objects too: resolve a callable to its backing object so
    // `Object.defineProperty(fn, ...)` works (not just plain objects).
    const obj = try defineTarget(arena, if (args.len >= 1) args[0] else Value{}) orelse
        return throwTypeError(arena, "Object.defineProperty called on non-object");

    const key_raw = if (args.len >= 2) args[1] else Value{};

    // Symbol-keyed [[DefineOwnProperty]]: ordinary, never integer-indexed.
    if (key_raw.bits != 0 and key_raw.unbox() == .symbol) {
        const sdesc_val = if (args.len >= 3) args[2] else Value{};
        const sdesc = (try resolveObject(arena, sdesc_val)) orelse
            return throwTypeError(arena, "Property description must be an object");
        if (descHas(sdesc, "get") or descHas(sdesc, "set")) {
            const existing_acc = obj.getOwnSymEntry(key_raw);
            // Merge get/set with the existing accessor's handlers when the
            // descriptor omits one (partial-descriptor semantics).
            const existing_holder: ?Value = if (existing_acc) |ee|
                (if (ee.attr.is_accessor) obj.getOwnSym(key_raw) else null)
            else
                null;
            const cur_get: ?Value = if (existing_holder) |hv| hv.toPtr().object.getOwn("get") else null;
            const cur_set: ?Value = if (existing_holder) |hv| hv.toPtr().object.getOwn("set") else null;
            const getter: ?Value = if (descHas(sdesc, "get")) try descGet(arena, sdesc_val, sdesc, "get") else cur_get;
            const setter: ?Value = if (descHas(sdesc, "set")) try descGet(arena, sdesc_val, sdesc, "set") else cur_set;
            const holder = try makeAccessorHolder(arena, getter, setter);
            // Omitted enumerable/configurable inherit from the existing property.
            const sok = try obj.defineOwnAccessorSym(key_raw, holder, .{
                .enumerable = if (descHas(sdesc, "enumerable")) descTruthy(try descGet(arena, sdesc_val, sdesc, "enumerable")) else if (existing_acc) |ee| ee.attr.enumerable else false,
                .configurable = if (descHas(sdesc, "configurable")) descTruthy(try descGet(arena, sdesc_val, sdesc, "configurable")) else if (existing_acc) |ee| ee.attr.configurable else false,
            });
            if (!sok) return throwTypeError(arena, "cannot redefine property");
            return args[0];
        }
        // ES §10.1.6.3 step 4: generic descriptor (no fields) on an existing prop → true.
        const is_generic_sym = !descHas(sdesc, "value") and !descHas(sdesc, "writable") and
            !descHas(sdesc, "enumerable") and !descHas(sdesc, "configurable");
        if (is_generic_sym and obj.hasOwnSym(key_raw)) return args[0];
        // Preserve existing value/attrs for omitted descriptor fields (partial-descriptor
        // semantics: an empty {} leaves everything unchanged on a non-configurable prop).
        const existing_sym = obj.getOwnSymEntry(key_raw);
        const sval = if (descHas(sdesc, "value"))
            (try descGet(arena, sdesc_val, sdesc, "value"))
        else if (existing_sym) |ee| if (!ee.attr.is_accessor)
            (obj.getOwnSym(key_raw) orelse try val_mod.makeUndefined(arena))
        else
            try val_mod.makeUndefined(arena)
        else
            try val_mod.makeUndefined(arena);
        const sok = try obj.defineOwnDataSym(key_raw, sval, .{
            .writable = if (descHas(sdesc, "writable")) descTruthy(try descGet(arena, sdesc_val, sdesc, "writable")) else if (existing_sym) |ee| ee.attr.writable else false,
            .enumerable = if (descHas(sdesc, "enumerable")) descTruthy(try descGet(arena, sdesc_val, sdesc, "enumerable")) else if (existing_sym) |ee| ee.attr.enumerable else false,
            .configurable = if (descHas(sdesc, "configurable")) descTruthy(try descGet(arena, sdesc_val, sdesc, "configurable")) else if (existing_sym) |ee| ee.attr.configurable else false,
        });
        if (!sok) return throwTypeError(arena, "cannot redefine property");
        return args[0];
    }

    const key = (try coerceKey(arena, key_raw)) orelse "";

    // M16: Module Namespace exotic [[DefineOwnProperty]] for string keys (§10.4.6.7).
    // Symbol keys already went through OrdinaryDefineOwnProperty above.
    if (obj.internal_kind == .module_namespace) {
        try namespace_mod.triggerForStringKey(arena, obj, key); // import-defer: [[DefineOwnProperty]]
        // Step 3: key must be an export.
        if (!namespace_mod.hasExport(obj, key))
            return throwTypeError(arena, "Cannot define property on module namespace object");
        const ns_desc = if (args.len >= 3 and args[2].bits != 0 and args[2].unbox() == .object)
            args[2].toPtr().object
        else
            null;
        if (ns_desc) |d| {
            // Steps 6, 5, 6 (IsAccessorDescriptor), 7, 8.
            if (d.hasOwn("get") or d.hasOwn("set"))
                return throwTypeError(arena, "Cannot redefine module namespace export as accessor");
            if (d.hasOwn("configurable") and descTruthy(d.getOwn("configurable")))
                return throwTypeError(arena, "Cannot redefine module namespace export as configurable");
            if (d.hasOwn("enumerable") and !descTruthy(d.getOwn("enumerable")))
                return throwTypeError(arena, "Cannot redefine module namespace export as non-enumerable");
            if (d.hasOwn("writable") and !descTruthy(d.getOwn("writable")))
                return throwTypeError(arena, "Cannot redefine module namespace export as non-writable");
            if (d.hasOwn("value")) {
                const new_val = d.getOwn("value") orelse Value{};
                const b = namespace_mod.backing(obj).?;
                const cur_val = b.get(key) orelse Value{};
                // SameValue check: bits-equal covers most cases; for numbers, compare by value.
                const same = if (new_val.bits == cur_val.bits)
                    true
                else if (new_val.bits != 0 and cur_val.bits != 0 and
                    new_val.unbox() == .number and cur_val.unbox() == .number)
                    new_val.unbox().number == cur_val.unbox().number
                else
                    false;
                if (!same) return throwTypeError(arena, "Cannot change value of module namespace export");
            }
        }
        return args[0];
    }

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

    // ToPropertyDescriptor: the descriptor must be an object (functions count).
    const desc_val = if (args.len >= 3) args[2] else Value{};
    const desc = (try resolveObject(arena, desc_val)) orelse
        return throwTypeError(arena, "Property description must be an object");

    // ToPropertyDescriptor validation (§6.2.6.5): a get/set must be callable or
    // undefined, and a descriptor cannot be both an accessor and a data descriptor.
    {
        if (descHas(desc, "get")) {
            const g = try descGet(arena, desc_val, desc, "get");
            if (g.bits != 0 and g.unbox() != .undefined_ and !descIsCallable(g))
                return throwTypeError(arena, "Getter must be a function");
        }
        if (descHas(desc, "set")) {
            const s = try descGet(arena, desc_val, desc, "set");
            if (s.bits != 0 and s.unbox() != .undefined_ and !descIsCallable(s))
                return throwTypeError(arena, "Setter must be a function");
        }
        if ((descHas(desc, "get") or descHas(desc, "set")) and (descHas(desc, "value") or descHas(desc, "writable")))
            return throwTypeError(arena, "Invalid property descriptor: cannot specify both accessors and a value or writable");
    }

    // Array exotic [[DefineOwnProperty]] on "length" (ES §10.4.2.1 → ArraySetLength
    // §10.4.2.4): the new length is ToUint32(value) and must equal ToNumber(value),
    // else a RangeError is thrown. Setting a smaller length truncates the array.
    if (obj.is_array and std.mem.eql(u8, key, "length")) {
        if (descHas(desc, "get") or descHas(desc, "set"))
            return throwTypeError(arena, "cannot redefine property: length");
        if (descHas(desc, "value")) {
            const lv = try descGet(arena, desc_val, desc, "value");
            try arraySetLengthThrowing(arena, obj, lv);
        }
        return args[0];
    }

    // Classify the descriptor (§6.2.6): a generic descriptor (no value/writable/
    // get/set) applied to an EXISTING accessor must preserve it as an accessor
    // — only its enumerable/configurable change. Otherwise it would clobber the
    // getter/setter with a fresh `undefined` data property.
    const desc_is_accessor = descHas(desc, "get") or descHas(desc, "set");
    const desc_is_data = descHas(desc, "value") or descHas(desc, "writable");
    const existing_is_accessor = if (obj.ownAttr(key)) |a| a.is_accessor else false;
    if (desc_is_accessor or (!desc_is_data and existing_is_accessor)) {
        // Partial descriptor: omitted get/set/enumerable/configurable keep the
        // EXISTING accessor's handlers/attributes (redefine), else default
        // undefined/false (create). Preserving the absent handler is required by
        // ValidateAndApplyPropertyDescriptor — e.g. redefining a {get} accessor
        // with a bare {set:undefined} must leave the existing getter intact and,
        // for a non-configurable accessor, is a permitted no-op change.
        var prev_e = false;
        var prev_c = false;
        var cur_get: ?Value = null;
        var cur_set: ?Value = null;
        if (obj.ownAttr(key)) |a| { // dense-aware own-property attrs
            prev_e = a.enumerable;
            prev_c = a.configurable;
            if (a.is_accessor) {
                if (obj.ownAccessorHolder(key)) |hv| {
                    cur_get = hv.toPtr().object.getOwn("get");
                    cur_set = hv.toPtr().object.getOwn("set");
                }
            }
        }
        const getter: ?Value = if (descHas(desc, "get")) try descGet(arena, desc_val, desc, "get") else cur_get;
        const setter: ?Value = if (descHas(desc, "set")) try descGet(arena, desc_val, desc, "set") else cur_set;
        const holder = try makeAccessorHolder(arena, getter, setter);
        const attr = PropAttr{
            .enumerable = if (descHas(desc, "enumerable")) descTruthy(try descGet(arena, desc_val, desc, "enumerable")) else prev_e,
            .configurable = if (descHas(desc, "configurable")) descTruthy(try descGet(arena, desc_val, desc, "configurable")) else prev_c,
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
    if (obj.ownAttr(key)) |a| { // dense-aware own-property attrs
        // Converting an accessor → data preserves the existing enumerable/
        // configurable and defaults writable/value (§10.1.6.3 step 4.b.i).
        cur_e = a.enumerable;
        cur_c = a.configurable;
        if (!a.is_accessor) {
            cur_w = a.writable;
            cur_val = obj.getOwn(key);
            has_own_data = true;
        }
    }
    const value = if (descHas(desc, "value"))
        (try descGet(arena, desc_val, desc, "value"))
    else if (has_own_data and cur_val != null)
        cur_val.?
    else
        try val_mod.makeUndefined(arena);
    const attr = PropAttr{
        .writable = if (descHas(desc, "writable")) descTruthy(try descGet(arena, desc_val, desc, "writable")) else cur_w,
        .enumerable = if (descHas(desc, "enumerable")) descTruthy(try descGet(arena, desc_val, desc, "enumerable")) else cur_e,
        .configurable = if (descHas(desc, "configurable")) descTruthy(try descGet(arena, desc_val, desc, "configurable")) else cur_c,
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

    // Step 2: props = ToObject(Properties). null/undefined throw TypeError;
    // other primitives box (and expose no relevant enumerable own keys).
    const props_val = if (args.len >= 2) args[1] else Value{};
    if (props_val.bits == 0 or props_val.unbox() == .undefined_ or props_val.unbox() == .null_)
        return throwTypeError(arena, "Object.defineProperties: Properties must be coercible to an object");
    const props = (try resolveObject(arena, props_val)) orelse {
        // ToObject(string) yields a String exotic whose indexed own properties are
        // enumerable single-char strings; ToPropertyDescriptor of the first char
        // throws TypeError (a non-object descriptor). Empty string is a no-op.
        if (props_val.unbox() == .string and props_val.toPtr().string.len > 0)
            return throwTypeError(arena, "Property description must be an object");
        const realm_mod = @import("../realm.zig");
        const boxed = try realm_mod.toObjectForThis(arena, props_val);
        if (boxed.bits != 0 and boxed.unbox() == .object) {
            return defineFromProps(arena, args[0], boxed, boxed.toPtr().object);
        }
        return args[0];
    };
    return defineFromProps(arena, args[0], props_val, props);
}

/// Shared body of Object.defineProperties: for each enumerable own key of `props`,
/// ToPropertyDescriptor(Get(props, key)) then DefinePropertyOrThrow(O, key, desc).
/// A non-object descriptor value makes ToPropertyDescriptor throw TypeError.
fn defineFromProps(arena: std.mem.Allocator, target: Value, props_val: Value, props: *JsObject) anyerror!Value {
    // Delegate each property to Object.defineProperty so exotic [[DefineOwnProperty]]
    // (TypedArray integer-indexed elements, Proxy, module namespace) is honored
    // instead of writing straight to ordinary property storage.
    for (props.ownKeys()) |k| {
        if (!props.isEnumerable(k)) continue;
        // Get(props, k) — invokes getters (with props as the receiver), so an
        // accessor-backed descriptor property is honored with its side effects.
        const desc_val = try descGet(arena, props_val, props, k);
        // ToPropertyDescriptor requires an object (functions count); a primitive
        // descriptor value throws TypeError.
        if ((try resolveObject(arena, desc_val)) == null)
            return throwTypeError(arena, "Property description must be an object");
        const key_val = try val_mod.makeString(arena, k);
        _ = try nativeObjectDefineProperty(arena, target, &[_]Value{ target, key_val, desc_val });
    }
    return target;
}

/// Object.freeze(o): freeze the object (non-extensible, all props non-writable/non-configurable).
pub fn nativeObjectFreeze(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    const obj = args[0].toPtr().object;
    // Module Namespace: [[DefineOwnProperty]] rejects {writable:false} for exports
    // (§10.4.6.7), so SetIntegrityLevel("frozen") always throws TypeError.
    if (obj.internal_kind == .module_namespace) {
        const names = try namespace_mod.sortedNames(arena, obj);
        if (names.len > 0) return throwTypeError(arena, "Cannot define property on module namespace");
    }
    // TypedArray SetIntegrityLevel(frozen) throws TypeError when either:
    //  - [[PreventExtensions]] fails, which it does for any TA on a non-shared
    //    resizable buffer (IsTypedArrayFixedLength is false), or
    //  - a non-empty fixed-length TA must make its integer indices non-writable,
    //    which [[DefineOwnProperty]] rejects.
    // An empty fixed-length TA has no integer keys, so freezing it succeeds.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        const resizable = td.ab.max_byte_length != null and !td.ab.shared;
        const len = if (ta_mod.taIsOob(td)) 0 else ta_mod.taCurrentLen(td);
        // SetIntegrityLevel runs PreventExtensions first; for a resizable TA that
        // itself fails (object stays extensible), but for a non-empty fixed-length
        // TA it succeeds (object becomes non-extensible) before the per-index
        // DefineOwnProperty throws.
        if (resizable) return throwTypeError(arena, "Cannot freeze this TypedArray");
        if (len > 0) {
            obj.preventExtensionsSelf();
            return throwTypeError(arena, "Cannot freeze this TypedArray");
        }
    }
    obj.freezeSelf();
    return args[0];
}

/// Object.seal(o): seal the object (non-extensible, all props non-configurable).
pub fn nativeObjectSeal(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    const obj = args[0].toPtr().object;
    // TypedArray SetIntegrityLevel(sealed) throws TypeError when either the
    // backing buffer is resizable (PreventExtensions fails) or the TA is
    // non-empty (its integer indices cannot be made non-configurable). An empty
    // fixed-length TA has no integer keys, so sealing it succeeds.
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        const resizable = td.ab.max_byte_length != null and !td.ab.shared;
        const len = if (ta_mod.taIsOob(td)) 0 else ta_mod.taCurrentLen(td);
        // PreventExtensions succeeds for a non-empty fixed-length TA (becomes
        // non-extensible) before the per-index DefineOwnProperty throws; it fails
        // outright for a resizable TA (stays extensible).
        if (resizable) return throwTypeError(arena, "Cannot seal this TypedArray");
        if (len > 0) {
            obj.preventExtensionsSelf();
            return throwTypeError(arena, "Cannot seal this TypedArray");
        }
    }
    obj.sealSelf();
    return args[0];
}

/// Object.preventExtensions(o): prevent new own properties from being added.
pub fn nativeObjectPreventExtensions(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeUndefined(arena);
    if (args[0].unbox() != .object) return args[0];
    const obj = args[0].toPtr().object;
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyPreventExtensions(arena, obj)) |ok| {
            if (!ok) return throwTypeError(arena, "proxy preventExtensions returned false");
            return args[0];
        }
        if (proxy_mod.proxyTarget(obj)) |t| return nativeObjectPreventExtensions(arena, Value{}, &[_]Value{t});
    }
    obj.preventExtensionsSelf();
    return args[0];
}

/// Object.isFrozen(o): primitives → true; objects → isFrozenSelf().
pub fn nativeObjectIsFrozen(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, true);
    if (args[0].unbox() != .object) return val_mod.makeBool(arena, true);
    const obj = args[0].toPtr().object;
    // Module Namespace exports always have writable:true → namespace is never frozen.
    if (obj.internal_kind == .module_namespace) {
        const names = try namespace_mod.sortedNames(arena, obj);
        if (names.len > 0) return val_mod.makeBool(arena, false);
    }
    // A non-empty TypedArray is never frozen: its integer indices stay writable
    // and configurable (they are exotic, not in the property table).
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        const len = if (ta_mod.taIsOob(td)) 0 else ta_mod.taCurrentLen(td);
        if (len > 0) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, obj.isFrozenSelf());
}

/// Object.isSealed(o): primitives → true; objects → isSealedSelf().
pub fn nativeObjectIsSealed(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, true);
    if (args[0].unbox() != .object) return val_mod.makeBool(arena, true);
    const obj = args[0].toPtr().object;
    // A non-empty TypedArray is never sealed: its integer indices stay
    // configurable (they are exotic, not in the property table).
    if (obj.internal_kind == .typed_array and obj.internal_slot != null) {
        const ta_mod = @import("typed_array.zig");
        const td: *ta_mod.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
        const len = if (ta_mod.taIsOob(td)) 0 else ta_mod.taCurrentLen(td);
        if (len > 0) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, obj.isSealedSelf());
}

/// Object.isExtensible(o): primitives → false; objects → extensible flag.
pub fn nativeObjectIsExtensible(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) return val_mod.makeBool(arena, false);
    return switch (args[0].unbox()) {
        .object => |o| blk: {
            if (o.internal_kind == .proxy) {
                if (try proxy_mod.proxyIsExtensible(arena, o)) |b| break :blk val_mod.makeBool(arena, b);
                if (proxy_mod.proxyTarget(o)) |t| break :blk nativeObjectIsExtensible(arena, Value{}, &[_]Value{t});
            }
            break :blk val_mod.makeBool(arena, o.extensible);
        },
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
    // import-defer: [[OwnPropertyKeys]] triggers evaluation; it also clears the
    // internal deferred-id symbol so it does not leak as an own symbol key.
    if (obj.internal_kind == .module_namespace) try namespace_mod.triggerAll(arena, obj);
    var i: u32 = 0;
    for (obj.symKeys()) |sp| {
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(idx_key, sp.key);
        i += 1;
    }
    arr.array_length = i;
    return val_mod.makeObject(arena, arr);
}
