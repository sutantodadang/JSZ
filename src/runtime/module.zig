// SPDX-License-Identifier: Apache-2.0
//! Milestone 16 (ESM) — Phase 1: foundational module records and registry.
//!
//! A `ModuleRecord` mirrors the spec's Abstract Module Record (the Cyclic
//! Module Record subset we need): a specifier-keyed unit of source that moves
//! through the resolve → instantiate(link) → evaluate phases, each guarded by a
//! `ModuleStatus`. The `ModuleRegistry` is the host-side cache that dedups
//! records by canonical specifier so a module is parsed/compiled/evaluated at
//! most once (and so cyclic imports observe a partially-initialised record).
//!
//! Phase 1 keeps the actual linking/evaluation reusing the existing CommonJS
//! `require()`/`exports` desugaring that the parser already emits for
//! import/export — the records here track lifecycle + cache the compiled
//! artefact and the resulting namespace, while later phases fill in real
//! resolve/instantiate graph walking and live-binding linkage.
//!
//! All storage is arena-allocated; the caller owns the arena lifetime (matching
//! the parser/compiler convention used across the engine).
const std = @import("std");
const ast = @import("../parser/ast.zig");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const BcFunction = @import("../bytecode/function.zig").BcFunction;

/// Lifecycle of a module record, mirroring the spec [[Status]] field. Phase 1
/// uses these to dedup work and to expose a partially-initialised record to a
/// cyclic importer (a record that is `.evaluating` when re-entered).
pub const ModuleStatus = enum {
    /// Created but not yet parsed/linked.
    unlinked,
    /// Dependency resolution / instantiation in progress.
    linking,
    /// Linked (instantiated): compiled and ready to evaluate.
    linked,
    /// Evaluation in progress (re-entrant cyclic imports see this).
    evaluating,
    /// Evaluation completed successfully; `namespace` is populated.
    evaluated,
    /// Parse/link/evaluation threw; `eval_error` holds the thrown value.
    errored,
};

/// One module unit, keyed by its canonical specifier (`id`).
pub const ModuleRecord = struct {
    /// Canonical specifier (host-resolved; '/'-separated for the FS loader).
    id: []const u8,
    /// Module source text (already template-rewritten by the caller, if any).
    source: []const u8,
    status: ModuleStatus = .unlinked,
    /// Always true for an ES module: module code is strict by spec (§11.2.2).
    is_strict: bool = true,
    /// Parsed + desugared top-level statements (set once parsed).
    body: ?[]*ast.Node = null,
    /// Compiled top-level function (set once linked).
    func: ?*const BcFunction = null,
    /// Module namespace / completion value (set once evaluated). Default
    /// `Value{}` (bits==0) reads as the empty sentinel until populated.
    namespace: Value = .{},
    /// The value thrown if `status == .errored`.
    eval_error: Value = .{},

    pub fn init(id: []const u8, source: []const u8) ModuleRecord {
        return .{ .id = id, .source = source };
    }
};

/// Host-side cache of module records keyed by canonical specifier. Phase 1: a
/// flat map; later phases grow a resolve hook + dependency edges.
pub const ModuleRegistry = struct {
    arena: std.mem.Allocator,
    records: std.StringHashMapUnmanaged(*ModuleRecord) = .{},

    pub fn init(arena: std.mem.Allocator) ModuleRegistry {
        return .{ .arena = arena };
    }

    /// Look up a record by canonical specifier; null if not registered.
    pub fn get(self: *const ModuleRegistry, id: []const u8) ?*ModuleRecord {
        return self.records.get(id);
    }

    /// Fetch the record for `id`, creating (and registering) an `.unlinked`
    /// one over `source` if absent. The returned record is owned by the arena.
    pub fn getOrCreate(self: *ModuleRegistry, id: []const u8, source: []const u8) !*ModuleRecord {
        if (self.records.get(id)) |rec| return rec;
        const rec = try self.arena.create(ModuleRecord);
        rec.* = ModuleRecord.init(id, source);
        try self.records.put(self.arena, id, rec);
        return rec;
    }

    /// Register an externally-built record under its own `id`.
    pub fn register(self: *ModuleRegistry, rec: *ModuleRecord) !void {
        try self.records.put(self.arena, rec.id, rec);
    }

    pub fn count(self: *const ModuleRegistry) usize {
        return self.records.count();
    }
};

// ------------------------------------------------------------------- tests ---

test "ModuleRegistry: getOrCreate dedups by id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ModuleRegistry.init(arena.allocator());

    const a = try reg.getOrCreate("./a.js", "export var x = 1;");
    const b = try reg.getOrCreate("./a.js", "ignored second source");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expectEqual(ModuleStatus.unlinked, a.status);
    try std.testing.expect(a.is_strict);
}

test "ModuleRegistry: get returns null for unknown id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ModuleRegistry.init(arena.allocator());
    try std.testing.expect(reg.get("./missing.js") == null);
    _ = try reg.getOrCreate("./present.js", "");
    try std.testing.expect(reg.get("./present.js") != null);
}

test "ModuleRecord: default namespace is the empty sentinel" {
    const rec = ModuleRecord.init("m", "");
    try std.testing.expectEqual(@as(u64, 0), rec.namespace.bits);
    try std.testing.expectEqual(ModuleStatus.unlinked, rec.status);
}
