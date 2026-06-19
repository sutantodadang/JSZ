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

// ------------------------------------------------- host filesystem loader ---
//
// The spec's `HostResolveImportedModule` + the `InnerModuleLinking` graph walk,
// realised against the existing import/export → CommonJS `require`/`exports`
// desugar: rather than build live-binding module environments, we discover the
// dependency graph from disk, register each reachable module as a factory in a
// `__modules__` registry, and let the runtime `require()` resolver perform the
// actual linking/evaluation (cache-before-invoke already gives cyclic safety).
//
// The discovery DFS is comment/string/template aware (test262 license and
// `info:` blocks are full of apostrophes that a naive quote scan mis-pairs).

/// `dirname` for a '/'-separated canonical id ("" when there is no separator).
pub fn dirnameSlash(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |idx| return id[0..idx];
    return "";
}

/// Normalize a '/'-or-'\\'-separated path: drop "."/empty segments, resolve "..".
pub fn normalizeRel(allocator: std.mem.Allocator, p: []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8){};
    defer parts.deinit(allocator);
    var it = std.mem.splitAny(u8, p, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, seg);
    }
    return std.mem.join(allocator, "/", parts.items);
}

/// Resolve a relative specifier against the importer's canonical id (the spec's
/// HostResolveImportedModule name-resolution half).
pub fn resolveSpec(allocator: std.mem.Allocator, importer_id: []const u8, spec: []const u8) ![]const u8 {
    const base = dirnameSlash(importer_id);
    const joined = if (base.len == 0)
        try allocator.dupe(u8, spec)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, spec });
    return normalizeRel(allocator, joined);
}

/// Append canonical ids of relative module specifiers found in `src` (resolved
/// against `importer_id`) to `out`. Skips line/block comments and treats string
/// and template-literal bodies as opaque, so prose apostrophes/quotes inside
/// comments cannot be mistaken for specifier delimiters.
pub fn scanSpecifiers(src: []const u8, importer_id: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // Comments: consume to the comment's end without inspecting contents.
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
                i += 2;
                continue;
            }
        }
        // Template literal: opaque body (nested `${}` substitutions may contain
        // strings, but they cannot be a top-level import specifier, so skipping
        // the whole template is safe for discovery).
        if (c == '`') {
            i += 1;
            while (i < src.len and src[i] != '`') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i + 1;
            var j = start;
            while (j < src.len and src[j] != c) : (j += 1) {
                if (src[j] == '\\') j += 1;
            }
            if (j <= src.len) {
                const end = @min(j, src.len);
                const lit = src[start..end];
                if (std.mem.startsWith(u8, lit, "./") or std.mem.startsWith(u8, lit, "../")) {
                    const id = resolveSpec(allocator, importer_id, lit) catch "";
                    if (id.len > 0) out.append(allocator, id) catch {};
                }
            }
            i = j + 1;
            continue;
        }
        i += 1;
    }
}

/// Read a module file under `base_dir` by canonical id, trying `id` then `id.js`.
fn readModuleFile(allocator: std.mem.Allocator, base_dir: []const u8, id: []const u8) ?[]const u8 {
    const max = 10 * 1024 * 1024;
    const p1 = std.fs.path.join(allocator, &.{ base_dir, id }) catch return null;
    if (std.fs.cwd().readFileAlloc(allocator, p1, max)) |s| return s else |_| {}
    const p2 = std.fmt.allocPrint(allocator, "{s}.js", .{p1}) catch return null;
    if (std.fs.cwd().readFileAlloc(allocator, p2, max)) |s| return s else |_| {}
    return null;
}

/// The id used for the bundle entry point (its own relative imports resolve
/// against `base_dir`, i.e. as if it lived directly in that directory).
pub const ENTRY_ID = "__entry__";

