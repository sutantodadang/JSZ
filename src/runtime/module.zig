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
                    var id = resolveSpec(allocator, importer_id, lit) catch "";
                    // A `with { type: '...' }` attribute right after the specifier
                    // makes this a typed (JSON/text) module: encode the type into
                    // the id so it keys distinctly and gets a synthetic factory.
                    if (id.len > 0) {
                        if (attrTypeAfter(src, j + 1)) |ty| {
                            id = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ id, ty }) catch id;
                        }
                        out.append(allocator, id) catch {};
                    }
                }
            }
            i = j + 1;
            continue;
        }
        i += 1;
    }
}

/// Strip the `\x00<type>` attribute suffix from a canonical id, leaving the
/// bare on-disk path (typed modules — JSON/text — encode their type into the id
/// so they key distinctly from a plain JS import of the same path).
pub fn bareId(id: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, id, 0)) |n| return id[0..n];
    return id;
}

/// The module-type attribute encoded in a typed id (`\x00json` / `\x00text`),
/// or null for an ordinary JS module.
pub fn idType(id: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, id, 0)) |n| return id[n + 1 ..];
    return null;
}

/// Append `s` to `sb` as a double-quoted JS string literal, escaping characters
/// that cannot appear literally inside one (quotes, backslash, control chars,
/// line separators). UTF-8 bytes pass through unchanged. Used to embed arbitrary
/// file content (JSON / text module bodies, typed-module keys) into the bundle.
fn appendJsString(gpa: std.mem.Allocator, sb: *std.ArrayList(u8), s: []const u8) !void {
    try sb.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try sb.appendSlice(gpa, "\\\""),
            '\\' => try sb.appendSlice(gpa, "\\\\"),
            '\n' => try sb.appendSlice(gpa, "\\n"),
            '\r' => try sb.appendSlice(gpa, "\\r"),
            '\t' => try sb.appendSlice(gpa, "\\t"),
            0x08 => try sb.appendSlice(gpa, "\\b"),
            0x0c => try sb.appendSlice(gpa, "\\f"),
            0...7, 0x0b, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                try sb.appendSlice(gpa, hex);
            },
            else => try sb.append(gpa, ch),
        }
    }
    try sb.append(gpa, '"');
}

/// If a `with { type: '...' }` / `assert { ... }` import-attribute clause begins
/// at `pos` (after optional whitespace/comments), return the `type` attribute's
/// string value (e.g. "json", "text"); otherwise null. Used by `scanSpecifiers`
/// to classify a discovered specifier as a typed (synthetic) module.
fn attrTypeAfter(src: []const u8, pos: usize) ?[]const u8 {
    var i = skipWsComments(src, pos);
    // Match the `with` / `assert` keyword as a standalone word.
    const kw_with = i + 4 <= src.len and std.mem.eql(u8, src[i .. i + 4], "with") and
        (i + 4 == src.len or !isIdentChar(src[i + 4]));
    const kw_assert = i + 6 <= src.len and std.mem.eql(u8, src[i .. i + 6], "assert") and
        (i + 6 == src.len or !isIdentChar(src[i + 6]));
    if (kw_with) {
        i += 4;
    } else if (kw_assert) {
        i += 6;
    } else return null;
    i = skipWsComments(src, i);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;
    // Scan the brace body for a `type` key followed by a string value.
    var saw_type_key = false;
    var saw_colon = false;
    while (i < src.len and src[i] != '}') {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ',') {
            if (c == ',') {
                saw_type_key = false;
                saw_colon = false;
            }
            i += 1;
            continue;
        }
        if (c == ':') {
            saw_colon = true;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const s = i + 1;
            var k = s;
            while (k < src.len and src[k] != c) : (k += 1) {
                if (src[k] == '\\') k += 1;
            }
            const val = src[s..@min(k, src.len)];
            if (saw_type_key and saw_colon) return val;
            // A bare string token at key position: is it the `type` key?
            if (!saw_colon and std.mem.eql(u8, val, "type")) saw_type_key = true;
            i = k + 1;
            continue;
        }
        if (isIdentChar(c)) {
            const s = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            if (!saw_colon and std.mem.eql(u8, src[s..i], "type")) saw_type_key = true;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Read a module file under `base_dir` by canonical id, trying `id` then `id.js`.
fn readModuleFile(allocator: std.mem.Allocator, base_dir: []const u8, id_in: []const u8) ?[]const u8 {
    const id = bareId(id_in);
    const max = 10 * 1024 * 1024;
    const p1 = std.fs.path.join(allocator, &.{ base_dir, id }) catch return null;
    if (std.fs.cwd().readFileAlloc(allocator, p1, max)) |s| return s else |_| {}
    const p2 = std.fmt.allocPrint(allocator, "{s}.js", .{p1}) catch return null;
    if (std.fs.cwd().readFileAlloc(allocator, p2, max)) |s| return s else |_| {}
    return null;
}

// ----------------------------------------------- M16 TLA: async classification ---
//
// Top-level await needs the spec's async InnerModuleEvaluation ordering. JSZ
// realises it on the desugar model: a module that has top-level await — or that
// (transitively) imports such a module — is evaluated as an `async function`
// factory whose result Promise is its evaluation-completion promise. Importers
// of an async module insert an `await __awaitDeps__([...])` barrier after their
// import prologue so their body runs only once every async dependency has
// finished evaluating (matching the spec's PendingAsyncDependencies gate).

/// True when the next `len`-bounded run starting at `i` is an identifier
/// character (used to find word boundaries).
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Skip whitespace and line/block comments starting at `i`; return the new index.
fn skipWsComments(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n') : (i += 1) {}
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
                i = @min(i + 2, src.len);
                continue;
            }
        }
        break;
    }
    return i;
}

