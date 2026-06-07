// SPDX-License-Identifier: Apache-2.0
//! Phase 7 Promise practical subset with reaction queues.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const fn_proto = @import("./function_proto.zig");
const iter_mod = @import("./es2015_collections.zig");

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

/// Collect all elements from an iterable into an arena-allocated slice.
/// On non-iterable input, sets pending_exception and returns error.JsException.
fn collectIterable(arena: std.mem.Allocator, iterable: Value) ![]Value {
    var list = std.ArrayListUnmanaged(Value){};
    const it = try iter_mod.nativeGetIterator(arena, Value{}, &[_]Value{iterable});
    while (true) {
        const step = try iter_mod.nativeIterStep(arena, Value{}, &[_]Value{it});
        // step is an object with "done" and "value" properties
        if (step.bits == 0 or step.unbox() != .object) break;
        const done_v = step.toPtr().object.get("done") orelse break;
        // done_v is a boolean Value — treat as truthy using unbox
        const done: bool = blk: {
            if (done_v.bits == 0) break :blk false;
            break :blk switch (done_v.unbox()) {
                .boolean => |b| b,
                .undefined_, .null_ => false,
                .number => |n| n != 0 and !std.math.isNan(n),
                .string => |s| s.len > 0,
                else => true,
            };
        };
        if (done) break;
        const val = step.toPtr().object.get("value") orelse try val_mod.makeUndefined(arena);
        try list.append(arena, val);
    }
    return list.items;
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

const AllSettledCtx = struct {
    result_promise: *PromiseData,
    results: []Value,
    remaining: usize,
    result_arr: *JsObject,
};

fn allSettledRecord(arena: std.mem.Allocator, ctx: *AllSettledCtx, idx: usize, status: []const u8, payload: Value) void {
    const obj_proto = realm_mod.active_object_proto;
    const entry = if (realm_mod.active_heap) |h|
        JsObject.createOnHeap(h, obj_proto) catch return
    else
        JsObject.create(arena, obj_proto) catch return;
    const status_val = val_mod.makeString(arena, status) catch return;
    entry.set("status", status_val) catch return;
    if (std.mem.eql(u8, status, "fulfilled")) {
        entry.set("value", payload) catch return;
    } else {
        entry.set("reason", payload) catch return;
    }
    const idx_key = std.fmt.allocPrint(arena, "{d}", .{idx}) catch return;
    const entry_val = val_mod.makeObject(arena, entry) catch return;
    ctx.result_arr.set(idx_key, entry_val) catch return;
    ctx.results[idx] = entry_val;

    if (ctx.remaining > 0) {
        ctx.remaining -= 1;
    }
    if (ctx.remaining == 0) {
        ctx.result_arr.array_length = @intCast(ctx.results.len);
        const arr_val = val_mod.makeObject(arena, ctx.result_arr) catch return;
        promiseResolveData(arena, ctx.result_promise, arr_val);
        flushReactions(arena, ctx.result_promise);
    }
}

fn nativeAllSettledFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AllSettledCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len < 2) return val_mod.makeUndefined(arena);
    const idx: usize = @intFromFloat(@trunc(args[0].toF64()));
    allSettledRecord(arena, ctx, idx, "fulfilled", args[1]);
    return val_mod.makeUndefined(arena);
}

fn nativeAllSettledReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AllSettledCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (args.len < 2) return val_mod.makeUndefined(arena);
    const idx: usize = @intFromFloat(@trunc(args[0].toF64()));
    allSettledRecord(arena, ctx, idx, "rejected", args[1]);
    return val_mod.makeUndefined(arena);
}

fn subscribeAllSettledAsync(arena: std.mem.Allocator, ctx: *AllSettledCtx, idx: usize, wrapped: Value) !void {
    const fulfill_base = try val_mod.makeNativeFunction(arena, nativeAllSettledFulfill);
    const reject_base = try val_mod.makeNativeFunction(arena, nativeAllSettledReject);
    const on_fulfill = try makeCtxHandler(arena, fulfill_base, ctx, idx, true);
    const on_reject = try makeCtxHandler(arena, reject_base, ctx, idx, true);
    _ = try nativePromiseThen(arena, wrapped, &[_]Value{ on_fulfill, on_reject });
}

