// SPDX-License-Identifier: Apache-2.0
//! ES2025 Explicit Resource Management: DisposableStack + AsyncDisposableStack.
//!
//! A DisposableStack collects "disposable resources" (values carrying a
//! `[Symbol.dispose]` method, or ad-hoc dispose callbacks) and runs them in
//! LIFO order when `dispose()` is called, aggregating any thrown errors into a
//! SuppressedError chain. AsyncDisposableStack mirrors this with
//! `[Symbol.asyncDispose]` and a promise-returning `disposeAsync()`.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const PropAttr = @import("../../object/object.zig").PropAttr;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const function_proto = @import("function_proto.zig");
const promise_mod = @import("promise.zig");
const Heap = @import("../../gc/heap.zig").Heap;

/// One entry in a DisposeCapability's resource stack. `method` is called with
/// `this_val` as the receiver and, when `has_arg` is set, `arg` as its sole
/// argument (the `adopt` case, which passes the adopted value).
const DisposeRecord = struct {
    this_val: Value,
    method: Value,
    arg: Value = Value{},
    has_arg: bool = false,
};

pub const DisposableStackData = struct {
    /// true once `dispose()`/`disposeAsync()`/`move()` has run.
    disposed: bool = false,
    records: std.ArrayListUnmanaged(DisposeRecord) = .{},
};

/// %DisposableStack.prototype% / %AsyncDisposableStack.prototype% — stored so
/// registerSymbols can attach @@toStringTag and @@dispose / @@asyncDispose.
pub var active_disposable_proto: ?*JsObject = null;
pub var active_async_disposable_proto: ?*JsObject = null;
var active_disposable_ctor: ?*JsObject = null;
var active_async_disposable_ctor: ?*JsObject = null;

// ---- helpers --------------------------------------------------------------

fn makeObj(arena: std.mem.Allocator, proto: ?*JsObject, kind: @TypeOf((@as(JsObject, undefined)).internal_kind)) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    obj.internal_kind = kind;
    return val_mod.makeObject(arena, obj);
}

fn makeErr(arena: std.mem.Allocator, proto: ?*JsObject, name: []const u8, msg: []const u8) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, name));
    try obj.set("message", try val_mod.makeString(arena, msg));
    return val_mod.makeObject(arena, obj);
}

fn typeError(arena: std.mem.Allocator, msg: []const u8) !Value {
    return makeErr(arena, realm_mod.error_proto_TypeError, "TypeError", msg);
}

fn refError(arena: std.mem.Allocator, msg: []const u8) !Value {
    return makeErr(arena, realm_mod.error_proto_ReferenceError, "ReferenceError", msg);
}

fn throwType(arena: std.mem.Allocator, msg: []const u8) anyerror {
    realm_mod.pending_exception = try typeError(arena, msg);
    return error.JsException;
}

fn throwRef(arena: std.mem.Allocator, msg: []const u8) anyerror {
    realm_mod.pending_exception = try refError(arena, msg);
    return error.JsException;
}

/// Build a SuppressedError(error, suppressed) value directly (mirrors the
/// SuppressedError constructor: non-enumerable `error`/`suppressed`, empty
/// `message`, name inherited from %SuppressedError.prototype%).
fn suppressedError(arena: std.mem.Allocator, err: Value, suppressed: Value) !Value {
    const proto = realm_mod.error_proto_SuppressedError;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    const a: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try obj.defineOwnData("message", try val_mod.makeString(arena, ""), a);
    _ = try obj.defineOwnData("error", err, a);
    _ = try obj.defineOwnData("suppressed", suppressed, a);
    return val_mod.makeObject(arena, obj);
}

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .native_function, .bc_function, .function => true,
        .object => |o| o.is_callable_intrinsic or o.get("__call__") != null or o.internal_kind == .bound_function,
        else => false,
    };
}

/// True for the values that carry properties / can expose a @@dispose method:
/// ordinary objects and every function representation (functions are objects).
fn isObjectLike(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
}

fn isNullOrUndefined(v: Value) bool {
    if (v.bits == 0) return true;
    return switch (v.unbox()) {
        .undefined_, .null_ => true,
        else => false,
    };
}