/// Scan `src` for every exported name and append them to `out`. Handles
/// comment/string/template skipping (reuses the same skip logic as
/// `scanSpecifiers`). This is a syntactic scan, not a full parse — sufficient
/// for the CJS-desugar module namespace TDZ setup in `buildBundle`.
pub fn findExportNames(src: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // Comments and strings: skip entirely (same as scanSpecifiers).
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
                i += 2;
                continue;
            }
        }
        if (c == '`') {
            i += 1;
            while (i < src.len and src[i] != '`') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const q = c;
            i += 1;
            while (i < src.len and src[i] != q) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        // Look for `export ` keyword.
        if (i + 7 <= src.len and std.mem.eql(u8, src[i..i + 7], "export ")) {
            i += 7;
            const rest = src[i..];
            // export default
            if (std.mem.startsWith(u8, rest, "default ")) {
                out.append(allocator, "default") catch {};
                continue;
            }
            // export * as name from
            if (std.mem.startsWith(u8, rest, "* as ")) {
                var j: usize = 5;
                // skip spaces before identifier
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                }
                continue;
            }
            // export function <name>
            if (std.mem.startsWith(u8, rest, "function ")) {
                var j: usize = 9;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                }
                continue;
            }
            // export class <name>
            if (std.mem.startsWith(u8, rest, "class ")) {
                var j: usize = 6;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                }
                continue;
            }
            // export { a, b as c, ... } [from "mod"]
            if (rest.len > 0 and rest[0] == '{') {
                var j: usize = 1;
                while (j < rest.len and rest[j] != '}') : (j += 1) {
                    // Skip whitespace, commas, and braces
                    if (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '\n' or rest[j] == ',' or rest[j] == '{') continue;
                    if (rest[j] == '}') break;
                    // Read identifier (the local name)
                    const local_start = j;
                    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                    if (j >= rest.len or j == local_start) continue;
                    // Check if followed by 'as' keyword — if so, the identifier
                    // before 'as' is the local name, not the exported name.
                    // Skip past 'as' and read the exported name.
                    var k = j;
                    while (k < rest.len and (rest[k] == ' ' or rest[k] == '\t' or rest[k] == '\n')) : (k += 1) {}
                    if (k + 2 < rest.len and std.mem.eql(u8, rest[k..k + 2], "as") and
                        (k + 2 >= rest.len or rest[k + 2] == ' ' or rest[k + 2] == '\t' or rest[k + 2] == '\n' or rest[k + 2] == '}'))
                    {
                        // Skip 'as' and whitespace, then read the exported name.
                        j = k + 2;
                        while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '\n')) : (j += 1) {}
                        const name_start = j;
                        while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                        if (j > name_start) {
                            out.append(allocator, rest[name_start..j]) catch {};
                        }
                    } else {
                        // No 'as' — the identifier itself is the exported name.
                        out.append(allocator, rest[local_start..j]) catch {};
                    }
                }
                continue;
            }
            // export let/var/const <name>
            if (std.mem.startsWith(u8, rest, "let ") or
                std.mem.startsWith(u8, rest, "var ") or
                std.mem.startsWith(u8, rest, "const "))
            {
                var j: usize = 4;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                }
                continue;
            }
            continue;
        }
        i += 1;
    }
}
/// Build a self-contained script: a `__modules__` registry of every relative
/// `base_dir`), each wrapped as a `function(require, module, exports)` factory
/// keyed by its canonical id, followed by the entry body. This realises the
/// link phase: the runtime `require()` resolver evaluates factories on demand
/// with cache-before-invoke cyclic safety. Modules absent on disk are skipped
/// (left to resolve — and fail — at runtime, matching a missing dependency).
///
/// `entry_id` is the entry module's own canonical id (its `null` form falls
/// back to `ENTRY_ID`). The entry body is always inlined at top level so its
/// declarations live in module scope and a parse error in it surfaces directly
/// (negative parse-phase tests rely on this). When `entry_id` is non-null the
/// entry's `module` object is *pre-registered* in `__modules__` under that id
/// before the body runs, so a module that imports itself
/// (`import * as ns from './self.js'`) — or a cycle resolving back to the entry
/// — observes the very same live `exports` object rather than a second
/// evaluation.
///
/// Allocations use `gpa`; the returned slice is owned by the caller.
pub fn buildBundle(gpa: std.mem.Allocator, base_dir: []const u8, entry_id: ?[]const u8, entry_src: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const self_id = entry_id orelse ENTRY_ID;
    var registry = std.StringArrayHashMap([]const u8).init(arena);
    var queue = std.ArrayList([]const u8){};
    scanSpecifiers(entry_src, self_id, &queue, arena);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const id = queue.items[qi];
        // The entry resolves to itself via the pre-registered `module` (below),
        // not a disk re-read, so skip its own id here.
        if (std.mem.eql(u8, id, self_id)) continue;
        if (registry.contains(id)) continue;
        const src = readModuleFile(arena, base_dir, id) orelse continue;
        try registry.put(id, src);
        scanSpecifiers(src, id, &queue, arena);
    }

    var sb = std.ArrayList(u8){};
    errdefer sb.deinit(gpa);
    try sb.appendSlice(gpa, "var __modules__ = {};\n");
    var it = registry.iterator();
    while (it.next()) |e| {
        try sb.appendSlice(gpa, "__modules__[\"");
        try sb.appendSlice(gpa, e.key_ptr.*);
        try sb.appendSlice(gpa, "\"] = function(require, module, exports){\nvar __module_id__ = \"");
        try sb.appendSlice(gpa, e.key_ptr.*);
        try sb.appendSlice(gpa, "\";\n");
        // M16 Phase 4: inject export name setup so the module namespace exotic
        // can detect TDZ (known exports missing from the backing). Scan the
        // source for export names and call __initModuleExports__(exports, [...]).
        var export_names = std.ArrayList([]const u8){};
        findExportNames(e.value_ptr.*, &export_names, arena);
        if (export_names.items.len > 0) {
            try sb.appendSlice(gpa, "__initExports__(exports,[");
            for (export_names.items, 0..) |nm, eni| {
                if (eni > 0) try sb.appendSlice(gpa, ",");
                try sb.appendSlice(gpa, "\"");
                // Escape any embedded quotes/backslashes in the name.
                for (nm) |ch| {
                    if (ch == '\\' or ch == '"') {
                        try sb.appendSlice(gpa, "\\");
                    }
                    try sb.appendSlice(gpa, &.{ch});
                }
                try sb.appendSlice(gpa, "\"");
            }
            try sb.appendSlice(gpa, "]);\n");
        }
        try sb.appendSlice(gpa, e.value_ptr.*);
        try sb.appendSlice(gpa, "\n};\n");
    }
    try sb.appendSlice(gpa, "var module = { exports: {} }; var exports = module.exports;\nvar __module_id__ = \"");
    try sb.appendSlice(gpa, self_id);
    try sb.appendSlice(gpa, "\";\n");
    if (entry_id != null) {
        // Pre-register the entry so a self-/cyclic `require` returns this exact
        // (partial) exports object — cache-before-invoke for the entry itself.
        try sb.appendSlice(gpa, "__modules__[\"");
        try sb.appendSlice(gpa, self_id);
        try sb.appendSlice(gpa, "\"] = module;\n");
    }
    // M16 Phase 4: inject export name setup for the entry module too.
    var entry_names = std.ArrayList([]const u8){};
    findExportNames(entry_src, &entry_names, arena);
    if (entry_names.items.len > 0) {
        try sb.appendSlice(gpa, "__initExports__(exports,[");
        for (entry_names.items, 0..) |nm, eni| {
            if (eni > 0) try sb.appendSlice(gpa, ",");
            try sb.appendSlice(gpa, "\"");
            for (nm) |ch| {
                if (ch == '\\' or ch == '"') try sb.appendSlice(gpa, "\\");
                try sb.appendSlice(gpa, &.{ch});
            }
            try sb.appendSlice(gpa, "\"");
        }
        try sb.appendSlice(gpa, "]);\n");
    }
    try sb.appendSlice(gpa, entry_src);
    return sb.toOwnedSlice(gpa);
}

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

test "scanSpecifiers: ignores apostrophes/quotes inside comments and templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\// it's a comment with a 'quote and "another
        \\/* block: don't be fooled by './fake.js' */
        \\const t = `template with './also-fake.js' ${x}`;
        \\import { y } from './real.js';
        \\export { z } from '../up/real2.js';
    ;
    var out: std.ArrayList([]const u8) = .empty;
    scanSpecifiers(src, "dir/entry.js", &out, a);
    // Only the two genuine specifiers, resolved against "dir/entry.js".
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("dir/real.js", out.items[0]);
    try std.testing.expectEqualStrings("up/real2.js", out.items[1]);
}

test "scanSpecifiers: bare/absolute specifiers are not relative imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    scanSpecifiers("import x from 'lodash'; import y from '/abs.js';", ENTRY_ID, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "buildBundle: registers reachable factory and pre-registers a self-import entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No disk fixtures here, so only the entry self-registration is exercised.
    const out = try buildBundle(a, ".", "self.js", "import * as ns from './self.js'; export var v = 1;");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var __modules__ = {};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__modules__[\"self.js\"] = module;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var __module_id__ = \"self.js\";") != null);
}
