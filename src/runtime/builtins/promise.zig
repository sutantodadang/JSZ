// SPDX-License-Identifier: Apache-2.0
//! Phase 7 Promise practical subset with reaction queues.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const fn_proto = @import("./function_proto.zig");
const iter_mod = @import("./es2015_collections.zig");
const intrinsics = @import("intrinsics.zig");

/// R1: create Promise.prototype + constructor, bind the `Promise` global, and
/// return promise_proto so that realm.zig can set active_promise_proto.
pub fn register(ctx: *const intrinsics.Ctx) !*JsObject {
    const arena = ctx.arena;
    const promise_proto = try JsObject.create(arena, ctx.object_proto);
    try promise_proto.set("then", try val_mod.makeNativeFunctionNamed(arena, nativePromiseThen, "then", 0));
    try promise_proto.set("catch", try val_mod.makeNativeFunctionNamed(arena, nativePromiseCatch, "catch", 0));

    const promise_ctor_obj = try JsObject.create(arena, null);
    try promise_ctor_obj.set("prototype", try val_mod.makeObject(arena, promise_proto));
    try promise_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativePromiseCtor));
    try promise_ctor_obj.set("resolve", try val_mod.makeNativeFunctionNamed(arena, nativePromiseResolve, "resolve", 0));
    try promise_ctor_obj.set("reject", try val_mod.makeNativeFunctionNamed(arena, nativePromiseReject, "reject", 0));
    try promise_ctor_obj.set("allSettled", try val_mod.makeNativeFunctionNamed(arena, nativePromiseAllSettled, "allSettled", 0));
    try promise_ctor_obj.set("all", try val_mod.makeNativeFunctionNamed(arena, nativePromiseAll, "all", 0));
    try promise_ctor_obj.set("race", try val_mod.makeNativeFunctionNamed(arena, nativePromiseRace, "race", 0));
    try promise_ctor_obj.set("any", try val_mod.makeNativeFunctionNamed(arena, nativePromiseAny, "any", 0));
    try promise_ctor_obj.set("withResolvers", try val_mod.makeNativeFunctionNamed(arena, nativePromiseWithResolvers, "withResolvers", 0));
    try promise_ctor_obj.set("try", try val_mod.makeNativeFunctionNamed(arena, nativePromiseTry, "try", 1));
    try promise_proto.set("finally", try val_mod.makeNativeFunctionNamed(arena, nativePromiseFinally, "finally", 0));
    _ = try promise_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Promise"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try promise_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try promise_proto.defineOwnData("constructor", try val_mod.makeObject(arena, promise_ctor_obj), .{ .writable = true, .enumerable = false, .configurable = true });
    try ctx.env.define("Promise", try val_mod.makeObject(arena, promise_ctor_obj));
    return promise_proto;
}

const PromiseState = enum { pending, fulfilled, rejected };

const PromiseData = struct {
    state: PromiseState = .pending,
    value: Value = Value{},
    reactions: std.ArrayListUnmanaged(Reaction) = .empty,
};

const Reaction = struct {
    on_fulfilled: Value,
    on_rejected: Value,
    next_data: *PromiseData,
};

const Job = struct {
    reaction: Reaction,
    input_state: PromiseState,
    input_value: Value,
};

const ResolverData = struct {
    promise: *PromiseData,
    resolve_mode: bool,
};

var microtasks: std.ArrayListUnmanaged(Job) = .empty;

fn getThenMethod(v: Value) ?Value {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const then_v = v.toPtr().object.get("then") orelse return null;
    if (!isCallable(then_v)) return null;
    return then_v;
}

fn makeResolverObject(arena: std.mem.Allocator, data: *ResolverData) !Value {
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_slot = data;
    try obj.set("__call__", try val_mod.makeNativeFunction(arena, nativePromiseResolver));
    return val_mod.makeObject(arena, obj);
}

fn assimilateThenable(arena: std.mem.Allocator, data: *PromiseData, thenable: Value) !bool {
    const then_method = getThenMethod(thenable) orelse return false;
    const resolve_data = try arena.create(ResolverData);
    const reject_data = try arena.create(ResolverData);
    resolve_data.* = .{ .promise = data, .resolve_mode = true };
    reject_data.* = .{ .promise = data, .resolve_mode = false };
    const resolve_val = try makeResolverObject(arena, resolve_data);
    const reject_val = try makeResolverObject(arena, reject_data);
    _ = fn_proto.invokeCallback(arena, thenable, then_method, &[_]Value{ resolve_val, reject_val }) catch |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            return true;
        }
        return e;
    };
    return true;
}

fn makePromise(arena: std.mem.Allocator, state: PromiseState, value: Value) !Value {
    const proto = realm_mod.active_promise_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    const d = try arena.create(PromiseData);
    d.* = .{ .state = state, .value = value };
    obj.internal_kind = .promise;
    obj.internal_slot = d;
    return val_mod.makeObject(arena, obj);
}

fn makePendingPromise(arena: std.mem.Allocator) !Value {
    return makePromise(arena, .pending, try val_mod.makeUndefined(arena));
}

/// Host/internal handle to a pending promise: the JS `promise` value plus an
/// opaque handle to its internal state, so a native caller (e.g.
/// Atomics.waitAsync) can settle it later via `resolveInternalPromise`.
pub const InternalPromise = struct { promise: Value, handle: *anyopaque };

/// Create a pending promise for internal use. The returned handle stays valid as
/// long as the promise object is reachable from JS (it is the same arena/heap
/// allocation), so keep the `promise` value rooted until it is settled.
pub fn makeInternalPromise(arena: std.mem.Allocator) !InternalPromise {
    const p = try makePendingPromise(arena);
    return .{ .promise = p, .handle = @ptrCast(getData(p).?) };
}

/// Resolve an internal promise (from `makeInternalPromise`) with `v`, running the
/// normal resolve semantics (thenable assimilation + reaction scheduling).
pub fn resolveInternalPromise(arena: std.mem.Allocator, handle: *anyopaque, v: Value) void {
    const d: *PromiseData = @ptrCast(@alignCast(handle));
    promiseResolveData(arena, d, v);
}

