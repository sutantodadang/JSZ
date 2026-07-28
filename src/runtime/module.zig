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
const parser_mod = @import("../parser/parser.zig");

/// True when `src` is parseable as the body of a bundle module factory. A module
/// whose source has a syntax error must NOT be inlined verbatim into the bundle:
/// doing so makes the *whole* bundle fail to parse, which surfaces as a spurious
/// parse error for the entry test rather than a runtime rejection. Instead such a
/// module gets a factory that throws a SyntaxError when first required (matching
/// the spec: a module with a parse error rejects/throws at evaluation, e.g.
/// `ShadowRealm.prototype.importValue` rejects with a TypeError).
///
/// The check mirrors exactly how a module body is embedded: wrapped in an
/// `async function(require, module, exports){ ... }` (async covers top-level
/// await; the function wrapper covers any construct legal inside the factory),
/// with template literals rewritten the same way the runtime does before
/// evaluating the bundle. If even that wrapped form fails to parse, the module is
/// genuinely unparseable and would otherwise break the bundle.
fn moduleSourceParses(gpa: std.mem.Allocator, src: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wrapped = std.fmt.allocPrint(
        arena,
        "(async function(require, module, exports){{\n{s}\n}});\n",
        .{src},
    ) catch return true; // OOM: don't misclassify as a syntax error.
    const isolate_mod = @import("../vm/isolate.zig");
    const rewritten = isolate_mod.rewriteTemplateLiterals(arena, wrapped) catch return true;
    var p = parser_mod.Parser.init(rewritten, arena);
    return switch (p.parseScript()) {
        .ok => true,
        .err => false,
    };
}

/// True when `name` is a compiler-synthesised binding (the class/destructuring/
/// import desugars mint `__…__` helpers). Such names are not user-visible
/// declarations, so the module-goal early-error scan must ignore them.
fn isSyntheticBinding(name: []const u8) bool {
    return name.len >= 2 and name[0] == '_' and name[1] == '_';
}

/// VarDeclaredNames of a statement (§8.2.6): every `var` binding reachable
/// through *statement* nesting. Deliberately does not descend into function or
/// class bodies — those open a new variable scope.
fn collectVarDeclaredNames(node: *ast.Node, out: *std.StringHashMap(void)) void {
    switch (node.kind) {
        .var_decl => if (node.data.var_decl.kind == .var_) {
            out.put(node.data.var_decl.name, {}) catch {};
        },
        .block_stmt => for (node.data.block_stmt.body) |c| collectVarDeclaredNames(c, out),
        .if_stmt => {
            collectVarDeclaredNames(node.data.if_stmt.consequent, out);
            if (node.data.if_stmt.alternate) |a| collectVarDeclaredNames(a, out);
        },
        .while_stmt => collectVarDeclaredNames(node.data.while_stmt.body, out),
        .do_while_stmt => collectVarDeclaredNames(node.data.do_while_stmt.body, out),
        .with_stmt => collectVarDeclaredNames(node.data.with_stmt.body, out),
        .for_stmt => {
            if (node.data.for_stmt.init) |i| collectVarDeclaredNames(i, out);
            collectVarDeclaredNames(node.data.for_stmt.body, out);
        },
        .for_in_stmt => {
            collectVarDeclaredNames(node.data.for_in_stmt.left, out);
            collectVarDeclaredNames(node.data.for_in_stmt.body, out);
        },
        .try_stmt => {
            collectVarDeclaredNames(node.data.try_stmt.block, out);
            if (node.data.try_stmt.handler) |h| collectVarDeclaredNames(h.body, out);
            if (node.data.try_stmt.finalizer) |f| collectVarDeclaredNames(f, out);
        },
        .switch_stmt => for (node.data.switch_stmt.cases) |c| {
            for (c.body) |s| collectVarDeclaredNames(s, out);
        },
        .labeled_stmt => collectVarDeclaredNames(node.data.labeled_stmt.body, out),
        else => {},
    }
}

/// LexicallyDeclaredNames of a *module* top-level item: `let`/`const`/`class`
/// plus — unlike a Script — `function`/`function*`/`async function`, which is
/// exactly what makes `var x; function x(){}` legal script code but illegal
/// module code.
///
/// A `block_stmt` with `lexical_scope == false` is a synthetic container the
/// desugars emit (class declarations, multi-declarator lowering) whose bindings
/// belong to the enclosing scope, so it is transparent here; a real block is not.
fn collectTopLexicalNames(
    node: *ast.Node,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) void {
    switch (node.kind) {
        .var_decl => if (node.data.var_decl.kind != .var_) {
            out.append(allocator, node.data.var_decl.name) catch {};
        },
        .function_decl => out.append(allocator, node.data.function_decl.name) catch {},
        .block_stmt => if (!node.data.block_stmt.lexical_scope) {
            for (node.data.block_stmt.body) |c| collectTopLexicalNames(c, out, allocator);
        },
        else => {},
    }
}

/// ModuleBody early errors that a *Script*-goal parse cannot see (§16.2.1.5):
///
///   - LexicallyDeclaredNames of ModuleItemList contains duplicate entries;
///   - any LexicallyDeclaredName also occurs in VarDeclaredNames.
///
/// Top-level `function` declarations are lexical in a Module but var-scoped in a
/// Script, so `var smoosh; function smoosh() {}` is legal Script code and a
/// SyntaxError as module code — and `moduleSourceParses` cannot tell, because it
/// wraps the source in a function (i.e. re-parses it under the Script goal).
///
/// Conservative by construction: a source that does not parse at all returns
/// false (that is `moduleSourceParses`'s job), synthetic `__…__` desugar bindings
/// are ignored, and the duplicate check only looks at directly-declared top-level
/// names. A false negative costs a test; a false positive breaks a valid module.
fn moduleGoalEarlyError(gpa: std.mem.Allocator, src: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const isolate_mod = @import("../vm/isolate.zig");
    const rewritten = isolate_mod.rewriteTemplateLiterals(arena, src) catch return false;
    var p = parser_mod.Parser.init(rewritten, arena);
    const stmts = switch (p.parseModule()) {
        .ok => |s| s,
        .err => return false,
    };

    var vars = std.StringHashMap(void).init(arena);
    var lex = std.ArrayList([]const u8){};
    var direct = std.ArrayList([]const u8){};
    for (stmts) |s| {
        collectVarDeclaredNames(s, &vars);
        collectTopLexicalNames(s, &lex, arena);
        switch (s.kind) {
            .var_decl => if (s.data.var_decl.kind != .var_) {
                direct.append(arena, s.data.var_decl.name) catch {};
            },
            .function_decl => direct.append(arena, s.data.function_decl.name) catch {},
            else => {},
        }
    }
    for (lex.items) |n| {
        if (isSyntheticBinding(n)) continue;
        if (vars.contains(n)) return true;
    }
    var seen = std.StringHashMap(void).init(arena);
    for (direct.items) |n| {
        if (isSyntheticBinding(n)) continue;
        if (seen.contains(n)) return true;
        seen.put(n, {}) catch {};
    }
    return false;
}

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

/// Best-effort collection of `const|let|var NAME = 'STRING';` single-literal
/// initializers in `src`, keyed by `NAME`. Used only to reconstruct dynamic
/// `import(x + a)` / `import(x += a)` specifiers built by concatenating
/// string-literal-valued identifiers — a shape a real host resolves at
/// runtime (`ToString` of the evaluated argument) but which this ahead-of-time
/// bundler must reconstruct statically to know which on-disk fixture to link.
/// Anything more complex than a bare literal initializer is simply absent from
/// the map, so a concatenation referencing it fails closed (discovers
/// nothing) rather than guessing.
fn collectStringBindings(src: []const u8, out: *std.StringHashMap([]const u8)) void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const ws = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            const word = src[ws..i];
            if (!(std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "let") or std.mem.eql(u8, word, "var"))) continue;
            var j = skipWsComments(src, i);
            if (j >= src.len or !(isIdentChar(src[j]) and !std.ascii.isDigit(src[j]))) continue;
            const ns = j;
            while (j < src.len and isIdentChar(src[j])) : (j += 1) {}
            const name = src[ns..j];
            j = skipWsComments(src, j);
            if (j >= src.len or src[j] != '=') continue;
            j = skipWsComments(src, j + 1);
            if (j >= src.len or !(src[j] == '"' or src[j] == '\'')) continue;
            const q = src[j];
            const s = j + 1;
            var k = s;
            while (k < src.len and src[k] != q) : (k += 1) {
                if (src[k] == '\\') k += 1;
            }
            out.put(name, src[s..@min(k, src.len)]) catch {};
            i = k + 1;
            continue;
        }
        i += 1;
    }
}

