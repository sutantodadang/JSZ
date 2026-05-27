// SPDX-License-Identifier: MIT
//! Phase 3b: Mark-sweep garbage collector for JsObject instances.
//!
//! Design:
//!   - Non-moving collector. Pointers are stable across collect().
//!   - GcHeader is prepended to every GC allocation; objects are linked via
//!     all_objects_head (intrusive singly-linked list).
//!   - Roots: open HandleScope chain + extra_roots array + registered vm callbacks.
//!   - Mark phase: BFS/DFS from roots; marks reachable JsObjects.
//!   - Sweep phase: walks all_objects_head, frees unmarked, resets marks.
//!   - MVP: manual trigger only (Context.gc() / Heap.collect()).
//!     No automatic threshold-based trigger.
//!
//! GC-managed objects: JsObject only.
//! Arena-only (not GC): strings, FuncVal, BcClosure, BcFunction, Environment,
//!   AST nodes, JsValue wrappers. These share Context lifetime.
const std = @import("std");

// Forward-declare to avoid circular imports.
const JsObject = @import("../object/object.zig").JsObject;
const Value = @import("../value/value.zig").Value;
const HandleScope = @import("./handle.zig").HandleScope;

/// Tag identifying the kind of payload following a GcHeader.
/// MVP only uses js_object; others reserved for later phases.
pub const GcObjectKind = enum(u8) {
    js_object,
    environment,
    func_val,
    bc_closure,
};

/// Header prepended to every GC-managed allocation.
/// Layout: [GcHeader][payload bytes]
pub const GcHeader = struct {
    marked: bool = false,
    kind: GcObjectKind,
    /// Total bytes including this header.
    size: usize,
    /// Intrusive singly-linked list of all live allocations.
    next: ?*GcHeader = null,
};

/// Stats returned by a single collect() call.
pub const CollectStats = struct {
    freed_bytes: usize = 0,
    freed_objects: usize = 0,
    duration_ns: u64 = 0,
};

/// Callback type for VMs to register their own root walkers.
/// ctx is the opaque pointer passed at registration time.
pub const ScanCallback = struct {
    ctx: *anyopaque,
    scan: *const fn (ctx: *anyopaque, mark_fn: *const fn (*JsObject) void) void,
};