fn settlePromise(data: *PromiseData, state: PromiseState, value: Value) void {
    if (data.state != .pending) return;
    data.state = state;
    data.value = value;
}

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |o| o.internal_kind == .bound_function or o.get("__call__") != null,
        else => false,
    };
}

fn getData(this_val: Value) ?*PromiseData {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const o = this_val.toPtr().object;
    if (o.internal_kind != .promise) return null;
    if (o.internal_slot) |slot| return @ptrCast(@alignCast(slot));
    return null;
}

/// True when `v` is a Promise still in the pending state. Used by the module
/// loader to decide whether an async factory's evaluation has actually finished
/// (so its record may be marked `loaded`) or is still suspended at an `await`.
pub fn isPending(v: Value) bool {
    const d = getData(v) orelse return false;
    return d.state == .pending;
}

fn enqueueReactionJob(arena: std.mem.Allocator, r: Reaction, state: PromiseState, value: Value) !void {
    try microtasks.append(arena, .{
        .reaction = r,
        .input_state = state,
        .input_value = value,
    });
}

fn adoptOrFulfill(arena: std.mem.Allocator, next_data: *PromiseData, v: Value) !void {
    if (getData(v)) |inner| {
        if (inner == next_data) {
            settlePromise(next_data, .rejected, try val_mod.makeString(arena, "TypeError: self resolution"));
            flushReactions(arena, next_data);
            return;
        }
        if (inner.state == .pending) {
            try inner.reactions.append(arena, .{
                .on_fulfilled = Value{},
                .on_rejected = Value{},
                .next_data = next_data,
            });
            return;
        }
        settlePromise(next_data, inner.state, inner.value);
        flushReactions(arena, next_data);
        return;
    }
    if (try assimilateThenable(arena, next_data, v)) return;
    settlePromise(next_data, .fulfilled, v);
    flushReactions(arena, next_data);
}

fn flushReactions(arena: std.mem.Allocator, data: *PromiseData) void {
    for (data.reactions.items) |r| {
        enqueueReactionJob(arena, r, data.state, data.value) catch {};
    }
    data.reactions.clearRetainingCapacity();
}

fn promiseResolveData(arena: std.mem.Allocator, data: *PromiseData, v: Value) void {
    if (data.state != .pending) return;
    if (getData(v)) |inner| {
        if (inner == data) {
            settlePromise(data, .rejected, val_mod.makeString(arena, "TypeError: self resolution") catch Value{});
            flushReactions(arena, data);
            return;
        }
        if (inner.state == .pending) {
            inner.reactions.append(arena, .{
                .on_fulfilled = Value{},
                .on_rejected = Value{},
                .next_data = data,
            }) catch {};
            return;
        }
        settlePromise(data, inner.state, inner.value);
        flushReactions(arena, data);
        return;
    }
    if (assimilateThenable(arena, data, v)) |assimilated| {
        if (assimilated) return;
    } else |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            return;
        }
        promiseRejectData(arena, data, val_mod.makeString(arena, "TypeError: thenable assimilation failed") catch Value{});
        return;
    }
    settlePromise(data, .fulfilled, v);
    flushReactions(arena, data);
}

fn promiseRejectData(arena: std.mem.Allocator, data: *PromiseData, v: Value) void {
    if (data.state != .pending) return;
    settlePromise(data, .rejected, v);
    flushReactions(arena, data);
}

fn nativePromiseResolver(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = if (this_val.bits != 0 and this_val.unbox() == .object and this_val.toPtr().object.internal_slot != null)
        @as(*ResolverData, @ptrCast(@alignCast(this_val.toPtr().object.internal_slot.?)))
    else
        return val_mod.makeUndefined(arena);
    const arg = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (d.resolve_mode) {
        promiseResolveData(arena, d.promise, arg);
    } else {
        promiseRejectData(arena, d.promise, arg);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativePromiseCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        const d = try arena.create(PromiseData);
        d.* = .{};
        o.internal_kind = .promise;
        o.internal_slot = d;
        if (args.len > 0 and isCallable(args[0])) {
            const resolve_obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
            const reject_obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
            const resolve_data = try arena.create(ResolverData);
            const reject_data = try arena.create(ResolverData);
            resolve_data.* = .{ .promise = d, .resolve_mode = true };
            reject_data.* = .{ .promise = d, .resolve_mode = false };
            resolve_obj.internal_slot = resolve_data;
            reject_obj.internal_slot = reject_data;
            try resolve_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativePromiseResolver));
            try reject_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativePromiseResolver));
            // The resolving functions are anonymous unary functions (name "",
            // length 1) per §27.2.1.3.
            for ([_]*JsObject{ resolve_obj, reject_obj }) |ro| {
                try ro.set("name", try val_mod.makeString(arena, ""));
                try ro.set("length", try val_mod.makeNumber(arena, 1));
            }
            const resolve_val = try val_mod.makeObject(arena, resolve_obj);
            const reject_val = try val_mod.makeObject(arena, reject_obj);
            _ = fn_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), args[0], &[_]Value{ resolve_val, reject_val }) catch |e| {
                if (e == error.JsException) {
                    promiseRejectData(arena, d, realm_mod.pending_exception);
                    realm_mod.pending_exception = Value{};
                }
            };
        }
        return this_val;
    }
    return makePromise(arena, .pending, try val_mod.makeUndefined(arena));
}

/// True when `v` is a constructor (mirrors Reflect's IsConstructor check): the
/// native-built Promise constructor is an ordinary object carrying `__call__`.
fn isConstructorVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => true,
        .object => |o| o.get("__call__") != null or
            o.internal_kind == .bound_function or
            o.internal_kind == .proxy,
        else => false,
    };
}

