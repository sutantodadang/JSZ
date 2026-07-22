// SPDX-License-Identifier: Apache-2.0
//! Phase 4d: Function.prototype — call, apply, bind.
//!
//! BoundFunction is stored as a JsObject with internal_kind = .bound_function.
//! The internal_slot points to a BoundData struct (arena-allocated).
//! GC traverses props naturally (no markObject change needed).
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const proxy_mod = @import("proxy.zig");

/// Data stored inside a bound function object's internal_slot.
pub const BoundData = struct {
    target: Value,
    this_val: Value,
    prefix: []Value,
};

/// Invoke any callable JS value synchronously.
/// Uses the active_context thread-local.
/// On JS exception: sets pending_exception and returns error.JsException.
pub fn invokeCallback(arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
    if (fn_val.bits == 0) {
        // undefined is not a function
        realm_mod.pending_exception = try makeTypeError(arena, "undefined is not a function");
        return error.JsException;
    }
    // Check reentrant depth.
    realm_mod.callback_depth += 1;
    defer realm_mod.callback_depth -= 1;
    if (realm_mod.callback_depth > 1000) {
        realm_mod.pending_exception = try makeRangeError(arena, "Maximum call stack size exceeded");
        return error.JsException;
    }

    // A native constructor sets `active_constructing` (read at its entry for the
    // requires-new check) and only clears it on return. When such a constructor
    // re-enters JS mid-body to drive an iterator — `new Set(gen)`, `new Map(gen)`,
    // `new Int8Array(gen)`, `new AggregateError(gen)` — that ordinary call must
    // not observe the stale flag, or a generator's `next` is misread as a
    // constructor call. Clear it for the duration of the callback and restore it.
    const saved_constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    defer realm_mod.active_constructing = saved_constructing;

    const inner = fn_val.unbox();
    switch (inner) {
        .native_function => |fn_ptr| {
            return fn_ptr.invoke(arena, this_val, args) catch |e| {
                if (e == error.JsException) return error.JsException;
                return error.OutOfMemory;
            };
        },
        .function, .bc_function => {
            // Delegate to active_context.
            if (realm_mod.active_context) |ctx| {
                return ctx.invokeJs(arena, this_val, fn_val, args);
            }
            realm_mod.pending_exception = try makeTypeError(arena, "no active context for JS callback");
            return error.JsException;
        },
        .object => |obj| {
            if (obj.internal_kind == .bound_function) {
                // Unpack bound function.
                if (obj.internal_slot) |slot| {
                    const bd: *BoundData = @ptrCast(@alignCast(slot));
                    // Combine prefix + runtime args.
                    const total = bd.prefix.len + args.len;
                    var combined = try arena.alloc(Value, total);
                    for (bd.prefix, 0..) |v, i| combined[i] = v;
                    for (args, 0..) |v, i| combined[bd.prefix.len + i] = v;
                    return invokeCallback(arena, bd.this_val, bd.target, combined);
                }
            }
            // Object with __call__: delegate via active_context.
            if (realm_mod.active_context) |ctx| {
                return ctx.invokeJs(arena, this_val, fn_val, args);
            }
            realm_mod.pending_exception = try makeTypeError(arena, "object is not callable");
            return error.JsException;
        },
        else => {
            realm_mod.pending_exception = try makeTypeError(arena, "value is not a function");
            return error.JsException;
        },
    }
}

fn makeTypeError(arena: std.mem.Allocator, msg: []const u8) !Value {
    const proto = realm_mod.error_proto_TypeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, msg);
    const name_val = try val_mod.makeString(arena, "TypeError");
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    return val_mod.makeObject(arena, obj);
}

fn makeRangeError(arena: std.mem.Allocator, msg: []const u8) !Value {
    const proto = realm_mod.error_proto_RangeError;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, msg);
    const name_val = try val_mod.makeString(arena, "RangeError");
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    return val_mod.makeObject(arena, obj);
}

