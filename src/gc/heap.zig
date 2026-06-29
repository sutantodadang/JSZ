// SPDX-License-Identifier: Apache-2.0
//! Generational mark-sweep garbage collector for JsObject instances (M19).
//!
//! Design:
//!   - Non-moving collector. Pointers are stable across collections (promotion
//!     only flips a generation flag and relinks the intrusive header).
//!   - GcHeader is prepended to every GC allocation. Allocations are linked into
//!     one of two intrusive lists by generation: `young_head` / `old_head`.
//!   - Roots: open HandleScope chain + extra_roots array + registered vm callbacks.
//!   - Marking is iterative (an explicit gray worklist), so a deep/long object
//!     graph cannot overflow the native stack.
//!   - Minor GC (collectMinor): traces from roots + the whole old generation
//!     (scanned as roots), sweeps only the young list, and promotes survivors to
//!     old. Sound without a write barrier — no old→young edge can be missed.
//!   - Major GC (collect): full mark-sweep over both generations; survivors are
//!     tenured to old.
//!   - Automatic trigger: allocation past a growing byte watermark runs a minor
//!     GC (a major every `major_period` minors). Suppressed until a VM root
//!     scanner is installed and disablable via `gc_enabled` / `JSZ_GC_OFF`.
//!
//! GC-managed objects: JsObject only.
//! Arena-only (not GC): strings, FuncVal, BcClosure, BcFunction, Environment,
//!   AST nodes, JsValue wrappers. These share Context lifetime.
const std = @import("std");

// Forward-declare to avoid circular imports.
const JsObject = @import("../object/object.zig").JsObject;
const Value = @import("../value/value.zig").Value;
const HandleScope = @import("./handle.zig").HandleScope;
const shape_mod = @import("../value/shape.zig");

/// Tag identifying the kind of payload following a GcHeader.
/// MVP only uses js_object; others reserved for later phases.
pub const GcObjectKind = enum(u8) {
    js_object,
    environment,
    func_val,
    bc_closure,
};

/// Generation of a GC allocation (M19 generational collector).
/// `young` = nursery (freshly allocated); `old` = tenured (survived a GC).
/// Non-moving: promotion only flips this flag and relinks the header — the
/// object's address is stable across collections.
pub const Generation = enum(u8) { young, old };