/// Parse a `+`/`+=`-joined run of string-literal or bound-identifier terms
/// starting right after the `(` at `paren_open` in an `import(...)` call,
/// stopping at the first top-level `,` or the matching `)`. Returns the
/// concatenated string when every term resolves (a literal, or a name found in
/// `bindings`); null the moment anything else appears (a call, member access,
/// number, etc.) — this "fails closed" rather than guessing at a specifier.
fn tryResolveConcatSpecifier(src: []const u8, paren_open: usize, bindings: *const std.StringHashMap([]const u8), allocator: std.mem.Allocator) ?[]const u8 {
    var i = paren_open + 1;
    var buf: std.ArrayList(u8) = .empty;
    var any_term = false;
    while (true) {
        i = skipWsComments(src, i);
        if (i >= src.len) return null;
        const c = src[i];
        if (c == '"' or c == '\'') {
            const s = i + 1;
            var k = s;
            while (k < src.len and src[k] != c) : (k += 1) {
                if (src[k] == '\\') k += 1;
            }
            buf.appendSlice(allocator, src[s..@min(k, src.len)]) catch return null;
            i = k + 1;
            any_term = true;
        } else if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const ns = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            const val = bindings.get(src[ns..i]) orelse return null;
            buf.appendSlice(allocator, val) catch return null;
            any_term = true;
        } else return null;
        i = skipWsComments(src, i);
        if (i >= src.len) return null;
        if (src[i] == ')' or src[i] == ',') break;
        if (src[i] != '+') return null;
        i += 1;
        if (i < src.len and src[i] == '=') i += 1; // tolerate `+=` as one token
    }
    if (!any_term) return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Append canonical ids of relative module specifiers found in `src` (resolved
/// against `importer_id`) to `out`. Skips line/block comments and treats string
/// and template-literal bodies as opaque (except for specifier discovery, see
/// below), so prose apostrophes/quotes inside comments cannot be mistaken for
/// specifier delimiters.
///
/// Bundling-only permissiveness beyond the literal `"./…"` case: a *static*
/// (no `${}` substitution) template-literal specifier is checked the same way
/// a string literal is (covers `import(tag\`./x.js\`)`); a string literal that
/// itself looks like it embeds a nested `import('./x.js')` is recursively
/// scanned (covers `eval("import('./x.js')")`); and `import(x + a)` /
/// `import(x += a)` calls are resolved via `tryResolveConcatSpecifier` when
/// every operand is a literal or a simply-bound identifier.
pub fn scanSpecifiers(src: []const u8, importer_id: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var bindings: ?std.StringHashMap([]const u8) = null;
    var prev_word: []const u8 = "";
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
        // Template literal. Real dynamic-import specifiers are never template
        // literals with substitutions (a `${}` value can't be known statically
        // here), but a *static* one — e.g. `import(tag\`./x.js\`)` — is exactly
        // as discoverable as a plain string literal.
        if (c == '`') {
            const start = i + 1;
            var j = start;
            var has_subst = false;
            while (j < src.len and src[j] != '`') : (j += 1) {
                if (src[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (src[j] == '$' and j + 1 < src.len and src[j + 1] == '{') has_subst = true;
            }
            if (!has_subst and j <= src.len) {
                const end = @min(j, src.len);
                const lit = src[start..end];
                if (std.mem.startsWith(u8, lit, "./") or std.mem.startsWith(u8, lit, "../")) {
                    var id = resolveSpec(allocator, importer_id, lit) catch "";
                    if (id.len > 0) {
                        if (attrTypeAfter(src, j + 1, lit)) |ty| {
                            id = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ id, ty }) catch id;
                        }
                        out.append(allocator, id) catch {};
                    }
                }
            }
            i = j + 1;
            prev_word = "";
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
                        if (attrTypeAfter(src, j + 1, lit)) |ty| {
                            id = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ id, ty }) catch id;
                        }
                        out.append(allocator, id) catch {};
                    }
                } else if (std.mem.indexOf(u8, lit, "import") != null and std.mem.indexOf(u8, lit, "./") != null) {
                    // Heuristic: a string (typically an `eval()` argument) that
                    // itself textually contains a dynamic `import(` and a
                    // relative path. Recurse so a specifier nested inside a
                    // string isn't invisible to the bundler. Bounded: each
                    // recursion operates on a strictly smaller slice.
                    scanSpecifiers(lit, importer_id, out, allocator);
                }
            }
            i = j + 1;
            prev_word = "";
            continue;
        }
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const ws = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            prev_word = src[ws..i];
            continue;
        }
        if (c == '(' and std.mem.eql(u8, prev_word, "import")) {
            if (bindings == null) {
                var b = std.StringHashMap([]const u8).init(allocator);
                collectStringBindings(src, &b);
                bindings = b;
            }
            if (tryResolveConcatSpecifier(src, i, &bindings.?, allocator)) |spec| {
                if (std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../")) {
                    const id = resolveSpec(allocator, importer_id, spec) catch "";
                    if (id.len > 0) out.append(allocator, id) catch {};
                }
            }
        }
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') prev_word = "";
        i += 1;
    }
}

/// Append the canonical ids of *static* import/export specifiers in `src`
/// (resolved against `importer_id`) — those introduced by an import/export
/// declaration (`import ... from "spec"`, bare `import "spec"`, `export ... from
/// "spec"`), but NOT dynamic `import("spec")`. Static edges are the ones a
/// module's load depends on, so they (and not dynamic imports) propagate eager
/// resolution-error taint. A specifier qualifies when the immediately preceding
/// significant word is `from`, or `import`/`export` directly followed by the
/// string (bare side-effect import). Comment/string/template aware.
fn scanStaticSpecifiers(src: []const u8, importer_id: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var i: usize = 0;
    // The last significant identifier word seen ("from"/"import"/"export"/other).
    var prev_word: []const u8 = "";
    while (i < src.len) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        if (c == '`') {
            i += 1;
            while (i < src.len and src[i] != '`') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            prev_word = "";
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i + 1;
            var j = start;
            while (j < src.len and src[j] != c) : (j += 1) {
                if (src[j] == '\\') j += 1;
            }
            const lit = src[start..@min(j, src.len)];
            const is_static = std.mem.eql(u8, prev_word, "from") or
                std.mem.eql(u8, prev_word, "import") or std.mem.eql(u8, prev_word, "export");
            if (is_static and (std.mem.startsWith(u8, lit, "./") or std.mem.startsWith(u8, lit, "../"))) {
                var id = resolveSpec(allocator, importer_id, lit) catch "";
                if (id.len > 0) {
                    if (attrTypeAfter(src, j + 1, lit)) |ty| {
                        id = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ id, ty }) catch id;
                    }
                    out.append(allocator, id) catch {};
                }
            }
            i = j + 1;
            prev_word = "";
            continue;
        }
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const ws = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            prev_word = src[ws..i];
            continue;
        }
        // A `(` right after `import` makes it a dynamic import — clear the marker
        // so the specifier inside is not treated as a static edge.
        if (c == '(') prev_word = "";
        // Any non-identifier token other than skipped whitespace ends the word.
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') {
            if (c != '(') prev_word = "";
        }
        i += 1;
    }
}

/// Match the keyword `word` as a standalone token at `*i` (after skipping ws/
/// comments). On success advance `*i` past the word and return true.
fn matchKeyword(src: []const u8, i: *usize, word: []const u8) bool {
    const start = skipWsComments(src, i.*);
    if (start + word.len > src.len) return false;
    if (!std.mem.eql(u8, src[start .. start + word.len], word)) return false;
    if (start + word.len < src.len and isIdentChar(src[start + word.len])) return false;
    i.* = start + word.len;
    return true;
}