/// Promise.withResolvers() (ES2024): returns `{ promise, resolve, reject }`
/// where `resolve`/`reject` settle the new pending `promise`. The receiver `C`
/// must be a constructor — `NewPromiseCapability(C)` throws a TypeError otherwise.
pub fn nativePromiseWithResolvers(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (!isConstructorVal(this_val)) {
        const err = if (realm_mod.active_heap) |h|
            try JsObject.createOnHeap(h, realm_mod.error_proto_TypeError)
        else
            try JsObject.create(arena, realm_mod.error_proto_TypeError);
        try err.set("name", try val_mod.makeString(arena, "TypeError"));
        try err.set("message", try val_mod.makeString(arena, "Promise.withResolvers called on a non-constructor"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, err);
        return error.JsException;
    }
    // NewPromiseCapability(C) constructs via the receiver `this` (step 2), so
    // `Promise.withResolvers.call(SubPromise)` yields a SubPromise instance whose
    // resolve/reject are the ones the base executor was handed.
    const cap = try newPromiseCapability(arena, this_val);
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try obj.set("promise", cap.promise);
    try obj.set("resolve", cap.resolve);
    try obj.set("reject", cap.reject);
    return val_mod.makeObject(arena, obj);
}

pub fn nativePromiseResolve(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (getData(v) != null) return v;
    const p = try makePendingPromise(arena);
    if (getData(p)) |d| promiseResolveData(arena, d, v);
    return p;
}

pub fn nativePromiseReject(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return makePromise(arena, .rejected, v);
}

fn nativeUndefinedThunk(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return val_mod.makeUndefined(arena);
}

/// %AsyncIteratorPrototype%[@@asyncDispose] (explicit-resource-management):
/// GetMethod(O, "return"); if present, call it and return a promise that
/// fulfills with undefined once the result settles (rejecting if `return`
/// throws or its result rejects). If absent, fulfill with undefined.
pub fn nativeAsyncIteratorAsyncDispose(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ctx = realm_mod.active_context orelse return realm_mod.throwTypeError(arena, "no active context");
    // GetMethod(O, "return"): a throwing getter rejects the returned promise.
    const ret = ctx.getProp(arena, this_val, "return") catch {
        const reason = realm_mod.pending_exception;
        realm_mod.pending_exception = Value{};
        return nativePromiseReject(arena, Value{}, &[_]Value{reason});
    };
    var result: Value = undefined;
    if (ret.bits == 0 or ret.isUndefined() or ret.isNull()) {
        result = try val_mod.makeUndefined(arena);
    } else if (!isCallable(ret)) {
        const proto: ?*JsObject = realm_mod.error_proto_TypeError;
        const eobj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
        try eobj.set("name", try val_mod.makeString(arena, "TypeError"));
        try eobj.set("message", try val_mod.makeString(arena, "return is not a function"));
        return nativePromiseReject(arena, Value{}, &[_]Value{try val_mod.makeObject(arena, eobj)});
    } else {
        result = ctx.invokeJs(arena, this_val, ret, &[_]Value{}) catch {
            const reason = realm_mod.pending_exception;
            realm_mod.pending_exception = Value{};
            return nativePromiseReject(arena, Value{}, &[_]Value{reason});
        };
    }
    // resultWrapper = PromiseResolve(%Promise%, result); then map fulfillment to undefined.
    const wrapper = try nativePromiseResolve(arena, Value{}, &[_]Value{result});
    const on_ful = try val_mod.makeNativeFunctionNamed(arena, nativeUndefinedThunk, "", 1);
    return nativePromiseThen(arena, wrapper, &[_]Value{on_ful});
}

/// Promise.try(callbackfn, ...args) (ES2025 §27.2.4.9): build a capability from
/// `C = this`, call `callbackfn` synchronously with the extra args, then resolve
/// the capability with its return value or reject with a thrown completion.
pub fn nativePromiseTry(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Step 2: If C is not an Object, throw a TypeError. Callables (functions,
    // classes) are Objects too, so accept every object-carrying tag here; the
    // not-a-constructor case is caught by NewPromiseCapability below.
    const is_object = this_val.bits != 0 and switch (this_val.unbox()) {
        .object, .function, .bc_function, .native_function => true,
        else => false,
    };
    if (!is_object)
        return realm_mod.throwTypeError(arena, "Promise.try called on a non-object");
    // Step 3: NewPromiseCapability(C).
    const cap = try newPromiseCapability(arena, this_val);
    const ctx = realm_mod.active_context orelse return realm_mod.throwTypeError(arena, "no active context");
    const undef = try val_mod.makeUndefined(arena);
    const cb = if (args.len > 0) args[0] else undef;
    const rest: []const Value = if (args.len > 1) args[1..] else &[_]Value{};
    // Step 4: status = Completion(Call(callbackfn, undefined, args)).
    if (ctx.invokeJs(arena, undef, cb, rest)) |result| {
        // Step 6: Call(cap.[[Resolve]], undefined, « result »).
        _ = ctx.invokeJs(arena, undef, cap.resolve, &[_]Value{result}) catch {};
    } else |e| {
        if (e != error.JsException) return e;
        const reason = realm_mod.pending_exception;
        realm_mod.pending_exception = Value{};
        // Step 5: Call(cap.[[Reject]], undefined, « status.[[Value]] »).
        _ = ctx.invokeJs(arena, undef, cap.reject, &[_]Value{reason}) catch {};
    }
    // Step 7: return cap.[[Promise]].
    return cap.promise;
}

// ---- ctx-on-this helpers ----

/// Extract a typed ctx pointer from the carrier object stored in this_val's internal_slot.
fn ctxFromThis(comptime T: type, this_val: Value) ?*T {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const slot = this_val.toPtr().object.internal_slot orelse return null;
    return @ptrCast(@alignCast(slot));
}

/// Build a bound handler whose `this` is a carrier object holding ctx_ptr in its
/// internal_slot. If with_index is true, prepends idx as the first call arg (prefix[0]).
fn makeCtxHandler(arena: std.mem.Allocator, native_fn: Value, ctx_ptr: *anyopaque, idx: usize, with_index: bool) !Value {
    const carrier = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    carrier.internal_slot = ctx_ptr;
    const carrier_val = try val_mod.makeObject(arena, carrier);
    const prefix: []Value = if (with_index) blk: {
        const p = try arena.alloc(Value, 1);
        p[0] = try val_mod.makeNumber(arena, @floatFromInt(idx));
        break :blk p;
    } else &[_]Value{};
    const bd = try arena.create(fn_proto.BoundData);
    bd.* = .{ .target = native_fn, .this_val = carrier_val, .prefix = prefix };
    const bound_obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    bound_obj.internal_kind = .bound_function;
    bound_obj.internal_slot = bd;
    return val_mod.makeObject(arena, bound_obj);
}

// ---- Promise combinators: shared NewPromiseCapability machinery ----
//
// The combinators (all/allSettled/race/any) are spec-faithful (ES §27.2.4.x):
// they read `C = this`, build the result promise via `NewPromiseCapability(C)`
// (so a subclass/species constructor produces the result), obtain `C.resolve`
// and, for every element, `nextPromise = C.resolve(elem)` then
// `nextPromise.then(onFulfilled, onRejected)`. All settlement therefore flows
// through the observable `resolve`/`then` methods and the microtask queue rather
// than the engine-internal promise data, which is what the conformance suite's
// call-count / ordering / species checks require.

/// A promise capability: the promise plus the resolve/reject functions that
/// settle it, produced by `new C(executor)` (ES §27.2.1.5).
const Capability = struct {
    promise: Value = Value{},
    resolve: Value = Value{},
    reject: Value = Value{},
    slots_set: bool = false,
};

/// GetCapabilitiesExecutor closure (ES §27.2.1.5.1): records resolve/reject into
/// the capability; a second invocation (either slot already set) is a TypeError.
fn nativeCapabilityExecutor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cap = ctxFromThis(Capability, this_val) orelse return val_mod.makeUndefined(arena);
    if (cap.slots_set) return realm_mod.throwTypeError(arena, "Promise executor already invoked");
    cap.slots_set = true;
    if (args.len > 0) cap.resolve = args[0];
    if (args.len > 1) cap.reject = args[1];
    return val_mod.makeUndefined(arena);
}

/// Resolve the receiver `this` for a combinator: an explicit constructor value,
/// or (for internal callers that pass an empty value) the realm's %Promise%.
fn combinatorConstructor(arena: std.mem.Allocator, this_val: Value) !Value {
    if (this_val.bits == 0) {
        const proto = realm_mod.active_promise_proto orelse return realm_mod.throwTypeError(arena, "no Promise constructor");
        return proto.get("constructor") orelse realm_mod.throwTypeError(arena, "no Promise constructor");
    }
    if (!isConstructorVal(this_val)) return realm_mod.throwTypeError(arena, "Promise combinator called on a non-constructor");
    return this_val;
}

/// NewPromiseCapability(C) (ES §27.2.1.5): `new C(executor)`, capturing the
/// resolve/reject the executor is handed. TypeError if C is not a constructor or
/// resolve/reject are not callable after construction.
fn newPromiseCapability(arena: std.mem.Allocator, ctor: Value) !*Capability {
    const ctx = realm_mod.active_context orelse return realm_mod.throwTypeError(arena, "no active context");
    const cap = try arena.create(Capability);
    cap.* = .{};
    const exec_base = try val_mod.makeNativeFunction(arena, nativeCapabilityExecutor);
    const executor = try makeCtxHandler(arena, exec_base, cap, 0, false);
    const promise = try ctx.construct(arena, ctor, &[_]Value{executor});
    if (!isCallable(cap.resolve) or !isCallable(cap.reject))
        return realm_mod.throwTypeError(arena, "Promise resolve/reject is not callable");
    cap.promise = promise;
    return cap;
}

/// Call `cap.reject(reason)` and hand back `cap.promise` — the IfAbruptRejectPromise
/// path shared by every combinator when a step after NewPromiseCapability throws.
fn rejectCapability(arena: std.mem.Allocator, cap: *Capability, reason: Value) Value {
    const ctx = realm_mod.active_context orelse return cap.promise;
    const undef = val_mod.makeUndefined(arena) catch Value{};
    _ = ctx.invokeJs(arena, undef, cap.reject, &[_]Value{reason}) catch {};
    return cap.promise;
}

/// IfAbruptRejectPromise for a pending exception: reject the capability with the
/// thrown value (cleared) and return its promise.
fn abruptReject(arena: std.mem.Allocator, cap: *Capability) Value {
    const reason = realm_mod.pending_exception;
    realm_mod.pending_exception = Value{};
    return rejectCapability(arena, cap, reason);
}

/// GetPromiseResolve(C): `C.resolve`, checked callable (ES §27.2.4.1.2 etc.).
fn getPromiseResolve(arena: std.mem.Allocator, ctor: Value) !Value {
    const ctx = realm_mod.active_context.?;
    const m = try ctx.getProp(arena, ctor, "resolve");
    if (!isCallable(m)) return realm_mod.throwTypeError(arena, "Promise.resolve is not callable");
    return m;
}

/// `nextPromise = C.resolve(elem)` then `nextPromise.then(onFulfilled, onRejected)`
/// (the per-element step shared by every combinator). Propagates a throw.
fn subscribeElement(arena: std.mem.Allocator, ctor: Value, resolve_method: Value, elem: Value, on_fulfilled: Value, on_rejected: Value) !void {
    const ctx = realm_mod.active_context.?;
    const next_promise = try ctx.invokeJs(arena, ctor, resolve_method, &[_]Value{elem});
    const then_method = try ctx.getProp(arena, next_promise, "then");
    if (!isCallable(then_method)) return realm_mod.throwTypeError(arena, "then is not callable");
    _ = try ctx.invokeJs(arena, next_promise, then_method, &[_]Value{ on_fulfilled, on_rejected });
}

/// `cap.resolve(value)` / `cap.reject(value)` from inside a reaction closure.
fn settleCapability(arena: std.mem.Allocator, settle_fn: Value, value: Value) void {
    const ctx = realm_mod.active_context orelse return;
    const undef = val_mod.makeUndefined(arena) catch Value{};
    _ = ctx.invokeJs(arena, undef, settle_fn, &[_]Value{value}) catch {};
}

/// The combinator's iterable argument, defaulting to `undefined` (which makes
/// GetIterator throw — `Promise.all()` rejects, per spec).
fn iterable(args: []const Value) Value {
    return if (args.len > 0) args[0] else Value{};
}

/// Root a stack-local Value across nested JS calls. The combinators drive the
/// iterator lazily, so the iterator object is held only in a native local while
/// each element's `C.resolve(...).then(...)` runs — work that can allocate enough
/// to trigger a collection. Without an explicit root the collector would free the
/// unreferenced iterator and the next `next()` call would fault. Caller must
/// `unrootValue` the same pointer before it leaves scope.
fn rootValue(ptr: *Value) void {
    if (realm_mod.active_heap) |h| h.addRoot(ptr) catch {};
}
fn unrootValue(ptr: *Value) void {
    if (realm_mod.active_heap) |h| h.removeRoot(ptr);
}

/// Advance the iterator one step: the next value, or null once exhausted. A
/// throwing `next()` propagates (the iterator is then considered closed).
/// Combinators iterate lazily (rather than collecting eagerly) so that an
/// infinite iterator whose consumption is meant to stop on a `C.resolve`/`then`
/// error is actually closed instead of spun forever (ES §27.2.4.1.1 IfAbrupt →
/// IteratorClose).
fn iterNext(arena: std.mem.Allocator, iterator: Value) !?Value {
    const ctx = realm_mod.active_context.?;
    const step = try iter_mod.nativeIterStep(arena, Value{}, &[_]Value{iterator});
    if (step.bits == 0 or step.unbox() != .object)
        return realm_mod.throwTypeError(arena, "iterator result is not an object");
    // `done`/`value` are read via Get so their getters (and any Proxy trap) fire
    // and propagate — IteratorStep/IteratorValue (ES §7.4.6/§7.4.7).
    const done_v = try ctx.getProp(arena, step, "done");
    const done: bool = if (done_v.bits == 0) false else switch (done_v.unbox()) {
        .boolean => |b| b,
        .undefined_, .null_ => false,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
    if (done) return null;
    return try ctx.getProp(arena, step, "value");
}

/// IteratorClose(iterator): invoke `iterator.return()` if present, swallowing any
/// error (the outer abrupt completion is what propagates).
fn iterClose(arena: std.mem.Allocator, iterator: Value) void {
    const ctx = realm_mod.active_context orelse return;
    const ret = ctx.getProp(arena, iterator, "return") catch return;
    if (ret.bits == 0 or !isCallable(ret)) return;
    _ = ctx.invokeJs(arena, iterator, ret, &[_]Value{}) catch {};
}

// Each combinator uses the spec `remainingElementsCount` counter (ES §27.2.4.1):
// it starts at 1, is incremented once per element as iteration streams, and is
// decremented by each element's settle closure plus once more after the loop —
// so the result settles exactly when every element has, without knowing the
// element count up front (which streaming iteration can't provide). Every element
// closure carries its own [[AlreadyCalled]] guard so a promise that settles twice
// counts once.

const AllCtx = struct { cap: *Capability, remaining: usize, result_arr: *JsObject, count: usize = 0 };
const AllElem = struct { parent: *AllCtx, index: usize, already: bool = false };

fn allDecrement(arena: std.mem.Allocator, ctx: *AllCtx) void {
    if (ctx.remaining > 0) ctx.remaining -= 1;
    if (ctx.remaining == 0) {
        ctx.result_arr.array_length = @intCast(ctx.count);
        const arr_val = val_mod.makeObject(arena, ctx.result_arr) catch return;
        settleCapability(arena, ctx.cap.resolve, arr_val);
    }
}

fn nativeAllFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const el = ctxFromThis(AllElem, this_val) orelse return val_mod.makeUndefined(arena);
    if (el.already) return val_mod.makeUndefined(arena);
    el.already = true;
    const val = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const idx_key = std.fmt.allocPrint(arena, "{d}", .{el.index}) catch return val_mod.makeUndefined(arena);
    el.parent.result_arr.set(idx_key, val) catch {};
    allDecrement(arena, el.parent);
    return val_mod.makeUndefined(arena);
}

/// ES2015 Promise.all(iterable)
pub fn nativePromiseAll(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctor = try combinatorConstructor(arena, this_val);
    const cap = try newPromiseCapability(arena, ctor);
    const resolve_method = getPromiseResolve(arena, ctor) catch return abruptReject(arena, cap);
    var iterator = iter_mod.nativeGetIterator(arena, Value{}, &[_]Value{iterable(args)}) catch return abruptReject(arena, cap);
    rootValue(&iterator);
    defer unrootValue(&iterator);

    const ctx = try arena.create(AllCtx);
    ctx.* = .{ .cap = cap, .remaining = 1, .result_arr = try JsObject.createArray(arena, realm_mod.active_array_proto) };
    const fulfill_base = try val_mod.makeNativeFunction(arena, nativeAllFulfill);

    var index: usize = 0;
    while (true) {
        const item = (iterNext(arena, iterator) catch return abruptReject(arena, cap)) orelse break;
        ctx.remaining += 1;
        const el = try arena.create(AllElem);
        el.* = .{ .parent = ctx, .index = index };
        // onRejected is the result capability's [[Reject]] directly (ES §27.2.4.1.2).
        const on_fulfill = try makeCtxHandler(arena, fulfill_base, el, 0, false);
        subscribeElement(arena, ctor, resolve_method, item, on_fulfill, cap.reject) catch {
            iterClose(arena, iterator);
            return abruptReject(arena, cap);
        };
        index += 1;
    }
    ctx.count = index;
    allDecrement(arena, ctx);
    return cap.promise;
}

// ---- Promise.allSettled ----

const AllSettledCtx = struct { cap: *Capability, remaining: usize, result_arr: *JsObject, count: usize = 0 };
const AllSettledElem = struct { parent: *AllSettledCtx, index: usize, already: bool = false };

fn allSettledDecrement(arena: std.mem.Allocator, ctx: *AllSettledCtx) void {
    if (ctx.remaining > 0) ctx.remaining -= 1;
    if (ctx.remaining == 0) {
        ctx.result_arr.array_length = @intCast(ctx.count);
        const arr_val = val_mod.makeObject(arena, ctx.result_arr) catch return;
        settleCapability(arena, ctx.cap.resolve, arr_val);
    }
}

fn allSettledRecord(arena: std.mem.Allocator, el: *AllSettledElem, status: []const u8, payload: Value) void {
    if (el.already) return;
    el.already = true;
    const obj_proto = realm_mod.active_object_proto;
    const entry = if (realm_mod.active_heap) |h|
        JsObject.createOnHeap(h, obj_proto) catch return
    else
        JsObject.create(arena, obj_proto) catch return;
    entry.set("status", val_mod.makeString(arena, status) catch return) catch return;
    if (std.mem.eql(u8, status, "fulfilled")) {
        entry.set("value", payload) catch return;
    } else {
        entry.set("reason", payload) catch return;
    }
    const idx_key = std.fmt.allocPrint(arena, "{d}", .{el.index}) catch return;
    el.parent.result_arr.set(idx_key, val_mod.makeObject(arena, entry) catch return) catch return;
    allSettledDecrement(arena, el.parent);
}

fn nativeAllSettledFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const el = ctxFromThis(AllSettledElem, this_val) orelse return val_mod.makeUndefined(arena);
    allSettledRecord(arena, el, "fulfilled", if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
    return val_mod.makeUndefined(arena);
}

fn nativeAllSettledReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const el = ctxFromThis(AllSettledElem, this_val) orelse return val_mod.makeUndefined(arena);
    allSettledRecord(arena, el, "rejected", if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
    return val_mod.makeUndefined(arena);
}

/// ES2020 Promise.allSettled(iterable) — never rejects; each input → {status,value|reason}.
pub fn nativePromiseAllSettled(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctor = try combinatorConstructor(arena, this_val);
    const cap = try newPromiseCapability(arena, ctor);
    const resolve_method = getPromiseResolve(arena, ctor) catch return abruptReject(arena, cap);
    var iterator = iter_mod.nativeGetIterator(arena, Value{}, &[_]Value{iterable(args)}) catch return abruptReject(arena, cap);
    rootValue(&iterator);
    defer unrootValue(&iterator);

    const ctx = try arena.create(AllSettledCtx);
    ctx.* = .{ .cap = cap, .remaining = 1, .result_arr = try JsObject.createArray(arena, realm_mod.active_array_proto) };
    const fulfill_base = try val_mod.makeNativeFunction(arena, nativeAllSettledFulfill);
    const reject_base = try val_mod.makeNativeFunction(arena, nativeAllSettledReject);

    var index: usize = 0;
    while (true) {
        const item = (iterNext(arena, iterator) catch return abruptReject(arena, cap)) orelse break;
        ctx.remaining += 1;
        const el = try arena.create(AllSettledElem);
        el.* = .{ .parent = ctx, .index = index };
        const on_fulfill = try makeCtxHandler(arena, fulfill_base, el, 0, false);
        const on_reject = try makeCtxHandler(arena, reject_base, el, 0, false);
        subscribeElement(arena, ctor, resolve_method, item, on_fulfill, on_reject) catch {
            iterClose(arena, iterator);
            return abruptReject(arena, cap);
        };
        index += 1;
    }
    ctx.count = index;
    allSettledDecrement(arena, ctx);
    return cap.promise;
}

// ---- Promise.race ----

/// ES2015 Promise.race(iterable). Each element's promise settles the result
/// capability directly via its [[Resolve]]/[[Reject]] (first settlement wins;
/// the capability's own already-resolved guard drops later ones). An empty
/// iterable leaves the result promise forever pending, per spec.
pub fn nativePromiseRace(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctor = try combinatorConstructor(arena, this_val);
    const cap = try newPromiseCapability(arena, ctor);
    const resolve_method = getPromiseResolve(arena, ctor) catch return abruptReject(arena, cap);
    var iterator = iter_mod.nativeGetIterator(arena, Value{}, &[_]Value{iterable(args)}) catch return abruptReject(arena, cap);
    rootValue(&iterator);
    defer unrootValue(&iterator);

    while (true) {
        const item = (iterNext(arena, iterator) catch return abruptReject(arena, cap)) orelse break;
        subscribeElement(arena, ctor, resolve_method, item, cap.resolve, cap.reject) catch {
            iterClose(arena, iterator);
            return abruptReject(arena, cap);
        };
    }
    return cap.promise;
}

// ---- Promise.any ----

const AnyCtx = struct { cap: *Capability, remaining: usize, errors_arr: *JsObject, count: usize = 0 };
const AnyElem = struct { parent: *AnyCtx, index: usize, already: bool = false };

/// Build an AggregateError object wrapping the given `errors` array object.
fn makeAggregateErrorFrom(arena: std.mem.Allocator, errors_val: Value, msg: []const u8) !Value {
    const proto: ?*JsObject = realm_mod.error_proto_AggregateError orelse realm_mod.error_proto_Error;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto)
    else
        try JsObject.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, "AggregateError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("errors", errors_val);
    return val_mod.makeObject(arena, obj);
}

