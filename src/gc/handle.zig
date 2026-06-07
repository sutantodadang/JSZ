// SPDX-License-Identifier: Apache-2.0
//! Phase 3b: HandleScope — RAII GC root frames.
//!
//! Every native function entry point must open a HandleScope on the Zig stack
//! and call scope.exit() (via defer) before returning. All JsObject-bearing
//! Values that must survive a collect() must be local()'d into the scope.
//!
//! MVP: non-moving collector, so the *Value returned by local() stays valid
//! across collect() — but the API is designed for a future moving collector
//! (Phase 6). Callers must re-read through the *Value slot, not cache the
//! raw pointer.
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const Heap = @import("./heap.zig").Heap;

/// A single HandleScope frame.
/// Holds up to 32 rooted Values; stack-allocated by callers.
pub const HandleScope = struct {
    heap: *Heap,
    /// Link to the previous open scope (or null for the bottom frame).
    parent: ?*HandleScope,
    /// Fixed-size root buffer.
    handles: [32]Value = [_]Value{Value{}} ** 32,
    /// Number of valid entries in handles[0..count].
    count: u32 = 0,

    /// Push a new scope frame onto the heap's scope stack.
    /// Returns a HandleScope that is live until exit() is called.
    pub fn enter(heap: *Heap) HandleScope {
        const scope = HandleScope{
            .heap = heap,
            .parent = heap.handle_scope_top,
        };
        return scope;
    }

    /// Register the scope with the heap. Must be called after enter()
    /// and before any local() calls. Separate from enter() so callers can
    /// store the scope before registering (avoids self-referential init).
    pub fn activate(self: *HandleScope) void {
        self.heap.handle_scope_top = self;
    }

    /// Pop this scope from the heap's scope stack.
    /// After exit(), no Values rooted in this scope are protected.
    pub fn exit(self: *HandleScope) void {
        self.heap.handle_scope_top = self.parent;
    }

    /// Root a Value in this scope. Returns a pointer to the slot.
    /// The slot is valid until exit(); do not retain beyond that.
    /// Returns error.OutOfMemory if the 32-slot buffer is exhausted.
    pub fn local(self: *HandleScope, v: Value) !*Value {
        if (self.count >= 32) return error.OutOfMemory;
        const idx = self.count;
        self.count += 1;
        self.handles[idx] = v;
        return &self.handles[idx];
    }
};

// ---------------------------------------------------------------------- tests ---

test "HandleScope: enter/exit round-trip" {
    var heap = @import("./heap.zig").Heap.init(std.testing.allocator);
    defer heap.deinit();

    var scope = HandleScope.enter(&heap);
    scope.activate();
    try std.testing.expect(heap.handle_scope_top == &scope);
    scope.exit();
    try std.testing.expect(heap.handle_scope_top == null);
}

test "HandleScope: local roots value" {
    var heap = @import("./heap.zig").Heap.init(std.testing.allocator);
    defer heap.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");

    const obj = try heap.allocateObject(null);
    const v = try val_mod.makeObject(arena.allocator(), obj);

    var scope = HandleScope.enter(&heap);
    scope.activate();
    defer scope.exit();

    const slot = try scope.local(v);
    _ = slot;

    // Object should survive a collect because it's in the scope.
    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
    try std.testing.expectEqual(@as(usize, 1), heap.objects_alive);
}

test "HandleScope: value freed after scope exits" {
    var heap = @import("./heap.zig").Heap.init(std.testing.allocator);
    defer heap.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");

    const obj = try heap.allocateObject(null);
    const v = try val_mod.makeObject(arena.allocator(), obj);

    {
        var scope = HandleScope.enter(&heap);
        scope.activate();
        _ = try scope.local(v);
        scope.exit(); // scope closes
    }

    // No more roots — object should be freed.
    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 1), stats.freed_objects);
}
