// SPDX-License-Identifier: Apache-2.0
//! Phase 6 hidden classes (shapes) with transition caches.
const std = @import("std");

pub const Shape = struct {
    id: u32,
    parent: ?*Shape,
    /// Property count represented by this shape.
    property_count: u32,
    /// Added property when transitioning from parent -> this shape.
    added_key: ?[]const u8,
    /// Transition cache: key -> next shape for "add property key".
    transitions: std.StringHashMapUnmanaged(*Shape),
    /// Stable slot index for each own property.
    key_to_slot: std.StringHashMapUnmanaged(u32),
    /// Insertion order snapshot for delete/rebuild transitions.
    key_order: std.ArrayListUnmanaged([]const u8),
};

pub const ShapeManager = struct {
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    root_shape: *Shape,

    pub fn init(allocator: std.mem.Allocator) !ShapeManager {
        const root_shape = try allocator.create(Shape);
        root_shape.* = .{
            .id = 0,
            .parent = null,
            .property_count = 0,
            .added_key = null,
            .transitions = .empty,
            .key_to_slot = .empty,
            .key_order = .empty,
        };
        return .{
            .allocator = allocator,
            .root_shape = root_shape,
        };
    }

    pub fn root(self: *ShapeManager) *Shape {
        return self.root_shape;
    }

    pub fn transitionAdd(self: *ShapeManager, shape: *Shape, key: []const u8) !*Shape {
        if (shape.transitions.get(key)) |next| {
            return next;
        }

        const next = try self.allocator.create(Shape);
        next.* = .{
            .id = self.next_id,
            .parent = shape,
            .property_count = shape.property_count + 1,
            .added_key = try self.allocator.dupe(u8, key),
            .transitions = .empty,
            .key_to_slot = .empty,
            .key_order = .empty,
        };
        self.next_id += 1;

        var parent_it = shape.key_to_slot.iterator();
        while (parent_it.next()) |entry| {
            try next.key_to_slot.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        for (shape.key_order.items) |k| {
            try next.key_order.append(self.allocator, k);
        }

        const slot = @as(u32, @intCast(shape.key_order.items.len));
        try next.key_to_slot.put(self.allocator, next.added_key.?, slot);
        try next.key_order.append(self.allocator, next.added_key.?);
        try shape.transitions.put(self.allocator, next.added_key.?, next);
        return next;
    }

    pub fn transitionDelete(self: *ShapeManager, shape: *Shape, key: []const u8) !*Shape {
        if (shape.key_to_slot.get(key) == null) return shape;

        const next = try self.allocator.create(Shape);
        next.* = .{
            .id = self.next_id,
            .parent = shape,
            .property_count = shape.property_count - 1,
            .added_key = null,
            .transitions = .empty,
            .key_to_slot = .empty,
            .key_order = .empty,
        };
        self.next_id += 1;

        var slot: u32 = 0;
        for (shape.key_order.items) |k| {
            if (std.mem.eql(u8, k, key)) continue;
            try next.key_to_slot.put(self.allocator, k, slot);
            try next.key_order.append(self.allocator, k);
            slot += 1;
        }
        return next;
    }
};

var global_manager: ?ShapeManager = null;

pub fn globalManager() *ShapeManager {
    if (global_manager == null) {
        global_manager = ShapeManager.init(std.heap.page_allocator) catch unreachable;
    }
    return &global_manager.?;
}

test "shape transition add reuses cached edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mgr = try ShapeManager.init(arena.allocator());
    const root = mgr.root();
    const s1 = try mgr.transitionAdd(root, "x");
    const s2 = try mgr.transitionAdd(root, "x");
    try std.testing.expect(s1 == s2);
    try std.testing.expectEqual(@as(u32, 1), s1.property_count);
    try std.testing.expectEqual(@as(?u32, 0), s1.key_to_slot.get("x"));
}

test "shape transition delete compacts slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mgr = try ShapeManager.init(arena.allocator());
    const s1 = try mgr.transitionAdd(mgr.root(), "a");
    const s2 = try mgr.transitionAdd(s1, "b");
    const s3 = try mgr.transitionDelete(s2, "a");
    try std.testing.expectEqual(@as(u32, 1), s3.property_count);
    try std.testing.expect(s3.key_to_slot.get("a") == null);
    try std.testing.expectEqual(@as(?u32, 0), s3.key_to_slot.get("b"));
}
