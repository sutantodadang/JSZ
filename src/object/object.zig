// SPDX-License-Identifier: Apache-2.0
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
const heap_mod = @import("../gc/heap.zig");

/// Maximum prototype chain depth before we give up (cycle guard, Phase 3a).
const MAX_PROTO_DEPTH: usize = 64;

/// Per-property attribute bits (ES5.1 property descriptor flags). Default = all
/// true, matching the behavior of a plain assigned data property.
pub const PropAttr = packed struct(u8) {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    is_accessor: bool = false,
    /// True for a private class element (`#x` field / `#m()` method). Modeled as
    /// a `"#"`-keyed own slot for storage, but hidden from every reflection path
    /// (hasOwnProperty, getOwnPropertyNames, getOwnPropertyDescriptor, for-in,
    /// Object.keys, spread) so it never appears as an ordinary property.
    is_private: bool = false,
    _pad: u3 = 0,
};

/// A symbol-keyed own property (stored separately from string-keyed slots so
/// string enumeration never sees it). `key` is a Value boxing a *SymbolData.
pub const SymProp = struct { key: Value, value: Value, attr: PropAttr = .{} };

pub const JsObject = struct {
    /// Prototype link (null = Object.prototype or bare object).
    proto: ?*JsObject = null,
    /// True if this object is the backing store for an array.
    is_array: bool = false,
    /// True if this object has an [[ErrorData]] internal slot (created by an
    /// Error constructor / subclass super() call). Drives Error.isError.
    is_error: bool = false,
    /// Cached length for array-backed objects.
    array_length: u32 = 0,
    /// Whether new properties can be added (Phase 3a: always true).
    extensible: bool = true,
    /// True when this object was allocated by Heap.allocateObject (has a
    /// valid GcHeader prefix). False for arena-allocated intrinsics.
    /// Used by the GC mark phase to avoid dereferencing a fake header on
    /// arena objects reached via proto walks.
    is_gc_managed: bool = false,
    /// The owning GC Heap (`*heap_mod.Heap`), set by Heap.allocateObject; null
    /// for arena objects. Used by the generational write barrier (gcWrite) to
    /// record old→young edges. Stored as opaque to avoid an import cycle in the
    /// field type (the barrier casts it back).
    gc_heap: ?*anyopaque = null,
    /// Transient GC cycle guard for arena-allocated (non-GC-managed) intrinsics,
    /// which have no GcHeader `marked` bit. Set while the mark phase is walking
    /// this object and cleared after each collection (see Heap.markObject). Guards
    /// against arena↔arena reference cycles, e.g. `String.prototype.constructor`
    /// ↔ `String` (whose `.prototype` points back to `String.prototype`).
    gc_seen: bool = false,
    /// Phase 4c: opaque pointer for internal slots (e.g., CompiledRegex).
    /// Arena-allocated; MUST NOT be traversed by markObject.
    internal_slot: ?*anyopaque = null,
    /// Phase 4c/4d: discriminator for internal_slot type.
    internal_kind: enum(u8) { none, regexp, bound_function, date, map, set, weakmap, weakset, weakref, finalization_registry, promise, generator, async_generator, return_completion, proxy, array_buffer, typed_array, data_view, shared_array_buffer, module_namespace, shadow_realm, wrapped_function, mapped_arguments, map_iterator, set_iterator, array_iterator, iterator_helper } = .none,
    /// Allocator for property storage (the eval arena).
    arena: std.mem.Allocator,
    /// Phase 6 hidden class manager (shared globally).
    shape_manager: *ShapeManager,
    /// Current hidden class for own properties.
    shape: *Shape,
    /// Slot values indexed by shape key_to_slot.
    slots: std.ArrayListUnmanaged(Value) = .empty,
    /// Per-slot attribute bits, parallel to `slots` (same index). Kept in
    /// lockstep with `slots` everywhere slots grow/shrink. Default all-true.
    attrs: std.ArrayListUnmanaged(PropAttr) = .empty,
    /// Symbol-keyed own properties (ES2015). Looked up by symbol pointer identity.
    sym_props: std.ArrayListUnmanaged(SymProp) = .empty,

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

    /// Generational write barrier: call after storing `v` into this object so the
    /// collector records an old→young edge. No-op for arena objects (gc_heap is
    /// null); the barrier itself filters out young owners and non-young values.
    pub inline fn gcWrite(self: *JsObject, v: Value) void {
        if (self.gc_heap) |hp| {
            const heap: *heap_mod.Heap = @ptrCast(@alignCast(hp));
            heap.writeBarrier(self, v);
        }
    }

    /// Write barrier for a `proto` assignment. Call after `self.proto = child`
    /// so an old→young prototype edge is recorded for the next minor GC.
    pub inline fn setProtoBarrier(self: *JsObject, child: ?*JsObject) void {
        if (child) |c| {
            if (self.gc_heap) |hp| {
                const heap: *heap_mod.Heap = @ptrCast(@alignCast(hp));
                heap.writeBarrierObj(self, c);
            }
        }
    }

    /// Get own property (no proto walk). Returns null for accessor slots so
    /// enumeration and the plain `get` path skip them (accessor dispatch happens
    /// in the VM via `findProperty`/`ownAccessorHolder`).
    pub fn getOwn(self: *JsObject, key: []const u8) ?Value {
        if (self.is_array and std.mem.eql(u8, key, "length")) return null;
        if (self.shape.key_to_slot.get(key)) |slot| {
            if (slot < self.attrs.items.len and self.attrs.items[slot].is_accessor) return null;
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

    /// Set own property. Respects non-writable data props (sloppy: silent no-op)
    /// and non-extensibility (cannot add new keys). Keeps `attrs` in lockstep.
    pub fn set(self: *JsObject, key: []const u8, value: Value) !void {
        // Array `length` write (ArraySetLength): adjust the cached length and, on
        // a shrink, delete the now-out-of-range indexed own properties. A `length`
        // assignment never creates an ordinary "length" data slot.
        if (self.is_array and std.mem.eql(u8, key, "length")) {
            const new_len = arrayLengthFromValue(value) orelse return;
            if (new_len < self.array_length) {
                // Delete only the EXISTING indexed own properties >= new_len.
                // Iterating the full [new_len, array_length) numeric range is
                // catastrophic for sparse arrays: `a[4294967294]=v; a.length=2`
                // would spin ~4.29e9 times. Snapshot matching keys first (deleteOwn
                // mutates the shape), then delete — key strings live in the shape
                // arena and stay valid across transitions.
                var to_delete: std.ArrayListUnmanaged([]const u8) = .empty;
                // Frees only the list's backing buffer; the key strings it holds
                // live in the shape arena and outlive this call.
                defer to_delete.deinit(self.arena);
                for (self.shape.key_order.items) |k| {
                    if (k.len > 1 and k[0] == '0') continue; // non-canonical → not an index
                    const kidx = std.fmt.parseUnsigned(u32, k, 10) catch continue;
                    if (kidx == std.math.maxInt(u32)) continue;
                    if (kidx >= new_len) to_delete.append(self.arena, k) catch continue;
                }
                for (to_delete.items) |k| _ = self.deleteOwn(k) catch {};
            }
            self.array_length = new_len;
            return;
        }
        if (self.shape.key_to_slot.get(key)) |slot| {
            if (slot < self.slots.items.len) {
                if (slot < self.attrs.items.len and !self.attrs.items[slot].writable) return;
                self.slots.items[slot] = value;
            }
        } else {
            if (!self.extensible) return;
            self.shape = try self.shape_manager.transitionAdd(self.shape, key);
            const new_slot = self.shape.key_to_slot.get(key) orelse unreachable;
            try self.growSlots(new_slot + 1);
            self.slots.items[new_slot] = value;
            self.attrs.items[new_slot] = .{};
        }
        self.gcWrite(value);
        if (self.is_array) {
            const idx = std.fmt.parseUnsigned(u32, key, 10) catch return;
            // "4294967295" (u32 max) is not a valid array index; `idx + 1` overflows.
            if (idx != std.math.maxInt(u32) and idx >= self.array_length) {
                self.array_length = idx + 1;
            }
        }
    }

    /// ToUint32-style coercion of an array-`length` assignment value. Returns the
    /// clamped length, or null when the value is not a number (the caller leaves
    /// the array unchanged rather than synthesizing an ordinary property).
    fn arrayLengthFromValue(v: Value) ?u32 {
        if (v.bits == 0) return null;
        return switch (v.unbox()) {
            .number => |n| blk: {
                if (std.math.isNan(n) or n <= 0) break :blk 0;
                if (n >= 4294967295.0) break :blk 4294967295;
                break :blk @intFromFloat(@trunc(n));
            },
            .boolean => |b| if (b) 1 else 0,
            else => null,
        };
    }

    /// Grow `slots` and `attrs` together to at least `n` entries, padding with
    /// undefined values and default (all-true) attributes.
    fn growSlots(self: *JsObject, n: usize) !void {
        while (self.slots.items.len < n) try self.slots.append(self.arena, Value{});
        while (self.attrs.items.len < n) try self.attrs.append(self.arena, .{});
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
        self.gcWrite(value);
        return true;
    }

    /// Delete own property and transition shape if key exists. Honors
    /// non-configurable (returns false without deleting). Rebuilds `attrs`
    /// parallel to the new slot order.
    pub fn deleteOwn(self: *JsObject, key: []const u8) !bool {
        // [[Delete]] of an absent own property succeeds (returns true).
        const del_slot = self.shape.key_to_slot.get(key) orelse return true;
        if (del_slot < self.attrs.items.len and !self.attrs.items[del_slot].configurable) return false;
        const old_shape = self.shape;
        self.shape = try self.shape_manager.transitionDelete(old_shape, key);
        var new_slots: std.ArrayListUnmanaged(Value) = .empty;
        var new_attrs: std.ArrayListUnmanaged(PropAttr) = .empty;
        for (self.shape.key_order.items) |k| {
            const old_slot = old_shape.key_to_slot.get(k);
            const v = if (old_slot) |s| (if (s < self.slots.items.len) self.slots.items[s] else Value{}) else Value{};
            const a = if (old_slot) |s| (if (s < self.attrs.items.len) self.attrs.items[s] else PropAttr{}) else PropAttr{};
            try new_slots.append(self.arena, v);
            try new_attrs.append(self.arena, a);
        }
        // Free the old parallel arrays before replacing them (else the prior
        // `slots`/`attrs` backing buffers leak for heap-allocated objects).
        var old_slots = self.slots;
        var old_attrs = self.attrs;
        self.slots = new_slots;
        self.attrs = new_attrs;
        old_slots.deinit(self.arena);
        old_attrs.deinit(self.arena);
        return true;
    }

    /// Spec-ordered own string keys: integer indices ascending, then the rest
    /// in insertion order (ES [[OwnPropertyKeys]]). Cached on the shape.
    pub fn ownKeys(self: *JsObject) []const []const u8 {
        return self.shape.orderedKeys(self.shape_manager.allocator);
    }

    /// True if `key` is an own enumerable property. Missing key → false.
    pub fn isEnumerable(self: *JsObject, key: []const u8) bool {
        const slot = self.shape.key_to_slot.get(key) orelse return false;
        if (slot >= self.attrs.items.len) return true;
        return self.attrs.items[slot].enumerable;
    }

    /// Mark an existing own `key` as a private class element: hidden from
    /// reflection and non-enumerable. No-op if `key` is not an own property.
    pub fn markPrivate(self: *JsObject, key: []const u8) void {
        const slot = self.shape.key_to_slot.get(key) orelse return;
        if (slot >= self.attrs.items.len) return;
        self.attrs.items[slot].is_private = true;
        self.attrs.items[slot].enumerable = false;
    }

    /// True when `key` is an own property flagged as a private class element.
    pub fn isPrivate(self: *JsObject, key: []const u8) bool {
        const slot = self.shape.key_to_slot.get(key) orelse return false;
        if (slot >= self.attrs.items.len) return false;
        return self.attrs.items[slot].is_private;
    }

    /// Own attribute bits for `key`, or null if not an own property.
    pub fn ownAttr(self: *JsObject, key: []const u8) ?PropAttr {
        const slot = self.shape.key_to_slot.get(key) orelse return null;
        if (slot >= self.attrs.items.len) return PropAttr{};
        return self.attrs.items[slot];
    }

    /// Set every own property's [[Enumerable]] to false. Setup helper: core
    /// built-in own properties (methods, constants) are all non-enumerable, but
    /// many are registered via `set()` (which defaults to enumerable). A realm
    /// post-pass calls this over the built-in objects to correct that in bulk.
    /// Only enumerable is touched; writable/configurable are left as-is.
    pub fn markOwnNonEnumerable(self: *JsObject) void {
        for (self.attrs.items) |*a| a.enumerable = false;
        for (self.sym_props.items) |*sp| sp.attr.enumerable = false;
    }

    /// Define or redefine an own DATA property with explicit attributes.
    /// Returns false (caller should throw TypeError) when disallowed by
    /// non-configurability or non-extensibility. Honors lockstep growth.
    pub fn defineOwnData(self: *JsObject, key: []const u8, value: Value, attr: PropAttr) !bool {
        if (self.shape.key_to_slot.get(key)) |slot| {
            const cur = if (slot < self.attrs.items.len) self.attrs.items[slot] else PropAttr{};
            // Converting accessor → data: delete the accessor slot first so a
            // shape transition happens and stale ICs miss.
            if (cur.is_accessor) {
                if (!cur.configurable) return false;
                _ = try self.deleteOwn(key);
                // Fall through to the add-new-key path below.
            } else {
                if (!cur.configurable) {
                    if (attr.configurable) return false;
                    if (attr.enumerable != cur.enumerable) return false;
                    if (!cur.writable) {
                        // Non-writable + non-configurable: a redefine is allowed only
                        // if it changes nothing — cannot become writable, cannot change
                        // the value (ES §10.1.6.3 ValidateAndApplyPropertyDescriptor).
                        if (attr.writable) return false;
                        const cur_v = if (slot < self.slots.items.len) self.slots.items[slot] else Value{};
                        if (!sameValueRough(cur_v, value)) return false;
                    }
                }
                if (slot < self.slots.items.len) self.slots.items[slot] = value;
                if (slot < self.attrs.items.len) self.attrs.items[slot] = attr;
                self.gcWrite(value);
                return true;
            }
        }
        // New key (or just-deleted-accessor) path.
        {
            if (!self.extensible) return false;
            self.shape = try self.shape_manager.transitionAdd(self.shape, key);
            const new_slot = self.shape.key_to_slot.get(key) orelse unreachable;
            try self.growSlots(new_slot + 1);
            self.slots.items[new_slot] = value;
            self.attrs.items[new_slot] = attr;
            self.gcWrite(value);
            if (self.is_array) {
                const idx = std.fmt.parseUnsigned(u32, key, 10) catch return true;
                // Valid array indices are 0..2^32-2; "4294967295" (u32 max) is a
                // normal property, and `idx + 1` there would overflow.
                if (idx != std.math.maxInt(u32) and idx >= self.array_length) self.array_length = idx + 1;
            }
            return true;
        }
    }

    /// Object.preventExtensions: forbid new own properties.
    pub fn preventExtensionsSelf(self: *JsObject) void {
        self.extensible = false;
    }

    /// Object.seal: prevent extensions + mark all own props non-configurable.
    pub fn sealSelf(self: *JsObject) void {
        self.extensible = false;
        for (self.attrs.items) |*a| a.configurable = false;
        for (self.sym_props.items) |*sp| sp.attr.configurable = false;
    }

    /// Object.freeze: seal + mark all own data props non-writable.
    pub fn freezeSelf(self: *JsObject) void {
        self.extensible = false;
        for (self.attrs.items) |*a| {
            a.configurable = false;
            a.writable = false;
        }
        for (self.sym_props.items) |*sp| {
            sp.attr.configurable = false;
            sp.attr.writable = false;
        }
    }

    /// Object.isSealed: non-extensible and every own prop non-configurable.
    pub fn isSealedSelf(self: *JsObject) bool {
        if (self.extensible) return false;
        for (self.attrs.items) |a| {
            if (a.configurable) return false;
        }
        for (self.sym_props.items) |sp| {
            if (sp.attr.configurable) return false;
        }
        return true;
    }

    /// Object.isFrozen: sealed and every own data prop non-writable.
    pub fn isFrozenSelf(self: *JsObject) bool {
        if (self.extensible) return false;
        for (self.attrs.items) |a| {
            if (a.configurable or a.writable) return false;
        }
        for (self.sym_props.items) |sp| {
            if (sp.attr.configurable or sp.attr.writable) return false;
        }
        return true;
    }

    /// Define/redefine an own ACCESSOR property. `holder` is a Value boxing a
    /// JsObject with own "get"/"set". Forces a shape transition so any stale
    /// data inline cache for the previous shape misses. Returns false if
    /// disallowed (non-configurable redefine, or add when non-extensible).
    /// Identity of an accessor holder's `get`/`set` slot (absent / undefined → 0).
    fn holderFnBits(o: *JsObject, k: []const u8) u64 {
        const v = o.getOwn(k) orelse return 0;
        if (v.bits == 0) return 0;
        if (v.unbox() == .undefined_) return 0;
        return v.bits;
    }

    /// SameValue on two accessor holders: identical get and identical set.
    fn accessorHoldersEqual(a: Value, b: Value) bool {
        if (a.bits == b.bits) return true;
        if (!(a.bits != 0 and a.unbox() == .object)) return false;
        if (!(b.bits != 0 and b.unbox() == .object)) return false;
        const ao = a.toPtr().object;
        const bo = b.toPtr().object;
        return holderFnBits(ao, "get") == holderFnBits(bo, "get") and
            holderFnBits(ao, "set") == holderFnBits(bo, "set");
    }

    pub fn defineOwnAccessor(self: *JsObject, key: []const u8, holder: Value, attr_in: PropAttr) !bool {
        var attr = attr_in;
        attr.is_accessor = true;
        if (self.shape.key_to_slot.get(key)) |slot| {
            const cur = if (slot < self.attrs.items.len) self.attrs.items[slot] else PropAttr{};
            if (!cur.configurable) {
                // Non-configurable: a redefine is rejected unless it makes no
                // observable change — same accessor with identical get/set and
                // unchanged enumerable (ValidateAndApplyPropertyDescriptor).
                if (!cur.is_accessor or cur.enumerable != attr.enumerable) return false;
                const cur_holder = if (slot < self.slots.items.len) self.slots.items[slot] else Value{};
                if (!accessorHoldersEqual(cur_holder, holder)) return false;
                return true;
            }
            // Configurable redefine: update the EXISTING slot in place. Deleting
            // and re-adding would move the key to the end of the creation order,
            // but [[DefineOwnProperty]] must not reorder (Object.keys/values order).
            if (slot < self.slots.items.len) self.slots.items[slot] = holder;
            if (slot < self.attrs.items.len) self.attrs.items[slot] = attr;
            self.gcWrite(holder);
            return true;
        } else {
            if (!self.extensible) return false;
        }
        self.shape = try self.shape_manager.transitionAdd(self.shape, key);
        const new_slot = self.shape.key_to_slot.get(key) orelse unreachable;
        try self.growSlots(new_slot + 1);
        self.slots.items[new_slot] = holder;
        self.attrs.items[new_slot] = attr;
        self.gcWrite(holder);
        // Array exotic [[DefineOwnProperty]]: defining an own property at an array
        // index >= length extends the array's length (matches defineOwnData).
        if (self.is_array) {
            const idx = std.fmt.parseUnsigned(u32, key, 10) catch return true;
            if (idx != std.math.maxInt(u32) and idx >= self.array_length) self.array_length = idx + 1;
        }
        return true;
    }

    /// If own `key` is an accessor, return the holder Value (boxing get/set).
    pub fn ownAccessorHolder(self: *JsObject, key: []const u8) ?Value {
        const slot = self.shape.key_to_slot.get(key) orelse return null;
        if (slot >= self.attrs.items.len or !self.attrs.items[slot].is_accessor) return null;
        if (slot >= self.slots.items.len) return null;
        return self.slots.items[slot];
    }

    /// Attribute bits at a resolved own slot.
    pub fn attrAt(self: *JsObject, slot: u32) PropAttr {
        if (slot >= self.attrs.items.len) return PropAttr{};
        return self.attrs.items[slot];
    }

    /// Locate a property along the prototype chain (own first). Returns the
    /// holder object that owns `key` and the slot index, or null.
    pub fn findProperty(self: *JsObject, key: []const u8) ?struct { holder: *JsObject, slot: u32 } {
        var depth: usize = 0;
        var cur: ?*JsObject = self;
        while (cur) |o| {
            if (depth >= MAX_PROTO_DEPTH) break;
            depth += 1;
            if (o.shape.key_to_slot.get(key)) |slot| return .{ .holder = o, .slot = slot };
            cur = o.proto;
        }
        return null;
    }

    /// Own symbol-keyed property by symbol identity (no proto walk).
    pub fn getOwnSym(self: *JsObject, sym_key: Value) ?Value {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return null;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) return sp.value;
        }
        return null;
    }

    pub fn getOwnSymEntry(self: *JsObject, sym_key: Value) ?SymProp {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return null;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) return sp;
        }
        return null;
    }

    pub fn hasOwnSym(self: *JsObject, sym_key: Value) bool {
        return self.getOwnSym(sym_key) != null;
    }

    /// Get symbol-keyed property with prototype chain walk.
    pub fn getSym(self: *JsObject, sym_key: Value) ?Value {
        var depth: usize = 0;
        var cur: ?*JsObject = self;
        while (cur) |obj| {
            if (depth >= MAX_PROTO_DEPTH) break;
            depth += 1;
            if (obj.getOwnSym(sym_key)) |v| return v;
            cur = obj.proto;
        }
        return null;
    }

    /// Set/upsert an own symbol-keyed property. Honors writable / extensible.
    pub fn setSym(self: *JsObject, sym_key: Value, value: Value) !void {
        return self.setSymAttr(sym_key, value, .{});
    }

    pub fn setSymAttr(self: *JsObject, sym_key: Value, value: Value, attr: PropAttr) !void {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |*sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) {
                if (!sp.attr.writable) return;
                sp.value = value;
                sp.attr = attr;
                self.gcWrite(value);
                return;
            }
        }
        if (!self.extensible) return;
        try self.sym_props.append(self.arena, .{ .key = sym_key, .value = value, .attr = attr });
        self.gcWrite(value);
    }

    /// Delete own symbol-keyed property; honors configurable. Returns true if removed.
    pub fn deleteOwnSym(self: *JsObject, sym_key: Value) bool {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return false;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items, 0..) |sp, i| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) {
                if (!sp.attr.configurable) return false;
                _ = self.sym_props.orderedRemove(i);
                return true;
            }
        }
        // Absent own symbol property → [[Delete]] succeeds.
        return true;
    }

    /// All own symbol-keyed properties (for Object.getOwnPropertySymbols).
    pub fn symKeys(self: *JsObject) []const SymProp {
        return self.sym_props.items;
    }

    /// [[DefineOwnProperty]] for a symbol-keyed DATA property. Returns false when
    /// an existing non-configurable property forbids the change (incompatible
    /// redefine) or the object is non-extensible and the key is absent.
    pub fn defineOwnDataSym(self: *JsObject, sym_key: Value, value: Value, attr: PropAttr) !bool {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return false;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |*sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) {
                if (!sp.attr.configurable) {
                    // Non-configurable: only a compatible no-op redefine is allowed.
                    if (attr.configurable) return false;
                    if (attr.enumerable != sp.attr.enumerable) return false;
                    if (sp.attr.is_accessor) return false; // accessor → data
                    if (!sp.attr.writable) {
                        if (attr.writable) return false;
                        if (!sameValueRough(value, sp.value)) return false;
                    }
                }
                sp.value = value;
                sp.attr = attr;
                sp.attr.is_accessor = false;
                self.gcWrite(value);
                return true;
            }
        }
        if (!self.extensible) return false;
        var a = attr;
        a.is_accessor = false;
        try self.sym_props.append(self.arena, .{ .key = sym_key, .value = value, .attr = a });
        self.gcWrite(value);
        return true;
    }

    /// [[DefineOwnProperty]] for a symbol-keyed ACCESSOR property. `holder` is an
    /// object carrying `get`/`set` (same shape the VM reads via getPropSym).
    /// Existing accessor holder for a symbol key, or null. Mirrors
    /// `ownAccessorHolder` for the symbol-keyed property table.
    pub fn ownAccessorHolderSym(self: *JsObject, sym_key: Value) ?Value {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return null;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) {
                if (!sp.attr.is_accessor) return null;
                return sp.value;
            }
        }
        return null;
    }

    pub fn defineOwnAccessorSym(self: *JsObject, sym_key: Value, holder: Value, attr: PropAttr) !bool {
        if (sym_key.bits == 0 or sym_key.unbox() != .symbol) return false;
        const target = sym_key.toPtr().symbol;
        for (self.sym_props.items) |*sp| {
            if (sp.key.bits != 0 and sp.key.unbox() == .symbol and sp.key.toPtr().symbol == target) {
                if (!sp.attr.configurable) {
                    if (attr.configurable) return false;
                    if (attr.enumerable != sp.attr.enumerable) return false;
                    if (!sp.attr.is_accessor) return false; // data → accessor
                    return false; // can't change a non-configurable accessor's handlers
                }
                sp.value = holder;
                sp.attr = attr;
                sp.attr.is_accessor = true;
                self.gcWrite(holder);
                return true;
            }
        }
        if (!self.extensible) return false;
        var a = attr;
        a.is_accessor = true;
        try self.sym_props.append(self.arena, .{ .key = sym_key, .value = holder, .attr = a });
        self.gcWrite(holder);
        return true;
    }
};

/// Loose SameValue for redefine compatibility checks: pointer-identity, or
/// numeric equality (pointer-boxed numbers may differ in bits while equal).
fn sameValueRough(a: Value, b: Value) bool {
    if (a.bits == b.bits) return true;
    if (a.bits == 0 or b.bits == 0) return false;
    const ua = a.unbox();
    const ub = b.unbox();
    if (ua == .number and ub == .number) return ua.number == ub.number;
    if (ua == .string and ub == .string) return std.mem.eql(u8, ua.string, ub.string);
    return false;
}

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