/// ES2020 Promise.allSettled(iterable) — never rejects; each input → {status,value|reason}.
pub fn nativePromiseAllSettled(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const result_p = try makePendingPromise(arena);
    const result_data = getData(result_p) orelse return result_p;

    const arr_proto = realm_mod.active_array_proto;
    const result_arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) {
        result_arr.array_length = 0;
        promiseResolveData(arena, result_data, try val_mod.makeObject(arena, result_arr));
        flushReactions(arena, result_data);
        return result_p;
    }

    const items = collectIterable(arena, args[0]) catch |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, result_data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            flushReactions(arena, result_data);
            return result_p;
        }
        return e;
    };
    const count = items.len;
    if (count == 0) {
        result_arr.array_length = 0;
        promiseResolveData(arena, result_data, try val_mod.makeObject(arena, result_arr));
        flushReactions(arena, result_data);
        return result_p;
    }

    const ctx = try arena.create(AllSettledCtx);
    const results = try arena.alloc(Value, count);
    @memset(results, Value{});
    ctx.* = .{
        .result_promise = result_data,
        .results = results,
        .remaining = count,
        .result_arr = result_arr,
    };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = items[i];
        const wrapped = try nativePromiseResolve(arena, Value{}, &[_]Value{item});
        const wd = getData(wrapped) orelse continue;
        switch (wd.state) {
            .fulfilled => allSettledRecord(arena, ctx, i, "fulfilled", wd.value),
            .rejected => allSettledRecord(arena, ctx, i, "rejected", wd.value),
            .pending => try subscribeAllSettledAsync(arena, ctx, i, wrapped),
        }
    }
    return result_p;
}

// ---- Promise.all ----

const AllCtx = struct {
    result_promise: *PromiseData,
    results: []Value,
    remaining: usize,
    result_arr: *JsObject,
    settled: bool,
};

fn nativeAllFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AllCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    if (args.len < 2) return val_mod.makeUndefined(arena);
    const idx: usize = @intFromFloat(@trunc(args[0].toF64()));
    const val = args[1];
    const idx_key = std.fmt.allocPrint(arena, "{d}", .{idx}) catch return val_mod.makeUndefined(arena);
    ctx.result_arr.set(idx_key, val) catch {};
    ctx.results[idx] = val;
    if (ctx.remaining > 0) ctx.remaining -= 1;
    if (ctx.remaining == 0) {
        ctx.settled = true;
        ctx.result_arr.array_length = @intCast(ctx.results.len);
        const arr_val = val_mod.makeObject(arena, ctx.result_arr) catch return val_mod.makeUndefined(arena);
        promiseResolveData(arena, ctx.result_promise, arr_val);
        flushReactions(arena, ctx.result_promise);
    }
    return val_mod.makeUndefined(arena);
}

fn nativeAllReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AllCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    ctx.settled = true;
    const reason = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    promiseRejectData(arena, ctx.result_promise, reason);
    flushReactions(arena, ctx.result_promise);
    return val_mod.makeUndefined(arena);
}

/// ES2015 Promise.all(iterable)
pub fn nativePromiseAll(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const result_p = try makePendingPromise(arena);
    const result_data = getData(result_p) orelse return result_p;

    const arr_proto = realm_mod.active_array_proto;
    const result_arr = try JsObject.createArray(arena, arr_proto);

    if (args.len == 0 or args[0].bits == 0) {
        result_arr.array_length = 0;
        promiseResolveData(arena, result_data, try val_mod.makeObject(arena, result_arr));
        flushReactions(arena, result_data);
        return result_p;
    }

    const items = collectIterable(arena, args[0]) catch |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, result_data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            flushReactions(arena, result_data);
            return result_p;
        }
        return e;
    };
    const count = items.len;
    if (count == 0) {
        result_arr.array_length = 0;
        promiseResolveData(arena, result_data, try val_mod.makeObject(arena, result_arr));
        flushReactions(arena, result_data);
        return result_p;
    }

    const ctx = try arena.create(AllCtx);
    const results = try arena.alloc(Value, count);
    @memset(results, Value{});
    ctx.* = .{
        .result_promise = result_data,
        .results = results,
        .remaining = count,
        .result_arr = result_arr,
        .settled = false,
    };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = items[i];
        const wrapped = try nativePromiseResolve(arena, Value{}, &[_]Value{item});
        const wd = getData(wrapped) orelse continue;
        switch (wd.state) {
            .fulfilled => {
                const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
                result_arr.set(idx_key, wd.value) catch {};
                results[i] = wd.value;
                if (ctx.remaining > 0) ctx.remaining -= 1;
                if (ctx.remaining == 0 and !ctx.settled) {
                    ctx.settled = true;
                    result_arr.array_length = @intCast(results.len);
                    const arr_val = try val_mod.makeObject(arena, result_arr);
                    promiseResolveData(arena, result_data, arr_val);
                    flushReactions(arena, result_data);
                }
            },
            .rejected => {
                if (!ctx.settled) {
                    ctx.settled = true;
                    promiseRejectData(arena, result_data, wd.value);
                    flushReactions(arena, result_data);
                }
            },
            .pending => {
                const fulfill_base = try val_mod.makeNativeFunction(arena, nativeAllFulfill);
                const reject_base = try val_mod.makeNativeFunction(arena, nativeAllReject);
                const on_fulfill = try makeCtxHandler(arena, fulfill_base, ctx, i, true);
                const on_reject = try makeCtxHandler(arena, reject_base, ctx, i, true);
                _ = try nativePromiseThen(arena, wrapped, &[_]Value{ on_fulfill, on_reject });
            },
        }
    }
    return result_p;
}

