// SPDX-License-Identifier: Apache-2.0
//! Recursive descent / Pratt-style parser for ES5 subset.
//! All nodes are arena-allocated; caller owns the arena lifetime.
//!
//! R4 split: statement/expression/class parsing bodies live in
//!   parser/stmt.zig, parser/expr.zig, parser/class.zig
//! as free functions on `*Parser`. This file keeps the Parser struct,
//! all primitive helpers, and thin one-line stubs for every moved function.
const std = @import("std");
const Lexer = @import("../lexer/lexer.zig").Lexer;
const LexError = @import("../lexer/lexer.zig").LexError;
const Token = @import("../lexer/token.zig").Token;
const TokenKind = @import("../lexer/token.zig").TokenKind;
const ast = @import("./ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;

const recovery = @import("./recovery.zig");
pub const ParseError = recovery.ParseError;
const stmt_mod = @import("./stmt.zig");
const expr_mod = @import("./expr.zig");
const class_mod = @import("./class.zig");

pub const ParamParse = struct {
    params: [][]const u8,
    param_defaults: []?*Node,
    rest_param: ?[]const u8,
};

/// Check if first statement of body is "use strict" directive.
/// Hoisted to file scope so stmt/expr/class modules can call it without
/// going through the Parser struct.
pub fn hasUseStrict(body: []*Node) bool {
    if (body.len == 0) return false;
    const first = body[0];
    if (first.kind != .expr_stmt) return false;
    const inner = first.data.expr_stmt;
    if (inner.kind != .string_literal) return false;
    return std.mem.eql(u8, inner.data.string_literal, "use strict");
}

pub const ParseResult = union(enum) {
    ok: []*Node,
    err: ParseError,
};

/// Phase 8: an ES-module named/default import binding to make live via use-site rewrite.
const LiveImport = struct { name: []const u8, ns: []const u8, prop: []const u8 };

pub const Parser = struct {
    lexer: Lexer,
    arena: std.mem.Allocator,
    /// Lookahead token (already lexed).
    current: Token,
    /// True if we hit an unrecoverable error.
    had_error: bool,
    error_info: ?ParseError,
    in_generator_function: bool,
    /// M16 Phase 4: true when parsing a module (not a script), so `await` is a
    /// reserved word and `new await` / `(await x) = y` are early SyntaxErrors.
    is_module: bool,
    /// Phase 8: statements produced by desugaring ES-module import/export that must be
    /// spliced into the program body after the primary statement (kept at module scope).
    extra_stmts: std.ArrayList(*Node),
    /// Phase 8: named/default import bindings collected per module unit, used to rewrite
    /// use-sites to live namespace member access (`local` -> `ns.prop`).
    live_imports: std.ArrayList(LiveImport),
    /// Phase 8: `export let`/`export var` names collected per module unit, used to rewrite
    /// their use-sites to `exports.name` so reassignments are observed live by importers.
    live_exports: std.ArrayList([]const u8),

    pub fn init(source: []const u8, arena: std.mem.Allocator) Parser {
        var p = Parser{
            .lexer = Lexer.init(source, arena),
            .arena = arena,
            .current = undefined,
            .had_error = false,
            .error_info = null,
            .in_generator_function = false,
            .is_module = false,
            .extra_stmts = .{},
            .live_imports = .{},
            .live_exports = .{},
        };
        // Prime the lookahead.
        p.current = p.lexNext();
        return p;
    }

    fn lexNext(self: *Parser) Token {
        return self.lexer.next() catch |err| {
            const msg = switch (err) {
                LexError.UnterminatedString => "unterminated string literal",
                LexError.UnterminatedComment => "unterminated comment",
                LexError.InvalidEscape => "invalid escape sequence",
                LexError.InvalidNumericLiteral => "invalid numeric literal",
                LexError.TemplateLiteralNotSupported => "template literals not supported in Phase 1",
                LexError.OutOfMemory => "out of memory",
            };
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{
                    .message = msg,
                    .line = self.current.line,
                    .column = self.current.column,
                };
            }
            return Token.initSimple(.eof, 0, 0, 1, 1, false);
        };
    }

    pub fn advance(self: *Parser) Token {
        const prev = self.current;
        self.current = self.lexNext();
        return prev;
    }

    pub fn check(self: *const Parser, kind: TokenKind) bool {
        return self.current.kind == kind;
    }

    /// Peek the token immediately after `current` without consuming it. The
    /// lexer is positioned just past `current`, so copying it and pulling one
    /// token gives the next lookahead. Used for contextual `async` detection.
    pub fn peekNext(self: *Parser) Token {
        var lx = self.lexer;
        return lx.next() catch Token.initSimple(.eof, 0, 0, 1, 1, false);
    }

    /// True if `current` is the contextual keyword `async` (a plain identifier).
    pub fn currentIsAsyncKw(self: *const Parser) bool {
        return self.current.kind == .identifier and std.mem.eql(u8, self.current.value_str, "async");
    }

    pub fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    /// Accept an IdentifierName at the current position: plain identifier OR any
    /// keyword token (ES spec §12.1 — reserved words are valid after `.` / `?.`).
    pub fn expectIdentifierName(self: *Parser) ?Token {
        const k = self.current.kind;
        if (k == .identifier) return self.advance();
        const i = @intFromEnum(k);
        if (i >= @intFromEnum(TokenKind.kw_break) and i <= @intFromEnum(TokenKind.kw_null)) {
            return self.advance();
        }
        // Fall through to normal error reporting via expect(.identifier).
        return self.expect(.identifier);
    }

    pub fn expect(self: *Parser, kind: TokenKind) ?Token {
        if (self.check(kind)) return self.advance();
        if (!self.had_error) {
            self.had_error = true;
            var buf: [128]u8 = undefined;
            const msg_s = std.fmt.bufPrint(&buf, "expected {s} but got {s}", .{
                @tagName(kind), @tagName(self.current.kind),
            }) catch "unexpected token";
            const owned = self.arena.dupe(u8, msg_s) catch "unexpected token";
            self.error_info = ParseError{
                .message = owned,
                .line = self.current.line,
                .column = self.current.column,
            };
        }
        return null;
    }

    pub fn alloc(self: *Parser) ?*Node {
        return self.arena.create(Node) catch {
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{ .message = "out of memory", .line = 0, .column = 0 };
            }
            return null;
        };
    }

    pub fn makeNode(self: *Parser, kind: NodeKind, start: u32, end: u32, data: ast.Data) ?*Node {
        const n = self.alloc() orelse return null;
        n.* = Node{ .kind = kind, .start = start, .end = end, .data = data };
        return n;
    }

    // ----------------------------------------------------------------- ASI ---

    /// Check if a semicolon can be auto-inserted:
    /// 1. Current token is an actual semicolon.
    /// 2. Current token has a line terminator before it.
    /// 3. Current token is '}'.
    /// 4. At EOF.
    pub fn hasSemicolon(self: *Parser) bool {
        if (self.current.kind == .semicolon) return true;
        if (self.current.kind == .right_brace) return true;
        if (self.current.kind == .eof) return true;
        if (self.current.line_terminator_before) return true;
        return false;
    }

    pub fn consumeSemicolon(self: *Parser) void {
        if (self.current.kind == .semicolon) {
            _ = self.advance();
        }
        // Otherwise ASI is implied.
    }

    // ---------------------------------------------------------------- parse ---

    /// Parse a complete script. Returns list of top-level statements or an error.
    pub fn parseScript(self: *Parser) ParseResult {
        var stmts = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&stmts);
        }
        self.applyLiveBindings(stmts.items, li_start, le_start);
        if (self.had_error) {
            return ParseResult{ .err = self.error_info orelse ParseError{
                .message = "parse error",
                .line = self.current.line,
                .column = self.current.column,
            } };
        }
        return ParseResult{ .ok = stmts.items };
    }

    /// Milestone 16 — Phase 1: parse a unit of ES-module code.
    ///
    /// Identical statement grammar to `parseScript` (the import/export desugar
    /// onto CommonJS `require`/`exports` already runs inside `parseStatement`),
    /// but the result is module code: always strict (§11.2.2). Callers build a
    /// `Program{ .is_module = true, .is_strict = true }` from `.ok`. Errors use
    /// the same `ParseResult.err` channel as scripts.
    pub fn parseModule(self: *Parser) ParseResult {
        self.is_module = true;
        var stmts = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&stmts);
        }
        self.applyLiveBindings(stmts.items, li_start, le_start);
        if (self.had_error) {
            return ParseResult{ .err = self.error_info orelse ParseError{
                .message = "parse error",
                .line = self.current.line,
                .column = self.current.column,
            } };
        }
        return ParseResult{ .ok = stmts.items };
    }

    // ---------------------------------------------------- Phase 8: ES modules ---
    // Desugar import/export onto the existing CommonJS require/exports model.

    pub fn fail(self: *Parser, msg: []const u8) ?*Node {
        if (!self.had_error) {
            self.had_error = true;
            self.error_info = ParseError{ .message = msg, .line = self.current.line, .column = self.current.column };
        }
        return null;
    }

    pub fn drainExtraStmts(self: *Parser, stmts: *std.ArrayList(*Node)) void {
        for (self.extra_stmts.items) |e| {
            stmts.append(self.arena, e) catch {
                self.had_error = true;
                return;
            };
        }
        self.extra_stmts.clearRetainingCapacity();
    }

    pub fn matchContextual(self: *Parser, word: []const u8) bool {
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.value_str, word)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    pub fn mkIdent(self: *Parser, name: []const u8) ?*Node {
        return self.makeNode(.identifier, self.current.start, self.current.start, .{ .identifier = name });
    }
    pub fn mkMember(self: *Parser, obj: *Node, prop: []const u8) ?*Node {
        const p = self.mkIdent(prop) orelse return null;
        return self.makeNode(.member_expr, obj.start, self.current.start, .{ .member_expr = .{ .object = obj, .property = p, .computed = false } });
    }
    pub fn mkRequire(self: *Parser, modname: []const u8) ?*Node {
        const callee = self.mkIdent("require") orelse return null;
        const arg = self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = modname }) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(self.arena, arg) catch return null;
        return self.makeNode(.call_expr, self.current.start, self.current.start, .{ .call_expr = .{ .callee = callee, .args = args.items } });
    }
    /// Build a one-argument call `callee_name(arg)` (e.g. `__makeNamespace__(x)`).
    pub fn mkCall1(self: *Parser, callee_name: []const u8, arg: *Node) ?*Node {
        const callee = self.mkIdent(callee_name) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(self.arena, arg) catch return null;
        return self.makeNode(.call_expr, self.current.start, self.current.start, .{ .call_expr = .{ .callee = callee, .args = args.items } });
    }
    pub fn mkVar(self: *Parser, name: []const u8, init_node: *Node) ?*Node {
        return self.makeNode(.var_decl, self.current.start, self.current.start, .{ .var_decl = .{ .kind = .var_, .name = name, .init = init_node } });
    }
    pub fn mkExportAssign(self: *Parser, exported: []const u8, value: *Node) ?*Node {
        const exports_id = self.mkIdent("exports") orelse return null;
        const target = self.mkMember(exports_id, exported) orelse return null;
        const assign = self.makeNode(.assignment_expr, self.current.start, self.current.start, .{ .assignment_expr = .{ .op = .assign, .target = target, .value = value } }) orelse return null;
        return self.makeNode(.expr_stmt, self.current.start, self.current.start, .{ .expr_stmt = assign });
    }

    /// Push items[1..] into extra_stmts; return items[0] (the primary statement).
    pub fn finishMulti(self: *Parser, items: []*Node) ?*Node {
        if (items.len == 0) return self.makeNode(.empty_stmt, self.current.start, self.current.start, .{ .empty_stmt = {} });
        for (items[1..]) |it| self.extra_stmts.append(self.arena, it) catch {
            self.had_error = true;
            return null;
        };
        return items[0];
    }

    pub fn collectDeclNames(self: *Parser, node: *Node, list: *std.ArrayList([]const u8)) void {
        switch (node.kind) {
            .var_decl => list.append(self.arena, node.data.var_decl.name) catch {},
            .function_decl => list.append(self.arena, node.data.function_decl.name) catch {},
            .block_stmt => for (node.data.block_stmt.body) |c| self.collectDeclNames(c, list),
            else => {},
        }
    }

    // Live bindings: rewrite each named/default import use-site to `ns.prop`, and each
    // `export let/var` use-site to `exports.name`, when the local name has no declaration
    // other than its own binding (count <= 1) — sound (no shadowing possible). Shadowed
    // names keep CJS-snapshot semantics.
    pub fn applyLiveBindings(self: *Parser, stmts: []*Node, li_start: usize, le_start: usize) void {
        if (self.had_error) {
            self.live_imports.shrinkRetainingCapacity(li_start);
            self.live_exports.shrinkRetainingCapacity(le_start);
            return;
        }
        const n = self.live_imports.items.len;
        const ne = self.live_exports.items.len;
        if (n <= li_start and ne <= le_start) return;
        var counts = std.StringHashMap(u32).init(self.arena);
        for (stmts) |s| self.countDecls(s, &counts);
        var i = li_start;
        while (i < n) : (i += 1) {
            const imp = self.live_imports.items[i];
            if ((counts.get(imp.name) orelse 0) <= 1) {
                for (stmts) |s| self.rewriteName(s, imp.name, imp.ns, imp.prop);
            }
        }
        var j = le_start;
        while (j < ne) : (j += 1) {
            const name = self.live_exports.items[j];
            if ((counts.get(name) orelse 0) <= 1) self.makeExportLive(stmts, name);
        }
        self.live_imports.shrinkRetainingCapacity(li_start);
        self.live_exports.shrinkRetainingCapacity(le_start);
    }

    /// Is `s` the generated snapshot `exports.name = name;`?
    pub fn isSnapshotAssign(s: *Node, name: []const u8) bool {
        if (s.kind != .expr_stmt) return false;
        const e = s.data.expr_stmt;
        if (e.kind != .assignment_expr) return false;
        const a = e.data.assignment_expr;
        if (a.value.kind != .identifier or !std.mem.eql(u8, a.value.data.identifier, name)) return false;
        const t = a.target;
        if (t.kind != .member_expr or t.data.member_expr.computed) return false;
        const obj = t.data.member_expr.object;
        const prop = t.data.member_expr.property;
        return obj.kind == .identifier and std.mem.eql(u8, obj.data.identifier, "exports") and
            prop.kind == .identifier and std.mem.eql(u8, prop.data.identifier, name);
    }

    /// Turn a `export let/var name = E` into the live form: seed `exports.name = E`,
    /// drop the snapshot assignment, and rewrite all `name` use-sites to `exports.name`.
    pub fn makeExportLive(self: *Parser, stmts: []*Node, name: []const u8) void {
        // If the only binding for `name` is a function declaration (not a var/let/const),
        // the snapshot `exports.name = name` is sufficient — function declarations are
        // hoisted so the snapshot always captures the correct value. Skip live rewriting
        // to avoid `exports.name = exports.name` circularity.
        var has_var_decl = false;
        var has_func_decl = false;
        for (stmts) |s| {
            if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, name)) has_var_decl = true;
            if (s.kind == .function_decl and std.mem.eql(u8, s.data.function_decl.name, name)) has_func_decl = true;
        }
        if (has_func_decl and !has_var_decl) return;
        for (stmts) |s| {
            if (isSnapshotAssign(s, name)) {
                s.* = Node{ .kind = .empty_stmt, .start = s.start, .end = s.end, .data = .{ .empty_stmt = {} } };
            } else if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, name)) {
                if (s.data.var_decl.init) |init_node| {
                    const obj = self.makeNode(.identifier, s.start, s.start, .{ .identifier = "exports" }) orelse continue;
                    const p = self.makeNode(.identifier, s.start, s.start, .{ .identifier = name }) orelse continue;
                    const tgt = self.makeNode(.member_expr, s.start, s.start, .{ .member_expr = .{ .object = obj, .property = p, .computed = false } }) orelse continue;
                    const asn = self.makeNode(.assignment_expr, s.start, s.start, .{ .assignment_expr = .{ .op = .assign, .target = tgt, .value = init_node } }) orelse continue;
                    s.* = Node{ .kind = .expr_stmt, .start = s.start, .end = s.end, .data = .{ .expr_stmt = asn } };
                } else {
                    // `export var/let x;` with no initializer still creates the
                    // exported binding (value undefined) so it appears in the
                    // module namespace's keys: rewrite to `exports.x = undefined`.
                    const obj = self.makeNode(.identifier, s.start, s.start, .{ .identifier = "exports" }) orelse continue;
                    const p = self.makeNode(.identifier, s.start, s.start, .{ .identifier = name }) orelse continue;
                    const tgt = self.makeNode(.member_expr, s.start, s.start, .{ .member_expr = .{ .object = obj, .property = p, .computed = false } }) orelse continue;
                    const undef = self.makeNode(.identifier, s.start, s.start, .{ .identifier = "undefined" }) orelse continue;
                    const asn = self.makeNode(.assignment_expr, s.start, s.start, .{ .assignment_expr = .{ .op = .assign, .target = tgt, .value = undef } }) orelse continue;
                    s.* = Node{ .kind = .expr_stmt, .start = s.start, .end = s.end, .data = .{ .expr_stmt = asn } };
                }
            }
        }
        for (stmts) |s| self.rewriteName(s, name, "exports", name);
    }

    pub fn incCount(self: *Parser, counts: *std.StringHashMap(u32), name: []const u8) void {
        _ = self;
        const gop = counts.getOrPut(name) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    pub fn countDecls(self: *Parser, n: *Node, counts: *std.StringHashMap(u32)) void {
        switch (n.kind) {
            .var_decl => {
                self.incCount(counts, n.data.var_decl.name);
                if (n.data.var_decl.init) |x| self.countDecls(x, counts);
            },
            .function_decl => {
                const f = n.data.function_decl;
                self.incCount(counts, f.name);
                for (f.params) |p| self.incCount(counts, p);
                if (f.rest_param) |r| self.incCount(counts, r);
                for (f.body) |s| self.countDecls(s, counts);
            },
            .function_expr => {
                const f = n.data.function_expr;
                if (f.name) |nm| self.incCount(counts, nm);
                for (f.params) |p| self.incCount(counts, p);
                if (f.rest_param) |r| self.incCount(counts, r);
                for (f.body) |s| self.countDecls(s, counts);
            },
            .program => for (n.data.program.body) |s| self.countDecls(s, counts),
            .block_stmt => for (n.data.block_stmt.body) |s| self.countDecls(s, counts),
            .expr_stmt => self.countDecls(n.data.expr_stmt, counts),
            .if_stmt => {
                self.countDecls(n.data.if_stmt.test_, counts);
                self.countDecls(n.data.if_stmt.consequent, counts);
                if (n.data.if_stmt.alternate) |a| self.countDecls(a, counts);
            },
            .while_stmt => {
                self.countDecls(n.data.while_stmt.test_, counts);
                self.countDecls(n.data.while_stmt.body, counts);
            },
            .do_while_stmt => {
                self.countDecls(n.data.do_while_stmt.body, counts);
                self.countDecls(n.data.do_while_stmt.test_, counts);
            },
            .for_stmt => {
                const f = n.data.for_stmt;
                if (f.init) |x| self.countDecls(x, counts);
                if (f.test_) |x| self.countDecls(x, counts);
                if (f.update) |x| self.countDecls(x, counts);
                self.countDecls(f.body, counts);
            },
            .for_in_stmt => {
                const f = n.data.for_in_stmt;
                self.countDecls(f.left, counts);
                self.countDecls(f.right, counts);
                self.countDecls(f.body, counts);
            },
            .return_stmt => if (n.data.return_stmt) |e| self.countDecls(e, counts),
            .throw_stmt => self.countDecls(n.data.throw_stmt, counts),
            .try_stmt => {
                const t = n.data.try_stmt;
                self.countDecls(t.block, counts);
                if (t.handler) |h| {
                    self.incCount(counts, h.param_name);
                    self.countDecls(h.body, counts);
                }
                if (t.finalizer) |fz| self.countDecls(fz, counts);
            },
            .switch_stmt => {
                const s = n.data.switch_stmt;
                self.countDecls(s.discriminant, counts);
                for (s.cases) |c| {
                    if (c.test_) |t| self.countDecls(t, counts);
                    for (c.body) |st| self.countDecls(st, counts);
                }
            },
            .labeled_stmt => self.countDecls(n.data.labeled_stmt.body, counts),
            .unary_expr => self.countDecls(n.data.unary_expr.operand, counts),
            .binary_expr => {
                self.countDecls(n.data.binary_expr.left, counts);
                self.countDecls(n.data.binary_expr.right, counts);
            },
            .logical_expr => {
                self.countDecls(n.data.logical_expr.left, counts);
                self.countDecls(n.data.logical_expr.right, counts);
            },
            .assignment_expr => {
                self.countDecls(n.data.assignment_expr.target, counts);
                self.countDecls(n.data.assignment_expr.value, counts);
            },
            .update_expr => self.countDecls(n.data.update_expr.operand, counts),
            .conditional_expr => {
                const c = n.data.conditional_expr;
                self.countDecls(c.test_, counts);
                self.countDecls(c.consequent, counts);
                self.countDecls(c.alternate, counts);
            },
            .sequence_expr => for (n.data.sequence_expr.exprs) |e| self.countDecls(e, counts),
            .spread_expr => self.countDecls(n.data.spread_expr, counts),
            .yield_expr => if (n.data.yield_expr) |e| self.countDecls(e, counts),
            .call_expr => {
                self.countDecls(n.data.call_expr.callee, counts);
                for (n.data.call_expr.args) |a| self.countDecls(a, counts);
            },
            .new_expr => {
                self.countDecls(n.data.new_expr.callee, counts);
                for (n.data.new_expr.args) |a| self.countDecls(a, counts);
            },
            .member_expr => {
                self.countDecls(n.data.member_expr.object, counts);
                if (n.data.member_expr.computed) self.countDecls(n.data.member_expr.property, counts);
            },
            .optional_chain => self.countDecls(n.data.optional_chain, counts),
            .object_literal => for (n.data.object_literal.properties) |p| self.countDecls(p.value, counts),
            .array_literal => for (n.data.array_literal.elements) |e| self.countDecls(e, counts),
            else => {},
        }
    }

    pub fn rewriteName(self: *Parser, n: *Node, name: []const u8, ns: []const u8, prop: []const u8) void {
        switch (n.kind) {
            .identifier => {
                if (std.mem.eql(u8, n.data.identifier, name)) {
                    const obj = self.makeNode(.identifier, n.start, n.end, .{ .identifier = ns }) orelse return;
                    const p = self.makeNode(.identifier, n.start, n.end, .{ .identifier = prop }) orelse return;
                    n.* = Node{ .kind = .member_expr, .start = n.start, .end = n.end, .data = .{ .member_expr = .{ .object = obj, .property = p, .computed = false } } };
                }
            },
            .function_decl => for (n.data.function_decl.body) |s| self.rewriteName(s, name, ns, prop),
            .function_expr => for (n.data.function_expr.body) |s| self.rewriteName(s, name, ns, prop),
            .program => for (n.data.program.body) |s| self.rewriteName(s, name, ns, prop),
            .block_stmt => for (n.data.block_stmt.body) |s| self.rewriteName(s, name, ns, prop),
            .var_decl => if (n.data.var_decl.init) |x| self.rewriteName(x, name, ns, prop),
            .expr_stmt => self.rewriteName(n.data.expr_stmt, name, ns, prop),
            .if_stmt => {
                self.rewriteName(n.data.if_stmt.test_, name, ns, prop);
                self.rewriteName(n.data.if_stmt.consequent, name, ns, prop);
                if (n.data.if_stmt.alternate) |a| self.rewriteName(a, name, ns, prop);
            },
            .while_stmt => {
                self.rewriteName(n.data.while_stmt.test_, name, ns, prop);
                self.rewriteName(n.data.while_stmt.body, name, ns, prop);
            },
            .do_while_stmt => {
                self.rewriteName(n.data.do_while_stmt.body, name, ns, prop);
                self.rewriteName(n.data.do_while_stmt.test_, name, ns, prop);
            },
            .for_stmt => {
                const f = n.data.for_stmt;
                if (f.init) |x| self.rewriteName(x, name, ns, prop);
                if (f.test_) |x| self.rewriteName(x, name, ns, prop);
                if (f.update) |x| self.rewriteName(x, name, ns, prop);
                self.rewriteName(f.body, name, ns, prop);
            },
            .for_in_stmt => {
                const f = n.data.for_in_stmt;
                self.rewriteName(f.left, name, ns, prop);
                self.rewriteName(f.right, name, ns, prop);
                self.rewriteName(f.body, name, ns, prop);
            },
            .return_stmt => if (n.data.return_stmt) |e| self.rewriteName(e, name, ns, prop),
            .throw_stmt => self.rewriteName(n.data.throw_stmt, name, ns, prop),
            .try_stmt => {
                const t = n.data.try_stmt;
                self.rewriteName(t.block, name, ns, prop);
                if (t.handler) |h| self.rewriteName(h.body, name, ns, prop);
                if (t.finalizer) |fz| self.rewriteName(fz, name, ns, prop);
            },
            .switch_stmt => {
                const s = n.data.switch_stmt;
                self.rewriteName(s.discriminant, name, ns, prop);
                for (s.cases) |c| {
                    if (c.test_) |t| self.rewriteName(t, name, ns, prop);
                    for (c.body) |st| self.rewriteName(st, name, ns, prop);
                }
            },
            .labeled_stmt => self.rewriteName(n.data.labeled_stmt.body, name, ns, prop),
            .unary_expr => self.rewriteName(n.data.unary_expr.operand, name, ns, prop),
            .binary_expr => {
                self.rewriteName(n.data.binary_expr.left, name, ns, prop);
                self.rewriteName(n.data.binary_expr.right, name, ns, prop);
            },
            .logical_expr => {
                self.rewriteName(n.data.logical_expr.left, name, ns, prop);
                self.rewriteName(n.data.logical_expr.right, name, ns, prop);
            },
            .assignment_expr => {
                self.rewriteName(n.data.assignment_expr.target, name, ns, prop);
                self.rewriteName(n.data.assignment_expr.value, name, ns, prop);
            },
            .update_expr => self.rewriteName(n.data.update_expr.operand, name, ns, prop),
            .conditional_expr => {
                const c = n.data.conditional_expr;
                self.rewriteName(c.test_, name, ns, prop);
                self.rewriteName(c.consequent, name, ns, prop);
                self.rewriteName(c.alternate, name, ns, prop);
            },
            .sequence_expr => for (n.data.sequence_expr.exprs) |e| self.rewriteName(e, name, ns, prop),
            .spread_expr => self.rewriteName(n.data.spread_expr, name, ns, prop),
            .yield_expr => if (n.data.yield_expr) |e| self.rewriteName(e, name, ns, prop),
            .call_expr => {
                self.rewriteName(n.data.call_expr.callee, name, ns, prop);
                for (n.data.call_expr.args) |a| self.rewriteName(a, name, ns, prop);
            },
            .new_expr => {
                self.rewriteName(n.data.new_expr.callee, name, ns, prop);
                for (n.data.new_expr.args) |a| self.rewriteName(a, name, ns, prop);
            },
            .member_expr => {
                self.rewriteName(n.data.member_expr.object, name, ns, prop);
                if (n.data.member_expr.computed) self.rewriteName(n.data.member_expr.property, name, ns, prop);
            },
            .optional_chain => self.rewriteName(n.data.optional_chain, name, ns, prop),
            .object_literal => for (n.data.object_literal.properties) |p| self.rewriteName(p.value, name, ns, prop),
            .array_literal => for (n.data.array_literal.elements) |e| self.rewriteName(e, name, ns, prop),
            else => {},
        }
    }

    pub fn parseImportDecl(self: *Parser) ?*Node {
        return stmt_mod.parseImportDecl(self);
    }

    pub fn parseExportDecl(self: *Parser) ?*Node {
        return stmt_mod.parseExportDecl(self);
    }

    pub fn parseStatement(self: *Parser) ?*Node {
        return stmt_mod.parseStatement(self);
    }

    /// Continue parsing an expression that started with an identifier node already parsed.
    pub fn parseExprFromIdent(self: *Parser, ident: *Node) ?*Node {
        return expr_mod.parseExprFromIdent(self, ident);
    }



    pub fn parseBlock(self: *Parser) ?*Node {
        return stmt_mod.parseBlock(self);
    }

    pub fn parseVarDeclStmt(self: *Parser) ?*Node {
        return stmt_mod.parseVarDeclStmt(self);
    }

    pub fn parseLexicalDeclStmt(self: *Parser, kind: ast.VarKind) ?*Node {
        return stmt_mod.parseLexicalDeclStmt(self, kind);
    }

    /// Parse one or more var declarators (comma separated). Returns a sequence
    /// if multiple, single VarDecl if one. For for-loop init this is fine.
    pub fn parseVarDeclarators(self: *Parser, start: u32, kind: ast.VarKind, consume_semicolon: bool) ?*Node {
        return stmt_mod.parseVarDeclarators(self, start, kind, consume_semicolon);
    }

    pub fn parseVarDeclarator(self: *Parser, kind: ast.VarKind) ?*Node {
        return stmt_mod.parseVarDeclarator(self, kind);
    }

    pub fn parseDestructuringDeclarator(self: *Parser, kind: ast.VarKind, start: u32) ?*Node {
        return stmt_mod.parseDestructuringDeclarator(self, kind, start);
    }

    pub fn parseFunctionDecl(self: *Parser, is_async: bool) ?*Node {
        return stmt_mod.parseFunctionDecl(self, is_async);
    }

    pub fn parseClassDeclStmt(self: *Parser) ?*Node {
        return class_mod.parseClassDeclStmt(self);
    }

    pub fn parseClassExpr(self: *Parser) ?*Node {
        return class_mod.parseClassExpr(self);
    }

    pub fn parseFunctionParams(self: *Parser) ?ParamParse {
        return class_mod.parseFunctionParams(self);
    }

    pub fn parseFunctionBody(self: *Parser) ?[]*Node {
        return class_mod.parseFunctionBody(self);
    }

    pub fn parseIfStmt(self: *Parser) ?*Node {
        return stmt_mod.parseIfStmt(self);
    }

    pub fn parseWhileStmt(self: *Parser) ?*Node {
        return stmt_mod.parseWhileStmt(self);
    }

    pub fn parseDoWhileStmt(self: *Parser) ?*Node {
        return stmt_mod.parseDoWhileStmt(self);
    }

    pub fn parseForStmt(self: *Parser) ?*Node {
        return stmt_mod.parseForStmt(self);
    }

    pub fn parseForDestructuring(self: *Parser, start: u32, kind: ast.VarKind) ?*Node {
        return stmt_mod.parseForDestructuring(self, start, kind);
    }

    pub fn parseForTail(self: *Parser, start: u32, init_node: ?*Node) ?*Node {
        return stmt_mod.parseForTail(self, start, init_node);
    }

    pub fn parseSwitchStmt(self: *Parser) ?*Node {
        return stmt_mod.parseSwitchStmt(self);
    }

    pub fn parseReturnStmt(self: *Parser) ?*Node {
        return stmt_mod.parseReturnStmt(self);
    }

    pub fn parseBreakStmt(self: *Parser) ?*Node {
        return stmt_mod.parseBreakStmt(self);
    }

    pub fn parseContinueStmt(self: *Parser) ?*Node {
        return stmt_mod.parseContinueStmt(self);
    }

    pub fn parseThrowStmt(self: *Parser) ?*Node {
        return stmt_mod.parseThrowStmt(self);
    }

    pub fn parseTryStmt(self: *Parser) ?*Node {
        return stmt_mod.parseTryStmt(self);
    }

    pub fn parseExprStmt(self: *Parser) ?*Node {
        return stmt_mod.parseExprStmt(self);
    }

    // --------------------------------------------------------- expressions ---

    /// Parse a full expression (includes comma operator).
    pub fn parseExpression(self: *Parser) ?*Node {
        return expr_mod.parseExpression(self);
    }

    pub fn parseAssignmentExpr(self: *Parser) ?*Node {
        return expr_mod.parseAssignmentExpr(self);
    }

    pub fn parseAssignmentExprCore(self: *Parser, is_async_arrow: bool) ?*Node {
        return expr_mod.parseAssignmentExprCore(self, is_async_arrow);
    }

    pub fn extractArrowParams(self: *Parser, lhs: *Node) ?[][]const u8 {
        return expr_mod.extractArrowParams(self, lhs);
    }

    pub fn parseConditionalExpr(self: *Parser) ?*Node {
        return expr_mod.parseConditionalExpr(self);
    }

    /// Emit the "cannot mix ?? with && or ||" SyntaxError.
    pub fn coalesceMixError(self: *Parser) void {
        expr_mod.coalesceMixError(self);
    }

    /// Pratt-style binary expression parser.
    pub fn parseBinaryExpr(self: *Parser, min_prec: u8) ?*Node {
        return expr_mod.parseBinaryExpr(self, min_prec);
    }

    pub fn parseUnaryExpr(self: *Parser) ?*Node {
        return expr_mod.parseUnaryExpr(self);
    }

    /// Parse call, member access, subscript. Handles ES2020 optional chaining
    /// (`?.`); if any link in the chain is optional, the whole chain is wrapped
    /// in an `optional_chain` node which establishes the short-circuit boundary.
    pub fn parseCallMemberExpr(self: *Parser) ?*Node {
        return expr_mod.parseCallMemberExpr(self);
    }

    /// Rewrite super call sites into explicit .call(this, ...) form.
    /// - super(a, b) -> super.call(this, a, b)
    /// - super.m(a)  -> super.m.call(this, a)
    pub fn rewriteSuperCall(self: *Parser, call_node: *Node) ?*Node {
        return expr_mod.rewriteSuperCall(self, call_node);
    }

    /// Parse a member expression without call expressions (for `new` callee).
    /// Handles dot and bracket access but NOT `(` argument lists.
    pub fn parseNewCallee(self: *Parser) ?*Node {
        return expr_mod.parseNewCallee(self);
    }

    pub fn parseArgs(self: *Parser) ?[]*Node {
        return expr_mod.parseArgs(self);
    }

    pub fn parsePrimaryExpr(self: *Parser) ?*Node {
        return expr_mod.parsePrimaryExpr(self);
    }

    pub fn parseObjectLiteral(self: *Parser) ?*Node {
        return expr_mod.parseObjectLiteral(self);
    }

    pub fn parseArrayLiteral(self: *Parser) ?*Node {
        return expr_mod.parseArrayLiteral(self);
    }

    pub fn parseFunctionExpr(self: *Parser, is_async: bool) ?*Node {
        return expr_mod.parseFunctionExpr(self, is_async);
    }

    /// Parse a complete script with strict mode detection.
    pub fn parseScriptWithStrict(self: *Parser) struct { stmts: []*Node, is_strict: bool } {
        var stmts = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&stmts);
        }
        self.applyLiveBindings(stmts.items, li_start, le_start);
        const is_strict = hasUseStrict(stmts.items);
        return .{ .stmts = stmts.items, .is_strict = is_strict };
    }
};