/// True when `src` contains a *top-level* `await` (one not lexically inside any
/// function body) — i.e. the module has top-level await (spec [[HasTLA]]).
/// Comment/string/template aware. Function nesting is tracked with a brace
/// stack: a `{` opens a function body when preceded by `=>`, or by a `)` whose
/// matching `(` is not a control-flow header (if/for/while/switch/catch/with) —
/// which covers `function`, methods, getters and parenthesised arrows. An
/// `await` keyword seen at function-depth 0 (and not after `.`) reports TLA.
pub fn hasTopLevelAwait(src: []const u8) bool {
    const cap = 256;
    var brace_is_fn: [cap]bool = undefined; // stack of brace kinds
    var brace_n: usize = 0;
    var paren_ctrl: [cap]bool = undefined; // per-`(`: was its prefix a control kw?
    var paren_n: usize = 0;
    var fn_depth: u32 = 0;

    // Classification of the previous significant token, for `{`/`(` decisions.
    const Prev = enum { none, arrow, close_paren, word, dot, other };
    var prev: Prev = .none;
    var prev_word_ctrl = false; // last word was a control-flow keyword

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // Comments.
        if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        // Template / strings: opaque bodies.
        if (c == '`') {
            i += 1;
            while (i < src.len and src[i] != '`') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            prev = .other;
            continue;
        }
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            prev = .other;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        // Identifier / keyword.
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const start = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            const word = src[start..i];
            if (std.mem.eql(u8, word, "await") and fn_depth == 0 and prev != .dot) {
                return true;
            }
            prev_word_ctrl = std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "for") or
                std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "switch") or
                std.mem.eql(u8, word, "catch") or std.mem.eql(u8, word, "with");
            prev = .word;
            continue;
        }
        // Arrow.
        if (c == '=' and i + 1 < src.len and src[i + 1] == '>') {
            i += 2;
            prev = .arrow;
            continue;
        }
        switch (c) {
            '(' => {
                if (paren_n < cap) {
                    paren_ctrl[paren_n] = (prev == .word and prev_word_ctrl);
                    paren_n += 1;
                }
                prev = .other;
            },
            ')' => {
                if (paren_n > 0) paren_n -= 1;
                prev = .close_paren;
            },
            '{' => {
                var is_fn = false;
                if (prev == .arrow) {
                    is_fn = true;
                } else if (prev == .close_paren) {
                    // The brace follows `)`: a function/method body unless the
                    // matching `(` was a control-flow header.
                    is_fn = !(paren_n < cap and paren_ctrl[paren_n]);
                }
                if (brace_n < cap) {
                    brace_is_fn[brace_n] = is_fn;
                    brace_n += 1;
                }
                if (is_fn) fn_depth += 1;
                prev = .other;
            },
            '}' => {
                if (brace_n > 0) {
                    brace_n -= 1;
                    if (brace_is_fn[brace_n] and fn_depth > 0) fn_depth -= 1;
                }
                prev = .other;
            },
            '.' => prev = .dot,
            else => prev = .other,
        }
        i += 1;
    }
    return false;
}

/// Return the byte offset just past a module's leading `import` declaration
/// prologue — the point at which an async-dependency `await` barrier may be
/// spliced so it runs after every static import's `require()` but before the
/// module body. Stops at the first top-level statement that is not a plain
/// `import` declaration (dynamic `import(`, `import.meta`, exports, code).
pub fn findImportPrologueEnd(src: []const u8) usize {
    var i: usize = 0;
    while (true) {
        i = skipWsComments(src, i);
        const stmt_start = i;
        if (i >= src.len) return i;
        // Must begin with the `import` keyword as a standalone word.
        if (!(i + 6 <= src.len and std.mem.eql(u8, src[i .. i + 6], "import") and
            (i + 6 == src.len or !isIdentChar(src[i + 6])))) return stmt_start;
        var j = skipWsComments(src, i + 6);
        // `import(` (dynamic) or `import.meta` are expressions, not a prologue.
        if (j < src.len and (src[j] == '(' or src[j] == '.')) return stmt_start;
        // Advance to the statement terminator `;` at top nesting, skipping
        // strings/comments. Import declarations in practice end with `;`.
        var depth: i32 = 0;
        while (j < src.len) {
            const c = src[j];
            if (c == '/' and j + 1 < src.len and (src[j + 1] == '/' or src[j + 1] == '*')) {
                j = skipWsComments(src, j);
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                const q = c;
                j += 1;
                while (j < src.len and src[j] != q) : (j += 1) {
                    if (src[j] == '\\') j += 1;
                }
                j += 1;
                continue;
            }
            if (c == '{' or c == '(' or c == '[') depth += 1;
            if (c == '}' or c == ')' or c == ']') depth -= 1;
            if (c == ';' and depth <= 0) {
                j += 1;
                break;
            }
            j += 1;
        }
        i = j;
    }
}

/// Compute the set of module ids (within `sources`, plus `entry_id`/`entry_src`)
/// that are async: they have top-level await, or transitively import a module
/// that does. Returns a set of ids (arena-owned keys reference `sources`/given
/// ids). `dep_of` is filled with each id's relative dependency id list.
fn computeAsyncSet(
    arena: std.mem.Allocator,
    sources: *std.StringArrayHashMap([]const u8),
    entry_id: []const u8,
    entry_src: []const u8,
    dep_of: *std.StringHashMap([]const []const u8),
) !std.StringHashMap(void) {
    var async_set = std.StringHashMap(void).init(arena);
    // Direct TLA + dependency lists for every module and the entry.
    var direct = std.StringHashMap(bool).init(arena);
    {
        var it = sources.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            // Typed (JSON/text/bytes) modules are opaque data, not JS: never async
            // and have no dependencies. Skip scanning their (possibly binary)
            // content for `await`/specifiers, which could otherwise misfire.
            if (idType(id) != null) {
                try direct.put(id, false);
                try dep_of.put(id, &[_][]const u8{});
                continue;
            }
            const src = e.value_ptr.*;
            try direct.put(id, hasTopLevelAwait(src));
            var deps = std.ArrayList([]const u8){};
            scanSpecifiers(src, id, &deps, arena);
            try dep_of.put(id, deps.items);
        }
        try direct.put(entry_id, hasTopLevelAwait(entry_src));
        var edeps = std.ArrayList([]const u8){};
        scanSpecifiers(entry_src, entry_id, &edeps, arena);
        try dep_of.put(entry_id, edeps.items);
    }
    // Seed with direct-TLA modules.
    {
        var it = direct.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) try async_set.put(e.key_ptr.*, {});
        }
    }
    // Fixpoint: a module is async if any dependency is async.
    var changed = true;
    while (changed) {
        changed = false;
        var it = dep_of.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            if (async_set.contains(id)) continue;
            for (e.value_ptr.*) |d| {
                if (async_set.contains(d)) {
                    try async_set.put(id, {});
                    changed = true;
                    break;
                }
            }
        }
    }
    return async_set;
}

