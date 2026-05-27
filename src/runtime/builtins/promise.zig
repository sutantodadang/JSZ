// SPDX-License-Identifier: MIT
//! Phase 7 Promise practical subset with reaction queues.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const fn_proto = @import("./function_proto.zig");

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
    return switch (v.toPtr().*) {
        .function, .native_function => true,
        .object => |o| o.get("__call__") != null,
        else => false,
    };
}

fn getData(this_val: Value) ?*PromiseData {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return null;
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
    settlePromise(data, .fulfilled, v);
    flushReactions(arena, data);
}

fn promiseRejectData(arena: std.mem.Allocator, data: *PromiseData, v: Value) void {
    if (data.state != .pending) return;
    settlePromise(data, .rejected, v);
    flushReactions(arena, data);
}

fn nativePromiseResolver(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = if (this_val.bits != 0 and this_val.toPtr().* == .object and this_val.toPtr().object.internal_slot != null)
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
    if (this_val.bits != 0 and this_val.toPtr().* == .object) {
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
    return makePromise(arena, .fulfilled, v);
}

pub fn nativePromiseReject(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return makePromise(arena, .rejected, v);
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

pub fn runMicrotasks(arena: std.mem.Allocator) void {
    var idx: usize = 0;
    while (idx < microtasks.items.len) : (idx += 1) {
        const job = microtasks.items[idx];
        if (job.input_state == .fulfilled) {
            if (job.reaction.on_fulfilled.bits != 0 and isCallable(job.reaction.on_fulfilled)) {
                const r = fn_proto.invokeCallback(arena, val_mod.makeUndefined(arena) catch Value{}, job.reaction.on_fulfilled, &[_]Value{job.input_value}) catch {
                    settlePromise(job.reaction.next_data, .rejected, realm_mod.pending_exception);
                    flushReactions(arena, job.reaction.next_data);
                    realm_mod.pending_exception = Value{};
                    continue;
                };
                adoptOrFulfill(arena, job.reaction.next_data, r) catch {};
            } else {
                settlePromise(job.reaction.next_data, .fulfilled, job.input_value);
                flushReactions(arena, job.reaction.next_data);
            }
        } else {
            if (job.reaction.on_rejected.bits != 0 and isCallable(job.reaction.on_rejected)) {
                const r = fn_proto.invokeCallback(arena, val_mod.makeUndefined(arena) catch Value{}, job.reaction.on_rejected, &[_]Value{job.input_value}) catch {
                    settlePromise(job.reaction.next_data, .rejected, realm_mod.pending_exception);
                    flushReactions(arena, job.reaction.next_data);
                    realm_mod.pending_exception = Value{};
                    continue;
                };
                adoptOrFulfill(arena, job.reaction.next_data, r) catch {};
            } else {
                settlePromise(job.reaction.next_data, .rejected, job.input_value);
                flushReactions(arena, job.reaction.next_data);
            }
        }
    }
    microtasks.clearRetainingCapacity();
}