/// RequireInternalSlot(this, [[DisposableState]]): returns the backing data or
/// throws a TypeError when `this` is not a matching stack object.
fn requireData(arena: std.mem.Allocator, this_val: Value, kind: @TypeOf((@as(JsObject, undefined)).internal_kind), what: []const u8) !*DisposableStackData {
    if (this_val.bits == 0 or this_val.unbox() != .object) return throwType(arena, what);
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != kind or obj.internal_slot == null) return throwType(arena, what);
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// GetMethod(V, key) for a well-known symbol: null/undefined → null result;
/// a non-callable value throws TypeError.
fn getMethodSym(arena: std.mem.Allocator, v: Value, sym: Value) !?Value {
    const ctx = realm_mod.active_context orelse return null;
    const m = try ctx.getPropSym(arena, v, sym);
    if (isNullOrUndefined(m)) return null;
    if (!isCallable(m)) return throwType(arena, "@@dispose is not callable");
    return m;
}

// ---- DisposableStack ------------------------------------------------------

fn nativeDisposableCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return throwType(arena, "Constructor DisposableStack requires 'new'");
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, active_disposable_proto, .disposable_stack);
    const obj = out.toPtr().object;
    obj.internal_kind = .disposable_stack;
    const d = try arena.create(DisposableStackData);
    d.* = .{};
    obj.internal_slot = d;
    return out;
}

fn nativeDisposed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "get disposed called on incompatible receiver");
    return val_mod.makeBool(arena, d.disposed);
}

fn nativeUse(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "use called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "DisposableStack already disposed");
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    // AddDisposableResource(capability, value, sync-dispose): null/undefined is a
    // no-op; otherwise value must be an Object exposing a callable @@dispose.
    if (!isNullOrUndefined(value)) {
        if (!isObjectLike(value)) return throwType(arena, "value is not disposable (not an object)");
        const disp_sym = realm_mod.active_sym_dispose orelse return throwType(arena, "Symbol.dispose unavailable");
        const method = (try getMethodSym(arena, value, disp_sym)) orelse
            return throwType(arena, "value is not disposable (no [Symbol.dispose])");
        try d.records.append(arena, .{ .this_val = value, .method = method });
    }
    return value;
}

fn nativeAdopt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "adopt called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "DisposableStack already disposed");
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const on_dispose = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (!isCallable(on_dispose)) return throwType(arena, "onDispose is not callable");
    // The disposer closure is `() => onDispose(value)`: receiver undefined, the
    // adopted value passed as the sole argument.
    try d.records.append(arena, .{ .this_val = try val_mod.makeUndefined(arena), .method = on_dispose, .arg = value, .has_arg = true });
    return value;
}

fn nativeDefer(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "defer called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "DisposableStack already disposed");
    const on_dispose = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (!isCallable(on_dispose)) return throwType(arena, "onDispose is not callable");
    try d.records.append(arena, .{ .this_val = try val_mod.makeUndefined(arena), .method = on_dispose });
    return try val_mod.makeUndefined(arena);
}

fn nativeMove(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "move called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "DisposableStack already disposed");
    const new_val = try makeObj(arena, active_disposable_proto, .disposable_stack);
    const nd = try arena.create(DisposableStackData);
    nd.* = .{ .records = d.records };
    new_val.toPtr().object.internal_slot = nd;
    // Transfer the capability to the new stack and dispose the source.
    d.records = .{};
    d.disposed = true;
    return new_val;
}

/// DisposeResources: run every record's dispose method in reverse (LIFO) order,
/// aggregating thrown errors into a SuppressedError chain. Shared by both the
/// sync `dispose()` and the async drain.
fn disposeResources(arena: std.mem.Allocator, d: *DisposableStackData) anyerror!void {
    return disposeResourcesSeeded(arena, d, null, false);
}