/// DFS pre-order discovery times from `entry_id` following `dep_of` edges.
/// Modules not reachable from the entry get no entry (treated as order = maxInt).
fn computeDfsOrder(
    arena: std.mem.Allocator,
    dep_of: *std.StringHashMap([]const []const u8),
    entry_id: []const u8,
) std.StringHashMap(usize) {
    var order = std.StringHashMap(usize).init(arena);
    var counter: usize = 0;
    var stack = std.ArrayList([]const u8){};
    stack.append(arena, entry_id) catch return order;
    while (stack.items.len > 0) {
        const id = stack.pop() orelse break;
        if (order.contains(id)) continue;
        order.put(id, counter) catch {};
        counter += 1;
        const ds = dep_of.get(id) orelse continue;
        // Push in reverse so left-most dep is processed first.
        var i: usize = ds.len;
        while (i > 0) {
            i -= 1;
            if (!order.contains(ds[i])) stack.append(arena, ds[i]) catch {};
        }
    }
    return order;
}

/// True when `target` is reachable from `from` by following dep_of edges.
fn canReach(
    arena: std.mem.Allocator,
    dep_of: *std.StringHashMap([]const []const u8),
    from: []const u8,
    target: []const u8,
) bool {
    var visited = std.StringHashMap(void).init(arena);
    var queue = std.ArrayList([]const u8){};
    const start_deps = dep_of.get(from) orelse return false;
    for (start_deps) |d| queue.append(arena, d) catch {};
    while (queue.items.len > 0) {
        const curr = queue.orderedRemove(0);
        if (std.mem.eql(u8, curr, target)) return true;
        if (visited.contains(curr)) continue;
        visited.put(curr, {}) catch {};
        const ds = dep_of.get(curr) orelse continue;
        for (ds) |d| if (!visited.contains(d)) queue.append(arena, d) catch {};
    }
    return false;
}

/// Return the SCC representative of `id`: the member of `id`'s SCC with the
/// smallest DFS discovery time.  If `id` is a singleton (not in any cycle)
/// this returns `id` itself.
fn findSccRoot(
    arena: std.mem.Allocator,
    dep_of: *std.StringHashMap([]const []const u8),
    dfs_order: *std.StringHashMap(usize),
    id: []const u8,
) []const u8 {
    var root = id;
    var root_order = dfs_order.get(id) orelse 0;
    // Walk all modules reachable from `id`; keep those that can also reach `id`.
    var visited = std.StringHashMap(void).init(arena);
    var queue = std.ArrayList([]const u8){};
    queue.append(arena, id) catch return id;
    while (queue.items.len > 0) {
        const curr = queue.orderedRemove(0);
        if (visited.contains(curr)) continue;
        visited.put(curr, {}) catch {};
        if (!std.mem.eql(u8, curr, id) and canReach(arena, dep_of, curr, id)) {
            const ord = dfs_order.get(curr) orelse std.math.maxInt(usize);
            if (ord < root_order) {
                root_order = ord;
                root = curr;
            }
        }
        const ds = dep_of.get(curr) orelse continue;
        for (ds) |d| if (!visited.contains(d)) queue.append(arena, d) catch {};
    }
    return root;
}

/// The (deduplicated) list of `id`'s dependency ids that are async modules,
/// with cycle-awareness mirroring the spec's InnerModuleEvaluation logic:
///
///  - If dep D and module M are in the **same SCC** and D has a *lower* DFS
///    discovery time than M, then D is a cycle ancestor (back-edge dep) — skip
///    it (M will not wait for its ancestor; the ancestor will wait for M).
///
///  - If D is in a **different SCC** from M, use D's SCC root (CycleRoot) as
///    the actual dep — this matches spec step 11.c.iv which redirects to the
///    cycle root when the dep's status is evaluating-async.
fn asyncDepsList(
    arena: std.mem.Allocator,
    async_set: *std.StringHashMap(void),
    dep_of: *std.StringHashMap([]const []const u8),
    dfs_order: *std.StringHashMap(usize),
    id: []const u8,
) []const []const u8 {
    const deps = dep_of.get(id) orelse return &[_][]const u8{};
    var out = std.ArrayList([]const u8){};
    var seen = std.StringHashMap(void).init(arena);
    const my_order = dfs_order.get(id) orelse std.math.maxInt(usize);
    for (deps) |d| {
        if (!async_set.contains(d)) continue;
        const d_order = dfs_order.get(d) orelse std.math.maxInt(usize);
        const in_same_scc = canReach(arena, dep_of, d, id);
        const actual_dep: []const u8 = blk: {
            if (in_same_scc) {
                // Back-edge: d was visited before id in DFS → id should NOT wait for d.
                if (d_order < my_order) continue;
                // Tree/forward edge within the SCC: id does wait for d.
                break :blk d;
            } else {
                // Different SCC: use d's SCC root (spec CycleRoot).
                break :blk findSccRoot(arena, dep_of, dfs_order, d);
            }
        };
        if (!async_set.contains(actual_dep)) continue;
        if (seen.contains(actual_dep)) continue;
        seen.put(actual_dep, {}) catch {};
        out.append(arena, actual_dep) catch {};
    }
    return out.items;
}

/// Emit `await __awaitDeps__(["id1","id2"]);` — the async-dependency barrier.
fn emitAwaitDeps(gpa: std.mem.Allocator, sb: *std.ArrayList(u8), deps: []const []const u8) !void {
    try sb.appendSlice(gpa, "await __awaitDeps__([");
    for (deps, 0..) |d, i| {
        if (i > 0) try sb.appendSlice(gpa, ",");
        try sb.appendSlice(gpa, "\"");
        for (d) |ch| {
            if (ch == '\\' or ch == '"') try sb.appendSlice(gpa, "\\");
            try sb.appendSlice(gpa, &.{ch});
        }
        try sb.appendSlice(gpa, "\"");
    }
    try sb.appendSlice(gpa, "]);\n");
}