/// The garbage-collected heap.
pub const Heap = struct {
    backing_allocator: std.mem.Allocator,
    /// Head of the intrusive linked list of all GC allocations.
    all_objects_head: ?*GcHeader = null,
    /// Top of the open HandleScope stack (LIFO).
    handle_scope_top: ?*HandleScope = null,
    /// Additional roots registered externally (Realm intrinsics, etc.).
    /// Each *Value points into caller-owned storage.
    extra_roots: std.ArrayListUnmanaged(*Value) = .empty,
    /// VM root-scan callbacks (tree-walker + bytecode VM register theirs).
    scan_callbacks: std.ArrayListUnmanaged(ScanCallback) = .empty,
    /// Cumulative stats.
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    collections: usize = 0,
    objects_alive: usize = 0,

    pub fn init(backing: std.mem.Allocator) Heap {
        return Heap{
            .backing_allocator = backing,
        };
    }

    pub fn deinit(self: *Heap) void {
        // Free every remaining GC allocation.
        var cur = self.all_objects_head;
        while (cur) |hdr| {
            const next = hdr.next;
            if (hdr.kind == .js_object) {
                const slot: *GcJsObjectSlot = @fieldParentPtr("header", hdr);
                slot.object.props.deinit(self.backing_allocator);
                self.backing_allocator.destroy(slot);
            }
            cur = next;
        }
        self.all_objects_head = null;
        self.extra_roots.deinit(self.backing_allocator);
        self.scan_callbacks.deinit(self.backing_allocator);
    }

    // ------------------------------------------------------------------
    // Allocation
    // ------------------------------------------------------------------

    /// Combined allocation unit: GcHeader + JsObject with proper alignment.
    const GcJsObjectSlot = struct {
        header: GcHeader,
        object: JsObject,
    };

    /// Allocate a new JsObject on the GC heap.
    /// The returned pointer is stable (non-moving collector).
    pub fn allocateObject(self: *Heap, proto: ?*JsObject) !*JsObject {
        const slot = try self.backing_allocator.create(GcJsObjectSlot);
        slot.header = GcHeader{
            .marked = false,
            .kind = .js_object,
            .size = @sizeOf(GcJsObjectSlot),
            .next = self.all_objects_head,
        };
        slot.object = JsObject{
            .arena = self.backing_allocator,
            .proto = proto,
            .is_gc_managed = true,
        };
        self.all_objects_head = &slot.header;

        self.bytes_allocated += @sizeOf(GcJsObjectSlot);
        self.objects_alive += 1;
        return &slot.object;
    }

    /// Allocate an array-backed JsObject on the GC heap.
    pub fn allocateArray(self: *Heap, proto: ?*JsObject) !*JsObject {
        const obj = try self.allocateObject(proto);
        obj.is_array = true;
        obj.array_length = 0;
        return obj;
    }

    // ------------------------------------------------------------------
    // Root management
    // ------------------------------------------------------------------

    /// Register an external root. The *Value must remain valid until
    /// removeRoot is called (caller guarantees lifetime).
    pub fn addRoot(self: *Heap, value_ptr: *Value) !void {
        try self.extra_roots.append(self.backing_allocator, value_ptr);
    }

    /// Unregister an external root (linear scan; call count is small).
    pub fn removeRoot(self: *Heap, value_ptr: *Value) void {
        const items = self.extra_roots.items;
        for (items, 0..) |item, i| {
            if (item == value_ptr) {
                _ = self.extra_roots.swapRemove(i);
                return;
            }
        }
    }

    /// Register a VM root-scan callback.
    pub fn addScanCallback(self: *Heap, cb: ScanCallback) !void {
        try self.scan_callbacks.append(self.backing_allocator, cb);
    }

    /// Unregister a VM root-scan callback.
    pub fn removeScanCallback(self: *Heap, ctx_ptr: *anyopaque) void {
        const items = self.scan_callbacks.items;
        for (items, 0..) |item, i| {
            if (item.ctx == ctx_ptr) {
                _ = self.scan_callbacks.swapRemove(i);
                return;
            }
        }
    }

    // ------------------------------------------------------------------
    // Collection
    // ------------------------------------------------------------------

    /// Retrieve the GcHeader for a JsObject allocated on this heap.
    /// The object MUST have been allocated by allocateObject (via GcJsObjectSlot).
    fn headerOf(obj: *JsObject) *GcHeader {
        const slot: *GcJsObjectSlot = @fieldParentPtr("object", obj);
        return &slot.header;
    }

    /// Mark a JsObject reachable and recursively mark its proto and property values.
    fn markObject(self: *Heap, obj: *JsObject) void {
        // Safety: arena-allocated intrinsics (Object.prototype before activateHeap,
        // error prototypes, etc.) do NOT have a valid GcHeader prefix.
        // Dereferencing headerOf() on such an object reads adjacent memory and,
        // worse, mark-writes can corrupt arena bookkeeping (BufNode chain).
        // Skip them entirely — their lifetime is the eval arena, not the GC.
        if (!obj.is_gc_managed) {
            // Still walk into their property values: those values may reference
            // heap-managed objects that need to be marked.
            var it = obj.props.iterator();
            while (it.next()) |entry| {
                self.markValue(entry.value_ptr.*);
            }
            // And the proto chain (may transition back into GC-managed objects).
            if (obj.proto) |proto| {
                self.markObject(proto);
            }
            return;
        }
        const hdr = headerOf(obj);
        if (hdr.marked) return; // already visited (cycle guard)
        hdr.marked = true;

        // Recursively mark prototype.
        if (obj.proto) |proto| {
            self.markObject(proto);
        }

        // Mark all own property values.
        var it = obj.props.iterator();
        while (it.next()) |entry| {
            self.markValue(entry.value_ptr.*);
        }
    }

    fn markValue(self: *Heap, v: Value) void {
        if (v.bits == 0) return;
        const inner = v.toPtr();
        switch (inner.*) {
            .object => |obj| self.markObject(obj),
            // All other variants are arena-only; nothing to mark.
            else => {},
        }
    }

    /// Mark phase: walk all roots and transitively mark reachable objects.
    fn mark(self: *Heap) void {
        // 1. extra_roots
        for (self.extra_roots.items) |vptr| {
            self.markValue(vptr.*);
        }

        // 2. HandleScope chain
        var scope_opt = self.handle_scope_top;
        while (scope_opt) |scope| {
            for (scope.handles[0..scope.count]) |v| {
                self.markValue(v);
            }
            scope_opt = scope.parent;
        }

        // 3. VM scan callbacks
        for (self.scan_callbacks.items) |cb| {
            const mark_fn = struct {
                fn do_mark(heap: *Heap, obj: *JsObject) void {
                    heap.markObject(obj);
                }
            }.do_mark;
            // Bridge: we need a closure-equivalent here. Use a thread-local pointer hack.
            // Zig 0.15 doesn't support closures; pass heap via the opaque ctx.
            _ = cb;
            _ = mark_fn;
            // Actually call via cb.scan with a stable function pointer.
            // We pass `self` as the ctx indirectly via a wrapper.
        }
        // Re-implement callbacks with heap pointer passed through ctx:
        for (self.scan_callbacks.items) |cb| {
            const Wrapper = struct {
                var heap_ptr: *Heap = undefined;
                fn markObj(obj: *JsObject) void {
                    heap_ptr.markObject(obj);
                }
            };
            Wrapper.heap_ptr = self;
            cb.scan(cb.ctx, Wrapper.markObj);
        }
    }

    /// Sweep phase: free unmarked objects, reset marks on live objects.
    fn sweep(self: *Heap) CollectStats {
        var stats = CollectStats{};
        var prev: ?*GcHeader = null;
        var cur = self.all_objects_head;

        while (cur) |hdr| {
            const next = hdr.next;
            if (!hdr.marked) {
                // Unlink from list.
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.all_objects_head = next;
                }

                const slot_size = hdr.size;
                if (hdr.kind == .js_object) {
                    const slot: *GcJsObjectSlot = @fieldParentPtr("header", hdr);
                    slot.object.props.deinit(self.backing_allocator);
                    self.backing_allocator.destroy(slot);
                }

                stats.freed_bytes += slot_size;
                stats.freed_objects += 1;
                self.bytes_freed += slot_size;
                self.objects_alive -|= 1;
            } else {
                // Live: reset mark for next cycle.
                hdr.marked = false;
                prev = hdr;
            }
            cur = next;
        }
        return stats;
    }

    /// Run a full mark-sweep cycle. Returns stats for this cycle.
    pub fn collect(self: *Heap) CollectStats {
        const start = std.time.nanoTimestamp();
        self.mark();
        var stats = self.sweep();
        const end = std.time.nanoTimestamp();
        stats.duration_ns = @intCast(end - start);
        self.collections += 1;
        return stats;
    }
};