/// DisposeResources seeded with an existing abrupt completion `seed` (the value
/// thrown by the guarded body). Each disposer that throws suppresses the current
/// completion: the result is `SuppressedError(disposerError, priorCompletion)`,
/// so a body error threads to the innermost `suppressed` of the chain. When
/// `is_async` is set (AsyncDisposeResources), each disposer's returned value is
/// awaited, so an async disposer that *rejects* is captured just like a throw.
fn disposeResourcesSeeded(arena: std.mem.Allocator, d: *DisposableStackData, seed: ?Value, is_async: bool) anyerror!void {
    var completion: ?Value = seed; // pending thrown value, if any
    var i: usize = d.records.items.len;
    while (i > 0) {
        i -= 1;
        const r = d.records.items[i];
        const call_args: []const Value = if (r.has_arg) &[_]Value{r.arg} else &[_]Value{};
        var thrown: ?Value = null;
        if (function_proto.invokeCallback(arena, r.this_val, r.method, call_args)) |rv| {
            // Await the disposer's result so an async @@asyncDispose that returns
            // a rejected promise surfaces as a disposal error (the await is a
            // synchronous microtask drain).
            if (is_async) {
                if (promise_mod.awaitValue(arena, rv)) |_| {} else |e| {
                    if (e != error.JsException) return e;
                    thrown = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
                    realm_mod.pending_exception = Value{};
                }
            }
        } else |e| {
            if (e != error.JsException) return e;
            thrown = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
            realm_mod.pending_exception = Value{};
        }
        if (thrown) |t| {
            if (completion) |prev| {
                completion = try suppressedError(arena, t, prev);
            } else {
                completion = t;
            }
        }
    }
    if (completion) |c| {
        realm_mod.pending_exception = c;
        return error.JsException;
    }
}

fn nativeDispose(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .disposable_stack, "dispose called on incompatible receiver");
    if (d.disposed) return try val_mod.makeUndefined(arena);
    d.disposed = true;
    try disposeResources(arena, d);
    return try val_mod.makeUndefined(arena);
}

// ---- AsyncDisposableStack -------------------------------------------------

fn nativeAsyncDisposableCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return throwType(arena, "Constructor AsyncDisposableStack requires 'new'");
    var out = this_val;
    if (out.bits == 0 or out.unbox() != .object) out = try makeObj(arena, active_async_disposable_proto, .async_disposable_stack);
    const obj = out.toPtr().object;
    obj.internal_kind = .async_disposable_stack;
    const d = try arena.create(DisposableStackData);
    d.* = .{};
    obj.internal_slot = d;
    return out;
}

fn nativeAsyncDisposed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .async_disposable_stack, "get disposed called on incompatible receiver");
    return val_mod.makeBool(arena, d.disposed);
}

fn nativeAsyncUse(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .async_disposable_stack, "use called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "AsyncDisposableStack already disposed");
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (!isNullOrUndefined(value)) {
        if (!isObjectLike(value)) return throwType(arena, "value is not disposable (not an object)");
        // async-dispose: prefer @@asyncDispose, fall back to @@dispose.
        var method: ?Value = null;
        if (realm_mod.active_sym_async_dispose) |s| method = try getMethodSym(arena, value, s);
        if (method == null) {
            if (realm_mod.active_sym_dispose) |s| method = try getMethodSym(arena, value, s);
        }
        const m = method orelse return throwType(arena, "value is not async-disposable");
        try d.records.append(arena, .{ .this_val = value, .method = m });
    }
    return value;
}

fn nativeAsyncAdopt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .async_disposable_stack, "adopt called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "AsyncDisposableStack already disposed");
    const value = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const on_dispose = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (!isCallable(on_dispose)) return throwType(arena, "onDispose is not callable");
    try d.records.append(arena, .{ .this_val = try val_mod.makeUndefined(arena), .method = on_dispose, .arg = value, .has_arg = true });
    return value;
}

fn nativeAsyncDefer(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .async_disposable_stack, "defer called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "AsyncDisposableStack already disposed");
    const on_dispose = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (!isCallable(on_dispose)) return throwType(arena, "onDispose is not callable");
    try d.records.append(arena, .{ .this_val = try val_mod.makeUndefined(arena), .method = on_dispose });
    return try val_mod.makeUndefined(arena);
}

fn nativeAsyncMove(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireData(arena, this_val, .async_disposable_stack, "move called on incompatible receiver");
    if (d.disposed) return throwRef(arena, "AsyncDisposableStack already disposed");
    const new_val = try makeObj(arena, active_async_disposable_proto, .async_disposable_stack);
    const nd = try arena.create(DisposableStackData);
    nd.* = .{ .records = d.records };
    new_val.toPtr().object.internal_slot = nd;
    d.records = .{};
    d.disposed = true;
    return new_val;
}

