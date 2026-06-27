// SPDX-License-Identifier: Apache-2.0
//! Phase 6 hidden classes (shapes) with transition caches.
const std = @import("std");

/// An ECMAScript array index: a canonical decimal string for an integer in
/// [0, 2^32-1). Returns the numeric value, or null if `key` is not one.
fn isArrayIndexKey(key: []const u8) ?u32 {
    if (key.len == 0) return null;
    for (key) |c| if (c < '0' or c > '9') return null;
    if (key.len > 1 and key[0] == '0') return null; // non-canonical leading zero
    const n = std.fmt.parseUnsigned(u32, key, 10) catch return null;
    if (n == std.math.maxInt(u32)) return null; // 2^32-1 is not an array index
    return n;
}

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
    /// Lazily-computed spec [[OwnPropertyKeys]] ordering cache. Null until first
    /// enumeration; shapes are immutable post-construction so it never invalidates.
    ordered_keys: ?[]const []const u8 = null,

    /// Spec [[OwnPropertyKeys]] string-key ordering: integer-index keys in
    /// ascending numeric order, then the remaining keys in insertion order.
    /// Cached on first call (`alloc` must match this shape's lifetime allocator).
    pub fn orderedKeys(self: *Shape, alloc: std.mem.Allocator) []const []const u8 {
        if (self.ordered_keys) |ok| return ok;
        const items = self.key_order.items;
        var has_idx = false;
        for (items) |k| {
            if (isArrayIndexKey(k) != null) {
                has_idx = true;
                break;
            }
        }
        // Fast path: no integer keys → insertion order already spec-correct.
        if (!has_idx) {
            self.ordered_keys = items;
            return items;
        }
        const IdxKey = struct { k: []const u8, n: u32 };
        var idxs: std.ArrayListUnmanaged(IdxKey) = .empty;
        var rest: std.ArrayListUnmanaged([]const u8) = .empty;
        for (items) |k| {
            if (isArrayIndexKey(k)) |n| {
                idxs.append(alloc, .{ .k = k, .n = n }) catch return items;
            } else {
                rest.append(alloc, k) catch return items;
            }
        }
        std.sort.block(IdxKey, idxs.items, {}, struct {
            fn lt(_: void, a: IdxKey, b: IdxKey) bool {
                return a.n < b.n;
            }
        }.lt);
        const out = alloc.alloc([]const u8, items.len) catch return items;
        var i: usize = 0;
        for (idxs.items) |e| {
            out[i] = e.k;
            i += 1;
        }
        for (rest.items) |k| {
            out[i] = k;
            i += 1;
        }
        idxs.deinit(alloc);
        rest.deinit(alloc);
        self.ordered_keys = out;
        return out;
    }
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
            .ordered_keys = null,
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
            .ordered_keys = null,
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
            .ordered_keys = null,
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