// ---------------------------------------------------------------- helpers ---
// tokenToBinaryOp, tokenToUnaryOp, tokenToAssignOp, parseRegexRaw,
// isUnparenthesizedAndOr, isUnparenthesizedNullish moved to expr.zig.

// ------------------------------------------------------------------- tests ---

test "Parser: 1+2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("1+2", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| {
            try std.testing.expectEqual(@as(usize, 1), stmts.len);
        },
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: function expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("(function(x){ return x * 2; })(21)", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| try std.testing.expectEqual(@as(usize, 1), stmts.len),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: var decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("var x = 42;", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| try std.testing.expectEqual(@as(usize, 1), stmts.len),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: if else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("if (1 < 2) { 1; } else { 2; }", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| try std.testing.expectEqual(@as(usize, 1), stmts.len),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("while (i < 5) { i = i + 1; }", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| try std.testing.expectEqual(@as(usize, 1), stmts.len),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("for (var i = 0; i < 10; i = i + 1) { }", arena.allocator());
    const result = p.parseScript();
    switch (result) {
        .ok => |stmts| try std.testing.expectEqual(@as(usize, 1), stmts.len),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "Parser: parseModule desugars export var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init("export var x = 42;", arena.allocator());
    const result = p.parseModule();
    switch (result) {
        .ok => |stmts| try std.testing.expect(stmts.len >= 1),
        .err => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}