/// Header prepended to every GC-managed allocation.
/// Layout: [GcHeader][payload bytes]
pub const GcHeader = struct {
    marked: bool = false,
    /// Generation this allocation currently belongs to.
    gen: Generation = .young,
    /// True while this (old-generation) object is in the remembered set — it has
    /// been written with a reference to a young object since the last collection.
    /// A dedup flag so a hot field never appends the same object twice.
    in_remembered: bool = false,
    /// True once this object has been registered in the heap's tracked-collection
    /// list (weak/Map/Set). Dedups repeat registrations from multiple call sites.
    tracked: bool = false,
    kind: GcObjectKind,
    /// Total bytes including this header.
    size: usize,
    /// Intrusive singly-linked list of all live allocations in this generation.
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
    /// Intrusive list of nursery (young-generation) allocations. New objects are
    /// prepended here; survivors of a collection are promoted to `old_head`.
    young_head: ?*GcHeader = null,
    /// Intrusive list of tenured (old-generation) allocations.
    old_head: ?*GcHeader = null,
    /// Top of the open HandleScope stack (LIFO).
    handle_scope_top: ?*HandleScope = null,
    /// Additional roots registered externally (Realm intrinsics, etc.).
    /// Each *Value points into caller-owned storage.
    extra_roots: std.ArrayListUnmanaged(*Value) = .empty,
    /// VM root-scan callbacks (tree-walker + bytecode VM register theirs).
    scan_callbacks: std.ArrayListUnmanaged(ScanCallback) = .empty,
    /// Arena intrinsics visited during the current mark phase (their `gc_seen`
    /// flag is set). Cleared after each collection. See markObject.
    arena_seen: std.ArrayListUnmanaged(*JsObject) = .empty,
    /// Explicit mark worklist (gray set). Marking is iterative, not recursive,
    /// so a deep/long object graph cannot overflow the native stack. Retained
    /// across collections so its capacity is reused. See mark().
    mark_worklist: std.ArrayListUnmanaged(*JsObject) = .empty,
    /// All weak containers (WeakMap/WeakSet/WeakRef/FinalizationRegistry) ever
    /// created and not yet collected. The runtime registers each at construction
    /// via noteWeakContainer; dead ones are compacted out during processWeak.
    /// Persistent (not per-cycle) because their weak entries live in arena structs
    /// the collector cannot reach by tracing, so a minor GC — which scans only the
    /// remembered set, not the whole old generation — would otherwise never see an
    /// old weak container.
    weak_containers: std.ArrayListUnmanaged(*JsObject) = .empty,
    /// Remembered set: old-generation objects written with a young reference since
    /// the last collection. A minor GC scans these (instead of the entire old
    /// generation) to find old→young edges. Maintained by the write barrier.
    remembered: std.ArrayListUnmanaged(*JsObject) = .empty,
    /// Set when the write barrier could not record an old→young edge (OOM). Forces
    /// the next collection to be a full major so the edge is not missed.
    force_major: bool = false,
    /// Optional hook invoked after marking to trace the STRONG internal contents
    /// of a marked collection object (e.g. Map/Set keys+values held in an
    /// arena-side data struct the GC cannot see directly). Set by the runtime.
    strong_trace_fn: ?*const fn (*Heap, *JsObject) void = null,
    /// Optional hook invoked after marking (before sweep) to run ephemeron
    /// marking and purge dead entries from the weak containers in `weak_seen`.
    /// Set by the runtime.
    weak_process_fn: ?*const fn (*Heap) void = null,
    /// Cumulative stats.
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    collections: usize = 0,
    objects_alive: usize = 0,

    // ---- Automatic collection policy (M19) -------------------------------
    /// When false, allocation never triggers a collection (manual `__gc__()`
    /// only). The collector machinery is unchanged; only the auto-trigger is off.
    gc_enabled: bool = true,
    /// Fixed nursery size: auto-collect once this many bytes have been allocated
    /// young since the last collection. A FIXED (non-growing) nursery is what
    /// keeps minor collections cheap and roughly constant-cost — the key to the
    /// generational throughput win.
    nursery_bytes: usize = 2 * 1024 * 1024,
    /// Bytes allocated into the young generation since the last collection.
    young_alloc_bytes: usize = 0,
    /// Count of collections triggered automatically by allocation pressure.
    auto_collections: usize = 0,

    // ---- Generational policy (M19) ---------------------------------------
    /// True while a minor (nursery-only) collection is in progress. Marking
    /// consults this to skip tracing the old generation: old objects are assumed
    /// live and their young referents are found by scanning the old list as roots.
    minor_mode: bool = false,
    /// Minor collections performed since the last major (full) collection.
    minors_since_major: usize = 0,
    /// After this many consecutive minors, the next auto-collection is a full
    /// major GC so floating garbage in the old generation is eventually reclaimed.
    major_period: usize = 8,
    /// Count of minor and major collections.
    minor_collections: usize = 0,
    major_collections: usize = 0,
    /// When set, each collection appends its pause (duration_ns) here so a
    /// benchmark can compute pause percentiles. Off by default (no overhead).
    pause_log_enabled: bool = false,
    pause_log: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(backing: std.mem.Allocator) Heap {
        return Heap{
            .backing_allocator = backing,
        };
    }

    pub fn deinit(self: *Heap) void {
        // Free every remaining GC allocation in both generations.
        self.freeList(self.young_head);
        self.freeList(self.old_head);
        self.young_head = null;
        self.old_head = null;
        self.extra_roots.deinit(self.backing_allocator);
        self.scan_callbacks.deinit(self.backing_allocator);
        self.arena_seen.deinit(self.backing_allocator);
        self.mark_worklist.deinit(self.backing_allocator);
        self.weak_containers.deinit(self.backing_allocator);
        self.remembered.deinit(self.backing_allocator);
        self.pause_log.deinit(self.backing_allocator);
    }

    /// Record a collection pause when logging is enabled (benchmark support).
    fn recordPause(self: *Heap, ns: u64) void {
        if (self.pause_log_enabled) self.pause_log.append(self.backing_allocator, ns) catch {};
    }

    // ------------------------------------------------------------------
    // Allocation
    // ------------------------------------------------------------------

    /// Combined allocation unit: GcHeader + JsObject with proper alignment.
    const GcJsObjectSlot = struct {
        header: GcHeader,
        object: JsObject,
    };

    /// Trigger an automatic collection once a nursery's worth of bytes has been
    /// allocated since the last collection.
    ///
    /// SAFETY: only collects while a VM root-scan callback is installed (i.e.
    /// during an active run), so the complete live root set — VM frames, env
    /// chains incl. globals, handle scopes, suspended generators — is reachable.
    /// During bootstrap (no scanner) auto-GC is suppressed; that allocation set
    /// is bounded and is collected on the first run instead. Called at the TOP of
    /// allocateObject so the object about to be created is never at risk.
    fn maybeCollect(self: *Heap) void {
        if (!self.gc_enabled) return;
        if (self.scan_callbacks.items.len == 0) return;
        if (self.young_alloc_bytes < self.nursery_bytes) return;
        // Mostly minor (cheap, nursery-only); promote to a full major GC every
        // `major_period` minors so old-generation floating garbage is reclaimed,
        // or immediately if the write barrier had to give up on an edge.
        if (self.force_major or self.minors_since_major >= self.major_period) {
            _ = self.collect();
        } else {
            _ = self.collectMinor();
        }
        self.auto_collections += 1;
        self.young_alloc_bytes = 0;
    }

    /// Allocate a new JsObject on the GC heap.
    /// The returned pointer is stable (non-moving collector).
    pub fn allocateObject(self: *Heap, proto: ?*JsObject) !*JsObject {
        self.maybeCollect();
        const slot = try self.backing_allocator.create(GcJsObjectSlot);
        slot.header = GcHeader{
            .marked = false,
            .gen = .young,
            .kind = .js_object,
            .size = @sizeOf(GcJsObjectSlot),
            .next = self.young_head,
        };
        slot.object = JsObject{
            .arena = self.backing_allocator,
            .proto = proto,
            .is_gc_managed = true,
            .gc_heap = self,
            .shape_manager = shape_mod.globalManager(),
            .shape = shape_mod.globalManager().root(),
        };
        self.young_head = &slot.header;

        self.bytes_allocated += @sizeOf(GcJsObjectSlot);
        self.young_alloc_bytes += @sizeOf(GcJsObjectSlot);
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

    /// Free the backing storage for a single GC allocation and its header.
    fn destroyHeader(self: *Heap, hdr: *GcHeader) void {
        if (hdr.kind == .js_object) {
            const slot: *GcJsObjectSlot = @fieldParentPtr("header", hdr);
            slot.object.slots.deinit(self.backing_allocator);
            slot.object.attrs.deinit(self.backing_allocator);
            slot.object.sym_props.deinit(self.backing_allocator);
            self.backing_allocator.destroy(slot);
        }
    }

    /// Free an entire intrusive list of allocations (used by deinit).
    fn freeList(self: *Heap, head: ?*GcHeader) void {
        var cur = head;
        while (cur) |hdr| {
            const next = hdr.next;
            self.destroyHeader(hdr);
            cur = next;
        }
    }

    /// Shade a JsObject gray: mark it reachable and enqueue it on the worklist
    /// so its outgoing references are scanned later. Iterative — never recurses
    /// into the object graph, so a deep/long chain cannot overflow the stack.
    ///
    /// Safety: arena-allocated intrinsics (Object.prototype before activateHeap,
    /// error prototypes, etc.) do NOT have a valid GcHeader prefix. Dereferencing
    /// headerOf() on such an object reads adjacent memory and, worse, mark-writes
    /// can corrupt arena bookkeeping. They are tracked by the transient `gc_seen`
    /// flag instead (cleared after each collection via `arena_seen`).
    fn markObject(self: *Heap, obj: *JsObject) void {
        if (!obj.is_gc_managed) {
            if (obj.gc_seen) return; // already gray/black (cycle guard)
            obj.gc_seen = true;
            self.arena_seen.append(self.backing_allocator, obj) catch {};
        } else {
            const hdr = headerOf(obj);
            // Minor GC: the old generation is assumed live and is NOT marked or
            // traced here. Old→young edges are recovered separately by scanning
            // the whole old list as roots (see collectMinor), so a young object
            // referenced only from an old object is still kept alive.
            if (self.minor_mode and hdr.gen == .old) return;
            if (hdr.marked) return; // already gray/black (cycle guard)
            hdr.marked = true;
        }
        // Newly shaded: enqueue for child scanning. On OOM, scan inline as a
        // best-effort fallback (matches the existing arena_seen error policy).
        self.mark_worklist.append(self.backing_allocator, obj) catch self.scanChildren(obj);
    }

    // ---- Write barrier + weak registration (M19) -------------------------

    /// Generational write barrier. Called by JsObject mutators after storing
    /// `written` into `owner` (a GC-managed object). If `owner` is in the old
    /// generation and `written` points at a young object, `owner` joins the
    /// remembered set so the next minor GC scans it for that old→young edge.
    pub fn writeBarrier(self: *Heap, owner: *JsObject, written: Value) void {
        const oh = headerOf(owner);
        if (oh.gen != .old or oh.in_remembered) return;
        if (!written.isHeapPtr()) return;
        const child = switch (written.toPtr().*) {
            .object => |o| o,
            else => return,
        };
        if (!child.is_gc_managed) return;
        if (headerOf(child).gen != .young) return;
        oh.in_remembered = true;
        self.remembered.append(self.backing_allocator, owner) catch {
            // Cannot record the edge → force the next collection to be a major
            // (which traces the whole old generation and cannot miss it).
            oh.in_remembered = false;
            self.force_major = true;
        };
    }

    /// Write barrier for a raw object reference (e.g. a `proto` assignment).
    /// Records an old→young edge the same way as writeBarrier.
    pub fn writeBarrierObj(self: *Heap, owner: *JsObject, child: *JsObject) void {
        const oh = headerOf(owner);
        if (oh.gen != .old or oh.in_remembered) return;
        if (!child.is_gc_managed) return;
        if (headerOf(child).gen != .young) return;
        oh.in_remembered = true;
        self.remembered.append(self.backing_allocator, owner) catch {
            oh.in_remembered = false;
            self.force_major = true;
        };
    }

    /// Register a tracked collection (Map/Set/WeakMap/WeakSet/WeakRef/
    /// FinalizationRegistry) at construction so collections can trace its strong
    /// contents and process its weak entries even after it tenures (an old
    /// collection is never visited by the remembered-set-driven minor walk).
    /// Idempotent for GC-managed objects via the header `tracked` flag.
    pub fn noteWeakContainer(self: *Heap, obj: *JsObject) void {
        if (obj.is_gc_managed) {
            const h = headerOf(obj);
            if (h.tracked) return;
            h.tracked = true;
        }
        self.weak_containers.append(self.backing_allocator, obj) catch {
            // On OOM, force majors so weak processing still iterates the heap via
            // the (compacted) container list on the next full collection.
            if (obj.is_gc_managed) headerOf(obj).tracked = false;
            self.force_major = true;
        };
    }

    /// Scan a gray object's outgoing references, shading each referent gray.
    fn scanChildren(self: *Heap, obj: *JsObject) void {
        if (obj.proto) |proto| self.markObject(proto);
        for (obj.slots.items) |v| self.markValue(v);
        for (obj.sym_props.items) |sp| {
            self.markValue(sp.key);
            self.markValue(sp.value);
        }
        // Strong internal contents (e.g. Map/Set keys+values) the GC cannot see
        // by walking slots — the runtime traces them via this hook.
        if (obj.internal_kind != .none) {
            if (self.strong_trace_fn) |f| f(self, obj);
        }
    }

    fn markValue(self: *Heap, v: Value) void {
        if (!v.isHeapPtr()) return;
        const inner = v.toPtr();
        switch (inner.*) {
            .object => |obj| self.markObject(obj),
            // A bc function may carry a heap-allocated backing object (own props +
            // lazily-created `prototype`). It is reachable through this Value, so a
            // closure stored as an object property must keep its backing alive —
            // otherwise GC frees it and a later `.prototype`/property access reads a
            // dangling pointer. (Mirrors gc.traceValue for the root-scan path.)
            .bc_function => |c| {
                if (c.obj) |o| self.markObject(@ptrCast(@alignCast(o)));
            },
            // Other variants are arena-only; nothing to mark.
            else => {},
        }
    }

    // ---- Weak-reference support (M19, used by the runtime's weak-process hook) -

    /// Whether a GC-managed object is currently considered live (survives the
    /// in-progress collection). Arena objects are never collected → always live;
    /// in a minor GC the whole old generation is assumed live.
    pub fn isLive(self: *const Heap, obj: *JsObject) bool {
        if (!obj.is_gc_managed) return true;
        const hdr = headerOf(obj);
        if (self.minor_mode and hdr.gen == .old) return true;
        return hdr.marked;
    }

    /// Whether the object a Value points at is live. Non-object / primitive
    /// values are not GC-collectable, so they count as live.
    pub fn isValueLive(self: *const Heap, v: Value) bool {
        if (v.bits == 0) return true;
        if (!v.isHeapPtr()) return true;
        const inner = v.toPtr();
        return switch (inner.*) {
            .object => |obj| self.isLive(obj),
            else => true,
        };
    }

    /// Shade a Value's object gray (used by ephemeron marking). Callers drain
    /// afterwards via drainWeak().
    pub fn markValueLive(self: *Heap, v: Value) void {
        self.markValue(v);
    }

    /// Drain the gray worklist to fixpoint (public entry for the weak-process
    /// hook after it shades ephemeron values gray).
    pub fn drainWeak(self: *Heap) void {
        self.drainWorklist();
    }

    /// All registered weak containers (some may be dead this cycle; the weak-
    /// process hook skips non-live ones via isLive, and processWeak compacts them).
    pub fn weakList(self: *Heap) []*JsObject {
        return self.weak_containers.items;
    }

    /// Drain the gray worklist to fixpoint: pop each gray object and scan its
    /// children, which may shade more objects gray, until empty (all black).
    fn drainWorklist(self: *Heap) void {
        while (self.mark_worklist.pop()) |obj| {
            self.scanChildren(obj);
        }
    }

    /// Shade every root gray (does NOT drain — callers add extra roots, e.g. the
    /// old generation in a minor GC, then drain once).
    fn markRoots(self: *Heap) void {
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

        // 3. VM scan callbacks. Zig 0.15 has no closures, so the heap pointer is
        // smuggled through a per-call wrapper; the callback shades roots gray.
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

    /// Full mark phase: shade all roots gray, then drain to fixpoint.
    fn mark(self: *Heap) void {
        self.markRoots();
        self.drainWorklist();
    }

    /// Retrieve the JsObject embedded after a header (kind must be .js_object).
    fn objectOf(hdr: *GcHeader) *JsObject {
        const slot: *GcJsObjectSlot = @fieldParentPtr("header", hdr);
        return &slot.object;
    }

    /// Sweep a detached intrusive list: free unmarked allocations, and promote
    /// every survivor into the old generation (resetting its mark). The source
    /// list is consumed; survivors are relinked onto `old_head`.
    fn sweepInto(self: *Heap, src: ?*GcHeader, stats: *CollectStats) void {
        var cur = src;
        while (cur) |hdr| {
            const next = hdr.next;
            if (!hdr.marked) {
                const sz = hdr.size;
                self.destroyHeader(hdr);
                stats.freed_bytes += sz;
                stats.freed_objects += 1;
                self.bytes_freed += sz;
                self.objects_alive -|= 1;
            } else {
                hdr.marked = false;
                hdr.gen = .old; // tenure / promote survivor
                hdr.next = self.old_head;
                self.old_head = hdr;
            }
            cur = next;
        }
    }

    /// Clear the transient arena cycle-guard flags set during a mark phase.
    fn clearArenaSeen(self: *Heap) void {
        for (self.arena_seen.items) |obj| obj.gc_seen = false;
        self.arena_seen.clearRetainingCapacity();
    }

    /// Run the runtime's ephemeron / weak-clearing hook, then compact the weak
    /// container list (drop containers that did not survive). Must run after the
    /// mark drain and before sweep (so dead entries are purged, and dead
    /// containers are dropped, before their memory is freed).
    fn processWeak(self: *Heap) void {
        if (self.weak_process_fn) |f| f(self);
        // Compact: keep only live containers (dead ones are about to be swept).
        const items = self.weak_containers.items;
        var w: usize = 0;
        for (items) |obj| {
            if (self.isLive(obj)) {
                items[w] = obj;
                w += 1;
            }
        }
        self.weak_containers.shrinkRetainingCapacity(w);
    }

    /// Clear the remembered set, resetting each old object's dedup flag.
    fn clearRemembered(self: *Heap) void {
        for (self.remembered.items) |obj| headerOf(obj).in_remembered = false;
        self.remembered.clearRetainingCapacity();
    }

    /// Strong-trace the internal contents of every live tracked collection, then
    /// drain. Needed in a minor GC because an old Map/Set is never visited by the
    /// remembered-set-driven walk, yet must keep its (possibly young) entries
    /// alive. Idempotent for collections already traced during the main drain.
    fn traceLiveCollections(self: *Heap) void {
        const f = self.strong_trace_fn orelse return;
        for (self.weak_containers.items) |c| {
            if (self.isLive(c)) f(self, c);
        }
        self.drainWorklist();
    }

    /// Run a minor (nursery-only) collection: trace from roots + the remembered
    /// set (old objects holding young references) + live weak containers, then
    /// sweep the young list, promoting survivors to old.
    ///
    /// Only remembered old objects are scanned (not the whole old generation) —
    /// the write barrier guarantees every old→young edge is represented there, so
    /// no live young object can be missed.
    pub fn collectMinor(self: *Heap) CollectStats {
        const start = std.time.nanoTimestamp();
        var stats = CollectStats{};

        self.minor_mode = true;
        self.markRoots();
        // Remembered set: shade the young referents of mutated old objects.
        for (self.remembered.items) |old_obj| self.scanChildren(old_obj);
        self.drainWorklist();
        // Collections (Map/Set + weak kinds) hold entries in arena-side structs
        // the graph walk cannot reach, and an OLD collection in a minor is never
        // scanned by the walk. Strong-trace every LIVE collection's contents so
        // Map/Set entries stay alive; weak kinds are handled by processWeak.
        self.traceLiveCollections();
        self.processWeak();
        self.clearArenaSeen();

        const young = self.young_head;
        self.young_head = null;
        self.sweepInto(young, &stats);
        // All survivors are now old; old→young edges recorded this cycle are stale.
        self.clearRemembered();
        self.minor_mode = false;

        const end = std.time.nanoTimestamp();
        stats.duration_ns = @intCast(end - start);
        self.recordPause(stats.duration_ns);
        self.collections += 1;
        self.minor_collections += 1;
        self.minors_since_major += 1;
        return stats;
    }

    /// Run a full (major) mark-sweep over both generations. Survivors are
    /// tenured into the old generation.
    pub fn collect(self: *Heap) CollectStats {
        const start = std.time.nanoTimestamp();
        var stats = CollectStats{};

        self.minor_mode = false;
        self.mark();
        // A full mark scans every reachable object, so reachable Map/Set are
        // strong-traced via scanChildren during the drain; processWeak then runs
        // ephemeron marking + purges dead weak entries.
        self.processWeak();
        self.clearArenaSeen();

        const young = self.young_head;
        const old = self.old_head;
        self.young_head = null;
        self.old_head = null;
        self.sweepInto(young, &stats);
        self.sweepInto(old, &stats);
        // Survivors are all old now; the remembered set (old→young) is stale.
        self.clearRemembered();
        self.force_major = false;

        const end = std.time.nanoTimestamp();
        stats.duration_ns = @intCast(end - start);
        self.recordPause(stats.duration_ns);
        self.collections += 1;
        self.major_collections += 1;
        self.minors_since_major = 0;
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

test "Heap: automatic collection fires under allocation pressure" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // A scan callback that marks nothing: every allocated object is unreachable,
    // so each auto-collect should reclaim the prior batch. Its mere presence is
    // the safety signal maybeCollect() requires (a VM root scanner is installed).
    const noop = struct {
        fn scan(_: *anyopaque, _: *const fn (*JsObject) void) void {}
    };
    var dummy: u8 = 0;
    try heap.addScanCallback(.{ .ctx = @ptrCast(&dummy), .scan = noop.scan });

    // Tiny watermark so a handful of allocations crosses it.
    const slot_bytes = @sizeOf(Heap.GcJsObjectSlot);
    heap.nursery_bytes = slot_bytes * 8;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try heap.allocateObject(null);
    }

    // Auto-collections happened and the unreachable working set stayed bounded
    // (it never grew to 1000 live objects).
    try std.testing.expect(heap.auto_collections > 0);
    try std.testing.expect(heap.objects_alive < 64);

    heap.removeScanCallback(@ptrCast(&dummy));
}

test "Heap: auto-collect suppressed without a root scanner" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    // No scan callback installed → maybeCollect must never run (bootstrap safety),
    // even with a zero watermark.
    heap.nursery_bytes = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = try heap.allocateObject(null);
    try std.testing.expectEqual(@as(usize, 0), heap.auto_collections);
    try std.testing.expectEqual(@as(usize, 100), heap.objects_alive);
}

test "Heap: minor GC keeps young referenced from old; promotes survivors" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");

    const old = try heap.allocateObject(null);
    var old_root = try val_mod.makeObject(arena.allocator(), old);
    try heap.addRoot(&old_root);

    // Major GC tenures `old` into the old generation.
    _ = heap.collect();
    try std.testing.expectEqual(Generation.old, Heap.headerOf(old).gen);
    try std.testing.expectEqual(@as(usize, 1), heap.objects_alive);

    // `y` is reachable ONLY through the old object's "y" property — exactly the
    // old→young edge the full old-generation scan must recover during a minor GC.
    const y = try heap.allocateObject(null);
    try old.set("y", try val_mod.makeObject(arena.allocator(), y));
    // A second young object referenced by nobody.
    _ = try heap.allocateObject(null);
    try std.testing.expectEqual(@as(usize, 3), heap.objects_alive);

    const s = heap.collectMinor();
    try std.testing.expectEqual(@as(usize, 1), s.freed_objects); // orphan only
    try std.testing.expectEqual(@as(usize, 2), heap.objects_alive);
    try std.testing.expectEqual(Generation.old, Heap.headerOf(y).gen); // promoted

    // Drop the edge → `y` becomes unreachable and a major GC reclaims it.
    try old.set("y", try val_mod.makeUndefined(arena.allocator()));
    _ = heap.collect();
    try std.testing.expectEqual(@as(usize, 1), heap.objects_alive);

    heap.removeRoot(&old_root);
}

test "Heap: deep object chain marks iteratively (no stack overflow)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val_mod = @import("../value/value.zig");

    // Build a chain of N objects, each linked to the next via a "next" property.
    // A recursive marker would overflow the native stack around a few tens of
    // thousands of frames; the iterative worklist handles this flat.
    const N: usize = 200_000;
    const head = try heap.allocateObject(null);
    var prev = head;
    var i: usize = 1;
    while (i < N) : (i += 1) {
        const obj = try heap.allocateObject(null);
        const v = try val_mod.makeObject(arena.allocator(), obj);
        try prev.set("next", v);
        prev = obj;
    }
    try std.testing.expectEqual(N, heap.objects_alive);

    // Root only the head; the whole chain must survive via transitive marking.
    var root_val = try val_mod.makeObject(arena.allocator(), head);
    try heap.addRoot(&root_val);
    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
    try std.testing.expectEqual(N, heap.objects_alive);
    heap.removeRoot(&root_val);

    // Drop the root: the entire chain becomes unreachable and is freed without
    // recursing N frames deep during the sweep-driven mark.
    const stats2 = heap.collect();
    try std.testing.expectEqual(N, stats2.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), heap.objects_alive);
}
