// SPDX-License-Identifier: MIT
//! Phase 3a/3b: JsObject — ES5 object with prototype chain.
//!
//! Allocation strategies:
//!   create(arena, proto)           — arena-allocated (intrinsics, shared lifetime)
//!   createArray(arena, proto)      — arena-allocated array
//!   createOnHeap(heap, proto)      — GC-tracked (object literals, user-created objects)
//!   createArrayOnHeap(heap, proto) — GC-tracked array
//!
//! GC-tracked objects have a GcHeader prepended (managed by Heap).
//! Arena objects are freed when the eval arena resets.
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const shape_mod = @import("../value/shape.zig");
const Shape = shape_mod.Shape;
const ShapeManager = shape_mod.ShapeManager;

/// Maximum prototype chain depth before we give up (cycle guard, Phase 3a).
const MAX_PROTO_DEPTH: usize = 64;

pub const JsObject = struct {
    /// Prototype link (null = Object.prototype or bare object).
    proto: ?*JsObject = null,
    /// True if this object is the backing store for an array.
    is_array: bool = false,
    /// Cached length for array-backed objects.
    array_length: u32 = 0,
    /// Whether new properties can be added (Phase 3a: always true).
    extensible: bool = true,
    /// True when this object was allocated by Heap.allocateObject (has a
    /// valid GcHeader prefix). False for arena-allocated intrinsics.
    /// Used by the GC mark phase to avoid dereferencing a fake header on
    /// arena objects reached via proto walks.
    is_gc_managed: bool = false,
    /// Phase 4c: opaque pointer for internal slots (e.g., CompiledRegex).
    /// Arena-allocated; MUST NOT be traversed by markObject.
    internal_slot: ?*anyopaque = null,
    /// Phase 4c/4d: discriminator for internal_slot type.
    internal_kind: enum(u8) { none, regexp, bound_function, date, map, set, weakmap, weakset, promise, generator } = .none,
    /// Allocator for property storage (the eval arena).
    arena: std.mem.Allocator,
    /// Phase 6 hidden class manager (shared globally).
    shape_manager: *ShapeManager,
    /// Current hidden class for own properties.
    shape: *Shape,
    /// Slot values indexed by shape key_to_slot.
    slots: std.ArrayListUnmanaged(Value) = .empty,

    /// Allocate a plain object with an optional prototype.
    pub fn create(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
        const obj = try arena.create(JsObject);
        const manager = shape_mod.globalManager();
        obj.* = JsObject{
            .arena = arena,
            .proto = proto,
            .shape_manager = manager,
            .shape = manager.root(),
        };
        return obj;
    }

    /// Allocate an array-backed object.
    pub fn createArray(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
        const obj = try arena.create(JsObject);
        const manager = shape_mod.globalManager();
        obj.* = JsObject{
            .arena = arena,
            .proto = proto,
            .is_array = true,
            .array_length = 0,
            .shape_manager = manager,
            .shape = manager.root(),
        };
        return obj;
    }

    /// Allocate a plain object on the GC heap (Phase 3b).
    /// Use this for all user-created objects (object literals, Object.create, etc.).
    /// Intrinsics that share Context lifetime should still use create(arena, proto).
    pub fn createOnHeap(heap: anytype, proto: ?*JsObject) !*JsObject {
        return heap.allocateObject(proto);
    }

    /// Allocate an array-backed object on the GC heap (Phase 3b).
    pub fn createArrayOnHeap(heap: anytype, proto: ?*JsObject) !*JsObject {
        return heap.allocateArray(proto);
    }

    /// Get own property (no proto walk).
    pub fn getOwn(self: *JsObject, key: []const u8) ?Value {
        if (self.is_array and std.mem.eql(u8, key, "length")) return null;
        if (self.shape.key_to_slot.get(key)) |slot| {
            if (slot < self.slots.items.len) return self.slots.items[slot];
        }
        return null;
    }

    /// Get property with prototype chain walk. Returns null if not found.
    pub fn get(self: *JsObject, key: []const u8) ?Value {
        // Special: "length" on arrays.
        if (self.is_array and std.mem.eql(u8, key, "length")) {
            return self.getLength();
        }
        var depth: usize = 0;
        var cur: ?*JsObject = self;
        while (cur) |obj| {
            if (depth >= MAX_PROTO_DEPTH) break;
            depth += 1;
            if (obj.getOwn(key)) |v| return v;
            cur = obj.proto;
        }
        return null;
    }

    /// Set own property. Updates array_length if key is an array index.
    pub fn set(self: *JsObject, key: []const u8, value: Value) !void {
        if (self.shape.key_to_slot.get(key)) |slot| {
            if (slot < self.slots.items.len) {
                self.slots.items[slot] = value;
            }
        } else {
            self.shape = try self.shape_manager.transitionAdd(self.shape, key);
            const new_slot = self.shape.key_to_slot.get(key) orelse unreachable;
            if (new_slot == self.slots.items.len) {
                try self.slots.append(self.arena, value);
            } else {
                while (self.slots.items.len <= new_slot) {
                    try self.slots.append(self.arena, Value{});
                }
                self.slots.items[new_slot] = value;
            }
        }
        if (self.is_array) {
            // If key parses as a non-negative integer, bump array_length.
            const idx = std.fmt.parseUnsigned(u32, key, 10) catch return;
            if (idx >= self.array_length) {
                self.array_length = idx + 1;
            }
        }
    }

    /// Has own property check.
    pub fn hasOwn(self: *JsObject, key: []const u8) bool {
        return self.shape.key_to_slot.contains(key);
    }

    /// Get length: for arrays returns cached length as a Value.
    /// Returns null for non-arrays (caller may fall back to own prop "length").
    pub fn getLength(self: *JsObject) ?Value {
        if (!self.is_array) return self.getOwn("length");
        // Return a Value wrapping the length number.
        // We can't allocate here without error propagation, so we store a sentinel.
        // Caller uses getArrayLength() for the raw u32.
        return null; // use getArrayLengthValue with arena
    }

    pub fn getArrayLength(self: *JsObject) u32 {
        return self.array_length;
    }

    pub fn shapePtr(self: *JsObject) *anyopaque {
        return @ptrCast(self.shape);
    }

    pub fn resolveOwnSlot(self: *JsObject, key: []const u8) ?u32 {
        return self.shape.key_to_slot.get(key);
    }

    pub fn getOwnBySlot(self: *JsObject, expected_shape: *anyopaque, slot: u32) ?Value {
        if (@as(*anyopaque, @ptrCast(self.shape)) != expected_shape) return null;
        if (slot >= self.slots.items.len) return null;
        return self.slots.items[slot];
    }

    pub fn setOwnBySlot(self: *JsObject, expected_shape: *anyopaque, slot: u32, value: Value) bool {
        if (@as(*anyopaque, @ptrCast(self.shape)) != expected_shape) return false;
        if (slot >= self.slots.items.len) return false;
        self.slots.items[slot] = value;
        return true;
    }

    /// Delete own property and transition shape if key exists.
    pub fn deleteOwn(self: *JsObject, key: []const u8) !bool {
        if (self.shape.key_to_slot.get(key) == null) return false;
        const old_shape = self.shape;
        self.shape = try self.shape_manager.transitionDelete(old_shape, key);
        var new_slots: std.ArrayListUnmanaged(Value) = .empty;
        for (self.shape.key_order.items) |k| {
            const old_slot = old_shape.key_to_slot.get(k);
            const v = if (old_slot) |s| (if (s < self.slots.items.len) self.slots.items[s] else Value{}) else Value{};
            try new_slots.append(self.arena, v);
        }
        self.slots = new_slots;
        return true;
    }

    /// Ordered own-property keys (insertion order). Backed by the shape.
    pub fn ownKeys(self: *JsObject) []const []const u8 {
        return self.shape.key_order.items;
    }
};