fn nativeAnyReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const el = ctxFromThis(AnyElem, this_val) orelse return val_mod.makeUndefined(arena);
    if (el.already) return val_mod.makeUndefined(arena);
    el.already = true;
    const reason = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    const idx_key = std.fmt.allocPrint(arena, "{d}", .{el.index}) catch return val_mod.makeUndefined(arena);
    el.parent.errors_arr.set(idx_key, reason) catch {};
    if (el.parent.remaining > 0) el.parent.remaining -= 1;
    if (el.parent.remaining == 0) {
        el.parent.errors_arr.array_length = @intCast(el.parent.count);
        const errors_val = val_mod.makeObject(arena, el.parent.errors_arr) catch return val_mod.makeUndefined(arena);
        const agg_err = try makeAggregateErrorFrom(arena, errors_val, "All promises were rejected");
        settleCapability(arena, el.parent.cap.reject, agg_err);
    }
    return val_mod.makeUndefined(arena);
}

/// ES2021 Promise.any(iterable) — rejects with an AggregateError iff every input
/// rejects; the first fulfillment resolves the result capability.
pub fn nativePromiseAny(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctor = try combinatorConstructor(arena, this_val);
    const cap = try newPromiseCapability(arena, ctor);
    const resolve_method = getPromiseResolve(arena, ctor) catch return abruptReject(arena, cap);
    var iterator = iter_mod.nativeGetIterator(arena, Value{}, &[_]Value{iterable(args)}) catch return abruptReject(arena, cap);
    rootValue(&iterator);
    defer unrootValue(&iterator);

    const ctx = try arena.create(AnyCtx);
    ctx.* = .{ .cap = cap, .remaining = 1, .errors_arr = try JsObject.createArray(arena, realm_mod.active_array_proto) };
    const reject_base = try val_mod.makeNativeFunction(arena, nativeAnyReject);

    var index: usize = 0;
    while (true) {
        const item = (iterNext(arena, iterator) catch return abruptReject(arena, cap)) orelse break;
        ctx.remaining += 1;
        const el = try arena.create(AnyElem);
        el.* = .{ .parent = ctx, .index = index };
        // onFulfilled is the result capability's [[Resolve]] directly (ES §27.2.4.3.1).
        const on_reject = try makeCtxHandler(arena, reject_base, el, 0, false);
        subscribeElement(arena, ctor, resolve_method, item, cap.resolve, on_reject) catch {
            iterClose(arena, iterator);
            return abruptReject(arena, cap);
        };
        index += 1;
    }
    ctx.count = index;
    if (ctx.remaining > 0) ctx.remaining -= 1;
    if (ctx.remaining == 0) {
        ctx.errors_arr.array_length = @intCast(ctx.count);
        const errors_val = try val_mod.makeObject(arena, ctx.errors_arr);
        settleCapability(arena, cap.reject, try makeAggregateErrorFrom(arena, errors_val, "All promises were rejected"));
    }
    return cap.promise;
}