// ---- Promise.race ----

const RaceCtx = struct {
    result_promise: *PromiseData,
    settled: bool,
};

fn nativeRaceFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(RaceCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    ctx.settled = true;
    const val = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    promiseResolveData(arena, ctx.result_promise, val);
    flushReactions(arena, ctx.result_promise);
    return val_mod.makeUndefined(arena);
}

fn nativeRaceReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(RaceCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    ctx.settled = true;
    const reason = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    promiseRejectData(arena, ctx.result_promise, reason);
    flushReactions(arena, ctx.result_promise);
    return val_mod.makeUndefined(arena);
}

/// ES2015 Promise.race(iterable)
pub fn nativePromiseRace(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const result_p = try makePendingPromise(arena);
    const result_data = getData(result_p) orelse return result_p;

    if (args.len == 0 or args[0].bits == 0) return result_p;

    const items = collectIterable(arena, args[0]) catch |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, result_data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            flushReactions(arena, result_data);
            return result_p;
        }
        return e;
    };
    const count = items.len;
    if (count == 0) return result_p;

    const ctx = try arena.create(RaceCtx);
    ctx.* = .{ .result_promise = result_data, .settled = false };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (ctx.settled) break;
        const item = items[i];
        const wrapped = try nativePromiseResolve(arena, Value{}, &[_]Value{item});
        const wd = getData(wrapped) orelse continue;
        switch (wd.state) {
            .fulfilled => {
                if (!ctx.settled) {
                    ctx.settled = true;
                    promiseResolveData(arena, result_data, wd.value);
                    flushReactions(arena, result_data);
                }
            },
            .rejected => {
                if (!ctx.settled) {
                    ctx.settled = true;
                    promiseRejectData(arena, result_data, wd.value);
                    flushReactions(arena, result_data);
                }
            },
            .pending => {
                const fulfill_fn = try val_mod.makeNativeFunction(arena, nativeRaceFulfill);
                const reject_fn = try val_mod.makeNativeFunction(arena, nativeRaceReject);
                const on_fulfill = try makeCtxHandler(arena, fulfill_fn, ctx, 0, false);
                const on_reject = try makeCtxHandler(arena, reject_fn, ctx, 0, false);
                _ = try nativePromiseThen(arena, wrapped, &[_]Value{ on_fulfill, on_reject });
            },
        }
    }
    return result_p;
}

// ---- Promise.any ----

const AnyCtx = struct {
    result_promise: *PromiseData,
    remaining: usize,
    settled: bool,
    errors: []Value,
};

/// Build an AggregateError object from a slice of rejection reasons.
fn makeAggregateError(arena: std.mem.Allocator, errors: []const Value, msg: []const u8) !Value {
    // Build the errors array object.
    const arr_proto = realm_mod.active_array_proto;
    const err_arr = try JsObject.createArray(arena, arr_proto);
    for (errors, 0..) |e, k| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{k});
        try err_arr.set(key, e);
    }
    err_arr.array_length = @intCast(errors.len);
    const errors_val = try val_mod.makeObject(arena, err_arr);

    // Build the AggregateError object.
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

fn nativeAnyFulfill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AnyCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    ctx.settled = true;
    // args[0] is the index (bound prefix), args[1] is the value
    const val = if (args.len > 1) args[1] else if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    promiseResolveData(arena, ctx.result_promise, val);
    flushReactions(arena, ctx.result_promise);
    return val_mod.makeUndefined(arena);
}