// ------------------------------------------------------------------- tests ---

test "JsObject create and set/get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val_mod = @import("../value/value.zig");

    const obj = try JsObject.create(alloc, null);
    const v = try val_mod.makeNumber(alloc, 42.0);
    try obj.set("x", v);
    const got = obj.get("x");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(f64, 42.0), got.?.toF64());
    try std.testing.expectEqual(@as(?u32, 0), obj.resolveOwnSlot("x"));
}

test "JsObject proto chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val_mod = @import("../value/value.zig");

    const proto = try JsObject.create(alloc, null);
    const v = try val_mod.makeNumber(alloc, 7.0);
    try proto.set("greet", v);

    const child = try JsObject.create(alloc, proto);
    const got = child.get("greet");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(f64, 7.0), got.?.toF64());
}

test "JsObject array length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val_mod = @import("../value/value.zig");

    const arr = try JsObject.createArray(alloc, null);
    const v0 = try val_mod.makeNumber(alloc, 10.0);
    const v1 = try val_mod.makeNumber(alloc, 20.0);
    const v2 = try val_mod.makeNumber(alloc, 30.0);
    try arr.set("0", v0);
    try arr.set("1", v1);
    try arr.set("2", v2);
    try std.testing.expectEqual(@as(u32, 3), arr.getArrayLength());
}

test "JsObject shape delete compacts slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const val_mod = @import("../value/value.zig");

    const obj = try JsObject.create(alloc, null);
    const va = try val_mod.makeNumber(alloc, 1);
    const vb = try val_mod.makeNumber(alloc, 2);
    try obj.set("a", va);
    try obj.set("b", vb);
    try std.testing.expectEqual(@as(?u32, 0), obj.resolveOwnSlot("a"));
    try std.testing.expectEqual(@as(?u32, 1), obj.resolveOwnSlot("b"));
    _ = try obj.deleteOwn("a");
    try std.testing.expect(obj.resolveOwnSlot("a") == null);
    try std.testing.expectEqual(@as(?u32, 0), obj.resolveOwnSlot("b"));
    try std.testing.expectEqual(@as(f64, 2), obj.get("b").?.toF64());
}