// ---- Promise.prototype.finally ----

/// Thunk that ignores its arg and returns prefix[0] (the original fulfillment value).
fn nativeFinallyConstThunk(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // args[0] = orig_val (from prefix), args[1] = ignored settle value
    return if (args.len > 0) args[0] else val_mod.makeUndefined(arena);
}

/// Thunk that ignores its arg and re-throws prefix[0] (the original rejection reason).
fn nativeFinallyThrowThunk(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    _ = arena;
    // args[0] = orig_reason (from prefix)
    const reason = if (args.len > 0) args[0] else Value{};
    realm_mod.pending_exception = reason;
    return error.JsException;
}

/// Build a simple bound function with one prefix value and no carrier `this`.
pub fn bindValueAsPrefix(arena: std.mem.Allocator, native_fn: Value, prefix_val: Value) !Value {
    const pfx = try arena.alloc(Value, 1);
    pfx[0] = prefix_val;
    const bd = try arena.create(fn_proto.BoundData);
    bd.* = .{ .target = native_fn, .this_val = try val_mod.makeUndefined(arena), .prefix = pfx };
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
    obj.internal_kind = .bound_function;
    obj.internal_slot = bd;
    return val_mod.makeObject(arena, obj);
}

fn nativeFinallyFulfill(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // args[0] = onFinally callback (from prefix), args[1] = original fulfillment value
    const on_finally = if (args.len > 0) args[0] else Value{};
    const orig_val = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (on_finally.bits != 0 and isCallable(on_finally)) {
        const r = fn_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), on_finally, &[_]Value{}) catch |e| {
            if (e == error.JsException) {
                // on_finally threw: override with a rejected promise so the rejection
                // travels the promise chain (works with async/await catch in the VM).
                const reason = realm_mod.pending_exception;
                realm_mod.pending_exception = Value{};
                return nativePromiseReject(arena, Value{}, &[_]Value{reason});
            }
            return e;
        };
        // on_finally returned a value/thenable: wait for it, then pass through orig_val.
        const const_thunk = try val_mod.makeNativeFunction(arena, nativeFinallyConstThunk);
        const bound_thunk = try bindValueAsPrefix(arena, const_thunk, orig_val);
        const resolved = try nativePromiseResolve(arena, Value{}, &[_]Value{r});
        return nativePromiseThen(arena, resolved, &[_]Value{bound_thunk});
    }
    return orig_val;
}