/// Append the canonical ids of `import defer * as <name> from '<spec>'` static
/// deferred imports found in `src` (resolved against `importer_id`). Used by the
/// bundler to distinguish deferred dependency edges from ordinary ones: per the
/// import-defer × TLA spec (InnerModuleEvaluation), a deferred dependency does
/// not make the importer wait for the module itself — instead its asynchronous
/// transitive dependencies (TLA frontier) are evaluated eagerly. Comment/string/
/// template aware so a deferred-import-shaped string/comment is not matched.
pub fn scanDeferredSpecifiers(src: []const u8, importer_id: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // Comments.
        if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        // Strings / templates: opaque.
        if (c == '"' or c == '\'' or c == '`') {
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        // Identifier / keyword.
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const ws = i;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            if (!std.mem.eql(u8, src[ws..i], "import")) continue;
            // Match the exact `defer * as <ident> from "<spec>"` shape.
            var j = i;
            if (!matchKeyword(src, &j, "defer")) continue;
            j = skipWsComments(src, j);
            if (j >= src.len or src[j] != '*') continue;
            j += 1;
            if (!matchKeyword(src, &j, "as")) continue;
            j = skipWsComments(src, j);
            if (j >= src.len or !(isIdentChar(src[j]) and !std.ascii.isDigit(src[j]))) continue;
            while (j < src.len and isIdentChar(src[j])) : (j += 1) {}
            if (!matchKeyword(src, &j, "from")) continue;
            j = skipWsComments(src, j);
            if (j >= src.len or !(src[j] == '"' or src[j] == '\'')) continue;
            const q = src[j];
            const s = j + 1;
            var k = s;
            while (k < src.len and src[k] != q) : (k += 1) {
                if (src[k] == '\\') k += 1;
            }
            const lit = src[s..@min(k, src.len)];
            if (std.mem.startsWith(u8, lit, "./") or std.mem.startsWith(u8, lit, "../")) {
                var id = resolveSpec(allocator, importer_id, lit) catch "";
                if (id.len > 0) {
                    if (attrTypeAfter(src, k + 1, lit)) |ty| {
                        id = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ id, ty }) catch id;
                    }
                    out.append(allocator, id) catch {};
                }
            }
            i = k + 1;
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

/// Scan a `{ ... }` object body whose opening brace sits at `brace_pos` for a
/// top-level string-valued `type` key (e.g. `{ type: 'json' }`). Returns the
/// string value, or null if absent. Shared core for both the static
/// `with {...}` import-attribute clause and the object literal nested inside a
/// dynamic `import(spec, { with: { type: '...' } })` call (see
/// `findWithAttrType` below).
fn scanTypeKeyInBraces(src: []const u8, brace_pos: usize) ?[]const u8 {
    var i = brace_pos + 1;
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

/// Index just past the `}` matching the `{` at `open_pos` (comment/string/
/// template aware), or `src.len` if unterminated.
fn matchingBraceEnd(src: []const u8, open_pos: usize) usize {
    var i = open_pos + 1;
    var depth: usize = 1;
    while (i < src.len and depth > 0) {
        const c = src[i];
        if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            i += 1;
            while (i < src.len and src[i] != c) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            depth -= 1;
            i += 1;
            continue;
        }
        i += 1;
    }
    return i;
}