fn nativeAnyReject(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = ctxFromThis(AnyCtx, this_val) orelse return val_mod.makeUndefined(arena);
    if (ctx.settled) return val_mod.makeUndefined(arena);
    // args[0] = index, args[1] = rejection reason
    if (args.len >= 2) {
        const idx: usize = @intFromFloat(@trunc(args[0].toF64()));
        if (idx < ctx.errors.len) ctx.errors[idx] = args[1];
    }
    if (ctx.remaining > 0) ctx.remaining -= 1;
    if (ctx.remaining == 0) {
        ctx.settled = true;
        const agg_err = try makeAggregateError(arena, ctx.errors, "All promises were rejected");
        promiseRejectData(arena, ctx.result_promise, agg_err);
        flushReactions(arena, ctx.result_promise);
    }
    return val_mod.makeUndefined(arena);
}

/// ES2021 Promise.any(iterable)
pub fn nativePromiseAny(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const result_p = try makePendingPromise(arena);
    const result_data = getData(result_p) orelse return result_p;

    if (args.len == 0 or args[0].bits == 0) {
        const agg_err = try makeAggregateError(arena, &[_]Value{}, "All promises were rejected");
        promiseRejectData(arena, result_data, agg_err);
        flushReactions(arena, result_data);
        return result_p;
    }

    const items = collectIterable(arena, args[0]) catch |e| {
        if (e == error.JsException) {
            promiseRejectData(arena, result_data, realm_mod.pending_exception);
            realm_mod.pending_exception = Value{};
            flushReactions(arena, result_data);
            return result_p;
        }
        return e;
    };
    const count = items.len;
    if (count == 0) {
        const agg_err = try makeAggregateError(arena, &[_]Value{}, "All promises were rejected");
        promiseRejectData(arena, result_data, agg_err);
        flushReactions(arena, result_data);
        return result_p;
    }

    const errors = try arena.alloc(Value, count);
    @memset(errors, Value{});
    const ctx = try arena.create(AnyCtx);
    ctx.* = .{ .result_promise = result_data, .remaining = count, .settled = false, .errors = errors };

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (ctx.settled) break;
        const item = items[i];
        const wrapped = try nativePromiseResolve(arena, Value{}, &[_]Value{item});
        const wd = getData(wrapped) orelse continue;
        switch (wd.state) {
            .fulfilled => {
                if (!ctx.settled) {
                    ctx.settled = true;
                    promiseResolveData(arena, result_data, wd.value);
                    flushReactions(arena, result_data);
                }
            },
            .rejected => {
                if (!ctx.settled) {
                    errors[i] = wd.value;
                    if (ctx.remaining > 0) ctx.remaining -= 1;
                    if (ctx.remaining == 0) {
                        ctx.settled = true;
                        const agg_err = try makeAggregateError(arena, errors, "All promises were rejected");
                        promiseRejectData(arena, result_data, agg_err);
                        flushReactions(arena, result_data);
                    }
                }
            },
            .pending => {
                const fulfill_fn = try val_mod.makeNativeFunction(arena, nativeAnyFulfill);
                const reject_fn = try val_mod.makeNativeFunction(arena, nativeAnyReject);
                const on_fulfill = try makeCtxHandler(arena, fulfill_fn, ctx, i, true);
                const on_reject = try makeCtxHandler(arena, reject_fn, ctx, i, true);
                _ = try nativePromiseThen(arena, wrapped, &[_]Value{ on_fulfill, on_reject });
            },
        }
    }
    return result_p;
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
fn bindValueAsPrefix(arena: std.mem.Allocator, native_fn: Value, prefix_val: Value) !Value {
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

pub fn runMicrotasks(arena: std.mem.Allocator) void {
    // Index by position: reactions may enqueue more jobs (growing the list). A
    // job's fields are snapshotted inside runReactionJob, so a reallocation here
    // can't dangle a reference (see runReactionJob).
    var idx: usize = 0;
    while (idx < microtasks.items.len) : (idx += 1) {
        runReactionJob(arena, microtasks.items[idx]);
    }
    microtasks.clearRetainingCapacity();
}

pub fn clearMicrotasks() void {
    // Drop the backing slice (do NOT free — its arena was already reset by the caller).
    // Retaining capacity would dangle into the freed eval arena and crash the next append.
    microtasks = .empty;
}

/// Top-level-await for a single-threaded engine: drain the microtask queue until
/// the awaited promise settles. Non-promises (and unsettleable pendings) pass through.
pub fn awaitValue(arena: std.mem.Allocator, v: Value) anyerror!Value {
    const data = getData(v) orelse return v;
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