fn nativeFinallyReject(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // args[0] = onFinally callback (from prefix), args[1] = original rejection reason
    const on_finally = if (args.len > 0) args[0] else Value{};
    const orig_reason = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    if (on_finally.bits != 0 and isCallable(on_finally)) {
        const r = fn_proto.invokeCallback(arena, try val_mod.makeUndefined(arena), on_finally, &[_]Value{}) catch |e| {
            if (e == error.JsException) {
                // on_finally threw a NEW reason: override — return rejected promise.
                const new_reason = realm_mod.pending_exception;
                realm_mod.pending_exception = Value{};
                return nativePromiseReject(arena, Value{}, &[_]Value{new_reason});
            }
            return e;
        };
        // on_finally returned a thenable: wait for it, then re-reject with orig_reason.
        const throw_thunk = try val_mod.makeNativeFunction(arena, nativeFinallyThrowThunk);
        const bound_thunk = try bindValueAsPrefix(arena, throw_thunk, orig_reason);
        const resolved = try nativePromiseResolve(arena, Value{}, &[_]Value{r});
        return nativePromiseThen(arena, resolved, &[_]Value{bound_thunk});
    }
    // on_finally not callable: pass through original rejection as a rejected promise.
    return nativePromiseReject(arena, Value{}, &[_]Value{orig_reason});
}