/// %ThrowTypeError% — the shared poison-pill accessor used for the "caller"
/// and "arguments" restricted properties on Function.prototype (and on strict /
/// bound functions). Always throws a TypeError.
pub fn nativeThrowTypeError(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = this_val;
    _ = args;
    realm_mod.pending_exception = try makeTypeError(arena, "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
    return error.JsException;
}

// ------------------------------------------------------------------ Function.prototype methods ---

/// Function.prototype.call(thisArg, ...args)
pub fn nativeFunctionCall(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // `this_val` is the function being called.
    const fn_val = this_val;
    const call_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    return invokeCallback(arena, call_this, fn_val, call_args) catch |e| {
        if (e == error.JsException) return error.JsException;
        return e;
    };
}

/// Function.prototype.apply(thisArg, argArray)
pub fn nativeFunctionApply(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const fn_val = this_val;
    // Step 1: If IsCallable(func) is false, throw a TypeError.
    if (!isCallableFn(fn_val)) {
        realm_mod.pending_exception = try makeTypeError(arena, "Function.prototype.apply called on non-callable");
        return error.JsException;
    }
    const call_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // Step 2: If argArray is undefined or null, call with no arguments.
    const arr_val = if (args.len > 1) args[1] else Value{};
    if (arr_val.bits == 0 or arr_val.unbox() == .undefined_ or arr_val.unbox() == .null_) {
        return invokeCallback(arena, call_this, fn_val, &[_]Value{}) catch |e| {
            if (e == error.JsException) return error.JsException;
            return e;
        };
    }
    // Step 3: argList = CreateListFromArrayLike(argArray).
    const call_args = try createListFromArrayLike(arena, arr_val);
    return invokeCallback(arena, call_this, fn_val, call_args) catch |e| {
        if (e == error.JsException) return error.JsException;
        return e;
    };
}

/// CreateListFromArrayLike (ES §7.3.18): reads "length" (ToLength) and each
/// indexed element via [[Get]]. Throws TypeError if `obj` is not an Object.
fn createListFromArrayLike(arena: std.mem.Allocator, obj: Value) ![]Value {
    if (obj.bits == 0 or obj.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeError(arena, "CreateListFromArrayLike called on non-object");
        return error.JsException;
    }
    const ctx = realm_mod.active_context orelse {
        realm_mod.pending_exception = try makeTypeError(arena, "no active context");
        return error.JsException;
    };
    const len_v = try ctx.getProp(arena, obj, "length");
    const len = toLengthClamp(len_v);
    const out = try arena.alloc(Value, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        out[i] = try ctx.getProp(arena, obj, key);
    }
    return out;
}

/// ToLength restricted to what array-like `length` values in practice carry:
/// a finite non-negative integer count, clamped into [0, 2^32-1] for allocation.
fn toLengthClamp(v: Value) usize {
    if (v.bits == 0) return 0;
    const n: f64 = switch (v.unbox()) {
        .number => v.unbox().number,
        .boolean => if (v.unbox().boolean) 1 else 0,
        .string => std.fmt.parseFloat(f64, v.toPtr().string) catch 0,
        else => 0,
    };
    if (std.math.isNan(n) or n <= 0) return 0;
    const capped = @min(n, @as(f64, @floatFromInt(std.math.maxInt(u32))));
    return @intFromFloat(std.math.trunc(capped));
}

/// IsCallable for the four callable representations plus bound functions,
/// callable proxies, and objects carrying a `__call__` slot.
pub fn isCallableFn(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .native_function, .bc_function, .function => true,
        .object => |o| {
            if (o.internal_kind == .bound_function) return true;
            if (o.internal_kind == .proxy) {
                if (realm_mod.active_sym_proxy_target) |sym| {
                    if (o.getOwnSym(sym)) |t| return isCallableFn(t);
                }
                return false;
            }
            return o.get("__call__") != null;
        },
        else => false,
    };
}