/// disposeAsync(): synchronously drains the disposers (awaiting is approximated
/// by the engine's synchronous callback model) and returns a promise that is
/// resolved with undefined or rejected with the aggregated error.
fn nativeDisposeAsync(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = requireData(arena, this_val, .async_disposable_stack, "disposeAsync called on incompatible receiver") catch {
        // RequireInternalSlot failure is reported by rejecting the returned promise.
        const err = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
        realm_mod.pending_exception = Value{};
        return promise_mod.makeRejectedPromise(arena, err);
    };
    if (d.disposed) return promise_mod.makeResolvedPromise(arena, try val_mod.makeUndefined(arena));
    d.disposed = true;
    if (disposeResourcesSeeded(arena, d, null, true)) |_| {
        return promise_mod.makeResolvedPromise(arena, try val_mod.makeUndefined(arena));
    } else |e| {
        if (e != error.JsException) return e;
        const err = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
        realm_mod.pending_exception = Value{};
        return promise_mod.makeRejectedPromise(arena, err);
    }
}

/// `__usingDispose__(stack, hasError, error)` — the disposal step of a `using`
/// scope's try/finally desugar. Runs DisposeResources over `stack`, seeded with
/// the scope body's thrown `error` when `hasError` is true, so a body error
/// becomes the innermost `suppressed` of any SuppressedError chain. When the
/// body threw but no disposer does, the original error is re-thrown as-is.
pub fn nativeUsingDispose(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const stack = if (args.len > 0) args[0] else Value{};
    const has_err = args.len > 1 and isTrue(args[1]);
    const err: ?Value = if (has_err) (if (args.len > 2) args[2] else try val_mod.makeUndefined(arena)) else null;
    const d = try requireData(arena, stack, .disposable_stack, "using dispose on incompatible receiver");
    if (d.disposed) {
        if (err) |e| {
            realm_mod.pending_exception = e;
            return error.JsException;
        }
        return val_mod.makeUndefined(arena);
    }
    d.disposed = true;
    try disposeResourcesSeeded(arena, d, err, false);
    return val_mod.makeUndefined(arena);
}

/// Async counterpart of `__usingDispose__`: returns a promise that settles once
/// the (approximated-synchronous) disposal drains — rejected with the aggregated
/// completion, resolved with undefined otherwise.
pub fn nativeUsingDisposeAsync(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const stack = if (args.len > 0) args[0] else Value{};
    const has_err = args.len > 1 and isTrue(args[1]);
    const err: ?Value = if (has_err) (if (args.len > 2) args[2] else try val_mod.makeUndefined(arena)) else null;
    const d = requireData(arena, stack, .async_disposable_stack, "using dispose on incompatible receiver") catch {
        const e = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
        realm_mod.pending_exception = Value{};
        return promise_mod.makeRejectedPromise(arena, e);
    };
    if (!d.disposed) {
        d.disposed = true;
        if (disposeResourcesSeeded(arena, d, err, true)) |_| {
            return promise_mod.makeResolvedPromise(arena, try val_mod.makeUndefined(arena));
        } else |e| {
            if (e != error.JsException) return e;
            const ev = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
            realm_mod.pending_exception = Value{};
            return promise_mod.makeRejectedPromise(arena, ev);
        }
    }
    if (err) |e| return promise_mod.makeRejectedPromise(arena, e);
    return promise_mod.makeResolvedPromise(arena, try val_mod.makeUndefined(arena));
}

fn isTrue(v: Value) bool {
    return v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean;
}