/// The id used for the bundle entry point (its own relative imports resolve
/// against `base_dir`, i.e. as if it lived directly in that directory).
pub const ENTRY_ID = "__entry__";

/// Scan `src` for every exported name and append them to `out`. Handles
/// comment/string/template skipping (reuses the same skip logic as
/// `scanSpecifiers`). This is a syntactic scan, not a full parse — sufficient
/// for the CJS-desugar module namespace TDZ setup in `buildBundle`.
///
/// `out_tdz` receives ONLY the names that are in the temporal dead zone
/// (let, const, class declarations). var and function declarations are
/// hoisted/initialized at instantiation and are NOT added to out_tdz.
/// Re-exports (export { x } from, export * from) are also not in TDZ.
///
/// `out_fn` receives names that are function/generator declarations
/// (hoisted and initialized to the function value during instantiation).
/// These are emitted as `exports.NAME = NAME;` in the bundle prelude.
///
/// To correctly handle `export { localName as renamed }` where `localName`
/// may be a let/const/class, the function does a pre-pass to collect all
/// let/const/class local declarations (including non-exported ones) before
/// processing export-names in `export { ... }` lists.
pub fn findExportNames(src: []const u8, out: *std.ArrayList([]const u8), out_tdz: *std.ArrayList([]const u8), out_fn: *std.ArrayList([]const u8), out_default_fn_binding: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    // Pre-pass: collect ALL let/const/class local binding names (exported or
    // not), so `export { local2 as renamed }` can detect that `local2` is TDZ.
    var tdz_locals = std.StringHashMap(void).init(allocator);
    defer tdz_locals.deinit();
    {
        var i: usize = 0;
        while (i < src.len) {
            const c = src[i];
            // Skip comments and strings (same logic as main loop)
            if (c == '/' and i + 1 < src.len) {
                if (src[i + 1] == '/') { i += 2; while (i < src.len and src[i] != '\n') : (i += 1) {} continue; }
                if (src[i + 1] == '*') { i += 2; while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {} i += 2; continue; }
            }
            if (c == '`') { i += 1; while (i < src.len and src[i] != '`') : (i += 1) { if (src[i] == '\\') i += 1; } i += 1; continue; }
            if (c == '"' or c == '\'') { const q = c; i += 1; while (i < src.len and src[i] != q) : (i += 1) { if (src[i] == '\\') i += 1; } i += 1; continue; }

            // Check for `let `, `const `, `class ` (non-export) or after `export ` keyword
            const is_let = i + 4 <= src.len and std.mem.eql(u8, src[i..i + 4], "let ");
            const is_const = i + 6 <= src.len and std.mem.eql(u8, src[i..i + 6], "const ");
            const is_class = i + 6 <= src.len and std.mem.eql(u8, src[i..i + 6], "class ");
            // Also handle `export let/const/class` — skip past the "export " prefix
            var after_export: ?usize = null;
            if (i + 7 <= src.len and std.mem.eql(u8, src[i..i + 7], "export ")) {
                after_export = i + 7;
                const rest = src[after_export.?..];
                if (std.mem.startsWith(u8, rest, "let ")) {
                    var j: usize = 4;
                    while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                    const name_start = j;
                    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                    if (j > name_start) {
                        tdz_locals.put(rest[name_start..j], {}) catch {};
                    }
                    i = after_export.? + j;
                    continue;
                }
                if (std.mem.startsWith(u8, rest, "const ")) {
                    var j: usize = 6;
                    while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                    const name_start = j;
                    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                    if (j > name_start) {
                        tdz_locals.put(rest[name_start..j], {}) catch {};
                    }
                    i = after_export.? + j;
                    continue;
                }
                if (std.mem.startsWith(u8, rest, "class ")) {
                    var j: usize = 6;
                    while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                    const name_start = j;
                    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                    if (j > name_start) {
                        tdz_locals.put(rest[name_start..j], {}) catch {};
                    }
                    i = after_export.? + j;
                    continue;
                }
                // For `export default class` — named or anonymous, `default` is TDZ
                if (std.mem.startsWith(u8, rest, "default class") and rest.len > 13) {
                    const after_class = rest[13..];
                    // Check for named class: `default class C`
                    if (after_class.len > 0 and after_class[0] == ' ') {
                        var j: usize = 1;
                        while (j < after_class.len and after_class[j] == ' ') : (j += 1) {}
                        if (j < after_class.len) {
                            const name_start = j;
                            var k = name_start;
                            while (k < after_class.len and (std.ascii.isAlphanumeric(after_class[k]) or after_class[k] == '_' or after_class[k] == '$')) : (k += 1) {}
                            if (k > name_start) {
                                tdz_locals.put(after_class[name_start..k], {}) catch {};
                            }
                            i = after_export.? + 13 + k;
                        } else {
                            i = after_export.? + 13 + j;
                        }
                    } else {
                        // Anonymous class `export default class{` or `export default class {`
                        i = after_export.? + 13;
                        // skip past `{` if directly following
                        if (i < src.len and src[i] == '{') i += 1;
                    }
                    // default itself is also TDZ
                    tdz_locals.put("default", {}) catch {};
                    continue;
                }
            }
            // Non-exported let/const/class declarations
            if (is_let) {
                var j: usize = 4;
                while (j < src.len - i and src[i + j] == ' ') : (j += 1) {}
                const name_start = i + j;
                var k = name_start;
                while (k < src.len and (std.ascii.isAlphanumeric(src[k]) or src[k] == '_' or src[k] == '$')) : (k += 1) {}
                if (k > name_start) {
                    tdz_locals.put(src[name_start..k], {}) catch {};
                }
                i = k;
                continue;
            }
            if (is_const) {
                var j: usize = 6;
                while (j < src.len - i and src[i + j] == ' ') : (j += 1) {}
                const name_start = i + j;
                var k = name_start;
                while (k < src.len and (std.ascii.isAlphanumeric(src[k]) or src[k] == '_' or src[k] == '$')) : (k += 1) {}
                if (k > name_start) {
                    tdz_locals.put(src[name_start..k], {}) catch {};
                }
                i = k;
                continue;
            }
            if (is_class) {
                var j: usize = 6;
                while (j < src.len - i and src[i + j] == ' ') : (j += 1) {}
                const name_start = i + j;
                var k = name_start;
                while (k < src.len and (std.ascii.isAlphanumeric(src[k]) or src[k] == '_' or src[k] == '$')) : (k += 1) {}
                if (k > name_start) {
                    tdz_locals.put(src[name_start..k], {}) catch {};
                }
                i = k;
                continue;
            }
            i += 1;
        }
    }
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
                // default is in TDZ unless it's a function/generator
                // declaration (which are hoisted and initialized during
                // instantiation). Both named and anonymous function/generator
                // defaults are initialized; class defaults and expression
                // defaults are uninitialized (TDZ).
                const after_default = rest["default ".len..];
                // Match "function" or "async function" followed by ' ', '*', or
                // '(' — covering named, anonymous, and generator variants.
                const is_sync_fn = std.mem.startsWith(u8, after_default, "function") and
                    after_default.len >= 9 and
                    (after_default[8] == ' ' or after_default[8] == '*' or after_default[8] == '(');
                const is_async_fn = std.mem.startsWith(u8, after_default, "async function") and
                    after_default.len >= 15 and
                    (after_default[14] == ' ' or after_default[14] == '*' or after_default[14] == '(');
                const is_fn_hoisted = is_sync_fn or is_async_fn;
                if (!is_fn_hoisted) {
                    out_tdz.append(allocator, "default") catch {};
                }
                // Extract binding name for named default function/generator
                // so the bundle can pre-hoist exports["default"] = NAME;
                if (is_fn_hoisted) {
                    var j: usize = if (is_async_fn) @as(usize, 14) else @as(usize, 8);
                    const is_gen_default = j < after_default.len and after_default[j] == '*';
                    if (is_gen_default) j += 1;
                    while (j < after_default.len and after_default[j] == ' ') : (j += 1) {}
                    const name_start = j;
                    while (j < after_default.len and (std.ascii.isAlphanumeric(after_default[j]) or
                        after_default[j] == '_' or after_default[j] == '$')) : (j += 1) {}
                    if (j > name_start) {
                        out_default_fn_binding.append(allocator, after_default[name_start..j]) catch {};
                    } else {
                        // Anonymous default function/generator: use sentinel so the bundle can
                        // pre-hoist exports["default"] = __esm_dflt_fn__ / __esm_dflt_gen__.
                        const sentinel = if (is_gen_default) "__esm_dflt_gen__" else "__esm_dflt_fn__";
                        out_default_fn_binding.append(allocator, sentinel) catch {};
                    }
                }
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
            // export function <name> (hoisted)
            if (std.mem.startsWith(u8, rest, "function ")) {
                var j: usize = 9;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_fn.append(allocator, rest[name_start..j]) catch {}; // function is hoisted
                }
                continue;
            }
            // export function* <name> (generator, hoisted)
            // Check for "function*" (no space) or "function *" (with space)
            if (std.mem.startsWith(u8, rest, "function*") or std.mem.startsWith(u8, rest, "function *")) {
                var j: usize = 8;
                if (j < rest.len and rest[j] == '*') j += 1;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_fn.append(allocator, rest[name_start..j]) catch {}; // generator is hoisted
                }
                continue;
            }
            // export async function <name> (async fn, hoisted)
            if (std.mem.startsWith(u8, rest, "async function ")) {
                var j: usize = 15; // "async function ".len
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_fn.append(allocator, rest[name_start..j]) catch {}; // async fn is hoisted
                }
                continue;
            }
            // export async function* <name> (async generator, hoisted)
            if (std.mem.startsWith(u8, rest, "async function*") or std.mem.startsWith(u8, rest, "async function *")) {
                var j: usize = 14; // "async function".len
                if (j < rest.len and rest[j] == '*') j += 1;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_fn.append(allocator, rest[name_start..j]) catch {}; // async generator is hoisted
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
                    out_tdz.append(allocator, rest[name_start..j]) catch {}; // class is TDZ
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
                    const local_name = rest[local_start..j];
                    const is_tdz_local = tdz_locals.contains(local_name);
                    // Check if followed by 'as' keyword — if so, the identifier
                    // before 'as' is the local name, not the exported name.
                    var k = j;
                    while (k < rest.len and (rest[k] == ' ' or rest[k] == '\t' or rest[k] == '\n')) : (k += 1) {}
                    if (k + 2 < rest.len and std.mem.eql(u8, rest[k..k + 2], "as") and
                        (k + 2 >= rest.len or rest[k + 2] == ' ' or rest[k + 2] == '\t' or rest[k + 2] == '\n' or rest[k + 2] == '}'))
                    {
                        // Skip 'as' and whitespace, then read the exported name.
                        j = k + 2;
                        while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '\n')) : (j += 1) {}
                        const name_start = j;
                        // Handle \uXXXX / \u{XXXX} Unicode-escape identifiers as
                        // exported names (e.g. `export { x as μ }`).
                        if (j + 1 < rest.len and rest[j] == '\\' and rest[j + 1] == 'u') {
                            var cp: u32 = 0;
                            var ei = j + 2;
                            var parsed = false;
                            if (ei < rest.len and rest[ei] == '{') {
                                ei += 1;
                                var any = false;
                                while (ei < rest.len and rest[ei] != '}') : (ei += 1) {
                                    const hv: u32 = switch (rest[ei]) {
                                        '0'...'9' => rest[ei] - '0',
                                        'a'...'f' => rest[ei] - 'a' + 10,
                                        'A'...'F' => rest[ei] - 'A' + 10,
                                        else => 255,
                                    };
                                    if (hv > 15) break;
                                    cp = (cp << 4) | hv;
                                    any = true;
                                }
                                if (ei < rest.len and rest[ei] == '}' and any) { ei += 1; parsed = true; }
                            } else if (ei + 4 <= rest.len) {
                                var ok = true;
                                var ki: usize = 0;
                                while (ki < 4) : (ki += 1) {
                                    const hv: u32 = switch (rest[ei + ki]) {
                                        '0'...'9' => rest[ei + ki] - '0',
                                        'a'...'f' => rest[ei + ki] - 'a' + 10,
                                        'A'...'F' => rest[ei + ki] - 'A' + 10,
                                        else => blk: { ok = false; break :blk 0; },
                                    };
                                    cp = (cp << 4) | hv;
                                }
                                if (ok) { ei += 4; parsed = true; }
                            }
                            if (parsed) {
                                j = ei;
                                // Also consume any following ASCII ident chars.
                                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$' or rest[j] >= 0x80)) : (j += 1) {}
                                // Encode cp to UTF-8
                                var utf8: [4]u8 = undefined;
                                const utf8_len: usize = if (cp <= 0x7F) blk: {
                                    utf8[0] = @intCast(cp); break :blk 1;
                                } else if (cp <= 0x7FF) blk: {
                                    utf8[0] = @intCast(0xC0 | (cp >> 6));
                                    utf8[1] = @intCast(0x80 | (cp & 0x3F));
                                    break :blk 2;
                                } else if (cp <= 0xFFFF) blk: {
                                    utf8[0] = @intCast(0xE0 | (cp >> 12));
                                    utf8[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                                    utf8[2] = @intCast(0x80 | (cp & 0x3F));
                                    break :blk 3;
                                } else 0;
                                if (utf8_len > 0) {
                                    if (allocator.dupe(u8, utf8[0..utf8_len])) |en| {
                                        out.append(allocator, en) catch {};
                                        if (is_tdz_local) out_tdz.append(allocator, en) catch {};
                                    } else |_| {}
                                }
                            }
                        } else {
                            // Regular identifier — accept raw UTF-8 bytes (>= 0x80) too.
                            while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$' or rest[j] >= 0x80)) : (j += 1) {}
                            if (j > name_start) {
                                const exported_name = rest[name_start..j];
                                out.append(allocator, exported_name) catch {};
                                if (is_tdz_local) {
                                    out_tdz.append(allocator, exported_name) catch {};
                                }
                            }
                        }
                    } else {
                        // No 'as' — the identifier itself is the exported name.
                        out.append(allocator, local_name) catch {};
                        if (is_tdz_local) {
                            out_tdz.append(allocator, local_name) catch {};
                        }
                    }
                }
                continue;
            }
            // export let <name> (TDZ)
            if (std.mem.startsWith(u8, rest, "let ")) {
                var j: usize = 4;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_tdz.append(allocator, rest[name_start..j]) catch {}; // let is TDZ
                }
                continue;
            }
            // export var <name> (hoisted, NOT TDZ)
            if (std.mem.startsWith(u8, rest, "var ")) {
                var j: usize = 4;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    // var is NOT added to out_tdz — hoisted, initialized to undefined
                }
                continue;
            }
            // export const <name> (TDZ)
            if (std.mem.startsWith(u8, rest, "const ")) {
                var j: usize = 6;
                while (j < rest.len and rest[j] == ' ') : (j += 1) {}
                const name_start = j;
                while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '$')) : (j += 1) {}
                if (j > name_start) {
                    out.append(allocator, rest[name_start..j]) catch {};
                    out_tdz.append(allocator, rest[name_start..j]) catch {}; // const is TDZ
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
        // Typed (JSON/text) modules are opaque data, not JS — don't scan their
        // contents for nested specifiers (a JSON string value could look like a
        // relative path).
        if (idType(id) == null) scanSpecifiers(src, id, &queue, arena);
    }

    // M16 TLA: classify which modules (and the entry) must evaluate as async
    // factories, and each module's async-dependency id list for the barrier.
    var dep_of = std.StringHashMap([]const []const u8).init(arena);
    var async_set = try computeAsyncSet(arena, &registry, self_id, entry_src, &dep_of);
    // DFS pre-order discovery times from entry — used by asyncDepsList to detect
    // back-edge (cycle-ancestor) deps and redirect cross-SCC deps to their SCC root.
    var dfs_order = computeDfsOrder(arena, &dep_of, self_id);

    var sb = std.ArrayList(u8){};
    errdefer sb.deinit(gpa);
    try sb.appendSlice(gpa, "var __modules__ = {};\n");
    try sb.appendSlice(gpa, "function __exportStarGetter__(s,k){var f=function(){return s[k];};f.__s=s;f.__k=k;return f;}\n");
    // Follow a chain of forwarding getters (star re-exports, live re-exports) down
    // to the root (source object, key) that ultimately backs the binding. Used to
    // decide whether two star-exported names refer to the SAME binding (diamond,
    // unambiguous) or DIFFERENT bindings (ambiguous → must be omitted, ES §16.2.1.6.3).
    // Returns null when the chain is circular (ResolveExport cycle detection: a
    // cyclic re-export path provides no binding and is skipped by the star loop).
    // A module-namespace terminal (`export * as ns from`) canonicalizes to the
    // namespace object itself, so two re-exports of the same namespace compare equal.
    try sb.appendSlice(gpa, "function __starRoot__(s,k){var __ms=Symbol.for('jsz.moduleSource');var seen=[];for(var g=0;g<1000;g++){if(s&&typeof s==='object'&&s[Symbol.toStringTag]==='Module'){var bk=s.__backing__;if(bk)s=bk;}for(var i=0;i<seen.length;i++){if(seen[i][0]===s&&seen[i][1]===k)return null;}seen.push([s,k]);var d=Object.getOwnPropertyDescriptor(s,k);if(d&&d.get&&d.get.__s){s=d.get.__s;k=d.get.__k;continue;}if(d&&('value' in d)&&d.value!=null&&typeof d.value==='object'&&d.value[Symbol.toStringTag]==='Module')return [d.value,'\\u0000ns'];if(d&&d.get&&!d.get.__s){try{var sv=d.get();if(sv!=null&&typeof sv==='object'&&sv[__ms])return [sv,'\\u0000src'];}catch(e){}}if(d&&('value' in d)&&d.value!=null&&typeof d.value==='object'&&d.value[__ms])return [d.value,'\\u0000src'];return [s,k];}return [s,k];}\n");
    try sb.appendSlice(gpa, "var __ambMap__=new WeakMap();\n");
    // When a star-exported name already exists in the target, compare the binding
    // each path resolves to. A null (cyclic) existing path is replaced by a live
    // path; a null incoming path is skipped; differing non-null roots are ambiguous.
    try sb.appendSlice(gpa, "function __exportStar__(t,s){var amb=__ambMap__.get(t);var ks=Object.keys(s);for(var i=0;i<ks.length;i++){var k=ks[i];if(k===\"default\")continue;if(amb&&amb[k])continue;if(Object.prototype.hasOwnProperty.call(t,k)){var ex=Object.getOwnPropertyDescriptor(t,k);if(ex&&ex.get&&ex.get.__star){var r1=__starRoot__(ex.get.__s,ex.get.__k);var r2=__starRoot__(s,k);if(r1===null){if(r2!==null){var g2=__exportStarGetter__(s,k);g2.__star=true;Object.defineProperty(t,k,{get:g2,enumerable:true,configurable:true});}continue;}if(r2===null)continue;if(r1[0]!==r2[0]||r1[1]!==r2[1]){delete t[k];if(!amb){amb={};__ambMap__.set(t,amb);}amb[k]=true;}}continue;}var gg=__exportStarGetter__(s,k);gg.__star=true;Object.defineProperty(t,k,{get:gg,enumerable:true,configurable:true});}}\n");
    try sb.appendSlice(gpa, "function __liveReexport__(e,n,s,p){var g=function(){return s[p];};g.__s=s;g.__k=p;Object.defineProperty(e,n,{get:g,enumerable:true,configurable:true});}\n");
    try sb.appendSlice(gpa, "function __liveLocalExport__(e,n,g){var w={};Object.defineProperty(w,\"v\",{get:g,enumerable:true,configurable:true});__liveReexport__(e,n,w,\"v\");}\n");
    var it = registry.iterator();
    while (it.next()) |e| {
        const mod_id = e.key_ptr.*;
        // Typed (JSON/text) module: emit a synthetic factory whose only export is
        // `default` (the parsed JSON value or the raw text), per the JSON-modules
        // and import-text specs. No import/export desugaring applies to the data.
        if (idType(mod_id)) |ty| {
            try sb.appendSlice(gpa, "__modules__[");
            try appendJsString(gpa, &sb, mod_id);
            try sb.appendSlice(gpa, "] = function(require, module, exports){\nmodule.exports = { default: ");
            if (std.mem.eql(u8, ty, "json")) {
                try sb.appendSlice(gpa, "JSON.parse(");
                try appendJsString(gpa, &sb, e.value_ptr.*);
                try sb.appendSlice(gpa, ")");
            } else if (std.mem.eql(u8, ty, "bytes")) {
                // import-bytes: the default export is an immutable-ArrayBuffer-
                // backed Uint8Array of the file's raw bytes (sec-create-bytes-
                // module). Built in an IIFE so transferToImmutable — which detaches
                // the mutable source buffer — yields a single default-export
                // expression with the bytes frozen and the buffer non-resizable.
                try sb.appendSlice(gpa, "(function(){var __b=[");
                var nbuf: [4]u8 = undefined;
                for (e.value_ptr.*, 0..) |byte, bi| {
                    if (bi > 0) try sb.appendSlice(gpa, ",");
                    try sb.appendSlice(gpa, std.fmt.bufPrint(&nbuf, "{d}", .{byte}) catch "0");
                }
                try sb.appendSlice(gpa, "];var __ab=new ArrayBuffer(__b.length);var __t=new Uint8Array(__ab);for(var __i=0;__i<__b.length;__i++){__t[__i]=__b[__i];}return new Uint8Array(__ab.transferToImmutable());})()");
            } else {
                // text (and any other non-JSON type): the raw source as a string.
                try appendJsString(gpa, &sb, e.value_ptr.*);
            }
            try sb.appendSlice(gpa, " };\n};\n");
            continue;
        }
        const mod_is_async = async_set.contains(mod_id);
        try sb.appendSlice(gpa, "__modules__[\"");
        try sb.appendSlice(gpa, mod_id);
        if (mod_is_async)
            try sb.appendSlice(gpa, "\"] = async function(require, module, exports){\nvar __module_id__ = \"")
        else
            try sb.appendSlice(gpa, "\"] = function(require, module, exports){\nvar __module_id__ = \"");
        try sb.appendSlice(gpa, mod_id);
        try sb.appendSlice(gpa, "\";\n");
        // M16 Phase 4: inject export name setup so the module namespace exotic
        // can detect TDZ (known exports missing from the backing). Scan the
        // source for export names and call __initModuleExports__(exports, [...]).
        var export_names = std.ArrayList([]const u8){};
        var tdz_names = std.ArrayList([]const u8){};
        var fn_names = std.ArrayList([]const u8){};
        var fn_default_binding = std.ArrayList([]const u8){};
        findExportNames(e.value_ptr.*, &export_names, &tdz_names, &fn_names, &fn_default_binding, arena);
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
            try sb.appendSlice(gpa, "],[");
            for (tdz_names.items, 0..) |nm, eni| {
                if (eni > 0) try sb.appendSlice(gpa, ",");
                try sb.appendSlice(gpa, "\"");
                for (nm) |ch| {
                    if (ch == '\\' or ch == '"') try sb.appendSlice(gpa, "\\");
                    try sb.appendSlice(gpa, &.{ch});
                }
                try sb.appendSlice(gpa, "\"");
            }
            try sb.appendSlice(gpa, "]);\n");
            // Hoisted function/generator exports: pre-initialize exports.NAME = NAME
            // before the module body runs so self-imports see the function value.
            for (fn_names.items) |nm| {
                try sb.appendSlice(gpa, "exports.");
                try sb.appendSlice(gpa, nm);
                try sb.appendSlice(gpa, " = ");
                try sb.appendSlice(gpa, nm);
                try sb.appendSlice(gpa, ";\n");
            }
            // Named default function/generator pre-hoist: exports["default"] = NAME
            for (fn_default_binding.items) |bn| {
                try sb.appendSlice(gpa, "exports[\"default\"] = ");
                try sb.appendSlice(gpa, bn);
                try sb.appendSlice(gpa, ";\n");
            }
        }
        // M16 TLA: for an async module, insert an `await __awaitDeps__([...])`
        // barrier after the import prologue so the body runs only once every
        // async dependency has finished evaluating (spec PendingAsyncDependencies).
        const mod_src = e.value_ptr.*;
        const async_deps = asyncDepsList(arena, &async_set, &dep_of, &dfs_order, mod_id);
        if (mod_is_async and async_deps.len > 0) {
            const split = findImportPrologueEnd(mod_src);
            try sb.appendSlice(gpa, mod_src[0..split]);
            try sb.appendSlice(gpa, "\n");
            try emitAwaitDeps(gpa, &sb, async_deps);
            try sb.appendSlice(gpa, mod_src[split..]);
        } else {
            try sb.appendSlice(gpa, mod_src);
        }
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
    // M16: the host (test262 runner) may prepend a harness prelude (assert/sta/
    // $262) to the entry, separated by this sentinel.  The prelude must live at
    // bundle (module) scope — NOT inside the entry IIFE — so that *dependency*
    // modules (e.g. a re-export fixture that is itself a harness-using test file)
    // see `assert` etc. via the scope chain when their factory runs.  Only the
    // actual entry body (after the sentinel) is wrapped in the IIFE.
    const PRELUDE_SENTINEL = "/*__JSZ_PRELUDE_END__*/";
    var prelude_part: []const u8 = "";
    var body_part: []const u8 = entry_src;
    if (std.mem.indexOf(u8, entry_src, PRELUDE_SENTINEL)) |pi| {
        prelude_part = entry_src[0..pi];
        body_part = entry_src[pi + PRELUDE_SENTINEL.len ..];
    }
    // M16 Phase 4: inject export name setup for the entry module too.
    var entry_names = std.ArrayList([]const u8){};
    var entry_tdz = std.ArrayList([]const u8){};
    var entry_fn = std.ArrayList([]const u8){};
    var entry_default_fn = std.ArrayList([]const u8){};
    findExportNames(body_part, &entry_names, &entry_tdz, &entry_fn, &entry_default_fn, arena);
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
        try sb.appendSlice(gpa, "],[");
        for (entry_tdz.items, 0..) |nm, eni| {
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
    // Emit the harness prelude at module scope, BEFORE the hoist point — the
    // entry's own hoisted imports run at the hoist marker and may require()
    // dependency modules that need the harness globals already defined.
    if (prelude_part.len > 0) {
        try sb.appendSlice(gpa, prelude_part);
        try sb.appendSlice(gpa, "\n");
    }
    // M16 TLA: compute entry_is_async here (before the hoist marker) so we can
    // choose the right marker variant.
    const entry_is_async = async_set.contains(self_id);
    // M16 Phase 5: marker for the parser to identify where entry body starts.
    // For sync entries with function exports we use the `_no_se` variant: named
    // imports are still hoisted (so their `var __esm_N__` lives at module scope)
    // but bare side-effect imports stay in the IIFE body so they run AFTER the
    // pre-hoist `exports.fn = fn` assignments at the top of the IIFE.  This
    // guarantees that circular deps which import the entry's function exports see
    // them as callable (not undefined) when their factory runs.
    // For async entries or entries without function exports the original marker
    // hoists all imports — async entries need deps loaded before __awaitDeps__.
    if (!entry_is_async and entry_fn.items.len > 0) {
        try sb.appendSlice(gpa, "var __esm_hoist_point_no_se__=1;\n");
    } else {
        try sb.appendSlice(gpa, "var __esm_hoist_point__=1;\n");
    }
    // M16 Phase 5: wrap the entry body in an IIFE so its function/class/var
    // declarations are scoped to the IIFE, NOT the module scope.  Without this,
    // hoisted function declarations from the entry body (e.g. `export function A()`)
    // would be visible inside dependency factory function bodies via the scope
    // chain, causing tests that expect ReferenceError for re-export import names
    // to incorrectly find the hoisted function.  The IIFE receives require/module/
    // exports from the module scope so imports/exports still work; hoisted import
    // vars (inserted at the hoist point above) are also in the module scope and
    // accessible from the IIFE.
    // M16 TLA: the entry runs as an async IIFE when it (transitively) depends on
    // an async module or itself has top-level await, so its body can `await` the
    // dependency barrier / suspend at its own top-level awaits.
    if (entry_is_async)
        try sb.appendSlice(gpa, "(async function(require,module,exports){\"use strict\";\n")
    else
        try sb.appendSlice(gpa, "(function(require,module,exports){\"use strict\";\n");
    // Pre-hoist function/generator exports INSIDE the IIFE so the function
    // declaration (hoisted within the IIFE) is available for exports.NAME = NAME.
    for (entry_fn.items) |nm| {
        try sb.appendSlice(gpa, "exports.");
        try sb.appendSlice(gpa, nm);
        try sb.appendSlice(gpa, " = ");
        try sb.appendSlice(gpa, nm);
        try sb.appendSlice(gpa, ";\n");
    }
    // Named default function/generator pre-hoist for entry module.
    for (entry_default_fn.items) |bn| {
        try sb.appendSlice(gpa, "exports[\"default\"] = ");
        try sb.appendSlice(gpa, bn);
        try sb.appendSlice(gpa, ";\n");
    }
    // M16 TLA: the entry's static imports are hoisted to module scope (before the
    // IIFE runs), so all dependency `require()`s have completed; barrier here
    // awaits any async dependency's evaluation-completion promise before the body.
    if (entry_is_async) {
        const entry_async_deps = asyncDepsList(arena, &async_set, &dep_of, &dfs_order, self_id);
        if (entry_async_deps.len > 0) try emitAwaitDeps(gpa, &sb, entry_async_deps);
    }
    try sb.appendSlice(gpa, body_part);
    if (entry_is_async)
        // Record an unhandled rejection of the entry's async evaluation (spec
        // Evaluate() promise rejection) so the host can surface it as the eval
        // exception (negative module tests / uncaught async module errors).
        try sb.appendSlice(gpa, "\n})(require,module,exports).then(void 0,__jszModuleReject__);\n")
    else
        try sb.appendSlice(gpa, "\n})(require,module,exports);\n");
    const result = try sb.toOwnedSlice(gpa);
    if (std.posix.getenv("JSZ_DUMP_BUNDLE") != null) {
        const f = std.fs.cwd().createFile("/tmp/bundle_dump.js", .{}) catch return result;
        defer f.close();
        _ = f.writeAll(result) catch {};
    }
    return result;
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