/// `[[GetPrototypeOf]]` as a `?*JsObject` (null = null prototype). Proxy objects
/// dispatch their `getPrototypeOf` trap (forwarding to the target when absent),
/// so a throwing trap propagates and nested proxies resolve recursively.
fn getPrototypeOfV(arena: std.mem.Allocator, obj: *JsObject) anyerror!?*JsObject {
    if (obj.internal_kind == .proxy) {
        if (try proxy_mod.proxyGetPrototypeOf(arena, obj)) |res| {
            if (res.bits != 0 and res.unbox() == .object) return res.toPtr().object;
            return null; // trap returned null → null prototype
        }
        // No trap: forward to the target's [[GetPrototypeOf]].
        const target = proxy_mod.proxyTarget(obj) orelse return null;
        if (target.bits != 0 and target.unbox() == .object) return getPrototypeOfV(arena, target.toPtr().object);
        return null;
    }
    return obj.proto;
}

/// OrdinaryHasInstance(C, V) — the abstract operation behind
/// `Function.prototype[@@hasInstance]` (ECMA-262 §20.2.3.6 / §7.3.20).
fn ordinaryHasInstance(arena: std.mem.Allocator, c_val: Value, v_val: Value) anyerror!bool {
    // 1. If IsCallable(C) is false, return false.
    if (!isCallableFn(c_val)) return false;
    // 2. If C has a [[BoundTargetFunction]], return InstanceofOperator(V, target).
    if (c_val.bits != 0 and c_val.unbox() == .object and
        c_val.toPtr().object.internal_kind == .bound_function)
    {
        if (c_val.toPtr().object.internal_slot) |slot| {
            const bd: *BoundData = @ptrCast(@alignCast(slot));
            return ordinaryHasInstance(arena, bd.target, v_val);
        }
    }
    // 3. If V is not an Object, return false. Functions (bc/native/legacy) are
    // objects too — their [[Prototype]] chain is walked below.
    if (v_val.bits == 0) return false;
    const v_is_object = switch (v_val.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
    if (!v_is_object) return false;
    // 4. Let P be ? Get(C, "prototype").
    const ctx = realm_mod.active_context orelse return false;
    const p = try ctx.getProp(arena, c_val, "prototype");
    // 5. If P is not an Object, throw a TypeError.
    if (p.bits == 0 or p.unbox() != .object) {
        realm_mod.pending_exception = try makeTypeError(arena, "Function has non-object prototype in instanceof check");
        return error.JsException;
    }
    const p_obj = p.toPtr().object;
    // 6-7. Walk V's [[GetPrototypeOf]] chain, starting from V's own prototype.
    var cur_proto: ?*JsObject = switch (v_val.unbox()) {
        .object => try getPrototypeOfV(arena, v_val.toPtr().object),
        // A bc function's [[Prototype]] is its backing object's proto (a subclass
        // ctor points at its superclass), else %Function.prototype%.
        .bc_function => blk: {
            const cl = v_val.unbox().bc_function;
            if (cl.obj) |op| {
                const o: *JsObject = @ptrCast(@alignCast(op));
                break :blk o.proto;
            }
            break :blk realm_mod.active_function_proto;
        },
        else => realm_mod.active_function_proto,
    };
    var depth: usize = 0;
    while (cur_proto) |pr| {
        if (depth >= 100_000) break;
        depth += 1;
        if (pr == p_obj) return true;
        cur_proto = try getPrototypeOfV(arena, pr);
    }
    return false;
}

/// `Function.prototype[Symbol.hasInstance](V)` — OrdinaryHasInstance(this, V).
pub fn nativeFunctionHasInstance(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    return val_mod.makeBool(arena, try ordinaryHasInstance(arena, this_val, v));
}

/// Function.prototype.bind(thisArg, ...prefix) -> BoundFunction
pub fn nativeFunctionBind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const fn_val = this_val;
    // Step 1: If IsCallable(Target) is false, throw a TypeError.
    if (!isCallableFn(fn_val)) {
        realm_mod.pending_exception = try makeTypeError(arena, "Function.prototype.bind called on non-callable");
        return error.JsException;
    }
    const bind_this = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const prefix: []Value = if (args.len > 1) blk: {
        const p = try arena.alloc(Value, args.len - 1);
        for (args[1..], 0..) |v, i| p[i] = v;
        break :blk p;
    } else &[_]Value{};

    // Create bound data.
    const bd = try arena.create(BoundData);
    bd.* = BoundData{ .target = fn_val, .this_val = bind_this, .prefix = prefix };

    // Create bound function object. Proto is %Function.prototype% so a bound
    // function inherits call/apply/bind (e.g. re-binding `f.bind(a).bind(b)`).
    const bound_obj = try JsObject.create(arena, realm_mod.active_function_proto);
    bound_obj.internal_kind = .bound_function;
    bound_obj.internal_slot = bd;

    // SetFunctionLength (ES §20.2.3.2): read the target's "length" via [[Get]],
    // apply ToIntegerOrInfinity, then L = max(targetLen - boundArgs, 0) with
    // +∞ preserved and -∞ mapped to 0. Non-writable, non-enumerable, configurable.
    const target_len = try getFnProp(arena, fn_val, "length");
    var blen: f64 = 0;
    if (target_len.bits != 0 and target_len.unbox() == .number) {
        const tl = target_len.unbox().number;
        if (std.math.isPositiveInf(tl)) {
            blen = std.math.inf(f64);
        } else if (std.math.isNegativeInf(tl) or std.math.isNan(tl)) {
            blen = 0;
        } else {
            const ti = std.math.trunc(tl); // ToIntegerOrInfinity (finite here)
            blen = @max(0.0, ti - @as(f64, @floatFromInt(prefix.len)));
        }
    }
    _ = try bound_obj.defineOwnData("length", try val_mod.makeNumber(arena, blen), .{ .writable = false, .enumerable = false, .configurable = true });

    // SetFunctionName: name = "bound " + (target.name if a String, else "").
    const target_name = try getFnProp(arena, fn_val, "name");
    const nm: []const u8 = if (target_name.bits != 0 and target_name.unbox() == .string)
        target_name.toPtr().string
    else
        "";
    const bname = try std.fmt.allocPrint(arena, "bound {s}", .{nm});
    _ = try bound_obj.defineOwnData("name", try val_mod.makeString(arena, bname), .{ .writable = false, .enumerable = false, .configurable = true });

    return val_mod.makeObject(arena, bound_obj);
}