// ---- registration ---------------------------------------------------------

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const object_proto = ctx.object_proto;
    const m: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const nn: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };

    // ---- DisposableStack ----
    {
        const proto = try JsObject.create(arena, object_proto);
        _ = try proto.defineOwnData("use", try val_mod.makeNativeFunctionNamed(arena, nativeUse, "use", 1), m);
        _ = try proto.defineOwnData("adopt", try val_mod.makeNativeFunctionNamed(arena, nativeAdopt, "adopt", 2), m);
        _ = try proto.defineOwnData("defer", try val_mod.makeNativeFunctionNamed(arena, nativeDefer, "defer", 1), m);
        _ = try proto.defineOwnData("move", try val_mod.makeNativeFunctionNamed(arena, nativeMove, "move", 0), m);
        _ = try proto.defineOwnData("dispose", try val_mod.makeNativeFunctionNamed(arena, nativeDispose, "dispose", 0), m);
        try intrinsics.defineGetter(arena, proto, "disposed", nativeDisposed);
        active_disposable_proto = proto;

        const ctor = try JsObject.create(arena, ctx.function_proto);
        _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), nn);
        _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "DisposableStack"), nn);
        _ = try ctor.defineOwnData("prototype", try val_mod.makeObject(arena, proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeDisposableCtor));
        _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), m);
        active_disposable_ctor = ctor;
        try ctx.env.define("DisposableStack", try val_mod.makeObject(arena, ctor));
    }

    // ---- AsyncDisposableStack ----
    {
        const proto = try JsObject.create(arena, object_proto);
        _ = try proto.defineOwnData("use", try val_mod.makeNativeFunctionNamed(arena, nativeAsyncUse, "use", 1), m);
        _ = try proto.defineOwnData("adopt", try val_mod.makeNativeFunctionNamed(arena, nativeAsyncAdopt, "adopt", 2), m);
        _ = try proto.defineOwnData("defer", try val_mod.makeNativeFunctionNamed(arena, nativeAsyncDefer, "defer", 1), m);
        _ = try proto.defineOwnData("move", try val_mod.makeNativeFunctionNamed(arena, nativeAsyncMove, "move", 0), m);
        _ = try proto.defineOwnData("disposeAsync", try val_mod.makeNativeFunctionNamed(arena, nativeDisposeAsync, "disposeAsync", 0), m);
        try intrinsics.defineGetter(arena, proto, "disposed", nativeAsyncDisposed);
        active_async_disposable_proto = proto;

        const ctor = try JsObject.create(arena, ctx.function_proto);
        _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), nn);
        _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "AsyncDisposableStack"), nn);
        _ = try ctor.defineOwnData("prototype", try val_mod.makeObject(arena, proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeAsyncDisposableCtor));
        _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), m);
        active_async_disposable_ctor = ctor;
        try ctx.env.define("AsyncDisposableStack", try val_mod.makeObject(arena, ctor));
    }
}

/// Wire @@toStringTag and @@dispose / @@asyncDispose (needs the well-known
/// symbol values, resolved after Symbol setup).
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const tag_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    const method_attr: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    if (realm_mod.active_sym_to_string_tag) |tag| {
        if (active_disposable_proto) |p|
            try p.setSymAttr(tag, try val_mod.makeString(arena, "DisposableStack"), tag_attr);
        if (active_async_disposable_proto) |p|
            try p.setSymAttr(tag, try val_mod.makeString(arena, "AsyncDisposableStack"), tag_attr);
    }
    // DisposableStack.prototype[@@dispose] === DisposableStack.prototype.dispose.
    if (realm_mod.active_sym_dispose) |sym| {
        if (active_disposable_proto) |p| {
            if (p.get("dispose")) |fn_val| try p.setSymAttr(sym, fn_val, method_attr);
        }
    }
    // AsyncDisposableStack.prototype[@@asyncDispose] === …disposeAsync.
    if (realm_mod.active_sym_async_dispose) |sym| {
        if (active_async_disposable_proto) |p| {
            if (p.get("disposeAsync")) |fn_val| try p.setSymAttr(sym, fn_val, method_attr);
        }
    }
}

/// GC strong-trace hook: keep every pending disposer's receiver, method, and
/// adopted argument alive. Called from the shared strong_trace_fn.
pub fn gcTrace(heap: *Heap, obj: *JsObject) void {
    const d: *DisposableStackData = @ptrCast(@alignCast(obj.internal_slot orelse return));
    for (d.records.items) |r| {
        heap.markValueLive(r.this_val);
        heap.markValueLive(r.method);
        if (r.has_arg) heap.markValueLive(r.arg);
    }
}