/// Search the object-literal body starting at `from` (up to `end_limit`,
/// exclusive) for a top-level `with`/`assert` key mapped to a nested object,
/// and return that nested object's `type` value. Used to read the *dynamic*
/// `import(specifier, { with: { type: '...' } })` call-expression's second
/// argument — an ordinary object-literal expression, not the static `with
/// {...}` clause grammar. Comment/string aware; ignores unrelated keys.
fn findWithAttrType(src: []const u8, from: usize, end_limit: usize) ?[]const u8 {
    var i = from;
    const limit = @min(end_limit, src.len);
    while (i < limit) {
        const c = src[i];
        if (c == '/' and i + 1 < limit and (src[i + 1] == '/' or src[i + 1] == '*')) {
            i = skipWsComments(src, i);
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            i += 1;
            while (i < limit and src[i] != c) : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (isIdentChar(c) and !std.ascii.isDigit(c)) {
            const s = i;
            while (i < limit and isIdentChar(src[i])) : (i += 1) {}
            const word = src[s..i];
            if (std.mem.eql(u8, word, "with") or std.mem.eql(u8, word, "assert")) {
                var j = skipWsComments(src, i);
                if (j < limit and src[j] == ':') {
                    j = skipWsComments(src, j + 1);
                    if (j < limit and src[j] == '{') {
                        if (scanTypeKeyInBraces(src, j)) |ty| return ty;
                    }
                }
            }
            continue;
        }
        i += 1;
    }
    return null;
}

/// If a `with { type: '...' }` / `assert { ... }` import-attribute clause begins
/// at `pos` (after optional whitespace/comments), return the `type` attribute's
/// string value (e.g. "json", "text"); otherwise null. Used by `scanSpecifiers`
/// to classify a discovered specifier as a typed (synthetic) module.
///
/// Also recognizes the *dynamic* `import(specifier, optionsExpr)` call shape,
/// where `pos` lands right after the specifier's closing quote and the next
/// significant token is `,` rather than `with`/`assert` directly: when the
/// second argument is an inline object literal (`{ with: { type: '...' } }`),
/// extract the type the same way the runtime's `importReadTypeAttr` would.
/// When the second argument isn't statically readable (a variable, a Proxy —
/// e.g. `import(spec, options)`), fall back to the specifier's own file
/// extension (`.json`) for bundling purposes only: a wrong guess here just
/// means an unused synthetic registry entry, never a false rejection of a real
/// one, since the actual type used for lookup is always computed at runtime.
fn attrTypeAfter(src: []const u8, pos: usize, spec_hint: []const u8) ?[]const u8 {
    var i = skipWsComments(src, pos);
    // Match the `with` / `assert` keyword as a standalone word (the static
    // import-attribute clause grammar).
    const kw_with = i + 4 <= src.len and std.mem.eql(u8, src[i .. i + 4], "with") and
        (i + 4 == src.len or !isIdentChar(src[i + 4]));
    const kw_assert = i + 6 <= src.len and std.mem.eql(u8, src[i .. i + 6], "assert") and
        (i + 6 == src.len or !isIdentChar(src[i + 6]));
    if (kw_with) {
        i += 4;
    } else if (kw_assert) {
        i += 6;
    } else if (i < src.len and src[i] == ',') {
        // Dynamic `import(spec, optionsExpr)`: the second argument is an
        // ordinary expression, evaluated at runtime — not the static clause.
        const j = skipWsComments(src, i + 1);
        if (j < src.len and src[j] == '{') {
            const end = matchingBraceEnd(src, j);
            if (findWithAttrType(src, j + 1, if (end > 0) end - 1 else j + 1)) |ty| return ty;
        }
        if (std.mem.endsWith(u8, spec_hint, ".json")) return "json";
        return null;
    } else return null;
    i = skipWsComments(src, i);
    if (i >= src.len or src[i] != '{') return null;
    return scanTypeKeyInBraces(src, i);
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
/// Recursive worker for `gatherAsyncTransitive`: walk `id`'s dependency graph,
/// appending each top-level-await module reached through non-TLA modules to
/// `out` (deduplicated). Stops descending at a TLA module (its own async deps
/// are reached when it itself evaluates) and at typed (data) modules.
fn gatherInto(
    arena: std.mem.Allocator,
    tla_set: *std.StringHashMap(void),
    dep_of: *std.StringHashMap([]const []const u8),
    id: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList([]const u8),
) void {
    if (seen.contains(id)) return;
    seen.put(id, {}) catch {};
    if (idType(id) != null) return; // typed (data) module: not a Cyclic Module Record
    if (tla_set.contains(id)) {
        for (out.items) |x| if (std.mem.eql(u8, x, id)) return;
        out.append(arena, id) catch {};
        return;
    }
    const ds = dep_of.get(id) orelse return;
    for (ds) |d| gatherInto(arena, tla_set, dep_of, d, seen, out);
}

/// GatherAsynchronousTransitiveDependencies (import-defer × TLA spec op,
/// sec-innermoduleevaluation): the frontier of top-level-await modules reachable
/// from `id` through non-TLA modules. When `id` is deferred-imported, these
/// frontier modules must be evaluated *eagerly* (async evaluation cannot be done
/// lazily on a synchronous namespace access), while `id` itself stays deferred.
fn gatherAsyncTransitive(
    arena: std.mem.Allocator,
    tla_set: *std.StringHashMap(void),
    dep_of: *std.StringHashMap([]const []const u8),
    id: []const u8,
) []const []const u8 {
    var out = std.ArrayList([]const u8){};
    var seen = std.StringHashMap(void).init(arena);
    gatherInto(arena, tla_set, dep_of, id, &seen, &out);
    return out.items;
}

/// True when `dep` is a deferred-import dependency of `id`.
fn isDeferredEdge(deferred_of: *std.StringHashMap([]const []const u8), id: []const u8, dep: []const u8) bool {
    const list = deferred_of.get(id) orelse return false;
    for (list) |d| if (std.mem.eql(u8, d, dep)) return true;
    return false;
}

fn asyncDepsList(
    arena: std.mem.Allocator,
    async_set: *std.StringHashMap(void),
    dep_of: *std.StringHashMap([]const []const u8),
    dfs_order: *std.StringHashMap(usize),
    deferred_of: *std.StringHashMap([]const []const u8),
    tla_set: *std.StringHashMap(void),
    id: []const u8,
) []const []const u8 {
    const deps = dep_of.get(id) orelse return &[_][]const u8{};
    var out = std.ArrayList([]const u8){};
    var seen = std.StringHashMap(void).init(arena);
    const my_order = dfs_order.get(id) orelse std.math.maxInt(usize);
    for (deps) |d| {
        // Deferred edge: the importer does not wait for the deferred module, but
        // for its eagerly-evaluated async transitive dependencies (TLA frontier).
        if (isDeferredEdge(deferred_of, id, d)) {
            for (gatherAsyncTransitive(arena, tla_set, dep_of, d)) |g| {
                if (seen.contains(g)) continue;
                seen.put(g, {}) catch {};
                out.append(arena, g) catch {};
            }
            continue;
        }
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

// ------------------------------------------------ static export resolution ---
//
// The CJS desugar links names lazily at *runtime* (`__exportStar__` copies the
// keys it can see, dropping the ones two star paths disagree about), which is
// the right shape for the legal cases but cannot report the two *link-time*
// failures the spec demands: §16.2.1.6.4 InitializeEnvironment step 3 says every
// IndirectExportEntry must resolve, and §16.2.1.6.3 ResolveExport returns null
// for a circular re-export chain and "ambiguous" when two `export *` paths reach
// different bindings of the same name. Both are SyntaxErrors raised before the
// module ever evaluates.
//
// So run ResolveExport statically over the graph the disk DFS already
// discovered, and give any module with an unresolvable indirect export a
// throwing factory. Note this keys strictly off IndirectExportEntries: star
// ambiguity on its own is legal (the name is simply excluded from the
// namespace), which is exactly what `__exportStar__`/`__ambMap__` keep doing.
//
// The scanners below are the same hand-rolled character scanners as the rest of
// this file, so every verdict is opt-in: anything the scanner cannot model
// exactly sets `unsure`, and resolution through an unsure module returns
// `.unknown`, which suppresses the error. A false negative costs a test; a false
// positive turns a working module into a hard SyntaxError.

/// The spec's IndirectExportEntry — `export { importName as exportName } from
/// moduleRequest` — with the provenance `findExportNames` flattens away.
const IndirectExportEntry = struct {
    export_name: []const u8,
    /// Canonical id of the requested module.
    module_id: []const u8,
    import_name: []const u8,
};

/// The export entries of one module, split as in §16.2.1.6.1.
const ExportEntries = struct {
    /// ExportName of every LocalExportEntry, plus `export * as ns from` and
    /// re-exports of a namespace import — those resolve to a namespace object,
    /// which always exists, so they behave like a local binding here.
    locals: []const []const u8 = &.{},
    indirects: []const IndirectExportEntry = &.{},
    /// ModuleRequest ids of the StarExportEntries.
    stars: []const []const u8 = &.{},
    /// The scanner met something it cannot model exactly (string-literal or
    /// escaped export names, a bare/absolute/typed specifier, an unrecognised
    /// `import`/`export` form). Never report a failure for — or through — such
    /// a module.
    unsure: bool = false,
};

/// Where an imported local name comes from. `import_name.len == 0` marks a
/// namespace import (`import * as ns`), whose re-export never fails to resolve.
const ImportBinding = struct {
    module_id: []const u8,
    import_name: []const u8,
};

/// Read an identifier at (or after whitespace/comments following) `i.*`,
/// advancing `i.*` past it. Returns null for a string literal, a `\uXXXX`
/// escaped name, or anything that is not an identifier — all callers treat
/// that as "cannot model".
fn readIdentAt(src: []const u8, i: *usize) ?[]const u8 {
    const s = skipWsComments(src, i.*);
    if (s >= src.len) return null;
    const c = src[s];
    if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80)) return null;
    var j = s;
    while (j < src.len and (isIdentChar(src[j]) or src[j] >= 0x80)) : (j += 1) {}
    i.* = j;
    return src[s..j];
}

/// Read a module-request string literal at `i.*` and resolve it against
/// `importer_id`. Returns null (and still advances past the literal when there
/// was one) for a non-relative specifier or one carrying a `with { type: … }`
/// attribute — a typed module is opaque data, not a source text module.
fn readSpecifierAt(
    src: []const u8,
    i: *usize,
    importer_id: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const s = skipWsComments(src, i.*);
    if (s >= src.len) return null;
    const q = src[s];
    if (q != '"' and q != '\'') return null;
    var j = s + 1;
    while (j < src.len and src[j] != q) : (j += 1) {
        if (src[j] == '\\') j += 1;
    }
    if (j >= src.len) return null;
    const lit = src[s + 1 .. j];
    i.* = j + 1;
    if (attrTypeAfter(src, j + 1, lit) != null) return null;
    if (std.mem.indexOfScalar(u8, lit, '\\') != null) return null;
    if (!std.mem.startsWith(u8, lit, "./") and !std.mem.startsWith(u8, lit, "../")) return null;
    return resolveSpec(allocator, importer_id, lit) catch null;
}

/// Forward token walk shared by the export-entry scanners: skips comments,
/// strings and template literals, and yields each identifier-like word together
/// with the previous significant character — so `obj.export` can be told apart
/// from a real `export` declaration without scanning backwards over comment text
/// (a license header ending in "file." would otherwise look like a member access).
const WordScan = struct {
    src: []const u8,
    i: usize = 0,
    /// Last significant (non-whitespace, non-comment) byte before `word`.
    prev: u8 = 0,

    const Word = struct { text: []const u8, prev: u8, end: usize };

    fn next(self: *WordScan) ?Word {
        const src = self.src;
        while (self.i < src.len) {
            const c = src[self.i];
            if (c == '/' and self.i + 1 < src.len and (src[self.i + 1] == '/' or src[self.i + 1] == '*')) {
                const nxt = skipWsComments(src, self.i);
                self.i = if (nxt > self.i) nxt else self.i + 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
                continue;
            }
            if (c == '`' or c == '"' or c == '\'') {
                self.i = skipQuoted(src, self.i);
                self.prev = c;
                continue;
            }
            if (std.ascii.isAlphabetic(c) or c == '_' or c == '$') {
                const start = self.i;
                while (self.i < src.len and isIdentChar(src[self.i])) : (self.i += 1) {}
                const was = self.prev;
                self.prev = src[self.i - 1];
                return .{ .text = src[start..self.i], .prev = was, .end = self.i };
            }
            self.prev = c;
            self.i += 1;
        }
        return null;
    }
};

/// Collect the local-name → (module, import name) bindings introduced by the
/// `import` declarations in `src`. Sets `unsure` on any form it cannot model.
fn scanImportBindings(
    src: []const u8,
    importer_id: []const u8,
    out: *std.StringHashMap(ImportBinding),
    unsure: *bool,
    allocator: std.mem.Allocator,
) void {
    var scan = WordScan{ .src = src };
    while (scan.next()) |w| {
        if (!std.mem.eql(u8, w.text, "import")) continue;
        if (w.prev == '.') continue;
        var j = skipWsComments(src, w.end);
        if (j >= src.len) continue;
        // `import(...)` (dynamic) and `import.meta` are not declarations.
        if (src[j] == '(' or src[j] == '.') continue;
        // `import 'spec'` — side effect only, no bindings.
        if (src[j] == '"' or src[j] == '\'') {
            scan.i = skipQuoted(src, j);
            continue;
        }
        // `import defer * as ns from 'spec'` / `import source x from 'spec'`.
        _ = matchKeyword(src, &j, "defer");
        var pending = std.ArrayList([2][]const u8){};
        var namespaces = std.ArrayList([]const u8){};
        var ok = true;
        var clause_done = false;
        while (!clause_done) {
            j = skipWsComments(src, j);
            if (j >= src.len) {
                ok = false;
                break;
            }
            if (src[j] == '*') {
                j += 1;
                if (!matchKeyword(src, &j, "as")) {
                    ok = false;
                    break;
                }
                const ns = readIdentAt(src, &j) orelse {
                    ok = false;
                    break;
                };
                namespaces.append(allocator, ns) catch {};
            } else if (src[j] == '{') {
                j += 1;
                while (true) {
                    j = skipWsComments(src, j);
                    if (j >= src.len) {
                        ok = false;
                        break;
                    }
                    if (src[j] == '}') {
                        j += 1;
                        break;
                    }
                    if (src[j] == ',') {
                        j += 1;
                        continue;
                    }
                    const imported = readIdentAt(src, &j) orelse {
                        ok = false;
                        break;
                    };
                    var local = imported;
                    var k = j;
                    if (matchKeyword(src, &k, "as")) {
                        local = readIdentAt(src, &k) orelse {
                            ok = false;
                            break;
                        };
                        j = k;
                    }
                    pending.append(allocator, .{ local, imported }) catch {};
                }
                if (!ok) break;
            } else {
                // Default import binding (possibly after `source`/`defer`).
                const local = readIdentAt(src, &j) orelse {
                    ok = false;
                    break;
                };
                if (std.mem.eql(u8, local, "from")) {
                    ok = false;
                    break;
                }
                pending.append(allocator, .{ local, "default" }) catch {};
            }
            const after = skipWsComments(src, j);
            if (after < src.len and src[after] == ',') {
                j = after + 1;
                continue;
            }
            clause_done = true;
        }
        if (!ok) {
            unsure.* = true;
            scan.i = j;
            continue;
        }
        if (!matchKeyword(src, &j, "from")) {
            unsure.* = true;
            scan.i = j;
            continue;
        }
        const mod_id = readSpecifierAt(src, &j, importer_id, allocator) orelse {
            unsure.* = true;
            scan.i = j;
            continue;
        };
        for (pending.items) |pr| {
            out.put(pr[0], .{ .module_id = mod_id, .import_name = pr[1] }) catch {};
        }
        for (namespaces.items) |ns| {
            out.put(ns, .{ .module_id = mod_id, .import_name = "" }) catch {};
        }
        scan.i = j;
    }
}

/// Skip the string/template literal starting at `src[i]`, returning the index
/// just past its closing delimiter.
fn skipQuoted(src: []const u8, i: usize) usize {
    const q = src[i];
    var j = i + 1;
    while (j < src.len and src[j] != q) : (j += 1) {
        if (src[j] == '\\') j += 1;
    }
    return j + 1;
}

/// Split `src`'s `export` declarations into the spec's Local/Indirect/Star
/// export entries, resolving each ModuleRequest against `importer_id`.
fn scanExportEntries(src: []const u8, importer_id: []const u8, allocator: std.mem.Allocator) ExportEntries {
    var locals = std.ArrayList([]const u8){};
    var indirects = std.ArrayList(IndirectExportEntry){};
    var stars = std.ArrayList([]const u8){};
    var unsure = false;

    // `export { x }` where `x` is an imported binding is an IndirectExportEntry,
    // not a local one, so the import clauses have to be known up front.
    var imports = std.StringHashMap(ImportBinding).init(allocator);
    scanImportBindings(src, importer_id, &imports, &unsure, allocator);

    var scan = WordScan{ .src = src };
    while (scan.next()) |w| {
        if (!std.mem.eql(u8, w.text, "export")) continue;
        if (w.prev == '.') continue;
        scan.i = scanOneExport(src, w.end, importer_id, &imports, &locals, &indirects, &stars, &unsure, allocator);
    }
    return .{
        .locals = locals.items,
        .indirects = indirects.items,
        .stars = stars.items,
        .unsure = unsure,
    };
}

/// Parse the single `export` declaration whose keyword ends at `start`,
/// appending its entries. Returns the index to resume scanning from; sets
/// `unsure` on any unrecognised form.
fn scanOneExport(
    src: []const u8,
    start: usize,
    importer_id: []const u8,
    imports: *const std.StringHashMap(ImportBinding),
    locals: *std.ArrayList([]const u8),
    indirects: *std.ArrayList(IndirectExportEntry),
    stars: *std.ArrayList([]const u8),
    unsure: *bool,
    allocator: std.mem.Allocator,
) usize {
    var j = skipWsComments(src, start);
    if (j >= src.len) {
        unsure.* = true;
        return j;
    }
    // `export * from 'spec'` / `export * as ns from 'spec'`
    if (src[j] == '*') {
        j += 1;
        if (matchKeyword(src, &j, "as")) {
            const ns = readIdentAt(src, &j) orelse {
                unsure.* = true;
                return j;
            };
            locals.append(allocator, ns) catch {};
            if (!matchKeyword(src, &j, "from")) unsure.* = true;
            _ = readSpecifierAt(src, &j, importer_id, allocator);
            return j;
        }
        if (!matchKeyword(src, &j, "from")) {
            unsure.* = true;
            return j;
        }
        const mod_id = readSpecifierAt(src, &j, importer_id, allocator) orelse {
            unsure.* = true;
            return j;
        };
        stars.append(allocator, mod_id) catch {};
        return j;
    }
    // `export { a, b as c } [from 'spec']`
    if (src[j] == '{') {
        j += 1;
        var names = std.ArrayList([2][]const u8){};
        while (true) {
            j = skipWsComments(src, j);
            if (j >= src.len) {
                unsure.* = true;
                return j;
            }
            if (src[j] == '}') {
                j += 1;
                break;
            }
            if (src[j] == ',') {
                j += 1;
                continue;
            }
            const local = readIdentAt(src, &j) orelse {
                unsure.* = true;
                return j + 1;
            };
            var exported = local;
            var k = j;
            if (matchKeyword(src, &k, "as")) {
                exported = readIdentAt(src, &k) orelse {
                    unsure.* = true;
                    return k + 1;
                };
                j = k;
            }
            names.append(allocator, .{ local, exported }) catch {};
        }
        var k = j;
        if (matchKeyword(src, &k, "from")) {
            const mod_id = readSpecifierAt(src, &k, importer_id, allocator) orelse {
                unsure.* = true;
                return k;
            };
            for (names.items) |nm| {
                indirects.append(allocator, .{
                    .export_name = nm[1],
                    .module_id = mod_id,
                    .import_name = nm[0],
                }) catch {};
            }
            return k;
        }
        for (names.items) |nm| {
            if (imports.get(nm[0])) |ib| {
                if (ib.import_name.len > 0) {
                    indirects.append(allocator, .{
                        .export_name = nm[1],
                        .module_id = ib.module_id,
                        .import_name = ib.import_name,
                    }) catch {};
                    continue;
                }
            }
            locals.append(allocator, nm[1]) catch {};
        }
        return j;
    }
    if (matchKeyword(src, &j, "default")) {
        locals.append(allocator, "default") catch {};
        return j;
    }
    var dummy_tdz = std.ArrayList([]const u8){};
    if (matchKeyword(src, &j, "var") or matchKeyword(src, &j, "let") or
        matchKeyword(src, &j, "const") or matchKeyword(src, &j, "using"))
    {
        scanDeclaratorNames(src[j..], locals, &dummy_tdz, false, allocator);
        return j;
    }
    _ = matchKeyword(src, &j, "async");
    if (matchKeyword(src, &j, "function")) {
        j = skipWsComments(src, j);
        if (j < src.len and src[j] == '*') j += 1;
        const nm = readIdentAt(src, &j) orelse {
            unsure.* = true;
            return j;
        };
        locals.append(allocator, nm) catch {};
        return j;
    }
    if (matchKeyword(src, &j, "class")) {
        const nm = readIdentAt(src, &j) orelse {
            unsure.* = true;
            return j;
        };
        locals.append(allocator, nm) catch {};
        return j;
    }
    unsure.* = true;
    return j;
}

/// Outcome of §16.2.1.6.3 ResolveExport. `unknown` is this implementation's
/// extra state: the scanners could not model some module on the path, so no
/// verdict may be drawn.
const ResolutionKind = enum { resolved, none, ambiguous, unknown };

const Resolution = struct {
    kind: ResolutionKind,
    module_id: []const u8 = "",
    binding: []const u8 = "",
};

const ResolveCtx = struct {
    entries: *const std.StringHashMap(ExportEntries),
    /// The (module, exportName) pairs on the current resolution path — the
    /// spec's resolveSet, used to detect a circular re-export chain.
    path: *std.ArrayList([2][]const u8),
    allocator: std.mem.Allocator,
    depth: u32 = 0,
};

/// §16.2.1.6.3 ResolveExport, evaluated statically over the discovered graph.
fn resolveExport(ctx: *ResolveCtx, module_id: []const u8, export_name: []const u8) Resolution {
    if (ctx.depth > 64) return .{ .kind = .unknown };
    const ents = ctx.entries.get(module_id) orelse return .{ .kind = .unknown };
    if (ents.unsure) return .{ .kind = .unknown };
    for (ctx.path.items) |r| {
        if (std.mem.eql(u8, r[0], module_id) and std.mem.eql(u8, r[1], export_name)) {
            // Circular import request: this path provides no binding.
            return .{ .kind = .none };
        }
    }
    ctx.path.append(ctx.allocator, .{ module_id, export_name }) catch return .{ .kind = .unknown };
    defer _ = ctx.path.pop();
    ctx.depth += 1;
    defer ctx.depth -= 1;

    for (ents.locals) |l| {
        if (std.mem.eql(u8, l, export_name)) {
            return .{ .kind = .resolved, .module_id = module_id, .binding = export_name };
        }
    }
    for (ents.indirects) |ind| {
        if (std.mem.eql(u8, ind.export_name, export_name)) {
            return resolveExport(ctx, ind.module_id, ind.import_name);
        }
    }
    // `export *` never provides `default`.
    if (std.mem.eql(u8, export_name, "default")) return .{ .kind = .none };
    var star: Resolution = .{ .kind = .none };
    for (ents.stars) |s| {
        const r = resolveExport(ctx, s, export_name);
        switch (r.kind) {
            .unknown => return .{ .kind = .unknown },
            .ambiguous => return .{ .kind = .ambiguous },
            .none => {},
            .resolved => {
                if (star.kind == .none) {
                    star = r;
                } else if (!std.mem.eql(u8, star.module_id, r.module_id) or
                    !std.mem.eql(u8, star.binding, r.binding))
                {
                    return .{ .kind = .ambiguous };
                }
            },
        }
    }
    return star;
}

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
            // export let/const <names...> (TDZ) and export var <names...> (hoisted):
            // scan the WHOLE comma-separated declarator list, not just the first
            // name, so `export let a, b, c;` registers every binding.
            if (std.mem.startsWith(u8, rest, "let ")) {
                scanDeclaratorNames(rest[4..], out, out_tdz, true, allocator);
                continue;
            }
            if (std.mem.startsWith(u8, rest, "var ")) {
                // var is hoisted (initialized to undefined), so not TDZ.
                scanDeclaratorNames(rest[4..], out, out_tdz, false, allocator);
                continue;
            }
            if (std.mem.startsWith(u8, rest, "const ")) {
                scanDeclaratorNames(rest[6..], out, out_tdz, true, allocator);
                continue;
            }
            continue;
        }
        i += 1;
    }
}