/// [[Get]] a property of a function-valued target, honouring redefined own
/// properties (via the active context's property machinery). Falls back to the
/// intrinsic length/name when no active context is available.
fn getFnProp(arena: std.mem.Allocator, v: Value, key: []const u8) !Value {
    if (realm_mod.active_context) |ctx| {
        return ctx.getProp(arena, v, key);
    }
    const tln = targetLenName(v);
    if (std.mem.eql(u8, key, "length")) return val_mod.makeNumber(arena, tln.len);
    return val_mod.makeString(arena, tln.name);
}

/// Read a function value's ECMAScript `.length` (declared param count) and
/// `.name` across the four callable representations, for Function.prototype.bind.
fn targetLenName(v: Value) struct { len: f64, name: []const u8 } {
    if (v.bits == 0) return .{ .len = 0, .name = "" };
    switch (v.unbox()) {
        .native_function => |e| return .{ .len = @floatFromInt(e.length), .name = e.name orelse "" },
        .function => |fv| return .{ .len = @floatFromInt(fv.params.len), .name = fv.name orelse "" },
        .bc_function => |cl| return .{ .len = @floatFromInt(cl.func.arity), .name = cl.effectiveName() },
        .object => |o| {
            var l: f64 = 0;
            if (o.getOwn("length")) |lv| {
                if (lv.bits != 0 and lv.unbox() == .number) l = lv.unbox().number;
            }
            var nm: []const u8 = "";
            if (o.getOwn("name")) |nv| {
                if (nv.bits != 0 and nv.unbox() == .string) nm = nv.toPtr().string;
            }
            return .{ .len = l, .name = nm };
        },
        else => return .{ .len = 0, .name = "" },
    }
}