/// ES2018 Promise.prototype.finally(onFinally)
pub fn nativePromiseFinally(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const on_finally = if (args.len > 0) args[0] else Value{};
    // Build bound wrappers that carry on_finally as prefix[0].
    const fulfill_target = try val_mod.makeNativeFunction(arena, nativeFinallyFulfill);
    const reject_target = try val_mod.makeNativeFunction(arena, nativeFinallyReject);
    const on_fulfill = try bindValueAsPrefix(arena, fulfill_target, on_finally);
    const on_reject = try bindValueAsPrefix(arena, reject_target, on_finally);
    return nativePromiseThen(arena, this_val, &[_]Value{ on_fulfill, on_reject });
}

pub fn nativePromiseThen(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = getData(this_val) orelse {
        realm_mod.pending_exception = try val_mod.makeString(arena, "TypeError: receiver is not Promise");
        return error.JsException;
    };
    const next_promise = try makePendingPromise(arena);
    const next_data = getData(next_promise) orelse return next_promise;

    const on_fulfilled = if (args.len > 0) args[0] else Value{};
    const on_rejected = if (args.len > 1) args[1] else Value{};
    const reaction = Reaction{
        .on_fulfilled = on_fulfilled,
        .on_rejected = on_rejected,
        .next_data = next_data,
    };
    if (d.state == .pending) {
        try d.reactions.append(arena, reaction);
        return next_promise;
    }
    try enqueueReactionJob(arena, reaction, d.state, d.value);
    return next_promise;
}

