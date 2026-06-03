// SPDX-License-Identifier: MIT
//! Phase 3b: GC module re-exports and tracing helpers.
//! This file serves as the roots/tracing shim described in the spec as roots.zig.
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const JsObject = @import("../object/object.zig").JsObject;
const Environment = @import("../runtime/execution_context.zig").Environment;

pub const Heap = @import("./heap.zig").Heap;
pub const GcHeader = @import("./heap.zig").GcHeader;
pub const GcObjectKind = @import("./heap.zig").GcObjectKind;
pub const CollectStats = @import("./heap.zig").CollectStats;
pub const HandleScope = @import("./handle.zig").HandleScope;

/// Trace a Value: if it holds a JsObject, call mark_fn on it.
pub fn traceValue(v: Value, mark_fn: *const fn (*JsObject) void) void {
    if (!v.isHeapPtr()) return;
    const inner = v.toPtr();
    switch (inner.*) {
        .object => |obj| mark_fn(obj),
        else => {},
    }
}

/// Trace all values in a JsObject's own properties and proto chain.
pub fn traceJsObject(obj: *JsObject, mark_fn: *const fn (*JsObject) void) void {
    // proto
    if (obj.proto) |proto| mark_fn(proto);
    // own props
    var it = obj.props.iterator();
    while (it.next()) |entry| {
        traceValue(entry.value_ptr.*, mark_fn);
    }
}

/// Trace all values bound in an Environment frame chain.
pub fn traceEnvironment(env: *Environment, mark_fn: *const fn (*JsObject) void) void {
    var cur: ?*Environment = env;
    while (cur) |e| {
        var it = e.bindings.valueIterator();
        while (it.next()) |bptr| {
            traceValue(bptr.value, mark_fn);
        }
        cur = e.parent;
    }
}

// ---------------------------------------------------------------------- tests ---

test "traceValue: object arm calls mark_fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");
    const obj = try JsObject.create(arena.allocator(), null);
    const v = try val_mod.makeObject(arena.allocator(), obj);

    var called: bool = false;
    const marker = struct {
        var flag: *bool = undefined;
        fn mark(_: *JsObject) void {
            flag.* = true;
        }
    };
    marker.flag = &called;
    traceValue(v, marker.mark);
    try std.testing.expect(called);
}

test "traceEnvironment: walks bindings and parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");
    const env_mod = @import("../runtime/execution_context.zig");

    const parent = try env_mod.Environment.init(arena.allocator(), null);
    const obj = try JsObject.create(arena.allocator(), null);
    const v = try val_mod.makeObject(arena.allocator(), obj);
    try parent.define("x", v);

    const child = try env_mod.Environment.init(arena.allocator(), parent);

    var count: usize = 0;
    const marker = struct {
        var cnt: *usize = undefined;
        fn mark(_: *JsObject) void {
            cnt.* += 1;
        }
    };
    marker.cnt = &count;
    traceEnvironment(child, marker.mark);
    try std.testing.expectEqual(@as(usize, 1), count);
}