// ---------------------------------------------------------------------- tests ---

test "Heap: allocate and collect unreachable" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Allocate without rooting — should be freed on collect.
    _ = try heap.allocateObject(null);
    try std.testing.expectEqual(@as(usize, 1), heap.objects_alive);

    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 1), stats.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), heap.objects_alive);
}

test "Heap: rooted object survives collect" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const obj = try heap.allocateObject(null);
    const val_mod = @import("../value/value.zig");
    // Need an arena for the JsValue wrapper.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_val = try val_mod.makeObject(arena.allocator(), obj);
    try heap.addRoot(&root_val);

    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
    try std.testing.expectEqual(@as(usize, 1), heap.objects_alive);

    heap.removeRoot(&root_val);
}

test "Heap: proto chain survives if child rooted" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const proto = try heap.allocateObject(null);
    const child = try heap.allocateObject(proto);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");
    var root_val = try val_mod.makeObject(arena.allocator(), child);
    try heap.addRoot(&root_val);

    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
    try std.testing.expectEqual(@as(usize, 2), heap.objects_alive);

    heap.removeRoot(&root_val);
}

test "Heap: collections counter increments" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    _ = heap.collect();
    _ = heap.collect();
    try std.testing.expectEqual(@as(usize, 2), heap.collections);
}