pub fn nativePromiseCatch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const on_rejected = if (args.len > 0) args[0] else Value{};
    return nativePromiseThen(arena, this_val, &[_]Value{ Value{}, on_rejected });
}

fn runReactionJob(arena: std.mem.Allocator, job: Job) void {
    // Snapshot every field into stack locals BEFORE any callback. A reaction can
    // enqueue more jobs (e.g. an async coroutine awaiting another promise), which
    // reallocates `microtasks`; since `job` may be passed by reference to an
    // element of that buffer, touching `job.*` afterward would read freed memory.
    const next_data = job.reaction.next_data;
    const on_fulfilled = job.reaction.on_fulfilled;
    const on_rejected = job.reaction.on_rejected;
    const input_state = job.input_state;
    const input_value = job.input_value;
    if (input_state == .fulfilled) {
        if (on_fulfilled.bits != 0 and isCallable(on_fulfilled)) {
            const r = fn_proto.invokeCallback(arena, val_mod.makeUndefined(arena) catch Value{}, on_fulfilled, &[_]Value{input_value}) catch {
                settlePromise(next_data, .rejected, realm_mod.pending_exception);
                flushReactions(arena, next_data);
                realm_mod.pending_exception = Value{};
                return;
            };
            adoptOrFulfill(arena, next_data, r) catch {};
        } else {
            settlePromise(next_data, .fulfilled, input_value);
            flushReactions(arena, next_data);
        }
    } else {
        if (on_rejected.bits != 0 and isCallable(on_rejected)) {
            const r = fn_proto.invokeCallback(arena, val_mod.makeUndefined(arena) catch Value{}, on_rejected, &[_]Value{input_value}) catch {
                settlePromise(next_data, .rejected, realm_mod.pending_exception);
                flushReactions(arena, next_data);
                realm_mod.pending_exception = Value{};
                return;
            };
            adoptOrFulfill(arena, next_data, r) catch {};
        } else {
            settlePromise(next_data, .rejected, input_value);
            flushReactions(arena, next_data);
        }
    }
}

// A monotonic cursor into `microtasks` shared across (possibly re-entrant)
// `runMicrotasks` calls, plus a flag marking whether a drain is already active.
// Re-entrancy happens when a job's JS callback synchronously drains the queue
// itself — e.g. an import-defer trigger evaluating an async module from within a
// property access that is itself running inside a microtask. The cursor is
// advanced *before* a job runs, so a nested drain resumes only at the not-yet-run
// jobs and never re-runs the in-flight one (which would resume an already-running
// coroutine). Only the outermost drain clears the (fully consumed) queue.
var drain_cursor: usize = 0;
var draining: bool = false;

pub fn runMicrotasks(arena: std.mem.Allocator) void {
    // Reactions may enqueue more jobs (growing the list). A job's fields are
    // snapshotted inside runReactionJob, so a reallocation here can't dangle a
    // reference (see runReactionJob); `microtasks.items` is re-read each step.
    const outermost = !draining;
    draining = true;
    while (drain_cursor < microtasks.items.len) {
        const job = microtasks.items[drain_cursor];
        drain_cursor += 1;
        runReactionJob(arena, job);
    }
    if (outermost) {
        microtasks.clearRetainingCapacity();
        drain_cursor = 0;
        draining = false;
    }
}

pub fn clearMicrotasks() void {
    // Drop the backing slice (do NOT free — its arena was already reset by the caller).
    // Retaining capacity would dangle into the freed eval arena and crash the next append.
    microtasks = .empty;
    drain_cursor = 0;
    draining = false;
}

/// Top-level-await for a single-threaded engine: drain the microtask queue until
/// the awaited value settles. Plain values, thenables, and actual Promises are
/// all routed through Promise.resolve() so thenables are assimilated and plain
/// primitives surface immediately as fulfilled values.
pub fn awaitValue(arena: std.mem.Allocator, v: Value) anyerror!Value {
    // Promise.resolve(promise) → identity; Promise.resolve(thenable) → calls
    // then(resolve,reject) synchronously; Promise.resolve(primitive) → fulfilled.
    const p = nativePromiseResolve(arena, Value{}, &[_]Value{v}) catch return v;
    const data = getData(p) orelse return v;
    runMicrotasks(arena);
    return switch (data.state) {
        .fulfilled => data.value,
        .rejected => blk: {
            realm_mod.pending_exception = data.value;
            break :blk error.JsException;
        },
        .pending => try val_mod.makeUndefined(arena),
    };
}

pub fn nativeAwait(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return awaitValue(arena, v);
}

pub fn nativeRunMicrotasks(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    runMicrotasks(arena);
    return val_mod.makeUndefined(arena);
}

// -------------------------------------------------------- W2-async driver hooks ---
// These let the bytecode VM build a real async function as a reaction-driven
// coroutine: a pending result promise, plus per-await subscriptions that resume
// the suspended coroutine via the microtask queue.

/// Create a fresh pending promise (the async function's result promise).
pub fn newPendingPromise(arena: std.mem.Allocator) !Value {
    return makePendingPromise(arena);
}

/// Settle an async function's result promise. `fulfill` true resolves with `v`
/// (adopting it if it is a thenable/promise — this is `return await`/`return p`
/// semantics); false rejects with `v`.
pub fn settleResult(arena: std.mem.Allocator, promise: Value, v: Value, fulfill: bool) void {
    const d = getData(promise) orelse return;
    if (fulfill) {
        promiseResolveData(arena, d, v);
    } else {
        promiseRejectData(arena, d, v);
    }
}

/// `Promise.resolve(awaited).then(on_fulfilled, on_rejected)` — used by the async
/// driver to resume the coroutine when the awaited value settles. The throwaway
/// chained promise is ignored.
pub fn subscribeAwait(arena: std.mem.Allocator, awaited: Value, on_fulfilled: Value, on_rejected: Value) !void {
    const p = try nativePromiseResolve(arena, try val_mod.makeUndefined(arena), &[_]Value{awaited});
    _ = try nativePromiseThen(arena, p, &[_]Value{ on_fulfilled, on_rejected });
}
