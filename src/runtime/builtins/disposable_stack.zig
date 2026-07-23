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
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function,
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
        if (value.unbox() != .object) return throwType(arena, "value is not disposable (not an object)");
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
    return disposeResourcesSeeded(arena, d, null);
}

/// As `disposeResources`, but the completion may be seeded with a pending thrown
/// value (`seed`). This models the DisposeResources(cap, completion) form used
/// by the `using` scope desugar: when the scope body already threw, a further
/// disposal error nests the body's error as the `suppressed` of a SuppressedError.
fn disposeResourcesSeeded(arena: std.mem.Allocator, d: *DisposableStackData, seed: ?Value) anyerror!void {
    var completion: ?Value = seed; // pending thrown value, if any
    var i: usize = d.records.items.len;
    while (i > 0) {
        i -= 1;
        const r = d.records.items[i];
        const call_args: []const Value = if (r.has_arg) &[_]Value{r.arg} else &[_]Value{};
        const res = function_proto.invokeCallback(arena, r.this_val, r.method, call_args);
        if (res) |_| {
            // normal completion — nothing to do
        } else |e| {
            if (e != error.JsException) return e;
            const thrown = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
            realm_mod.pending_exception = Value{};
            if (completion) |prev| {
                completion = try suppressedError(arena, thrown, prev);
            } else {
                completion = thrown;
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
        if (value.unbox() != .object) return throwType(arena, "value is not disposable (not an object)");
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
    if (disposeResources(arena, d)) |_| {
        return promise_mod.makeResolvedPromise(arena, try val_mod.makeUndefined(arena));
    } else |e| {
        if (e != error.JsException) return e;
        const err = if (realm_mod.pending_exception.bits != 0) realm_mod.pending_exception else try val_mod.makeUndefined(arena);
        realm_mod.pending_exception = Value{};
        return promise_mod.makeRejectedPromise(arena, err);
    }
}

// ---- `using` / `await using` desugar support ------------------------------
//
// A `using x = V` (or `await using x = V`) declaration lowers, in the parser,
// to a try/finally over the enclosing scope plus calls to the three hidden
// intrinsics below. They are bound as environment names (not globalThis
// properties), so user code and reflection never observe them:
//
//   let __using_stack__ = __usingStackInit__();
//   let __using_threw__ = false, __using_err__ = undefined;
//   try {
//     try { let x = __usingAdd__(__using_stack__, V, /*isAsync*/ false); ...body... }
//     catch (e) { __using_threw__ = true; __using_err__ = e; }
//   } finally { __usingDispose__(__using_stack__, __using_threw__, __using_err__); }

/// A fresh per-scope DisposeCapability. Backed by DisposableStackData but with a
/// null prototype so it can never be confused with a real DisposableStack.
pub fn nativeUsingStackInit(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_kind = .disposable_stack;
    const d = try arena.create(DisposableStackData);
    d.* = .{};
    obj.internal_slot = d;
    return val_mod.makeObject(arena, obj);
}

fn usingData(v: Value) ?*DisposableStackData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .disposable_stack or obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// AddDisposableResource for a `using`/`await using` binding.
/// args: [stack, value, isAsync]. Validates and registers `value` (§14.3.5),
/// then returns it so the caller binds `let x = __usingAdd__(stack, V, false)`.
pub fn nativeUsingAdd(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const stack = if (args.len > 0) args[0] else Value{};
    const value = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const is_async = args.len > 2 and val_mod.toBoolean(args[2]);
    const d = usingData(stack) orelse return throwType(arena, "internal: invalid using capability");
    if (isNullOrUndefined(value)) {
        // sync-dispose: null/undefined is skipped entirely; async-dispose adds a
        // no-op record (dispose method undefined) — AddDisposableResource step 1.
        if (!is_async) return value;
        try d.records.append(arena, .{ .this_val = value, .method = try val_mod.makeUndefined(arena) });
        return value;
    }
    // §CreateDisposableResource: "If V is not an Object, throw". Functions and
    // classes are Objects, so accept any callable too (not just plain objects).
    switch (value.unbox()) {
        .object, .function, .bc_function, .native_function => {},
        else => return throwType(arena, "using value is not an object"),
    }
    var method: ?Value = null;
    if (is_async) {
        if (realm_mod.active_sym_async_dispose) |s| method = try getMethodSym(arena, value, s);
        if (method == null) {
            if (realm_mod.active_sym_dispose) |s| method = try getMethodSym(arena, value, s);
        }
    } else {
        const s = realm_mod.active_sym_dispose orelse return throwType(arena, "Symbol.dispose unavailable");
        method = try getMethodSym(arena, value, s);
    }
    const m = method orelse return throwType(arena, "using value is not disposable");
    try d.records.append(arena, .{ .this_val = value, .method = m });
    return value;
}

/// DisposeResources at scope exit. args: [stack, threw, errValue]. When the
/// scope body completed abruptly with a throw, `threw` seeds the completion so a
/// disposal error nests the body error in a SuppressedError; otherwise disposal
/// errors surface directly (and a clean body re-surfaces any disposal error).
pub fn nativeUsingDispose(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const stack = if (args.len > 0) args[0] else Value{};
    const threw = args.len > 1 and val_mod.toBoolean(args[1]);
    const seed: ?Value = if (threw) (if (args.len > 2) args[2] else try val_mod.makeUndefined(arena)) else null;
    const d = usingData(stack) orelse return throwType(arena, "internal: invalid using capability");
    d.disposed = true;
    try disposeResourcesSeeded(arena, d, seed);
    return try val_mod.makeUndefined(arena);
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