/// Scan a `let`/`var`/`const` declarator list (the text right after the keyword)
/// and append every top-level binding identifier to `out` (and to `out_tdz` when
/// `is_tdz`). Initializers are skipped while tracking bracket/paren/brace depth
/// and string literals so a comma inside an initializer (e.g.
/// `new Promise((r, j) => …)`) is not mistaken for a declarator separator. Only
/// plain identifier bindings are collected; a destructuring pattern (`{`/`[`)
/// ends the scan (matching the previous behaviour of not registering those).
fn scanDeclaratorNames(
    rest: []const u8,
    out: *std.ArrayList([]const u8),
    out_tdz: *std.ArrayList([]const u8),
    is_tdz: bool,
    allocator: std.mem.Allocator,
) void {
    const ch = struct {
        fn identStart(c: u8) bool {
            return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
        }
        fn identPart(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
        }
        fn space(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }
    };

    var j: usize = 0;
    while (j < rest.len) {
        while (j < rest.len and ch.space(rest[j])) : (j += 1) {}
        if (j >= rest.len or !ch.identStart(rest[j])) break;
        const name_start = j;
        while (j < rest.len and ch.identPart(rest[j])) : (j += 1) {}
        out.append(allocator, rest[name_start..j]) catch {};
        if (is_tdz) out_tdz.append(allocator, rest[name_start..j]) catch {};
        while (j < rest.len and ch.space(rest[j])) : (j += 1) {}
        if (j >= rest.len) break;
        if (rest[j] == ',') {
            j += 1;
            continue;
        }
        if (rest[j] != '=') break; // ';', or end of declaration
        // Skip the initializer up to a top-level ',' or ';'.
        j += 1;
        var depth: i32 = 0;
        var done = false;
        while (j < rest.len) {
            const c = rest[j];
            if (c == '"' or c == '\'' or c == '`') {
                const q = c;
                j += 1;
                while (j < rest.len) : (j += 1) {
                    if (rest[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (rest[j] == q) break;
                }
                if (j < rest.len) j += 1;
                continue;
            }
            if (c == '(' or c == '[' or c == '{') {
                depth += 1;
            } else if (c == ')' or c == ']' or c == '}') {
                if (depth == 0) {
                    done = true;
                    break;
                }
                depth -= 1;
            } else if (depth == 0 and (c == ',' or c == ';')) {
                break;
            }
            j += 1;
        }
        if (done or j >= rest.len) break;
        if (rest[j] == ';') break;
        // rest[j] == ',' — advance to the next declarator.
        j += 1;
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
    return buildBundleImpl(gpa, base_dir, entry_id, entry_src, false);
}

/// Same dependency-graph link phase as `buildBundle`, but for an entry that is
/// *script* code rather than a Module Record. A script has no imports, exports or
/// module scope, so only the `__modules__` registry is emitted ahead of it; the
/// entry source itself is inlined verbatim at global scope (no IIFE, no
/// `"use strict"`, no export wiring) so it keeps ordinary sloppy-mode Script
/// semantics. What the registry buys the script is a *referrer*: `__module_id__`
/// names the script's own path, so a relative `import('./dep.js')` inside it
/// resolves against that path — the referencing-script half of
/// HostLoadImportedModule — instead of failing to resolve.
pub fn buildScriptBundle(gpa: std.mem.Allocator, base_dir: []const u8, entry_id: ?[]const u8, entry_src: []const u8) ![]const u8 {
    return buildBundleImpl(gpa, base_dir, entry_id, entry_src, true);
}

/// Emit a `__modules__[id]` factory that throws a `SyntaxError` the first time
/// the module is required. This is how a module that must fail at *link* time
/// (parse error, module-goal early error, unresolvable indirect export) reports
/// itself: `require` propagates the throw, and `import()` rejects with the error
/// object — so `error.name === "SyntaxError"`, unlike the `__moduleUnresolved__`
/// path which rejects with a bare string.
fn emitSyntaxErrorFactory(
    gpa: std.mem.Allocator,
    sb: *std.ArrayList(u8),
    mod_id: []const u8,
    message: []const u8,
) !void {
    try sb.appendSlice(gpa, "__modules__[");
    try appendJsString(gpa, sb, mod_id);
    try sb.appendSlice(gpa, "] = function(require, module, exports){\nthrow new SyntaxError(");
    try appendJsString(gpa, sb, message);
    try sb.appendSlice(gpa, "+");
    try appendJsString(gpa, sb, mod_id);
    try sb.appendSlice(gpa, ");\n};\n");
}

fn buildBundleImpl(gpa: std.mem.Allocator, base_dir: []const u8, entry_id: ?[]const u8, entry_src: []const u8, entry_is_script: bool) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const self_id = entry_id orelse ENTRY_ID;
    var registry = std.StringArrayHashMap([]const u8).init(arena);
    // Relative specifiers that could not be read from disk: per spec, module
    // resolution errors are reported eagerly at load (LoadRequestedModules walks
    // the whole graph, deferred deps included), so a module that transitively
    // imports one of these must fail to load rather than evaluate lazily.
    var missing_ids = std.StringHashMap(void).init(arena);
    var queue = std.ArrayList([]const u8){};
    scanSpecifiers(entry_src, self_id, &queue, arena);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const id = queue.items[qi];
        // A *module*-entry resolves a self-import to itself via the
        // pre-registered `module` (below) — the very same live module record,
        // not a fresh disk re-read — since real ES module self-import is a
        // single-record singleton. A *script* entry has no such live module
        // record (scripts have no Module Record); the dynamic `import()` of
        // its own filename from a script is a genuinely separate Module
        // Record load of the same source (sec-hostimportmoduledynamically —
        // see `eval-self-once-script.js`), so let it fall through to the
        // normal disk-read path below, which happens to read this very file
        // (base_dir/self_id is the test's own path).
        if (std.mem.eql(u8, id, self_id) and !entry_is_script) continue;
        if (registry.contains(id)) continue;
        const src = readModuleFile(arena, base_dir, id) orelse {
            try missing_ids.put(id, {});
            continue;
        };
        try registry.put(id, src);
        // Typed (JSON/text) modules are opaque data, not JS — don't scan their
        // contents for nested specifiers (a JSON string value could look like a
        // relative path).
        if (idType(id) == null) scanSpecifiers(src, id, &queue, arena);
    }

    // Eager resolution-error taint (sec-LoadRequestedModules): a module is
    // "unresolvable" if it transitively — via *static* import edges only, so
    // dynamic `import()` does not taint its importer — imports a module missing
    // from disk. `import()`/`require()` of such a module must reject/throw at load
    // rather than evaluate lazily, even when the missing module sits behind an
    // `import defer` (deferred-ness affects evaluation, not loading).
    var tainted = std.StringHashMap(void).init(arena);
    if (missing_ids.count() > 0) {
        var static_dep_of = std.StringHashMap([]const []const u8).init(arena);
        {
            var rit = registry.iterator();
            while (rit.next()) |e| {
                const id = e.key_ptr.*;
                if (idType(id) != null) {
                    try static_dep_of.put(id, &[_][]const u8{});
                    continue;
                }
                var ds = std.ArrayList([]const u8){};
                scanStaticSpecifiers(e.value_ptr.*, id, &ds, arena);
                try static_dep_of.put(id, ds.items);
            }
            var eds = std.ArrayList([]const u8){};
            scanStaticSpecifiers(entry_src, self_id, &eds, arena);
            try static_dep_of.put(self_id, eds.items);
        }
        // Fixpoint: a module is tainted if a static dep is missing or tainted.
        var changed = true;
        while (changed) {
            changed = false;
            var sit = static_dep_of.iterator();
            while (sit.next()) |e| {
                const id = e.key_ptr.*;
                if (tainted.contains(id)) continue;
                for (e.value_ptr.*) |d| {
                    if (missing_ids.contains(d) or tainted.contains(d)) {
                        try tainted.put(id, {});
                        changed = true;
                        break;
                    }
                }
            }
        }
    }

    // §16.2.1.6.4 InitializeEnvironment step 3: for each IndirectExportEntry of
    // a module, ResolveExport must yield a resolution — null (circular re-export
    // chain) or "ambiguous" (two `export *` paths reaching different bindings)
    // is a SyntaxError raised at link time, before the module evaluates. The CJS
    // desugar links lazily at runtime and cannot see either, so decide it here
    // over the graph the DFS just discovered and hand the offending module a
    // throwing factory below.
    var link_errors = std.StringHashMap(void).init(arena);
    {
        var entries = std.StringHashMap(ExportEntries).init(arena);
        var rit = registry.iterator();
        while (rit.next()) |e| {
            const id = e.key_ptr.*;
            // Typed (JSON/text/bytes) modules are opaque data — not modelled.
            const ents: ExportEntries = if (idType(id) != null)
                .{ .unsure = true }
            else
                scanExportEntries(e.value_ptr.*, id, arena);
            try entries.put(id, ents);
        }
        if (!entries.contains(self_id)) {
            try entries.put(self_id, if (entry_is_script)
                ExportEntries{ .unsure = true }
            else
                scanExportEntries(entry_src, self_id, arena));
        }
        var vit = registry.iterator();
        while (vit.next()) |e| {
            const id = e.key_ptr.*;
            const ents = entries.get(id) orelse continue;
            if (ents.unsure) continue;
            for (ents.indirects) |ind| {
                var path = std.ArrayList([2][]const u8){};
                var ctx = ResolveCtx{ .entries = &entries, .path = &path, .allocator = arena };
                const r = resolveExport(&ctx, id, ind.export_name);
                if (r.kind == .none or r.kind == .ambiguous) {
                    try link_errors.put(id, {});
                    break;
                }
            }
        }
    }

    // M16 TLA: classify which modules (and the entry) must evaluate as async
    // factories, and each module's async-dependency id list for the barrier.
    var dep_of = std.StringHashMap([]const []const u8).init(arena);
    var async_set = try computeAsyncSet(arena, &registry, self_id, entry_src, &dep_of);
    // DFS pre-order discovery times from entry — used by asyncDepsList to detect
    // back-edge (cycle-ancestor) deps and redirect cross-SCC deps to their SCC root.
    var dfs_order = computeDfsOrder(arena, &dep_of, self_id);

    // Import-defer × TLA: the set of modules with *direct* top-level await
    // (spec [[HasTLA]]) and, per importer, the set of deferred-imported deps.
    // A deferred dependency does not make the importer wait for the module
    // itself — instead its TLA frontier (GatherAsynchronousTransitiveDependencies)
    // is evaluated eagerly. `deferred_of` keys the importing module to that frontier.
    var tla_set = std.StringHashMap(void).init(arena);
    var deferred_of = std.StringHashMap([]const []const u8).init(arena);
    {
        var rit = registry.iterator();
        while (rit.next()) |e| {
            const id = e.key_ptr.*;
            if (idType(id) != null) continue;
            const src = e.value_ptr.*;
            if (hasTopLevelAwait(src)) try tla_set.put(id, {});
            var ds = std.ArrayList([]const u8){};
            scanDeferredSpecifiers(src, id, &ds, arena);
            try deferred_of.put(id, ds.items);
        }
        if (hasTopLevelAwait(entry_src)) try tla_set.put(self_id, {});
        var eds = std.ArrayList([]const u8){};
        scanDeferredSpecifiers(entry_src, self_id, &eds, arena);
        try deferred_of.put(self_id, eds.items);
    }

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
    // Import-defer × TLA: `__deferGather__[id]` is the eager-evaluation frontier
    // (GatherAsynchronousTransitiveDependencies) for a deferred-imported module.
    // `__importDefer__(id)` requires each listed module so its async (top-level
    // await) dependencies are evaluated eagerly, in source order, even though the
    // deferred module itself stays unevaluated until first access.
    try sb.appendSlice(gpa, "var __deferGather__ = {};\n");
    {
        var emitted = std.StringHashMap(void).init(arena);
        var dit = deferred_of.iterator();
        while (dit.next()) |e| {
            for (e.value_ptr.*) |target| {
                if (emitted.contains(target)) continue;
                try emitted.put(target, {});
                const frontier = gatherAsyncTransitive(arena, &tla_set, &dep_of, target);
                if (frontier.len == 0) continue;
                try sb.appendSlice(gpa, "__deferGather__[");
                try appendJsString(gpa, &sb, target);
                try sb.appendSlice(gpa, "]=[");
                for (frontier, 0..) |f, fi| {
                    if (fi > 0) try sb.appendSlice(gpa, ",");
                    try appendJsString(gpa, &sb, f);
                }
                try sb.appendSlice(gpa, "];\n");
            }
        }
    }
    // Import-defer ReadyForSyncExecution (sec-EnsureDeferredNamespaceEvaluation):
    // accessing a deferred namespace throws a TypeError unless the module's whole
    // synchronous frontier is ready — no module in it is still ~evaluating~/
    // ~evaluating-async~, and none has top-level await. The runtime needs each
    // module's resolved dependency id list and its [[HasTLA]] flag to walk that
    // frontier without evaluating anything, so emit them as `__moduleGraph__`.
    // Eager resolution-error set: `require`/`import()` of a listed id throws a
    // module-not-found error at load (before any evaluation).
    try sb.appendSlice(gpa, "var __moduleUnresolved__ = {};\n");
    {
        var tit = tainted.iterator();
        while (tit.next()) |e| {
            try sb.appendSlice(gpa, "__moduleUnresolved__[");
            try appendJsString(gpa, &sb, e.key_ptr.*);
            try sb.appendSlice(gpa, "]=true;\n");
        }
    }
    try sb.appendSlice(gpa, "var __moduleGraph__ = {};\n");
    {
        var git = dep_of.iterator();
        while (git.next()) |e| {
            const id = e.key_ptr.*;
            try sb.appendSlice(gpa, "__moduleGraph__[");
            try appendJsString(gpa, &sb, id);
            try sb.appendSlice(gpa, "]={tla:");
            try sb.appendSlice(gpa, if (tla_set.contains(id)) "true" else "false");
            try sb.appendSlice(gpa, ",deps:[");
            for (e.value_ptr.*, 0..) |d, di| {
                if (di > 0) try sb.appendSlice(gpa, ",");
                try appendJsString(gpa, &sb, d);
            }
            try sb.appendSlice(gpa, "]};\n");
        }
    }
    // ReadyForSyncExecution(module, seen): walk the module's synchronous frontier
    // and report whether it can be evaluated synchronously right now. A module is
    // not ready if it (or any transitive dependency) is currently ~evaluating~ or
    // has top-level await. `__moduleStatus__` derives the spec [[Status]] from the
    // runtime record: a still-a-function entry is ~linked~ (factory not invoked);
    // an object with `loaded===false` is ~evaluating~; otherwise ~evaluated~.
    try sb.appendSlice(gpa,
        \\function __moduleStatus__(id){var m=__modules__[id];if(m===undefined)return "linked";if(typeof m==="function")return "linked";if(m.__evalError__!==undefined)return "evaluated";if(m.loaded===false)return "evaluating";return "evaluated";}
        \\function __readyForSync__(id,seen){if(!seen)seen=[];if(seen.indexOf(id)!==-1)return true;seen.push(id);var st=__moduleStatus__(id);if(st==="evaluated")return true;if(st==="evaluating")return false;var g=__moduleGraph__[id];if(!g)return true;if(g.tla)return false;var deps=g.deps;for(var i=0;i<deps.length;i++){if(!__readyForSync__(deps[i],seen))return false;}return true;}
        \\
    );
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
        // A dependency whose source has a syntax error must not be inlined into
        // the bundle (it would break the whole bundle's parse). Emit a factory
        // that throws a SyntaxError when first required, so the parse error
        // surfaces lazily at evaluation — `import()` rejects and
        // `ShadowRealm.prototype.importValue` rejects with a TypeError.
        if (!moduleSourceParses(gpa, e.value_ptr.*)) {
            try emitSyntaxErrorFactory(gpa, &sb, mod_id, "Unexpected end of input in module ");
            continue;
        }
        // Module-goal early errors (§16.2.1.5) that the Script-goal parse above
        // cannot see — e.g. a top-level `function` colliding with a `var`.
        if (moduleGoalEarlyError(gpa, e.value_ptr.*)) {
            try emitSyntaxErrorFactory(gpa, &sb, mod_id, "Invalid module code in ");
            continue;
        }
        // An IndirectExportEntry that ResolveExport reports as null or
        // "ambiguous" (see the link_errors pass above).
        if (link_errors.contains(mod_id)) {
            try emitSyntaxErrorFactory(gpa, &sb, mod_id, "Unresolvable indirect export in module ");
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
        // sec-meta-properties-runtime-semantics-evaluation: a module's
        // [[ImportMeta]] is created per module and is NOT shared across modules.
        // Shadow the realm-global `__import_meta__` with a per-factory binding
        // (null-prototype, extensible) keyed by this module's id, so `import.meta`
        // in distinct modules yields distinct objects while every reference within
        // a module observes the same one.
        if (std.mem.indexOf(u8, e.value_ptr.*, "import.meta") != null) {
            try sb.appendSlice(gpa, "var __import_meta__=Object.create(null);__import_meta__.url=__module_id__;\n");
        }
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
        const async_deps = asyncDepsList(arena, &async_set, &dep_of, &dfs_order, &deferred_of, &tla_set, mod_id);
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
    if (entry_is_script) {
        // Script entry: everything above (the registry, the star/live-export
        // helpers, the module graph) is what a relative `import()` needs to
        // resolve; none of the *module* wiring applies. Name the referrer and
        // inline the script untouched at global scope.
        try sb.appendSlice(gpa, "var __module_id__ = ");
        try appendJsString(gpa, &sb, self_id);
        try sb.appendSlice(gpa, ";\n");
        try sb.appendSlice(gpa, entry_src);
        try sb.appendSlice(gpa, "\n");
        return finishBundle(gpa, &sb);
    }
    try sb.appendSlice(gpa, "var module = { exports: {} }; var exports = module.exports;\nvar __module_id__ = \"");
    try sb.appendSlice(gpa, self_id);
    try sb.appendSlice(gpa, "\";\n");
    // The entry module gets its own per-module `import.meta` too (distinct from
    // any dependency's), defined at bundle scope so the entry IIFE captures it.
    if (std.mem.indexOf(u8, entry_src, "import.meta") != null) {
        try sb.appendSlice(gpa, "var __import_meta__=Object.create(null);__import_meta__.url=__module_id__;\n");
    }
    if (entry_id != null) {
        // Pre-register the entry so a self-/cyclic `require` returns this exact
        // (partial) exports object — cache-before-invoke for the entry itself.
        // `loaded === false` marks the entry as ~evaluating~ for the duration of
        // its body, so a deferred-namespace ReadyForSyncExecution check that
        // reaches the entry (a self/cyclic `import defer`) sees it as not-ready.
        try sb.appendSlice(gpa, "__modules__[\"");
        try sb.appendSlice(gpa, self_id);
        try sb.appendSlice(gpa, "\"] = module; module.loaded = false;\n");
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
        const entry_async_deps = asyncDepsList(arena, &async_set, &dep_of, &dfs_order, &deferred_of, &tla_set, self_id);
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
    // The entry body has returned: it is now ~evaluated~ (see loaded=false above).
    if (entry_id != null) try sb.appendSlice(gpa, "module.loaded = true;\n");
    return finishBundle(gpa, &sb);
}

/// Take ownership of a finished bundle buffer, mirroring it to
/// `/tmp/bundle_dump.js` when JSZ_DUMP_BUNDLE is set (debugging aid).
fn finishBundle(gpa: std.mem.Allocator, sb: *std.ArrayList(u8)) ![]const u8 {
    const result = try sb.toOwnedSlice(gpa);
    if (std.process.hasEnvVarConstant("JSZ_DUMP_BUNDLE")) {
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
