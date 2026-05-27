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

/// Maximum prototype chain depth before we give up (cycle guard, Phase 3a).
const MAX_PROTO_DEPTH: usize = 64;

pub const JsObject = struct {
    /// Insertion-ordered property map (ES5: own properties keep insertion order).
    props: std.StringArrayHashMapUnmanaged(Value) = .empty,
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
    internal_kind: enum(u8) { none, regexp, bound_function, date } = .none,
    /// Allocator for property storage (the eval arena).
    arena: std.mem.Allocator,

    /// Allocate a plain object with an optional prototype.
    pub fn create(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
        const obj = try arena.create(JsObject);
        obj.* = JsObject{
            .arena = arena,
            .proto = proto,
        };
        return obj;
    }

    /// Allocate an array-backed object.
    pub fn createArray(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
        const obj = try arena.create(JsObject);
        obj.* = JsObject{
            .arena = arena,
            .proto = proto,
            .is_array = true,
            .array_length = 0,
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
        if (self.is_array and std.mem.eql(u8, key, "length")) {
            // length is virtual for arrays.
            return null; // will be handled by getLength
        }
        return self.props.get(key);
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
            if (obj.props.get(key)) |v| return v;
            cur = obj.proto;
        }
        return null;
    }

    /// Set own property. Updates array_length if key is an array index.
    pub fn set(self: *JsObject, key: []const u8, value: Value) !void {
        try self.props.put(self.arena, key, value);
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
        return self.props.contains(key);
    }

    /// Get length: for arrays returns cached length as a Value.
    /// Returns null for non-arrays (caller may fall back to own prop "length").
    pub fn getLength(self: *JsObject) ?Value {
        if (!self.is_array) return self.props.get("length");
        // Return a Value wrapping the length number.
        // We can't allocate here without error propagation, so we store a sentinel.
        // Caller uses getArrayLength() for the raw u32.
        return null; // use getArrayLengthValue with arena
    }

    pub fn getArrayLength(self: *JsObject) u32 {
        return self.array_length;
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
