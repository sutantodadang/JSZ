// SPDX-License-Identifier: MIT
//! Recursive descent / Pratt-style parser for ES5 subset.
//! All nodes are arena-allocated; caller owns the arena lifetime.
const std = @import("std");
const Lexer = @import("../lexer/lexer.zig").Lexer;
const LexError = @import("../lexer/lexer.zig").LexError;
const Token = @import("../lexer/token.zig").Token;
const TokenKind = @import("../lexer/token.zig").TokenKind;
const ast = @import("./ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;
const prec_mod = @import("./precedence.zig");
const Prec = prec_mod.Prec;
const infixPrec = prec_mod.infixPrec;
const isAssignOp = prec_mod.isAssignOp;
const recovery = @import("./recovery.zig");
pub const ParseError = recovery.ParseError;

const ParamParse = struct {
    params: [][]const u8,
    param_defaults: []?*Node,
    rest_param: ?[]const u8,
};

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

    fn advance(self: *Parser) Token {
        const prev = self.current;
        self.current = self.lexNext();
        return prev;
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.current.kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ?Token {
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

    fn alloc(self: *Parser) ?*Node {
        return self.arena.create(Node) catch {
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{ .message = "out of memory", .line = 0, .column = 0 };
            }
            return null;
        };
    }

    fn makeNode(self: *Parser, kind: NodeKind, start: u32, end: u32, data: ast.Data) ?*Node {
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
    fn hasSemicolon(self: *Parser) bool {
        if (self.current.kind == .semicolon) return true;
        if (self.current.kind == .right_brace) return true;
        if (self.current.kind == .eof) return true;
        if (self.current.line_terminator_before) return true;
        return false;
    }

    fn consumeSemicolon(self: *Parser) void {
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

    // ---------------------------------------------------- Phase 8: ES modules ---
    // Desugar import/export onto the existing CommonJS require/exports model.

    fn fail(self: *Parser, msg: []const u8) ?*Node {
        if (!self.had_error) {
            self.had_error = true;
            self.error_info = ParseError{ .message = msg, .line = self.current.line, .column = self.current.column };
        }
        return null;
    }

    fn drainExtraStmts(self: *Parser, stmts: *std.ArrayList(*Node)) void {
        for (self.extra_stmts.items) |e| {
            stmts.append(self.arena, e) catch {
                self.had_error = true;
                return;
            };
        }
        self.extra_stmts.clearRetainingCapacity();
    }

    fn matchContextual(self: *Parser, word: []const u8) bool {
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.value_str, word)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn mkIdent(self: *Parser, name: []const u8) ?*Node {
        return self.makeNode(.identifier, self.current.start, self.current.start, .{ .identifier = name });
    }
    fn mkMember(self: *Parser, obj: *Node, prop: []const u8) ?*Node {
        const p = self.mkIdent(prop) orelse return null;
        return self.makeNode(.member_expr, obj.start, self.current.start, .{ .member_expr = .{ .object = obj, .property = p, .computed = false } });
    }
    fn mkRequire(self: *Parser, modname: []const u8) ?*Node {
        const callee = self.mkIdent("require") orelse return null;
        const arg = self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = modname }) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(self.arena, arg) catch return null;
        return self.makeNode(.call_expr, self.current.start, self.current.start, .{ .call_expr = .{ .callee = callee, .args = args.items } });
    }
    fn mkVar(self: *Parser, name: []const u8, init_node: *Node) ?*Node {
        return self.makeNode(.var_decl, self.current.start, self.current.start, .{ .var_decl = .{ .kind = .var_, .name = name, .init = init_node } });
    }
    fn mkExportAssign(self: *Parser, exported: []const u8, value: *Node) ?*Node {
        const exports_id = self.mkIdent("exports") orelse return null;
        const target = self.mkMember(exports_id, exported) orelse return null;
        const assign = self.makeNode(.assignment_expr, self.current.start, self.current.start, .{ .assignment_expr = .{ .op = .assign, .target = target, .value = value } }) orelse return null;
        return self.makeNode(.expr_stmt, self.current.start, self.current.start, .{ .expr_stmt = assign });
    }

    /// Push items[1..] into extra_stmts; return items[0] (the primary statement).
    fn finishMulti(self: *Parser, items: []*Node) ?*Node {
        if (items.len == 0) return self.makeNode(.empty_stmt, self.current.start, self.current.start, .{ .empty_stmt = {} });
        for (items[1..]) |it| self.extra_stmts.append(self.arena, it) catch {
            self.had_error = true;
            return null;
        };
        return items[0];
    }

    fn collectDeclNames(self: *Parser, node: *Node, list: *std.ArrayList([]const u8)) void {
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
    fn applyLiveBindings(self: *Parser, stmts: []*Node, li_start: usize, le_start: usize) void {
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
    fn isSnapshotAssign(s: *Node, name: []const u8) bool {
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
    fn makeExportLive(self: *Parser, stmts: []*Node, name: []const u8) void {
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
                    s.* = Node{ .kind = .empty_stmt, .start = s.start, .end = s.end, .data = .{ .empty_stmt = {} } };
                }
            }
        }
        for (stmts) |s| self.rewriteName(s, name, "exports", name);
    }

    fn incCount(self: *Parser, counts: *std.StringHashMap(u32), name: []const u8) void {
        _ = self;
        const gop = counts.getOrPut(name) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    fn countDecls(self: *Parser, n: *Node, counts: *std.StringHashMap(u32)) void {
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
            .object_literal => for (n.data.object_literal.properties) |p| self.countDecls(p.value, counts),
            .array_literal => for (n.data.array_literal.elements) |e| self.countDecls(e, counts),
            else => {},
        }
    }

    fn rewriteName(self: *Parser, n: *Node, name: []const u8, ns: []const u8, prop: []const u8) void {
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
            .object_literal => for (n.data.object_literal.properties) |p| self.rewriteName(p.value, name, ns, prop),
            .array_literal => for (n.data.array_literal.elements) |e| self.rewriteName(e, name, ns, prop),
            else => {},
        }
    }

    fn parseImportDecl(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // import

        // import "mod";  (side-effect only)
        if (self.current.kind == .string) {
            const modname = self.current.value_str;
            _ = self.advance();
            self.consumeSemicolon();
            const req = self.mkRequire(modname) orelse return null;
            return self.makeNode(.expr_stmt, start, self.current.start, .{ .expr_stmt = req });
        }

        var default_name: ?[]const u8 = null;
        var ns_name: ?[]const u8 = null;
        const Named = struct { imp: []const u8, local: []const u8 };
        var named = std.ArrayList(Named){};

        if (self.current.kind == .identifier) {
            default_name = self.current.value_str;
            _ = self.advance();
            _ = self.match(.comma);
        }
        if (self.match(.star)) {
            if (!self.matchContextual("as")) return self.fail("expected 'as' after import *");
            const t = self.expect(.identifier) orelse return null;
            ns_name = t.value_str;
        } else if (self.match(.left_brace)) {
            while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
                const imp = self.expect(.identifier) orelse return null;
                var local = imp.value_str;
                if (self.matchContextual("as")) {
                    const lt = self.expect(.identifier) orelse return null;
                    local = lt.value_str;
                }
                named.append(self.arena, .{ .imp = imp.value_str, .local = local }) catch return null;
                if (!self.match(.comma)) break;
            }
            _ = self.expect(.right_brace) orelse return null;
        }
        if (!self.matchContextual("from")) return self.fail("expected 'from' in import declaration");
        const modtok = self.expect(.string) orelse return null;
        const modname = modtok.value_str;
        self.consumeSemicolon();

        const tmp = std.fmt.allocPrint(self.arena, "__esm_{d}", .{start}) catch return null;
        var out = std.ArrayList(*Node){};
        const req = self.mkRequire(modname) orelse return null;
        out.append(self.arena, self.mkVar(tmp, req) orelse return null) catch return null;
        if (default_name) |d| {
            const m = self.mkMember(self.mkIdent(tmp) orelse return null, "default") orelse return null;
            out.append(self.arena, self.mkVar(d, m) orelse return null) catch return null;
            self.live_imports.append(self.arena, .{ .name = d, .ns = tmp, .prop = "default" }) catch return null;
        }
        if (ns_name) |n| {
            out.append(self.arena, self.mkVar(n, self.mkIdent(tmp) orelse return null) orelse return null) catch return null;
        }
        for (named.items) |nb| {
            const m = self.mkMember(self.mkIdent(tmp) orelse return null, nb.imp) orelse return null;
            out.append(self.arena, self.mkVar(nb.local, m) orelse return null) catch return null;
            self.live_imports.append(self.arena, .{ .name = nb.local, .ns = tmp, .prop = nb.imp }) catch return null;
        }
        return self.finishMulti(out.items);
    }

    fn parseExportDecl(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // export

        // export default <assignmentExpr>;
        if (self.match(.kw_default)) {
            const expr = self.parseAssignmentExpr() orelse return null;
            self.consumeSemicolon();
            return self.mkExportAssign("default", expr);
        }

        // export { a, b as c } [from "mod"];
        if (self.match(.left_brace)) {
            const Spec = struct { local: []const u8, exported: []const u8 };
            var specs = std.ArrayList(Spec){};
            while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
                const l = self.expect(.identifier) orelse return null;
                var exported = l.value_str;
                if (self.matchContextual("as")) {
                    const e = self.expect(.identifier) orelse return null;
                    exported = e.value_str;
                }
                specs.append(self.arena, .{ .local = l.value_str, .exported = exported }) catch return null;
                if (!self.match(.comma)) break;
            }
            _ = self.expect(.right_brace) orelse return null;

            var tmp: ?[]const u8 = null;
            var out = std.ArrayList(*Node){};
            if (self.matchContextual("from")) {
                const modtok = self.expect(.string) orelse return null;
                tmp = std.fmt.allocPrint(self.arena, "__esm_{d}", .{start}) catch return null;
                const req = self.mkRequire(modtok.value_str) orelse return null;
                out.append(self.arena, self.mkVar(tmp.?, req) orelse return null) catch return null;
            }
            self.consumeSemicolon();
            for (specs.items) |sp| {
                const value = if (tmp) |t|
                    (self.mkMember(self.mkIdent(t) orelse return null, sp.local) orelse return null)
                else
                    (self.mkIdent(sp.local) orelse return null);
                out.append(self.arena, self.mkExportAssign(sp.exported, value) orelse return null) catch return null;
            }
            return self.finishMulti(out.items);
        }

        // export <declaration>: var/let/const/function/class
        const decl = self.parseStatement() orelse return null;
        var names = std.ArrayList([]const u8){};
        self.collectDeclNames(decl, &names);
        for (names.items) |nm| {
            const a = self.mkExportAssign(nm, self.mkIdent(nm) orelse return null) orelse return null;
            self.extra_stmts.append(self.arena, a) catch {
                self.had_error = true;
                return null;
            };
        }
        // A single reassignable declarator (`export let`/`export var x = E`) is made live:
        // its use-sites are rewritten to `exports.x` so reassignments are seen by importers.
        if (decl.kind == .var_decl and (decl.data.var_decl.kind == .let or decl.data.var_decl.kind == .var_)) {
            self.live_exports.append(self.arena, decl.data.var_decl.name) catch {};
        }
        return decl;
    }

    fn parseStatement(self: *Parser) ?*Node {
        if (self.had_error) return null;
        // Phase 8: a statement starting with `await` is an await-expression statement,
        // not a label/identifier — route to expression parsing (which desugars await).
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.value_str, "await")) {
            return self.parseExprStmt();
        }
        // Phase 4d: labeled statement — identifier followed by colon.
        if (self.current.kind == .identifier) {
            // Peek ahead: if next non-whitespace token is ':', this is a labeled stmt.
            // We need to save/restore state if it's not a label.
            // Simple approach: save state and check.
            const saved_tok = self.current;
            _ = self.advance();
            if (self.current.kind == .colon) {
                // It's a label!
                _ = self.advance(); // consume ':'
                const label_name = saved_tok.value_str;
                const body = self.parseStatement() orelse return null;
                return self.makeNode(.labeled_stmt, saved_tok.start, self.current.start, .{
                    .labeled_stmt = .{ .name = label_name, .body = body },
                });
            } else {
                // Not a label — restore by re-parsing as expr statement.
                // We consumed the identifier, so construct an identifier node.
                const ident_node = self.makeNode(.identifier, saved_tok.start, saved_tok.end, .{
                    .identifier = if (std.mem.eql(u8, saved_tok.value_str, "undefined")) blk: {
                        // It was an undefined literal but we already consumed it.
                        // Just return an undefined literal stmt.
                        break :blk saved_tok.value_str;
                    } else saved_tok.value_str,
                }) orelse return null;
                // Now parse the rest as an expression starting from ident_node.
                const full_expr = self.parseExprFromIdent(ident_node) orelse return null;
                self.consumeSemicolon();
                return self.makeNode(.expr_stmt, ident_node.start, self.current.start, .{ .expr_stmt = full_expr });
            }
        }
        return switch (self.current.kind) {
            .left_brace => self.parseBlock(),
            .kw_var => self.parseVarDeclStmt(),
            .kw_let => self.parseLexicalDeclStmt(.let),
            .kw_const => self.parseLexicalDeclStmt(.const_),
            .kw_class => self.parseClassDeclStmt(),
            .kw_import => self.parseImportDecl(),
            .kw_export => self.parseExportDecl(),
            .kw_function => self.parseFunctionDecl(),
            .kw_if => self.parseIfStmt(),
            .kw_while => self.parseWhileStmt(),
            .kw_do => self.parseDoWhileStmt(),
            .kw_for => self.parseForStmt(),
            .kw_return => self.parseReturnStmt(),
            .kw_break => self.parseBreakStmt(),
            .kw_continue => self.parseContinueStmt(),
            .kw_throw => self.parseThrowStmt(),
            .kw_try => self.parseTryStmt(),
            .kw_switch => self.parseSwitchStmt(),
            .semicolon => {
                const start = self.current.start;
                _ = self.advance();
                return self.makeNode(.empty_stmt, start, start + 1, .{ .empty_stmt = {} });
            },
            .kw_debugger => {
                const start = self.current.start;
                _ = self.advance();
                self.consumeSemicolon();
                return self.makeNode(.debugger_stmt, start, self.current.start, .{ .debugger_stmt = {} });
            },
            else => self.parseExprStmt(),
        };
    }

    /// Continue parsing an expression that started with an identifier node already parsed.
    fn parseExprFromIdent(self: *Parser, ident: *Node) ?*Node {
        // We have the identifier node. Check for assignment or other binary/postfix ops.
        var base: *Node = ident;
        // Handle postfix member access / calls.
        while (true) {
            if (self.check(.left_paren)) {
                const args = self.parseArgs() orelse return null;
                base = self.makeNode(.call_expr, base.start, self.current.start, .{
                    .call_expr = .{ .callee = base, .args = args },
                }) orelse return null;
            } else if (self.match(.dot)) {
                const prop_tok = self.expect(.identifier) orelse return null;
                const prop = self.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                    .identifier = prop_tok.value_str,
                }) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = false },
                }) orelse return null;
            } else if (self.match(.left_bracket)) {
                const prop = self.parseExpression() orelse return null;
                _ = self.expect(.right_bracket) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = true },
                }) orelse return null;
            } else if (!self.current.line_terminator_before and self.current.kind == .plus_plus) {
                _ = self.advance();
                base = self.makeNode(.update_expr, base.start, self.current.start, .{
                    .update_expr = .{ .op = .inc, .operand = base, .prefix = false },
                }) orelse return null;
                break;
            } else if (!self.current.line_terminator_before and self.current.kind == .minus_minus) {
                _ = self.advance();
                base = self.makeNode(.update_expr, base.start, self.current.start, .{
                    .update_expr = .{ .op = .dec, .operand = base, .prefix = false },
                }) orelse return null;
                break;
            } else {
                break;
            }
        }
        // Now parse binary ops.
        while (true) {
            const p = infixPrec(self.current.kind);
            if (p == 0) break;
            if (self.current.kind == .left_paren or self.current.kind == .left_bracket or self.current.kind == .dot) break;
            const op_kind = self.current.kind;
            _ = self.advance();
            const right = self.parseBinaryExpr(if (op_kind == .star_star) p - 1 else p) orelse return null;
            const start = base.start;
            base = switch (op_kind) {
                .amp_amp, .pipe_pipe => self.makeNode(.logical_expr, start, self.current.start, .{
                    .logical_expr = .{
                        .op = if (op_kind == .amp_amp) .and_ else .or_,
                        .left = base,
                        .right = right,
                    },
                }) orelse return null,
                else => self.makeNode(.binary_expr, start, self.current.start, .{
                    .binary_expr = .{
                        .op = tokenToBinaryOp(op_kind),
                        .left = base,
                        .right = right,
                    },
                }) orelse return null,
            };
        }
        // Check for assignment.
        if (isAssignOp(self.current.kind)) {
            const op = tokenToAssignOp(self.current.kind);
            _ = self.advance();
            const right = self.parseAssignmentExpr() orelse return null;
            base = self.makeNode(.assignment_expr, base.start, self.current.start, .{
                .assignment_expr = .{ .op = op, .target = base, .value = right },
            }) orelse return null;
        }
        // Ternary
        if (self.match(.question)) {
            const consequent = self.parseAssignmentExpr() orelse return null;
            _ = self.expect(.colon) orelse return null;
            const alternate = self.parseAssignmentExpr() orelse return null;
            base = self.makeNode(.conditional_expr, base.start, self.current.start, .{
                .conditional_expr = .{ .test_ = base, .consequent = consequent, .alternate = alternate },
            }) orelse return null;
        }
        // Comma
        if (self.check(.comma)) {
            var exprs = std.ArrayList(*Node){};
            exprs.append(self.arena, base) catch {
                self.had_error = true;
                return null;
            };
            while (self.match(.comma)) {
                const e = self.parseAssignmentExpr() orelse return null;
                exprs.append(self.arena, e) catch {
                    self.had_error = true;
                    return null;
                };
            }
            base = self.makeNode(.sequence_expr, base.start, self.current.start, .{
                .sequence_expr = .{ .exprs = exprs.items },
            }) orelse return null;
        }
        return base;
    }

    fn parseBlock(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.expect(.left_brace) orelse return null;
        var body = std.ArrayList(*Node){};
        while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            body.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
        }
        _ = self.expect(.right_brace) orelse return null;
        const end = self.current.start;
        const items = body.items;
        return self.makeNode(.block_stmt, start, end, .{ .block_stmt = .{ .body = items } });
    }

    fn parseVarDeclStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'var'
        return self.parseVarDeclarators(start, .var_, true);
    }

    fn parseLexicalDeclStmt(self: *Parser, kind: ast.VarKind) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume let/const
        return self.parseVarDeclarators(start, kind, true);
    }

    /// Parse one or more var declarators (comma separated). Returns a sequence
    /// if multiple, single VarDecl if one. For for-loop init this is fine.
    fn parseVarDeclarators(self: *Parser, start: u32, kind: ast.VarKind, consume_semicolon: bool) ?*Node {
        var decls = std.ArrayList(*Node){};
        while (true) {
            const d = self.parseVarDeclarator(kind) orelse return null;
            decls.append(self.arena, d) catch {
                self.had_error = true;
                return null;
            };
            if (!self.match(.comma)) break;
        }
        if (consume_semicolon) self.consumeSemicolon();
        if (decls.items.len == 1) return decls.items[0];
        // Multiple declarators: wrap in a block_stmt (not ideal, but works for eval)
        return self.makeNode(.block_stmt, start, self.current.start, .{ .block_stmt = .{ .body = decls.items } });
    }

    fn parseVarDeclarator(self: *Parser, kind: ast.VarKind) ?*Node {
        const start = self.current.start;
        if (self.check(.left_bracket) or self.check(.left_brace)) {
            return self.parseDestructuringDeclarator(kind, start);
        }
        const name_tok = self.expect(.identifier) orelse return null;
        const name = name_tok.value_str;
        var init_node: ?*Node = null;
        if (self.match(.eq)) {
            init_node = self.parseAssignmentExpr();
        }
        if (kind == .const_ and init_node == null) {
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{
                    .message = "const declaration requires an initializer",
                    .line = name_tok.line,
                    .column = name_tok.column,
                };
            }
            return null;
        }
        const end = self.current.start;
        return self.makeNode(.var_decl, start, end, .{ .var_decl = .{ .kind = kind, .name = name, .init = init_node } });
    }

    fn parseDestructuringDeclarator(self: *Parser, kind: ast.VarKind, start: u32) ?*Node {
        var names = std.ArrayList([]const u8){};
        const is_array = self.match(.left_bracket);
        if (is_array) {
            while (!self.check(.right_bracket) and !self.check(.eof) and !self.had_error) {
                if (self.check(.comma)) {
                    _ = self.advance();
                    continue;
                }
                const t = self.expect(.identifier) orelse return null;
                names.append(self.arena, t.value_str) catch return null;
                if (!self.match(.comma)) break;
            }
            _ = self.expect(.right_bracket) orelse return null;
        } else {
            _ = self.expect(.left_brace) orelse return null;
            while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
                const key = self.expect(.identifier) orelse return null;
                var bind_name = key.value_str;
                if (self.match(.colon)) {
                    const alias = self.expect(.identifier) orelse return null;
                    bind_name = alias.value_str;
                }
                names.append(self.arena, bind_name) catch return null;
                if (!self.match(.comma)) break;
            }
            _ = self.expect(.right_brace) orelse return null;
        }
        _ = self.expect(.eq) orelse return null;
        const rhs = self.parseAssignmentExpr() orelse return null;
        const tmp_name = std.fmt.allocPrint(self.arena, "__destruct_{d}", .{start}) catch return null;

        var body = std.ArrayList(*Node){};
        const tmp_decl = self.makeNode(.var_decl, start, self.current.start, .{
            .var_decl = .{ .kind = kind, .name = tmp_name, .init = rhs },
        }) orelse return null;
        body.append(self.arena, tmp_decl) catch return null;

        for (names.items, 0..) |n, i| {
            const tmp_id = self.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;
            const access = if (is_array) blk: {
                const idx = self.makeNode(.number_literal, start, start, .{ .number_literal = @floatFromInt(i) }) orelse return null;
                break :blk self.makeNode(.member_expr, start, start, .{
                    .member_expr = .{ .object = tmp_id, .property = idx, .computed = true },
                }) orelse return null;
            } else blk: {
                const prop = self.makeNode(.identifier, start, start, .{ .identifier = n }) orelse return null;
                break :blk self.makeNode(.member_expr, start, start, .{
                    .member_expr = .{ .object = tmp_id, .property = prop, .computed = false },
                }) orelse return null;
            };
            const vd = self.makeNode(.var_decl, start, self.current.start, .{
                .var_decl = .{ .kind = kind, .name = n, .init = access },
            }) orelse return null;
            body.append(self.arena, vd) catch return null;
        }
        return self.makeNode(.block_stmt, start, self.current.start, .{
            .block_stmt = .{ .body = body.items },
        });
    }

    fn parseFunctionDecl(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'function'
        const is_generator = self.match(.star);
        const name_tok = self.expect(.identifier) orelse return null;
        const name = name_tok.value_str;
        const parsed_params = self.parseFunctionParams() orelse return null;
        const prev_gen = self.in_generator_function;
        self.in_generator_function = is_generator;
        const body = self.parseFunctionBody() orelse {
            self.in_generator_function = prev_gen;
            return null;
        };
        self.in_generator_function = prev_gen;
        const is_strict = hasUseStrict(body);
        return self.makeNode(.function_decl, start, self.current.start, .{
            .function_decl = .{
                .name = name,
                .params = parsed_params.params,
                .param_defaults = parsed_params.param_defaults,
                .rest_param = parsed_params.rest_param,
                .body = body,
                .is_generator = is_generator,
                .is_strict = is_strict,
            },
        });
    }

    fn parseClassDeclStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // class
        const name_tok = self.expect(.identifier) orelse return null;
        const class_name = name_tok.value_str;

        var super_name: ?[]const u8 = null;
        if (self.match(.kw_extends)) {
            const s = self.expect(.identifier) orelse return null;
            super_name = s.value_str;
        }

        _ = self.expect(.left_brace) orelse return null;
        var ctor_params: [][]const u8 = &[_][]const u8{};
        var ctor_body: []*Node = &[_]*Node{};
        var methods = std.ArrayList(struct { name: []const u8, params: [][]const u8, body: []*Node }){};
        while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
            if (!self.check(.identifier)) {
                _ = self.advance();
                continue;
            }
            const mname_tok = self.advance();
            const mname = mname_tok.value_str;
            const mparams = self.parseFunctionParams() orelse return null;
            const mbody = self.parseFunctionBody() orelse return null;
            if (std.mem.eql(u8, mname, "constructor")) {
                ctor_params = mparams.params;
                ctor_body = mbody;
            } else {
                methods.append(self.arena, .{ .name = mname, .params = mparams.params, .body = mbody }) catch return null;
            }
        }
        _ = self.expect(.right_brace) orelse return null;

        if (ctor_body.len == 0) {
            if (super_name != null) {
                // Derived class default constructor: super.call(this)
                const id_super = self.makeNode(.identifier, start, start, .{ .identifier = "super" }) orelse return null;
                const id_call = self.makeNode(.identifier, start, start, .{ .identifier = "call" }) orelse return null;
                const super_call = self.makeNode(.member_expr, start, start, .{
                    .member_expr = .{ .object = id_super, .property = id_call, .computed = false },
                }) orelse return null;
                const this_expr = self.makeNode(.this_expr, start, start, .{ .this_expr = {} }) orelse return null;
                var super_args = std.ArrayList(*Node){};
                super_args.append(self.arena, this_expr) catch return null;
                const super_call_expr = self.makeNode(.call_expr, start, start, .{
                    .call_expr = .{ .callee = super_call, .args = super_args.items },
                }) orelse return null;
                const super_stmt = self.makeNode(.expr_stmt, start, start, .{ .expr_stmt = super_call_expr }) orelse return null;
                var body = std.ArrayList(*Node){};
                body.append(self.arena, super_stmt) catch return null;
                ctor_body = body.items;
            } else {
                ctor_body = &[_]*Node{};
            }
        }

        var out = std.ArrayList(*Node){};

        var ctor_body_effective = ctor_body;
        if (super_name) |sname| {
            // Allow `super(...)` in subclass constructors by binding local `super`.
            const id_super_ctor = self.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const super_decl = self.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "super", .init = id_super_ctor },
            }) orelse return null;
            var ctor_stmts = std.ArrayList(*Node){};
            ctor_stmts.append(self.arena, super_decl) catch return null;
            for (ctor_body) |st| ctor_stmts.append(self.arena, st) catch return null;
            ctor_body_effective = ctor_stmts.items;
        }

        // var ClassName = function ClassName(...) { ... }
        const ctor_fn = self.makeNode(.function_expr, start, self.current.start, .{
            .function_expr = .{
                .name = class_name,
                .params = ctor_params,
                .param_defaults = &[_]?*Node{},
                .rest_param = null,
                .body = ctor_body_effective,
                .is_arrow = false,
                .is_strict = hasUseStrict(ctor_body_effective),
                .requires_super = super_name != null,
            },
        }) orelse return null;
        const ctor_decl = self.makeNode(.var_decl, start, self.current.start, .{
            .var_decl = .{ .kind = .var_, .name = class_name, .init = ctor_fn },
        }) orelse return null;
        out.append(self.arena, ctor_decl) catch return null;

        if (super_name) |sname| {
            // ClassName.prototype = Object.create(Super.prototype)
            const id_class = self.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const id_proto = self.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const lhs_proto = self.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_class, .property = id_proto, .computed = false },
            }) orelse return null;

            const id_obj = self.makeNode(.identifier, start, start, .{ .identifier = "Object" }) orelse return null;
            const id_create = self.makeNode(.identifier, start, start, .{ .identifier = "create" }) orelse return null;
            const callee_create = self.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_obj, .property = id_create, .computed = false },
            }) orelse return null;

            const id_super = self.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const id_super_proto = self.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const super_proto = self.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_super, .property = id_super_proto, .computed = false },
            }) orelse return null;

            var args_create = std.ArrayList(*Node){};
            args_create.append(self.arena, super_proto) catch return null;
            const rhs_create = self.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee_create, .args = args_create.items },
            }) orelse return null;

            const assign_proto = self.makeNode(.assignment_expr, start, start, .{
                .assignment_expr = .{ .op = .assign, .target = lhs_proto, .value = rhs_create },
            }) orelse return null;
            const stmt_proto = self.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_proto }) orelse return null;
            out.append(self.arena, stmt_proto) catch return null;
        }

        // ClassName.prototype.constructor = ClassName
        const id_class_ctor = self.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const id_proto_ctor = self.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const class_proto_ctor = self.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_class_ctor, .property = id_proto_ctor, .computed = false },
        }) orelse return null;
        const id_ctor_name = self.makeNode(.identifier, start, start, .{ .identifier = "constructor" }) orelse return null;
        const ctor_slot = self.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = class_proto_ctor, .property = id_ctor_name, .computed = false },
        }) orelse return null;
        const id_class_value = self.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const assign_ctor = self.makeNode(.assignment_expr, start, start, .{
            .assignment_expr = .{ .op = .assign, .target = ctor_slot, .value = id_class_value },
        }) orelse return null;
        const stmt_ctor = self.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_ctor }) orelse return null;
        out.append(self.arena, stmt_ctor) catch return null;

        // prototype methods
        for (methods.items) |m| {
            const id_class = self.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const id_proto = self.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const class_proto = self.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_class, .property = id_proto, .computed = false },
            }) orelse return null;
            const id_method = self.makeNode(.identifier, start, start, .{ .identifier = m.name }) orelse return null;
            const lhs = self.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = class_proto, .property = id_method, .computed = false },
            }) orelse return null;
            var method_body = m.body;
            if (super_name) |sname| {
                // Allow `super.foo()` in subclass methods by binding `super = Super.prototype`.
                const id_super_cls = self.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
                const id_proto2 = self.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
                const super_proto2 = self.makeNode(.member_expr, start, start, .{
                    .member_expr = .{ .object = id_super_cls, .property = id_proto2, .computed = false },
                }) orelse return null;
                const super_decl2 = self.makeNode(.var_decl, start, start, .{
                    .var_decl = .{ .kind = .var_, .name = "super", .init = super_proto2 },
                }) orelse return null;
                var body_with_super = std.ArrayList(*Node){};
                body_with_super.append(self.arena, super_decl2) catch return null;
                for (m.body) |st| body_with_super.append(self.arena, st) catch return null;
                method_body = body_with_super.items;
            }
            const fn_expr = self.makeNode(.function_expr, start, self.current.start, .{
                .function_expr = .{
                    .name = null,
                    .params = m.params,
                    .param_defaults = &[_]?*Node{},
                    .rest_param = null,
                    .body = method_body,
                    .is_arrow = false,
                    .is_strict = hasUseStrict(method_body),
                },
            }) orelse return null;
            const assign = self.makeNode(.assignment_expr, start, self.current.start, .{
                .assignment_expr = .{ .op = .assign, .target = lhs, .value = fn_expr },
            }) orelse return null;
            const stmt = self.makeNode(.expr_stmt, start, self.current.start, .{ .expr_stmt = assign }) orelse return null;
            out.append(self.arena, stmt) catch return null;
        }

        if (out.items.len == 1) return out.items[0];
        return self.makeNode(.block_stmt, start, self.current.start, .{
            .block_stmt = .{ .body = out.items },
        });
    }

    fn parseFunctionParams(self: *Parser) ?ParamParse {
        _ = self.expect(.left_paren) orelse return null;
        var params = std.ArrayList([]const u8){};
        var defaults = std.ArrayList(?*Node){};
        var saw_rest = false;
        var rest_param: ?[]const u8 = null;
        while (!self.check(.right_paren) and !self.check(.eof) and !self.had_error) {
            var is_rest = false;
            if (self.match(.ellipsis)) is_rest = true;
            const p = self.expect(.identifier) orelse return null;
            if (is_rest) {
                saw_rest = true;
                rest_param = p.value_str;
                if (self.match(.eq)) {
                    if (!self.had_error) {
                        self.had_error = true;
                        self.error_info = ParseError{
                            .message = "rest parameter cannot have a default value",
                            .line = self.current.line,
                            .column = self.current.column,
                        };
                    }
                    return null;
                }
                if (!self.check(.right_paren)) {
                    if (!self.had_error) {
                        self.had_error = true;
                        self.error_info = ParseError{
                            .message = "rest parameter must be last",
                            .line = self.current.line,
                            .column = self.current.column,
                        };
                    }
                    return null;
                }
                break;
            }
            params.append(self.arena, p.value_str) catch {
                self.had_error = true;
                return null;
            };
            var default_expr: ?*Node = null;
            if (self.match(.eq)) {
                default_expr = self.parseAssignmentExpr() orelse return null;
            }
            defaults.append(self.arena, default_expr) catch return null;
            if (saw_rest) break;
            if (!self.match(.comma)) break;
        }
        _ = self.expect(.right_paren) orelse return null;
        return ParamParse{
            .params = params.items,
            .param_defaults = defaults.items,
            .rest_param = rest_param,
        };
    }

    fn parseFunctionBody(self: *Parser) ?[]*Node {
        _ = self.expect(.left_brace) orelse return null;
        var body = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            body.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&body);
        }
        self.applyLiveBindings(body.items, li_start, le_start);
        _ = self.expect(.right_brace) orelse return null;
        return body.items;
    }

    /// Check if first statement of body is "use strict" directive.
    fn hasUseStrict(body: []*Node) bool {
        if (body.len == 0) return false;
        const first = body[0];
        if (first.kind != .expr_stmt) return false;
        const inner = first.data.expr_stmt;
        if (inner.kind != .string_literal) return false;
        return std.mem.eql(u8, inner.data.string_literal, "use strict");
    }

    fn parseIfStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'if'
        _ = self.expect(.left_paren) orelse return null;
        const test_ = self.parseExpression() orelse return null;
        _ = self.expect(.right_paren) orelse return null;
        const consequent = self.parseStatement() orelse return null;
        var alternate: ?*Node = null;
        if (self.match(.kw_else)) {
            alternate = self.parseStatement();
        }
        return self.makeNode(.if_stmt, start, self.current.start, .{
            .if_stmt = .{ .test_ = test_, .consequent = consequent, .alternate = alternate },
        });
    }

    fn parseWhileStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'while'
        _ = self.expect(.left_paren) orelse return null;
        const test_ = self.parseExpression() orelse return null;
        _ = self.expect(.right_paren) orelse return null;
        const body = self.parseStatement() orelse return null;
        return self.makeNode(.while_stmt, start, self.current.start, .{
            .while_stmt = .{ .test_ = test_, .body = body },
        });
    }

    fn parseDoWhileStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'do'
        const body = self.parseStatement() orelse return null;
        _ = self.expect(.kw_while) orelse return null;
        _ = self.expect(.left_paren) orelse return null;
        const test_ = self.parseExpression() orelse return null;
        _ = self.expect(.right_paren) orelse return null;
        self.consumeSemicolon();
        return self.makeNode(.do_while_stmt, start, self.current.start, .{
            .do_while_stmt = .{ .body = body, .test_ = test_ },
        });
    }

    fn parseForStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'for'
        _ = self.expect(.left_paren) orelse return null;

        // Detect for-in: for (var/let/const x in obj) or for (x in obj)
        if (self.check(.kw_var) or self.check(.kw_let) or self.check(.kw_const)) {
            // save position: for (var/let/const NAME in ...) is for-in
            const decl_kind: ast.VarKind = if (self.check(.kw_var)) .var_ else if (self.check(.kw_let)) .let else .const_;
            _ = self.advance(); // consume declaration keyword
            if (self.check(.identifier)) {
                const name_tok = self.current;
                _ = self.advance(); // consume identifier
                if (self.check(.kw_in)) {
                    // It's for-in: for (var/let/const name in expr)
                    _ = self.advance(); // consume 'in'
                    const right = self.parseExpression() orelse return null;
                    _ = self.expect(.right_paren) orelse return null;
                    const body = self.parseStatement() orelse return null;
                    // Create a var_decl node as the left side
                    const left = self.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                        .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                    }) orelse return null;
                    return self.makeNode(.for_in_stmt, start, self.current.start, .{
                        .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = false },
                    });
                } else if (self.check(.kw_of)) {
                    _ = self.advance(); // consume 'of'
                    const right = self.parseExpression() orelse return null;
                    _ = self.expect(.right_paren) orelse return null;
                    const body = self.parseStatement() orelse return null;
                    const left = self.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                        .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                    }) orelse return null;
                    return self.makeNode(.for_in_stmt, start, self.current.start, .{
                        .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = true },
                    });
                } else if (self.check(.eq) or self.check(.comma) or self.check(.semicolon)) {
                    // Normal for loop: for (var/let/const name = ...; ...)
                    // Handle initializer if present
                    var init_val: ?*Node = null;
                    if (self.match(.eq)) {
                        init_val = self.parseAssignmentExpr();
                    }
                    if (decl_kind == .const_ and init_val == null) {
                        if (!self.had_error) {
                            self.had_error = true;
                            self.error_info = ParseError{
                                .message = "const declaration requires an initializer",
                                .line = name_tok.line,
                                .column = name_tok.column,
                            };
                        }
                        return null;
                    }
                    const first_decl = self.makeNode(.var_decl, name_tok.start, self.current.start, .{
                        .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = init_val },
                    }) orelse return null;
                    var decls = std.ArrayList(*Node){};
                    decls.append(self.arena, first_decl) catch {
                        self.had_error = true;
                        return null;
                    };
                    while (self.match(.comma)) {
                        const d = self.parseVarDeclarator(decl_kind) orelse return null;
                        decls.append(self.arena, d) catch {
                            self.had_error = true;
                            return null;
                        };
                    }
                    _ = self.expect(.semicolon) orelse return null;
                    const init_node: ?*Node = if (decls.items.len == 1) decls.items[0] else self.makeNode(.block_stmt, start, self.current.start, .{
                        .block_stmt = .{ .body = decls.items },
                    });
                    return self.parseForTail(start, init_node);
                } else {
                    // Unexpected — treat as for (var/let name; ...).
                    // const without initializer is invalid and already checked above.
                    const first_decl = self.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                        .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                    }) orelse return null;
                    _ = self.expect(.semicolon) orelse return null;
                    return self.parseForTail(start, first_decl);
                }
            } else {
                _ = self.expect(.semicolon) orelse return null;
                return self.parseForTail(start, null);
            }
        } else if (!self.check(.semicolon)) {
            // for (expr in ...) or for (expr; ...)
            // Parse the expression
            const expr = self.parseAssignmentExpr() orelse return null;
            if (self.check(.kw_in)) {
                // for-in with assignment expression left side
                _ = self.advance(); // consume 'in'
                const right = self.parseExpression() orelse return null;
                _ = self.expect(.right_paren) orelse return null;
                const body = self.parseStatement() orelse return null;
                return self.makeNode(.for_in_stmt, start, self.current.start, .{
                    .for_in_stmt = .{ .left = expr, .right = right, .body = body, .iterate_values = false },
                });
            }
            if (self.check(.kw_of)) {
                _ = self.advance(); // consume 'of'
                const right = self.parseExpression() orelse return null;
                _ = self.expect(.right_paren) orelse return null;
                const body = self.parseStatement() orelse return null;
                return self.makeNode(.for_in_stmt, start, self.current.start, .{
                    .for_in_stmt = .{ .left = expr, .right = right, .body = body, .iterate_values = true },
                });
            }
            // Normal for: consume remaining of init expr (may be comma-separated)
            var final_expr = expr;
            if (self.check(.comma)) {
                var exprs = std.ArrayList(*Node){};
                exprs.append(self.arena, expr) catch {
                    self.had_error = true;
                    return null;
                };
                while (self.match(.comma)) {
                    const e = self.parseAssignmentExpr() orelse return null;
                    exprs.append(self.arena, e) catch {
                        self.had_error = true;
                        return null;
                    };
                }
                final_expr = self.makeNode(.sequence_expr, expr.start, self.current.start, .{
                    .sequence_expr = .{ .exprs = exprs.items },
                }) orelse return null;
            }
            const init_node = self.makeNode(.expr_stmt, final_expr.start, final_expr.end, .{ .expr_stmt = final_expr });
            _ = self.expect(.semicolon) orelse return null;
            return self.parseForTail(start, init_node);
        } else {
            _ = self.expect(.semicolon) orelse return null;
            return self.parseForTail(start, null);
        }
    }

    fn parseForTail(self: *Parser, start: u32, init_node: ?*Node) ?*Node {
        // Test clause
        var test_node: ?*Node = null;
        if (!self.check(.semicolon)) {
            test_node = self.parseExpression();
        }
        _ = self.expect(.semicolon) orelse return null;

        // Update clause
        var update_node: ?*Node = null;
        if (!self.check(.right_paren)) {
            update_node = self.parseExpression();
        }
        _ = self.expect(.right_paren) orelse return null;
        const body = self.parseStatement() orelse return null;
        return self.makeNode(.for_stmt, start, self.current.start, .{
            .for_stmt = .{
                .init = init_node,
                .test_ = test_node,
                .update = update_node,
                .body = body,
            },
        });
    }

    fn parseSwitchStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'switch'
        _ = self.expect(.left_paren) orelse return null;
        const discriminant = self.parseExpression() orelse return null;
        _ = self.expect(.right_paren) orelse return null;
        _ = self.expect(.left_brace) orelse return null;

        var cases = std.ArrayList(ast.SwitchCase){};
        while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
            var test_node: ?*Node = null;
            if (self.check(.kw_case)) {
                _ = self.advance(); // consume 'case'
                test_node = self.parseExpression() orelse return null;
                _ = self.expect(.colon) orelse return null;
            } else if (self.check(.kw_default)) {
                _ = self.advance(); // consume 'default'
                _ = self.expect(.colon) orelse return null;
                test_node = null;
            } else {
                break; // unexpected
            }
            // Parse case body statements until next case/default/}
            var body = std.ArrayList(*Node){};
            while (!self.check(.kw_case) and !self.check(.kw_default) and
                !self.check(.right_brace) and !self.check(.eof) and !self.had_error)
            {
                const s = self.parseStatement() orelse break;
                body.append(self.arena, s) catch {
                    self.had_error = true;
                    break;
                };
            }
            cases.append(self.arena, ast.SwitchCase{ .test_ = test_node, .body = body.items }) catch {
                self.had_error = true;
                return null;
            };
        }
        _ = self.expect(.right_brace) orelse return null;
        return self.makeNode(.switch_stmt, start, self.current.start, .{
            .switch_stmt = .{ .discriminant = discriminant, .cases = cases.items },
        });
    }

    fn parseReturnStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'return'
        // ASI rule: if next token has line terminator before it, return undefined.
        var value: ?*Node = null;
        if (!self.hasSemicolon()) {
            value = self.parseExpression();
        }
        self.consumeSemicolon();
        return self.makeNode(.return_stmt, start, self.current.start, .{ .return_stmt = value });
    }

    fn parseBreakStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance();
        var label: ?[]const u8 = null;
        if (!self.hasSemicolon() and self.check(.identifier)) {
            label = self.current.value_str;
            _ = self.advance();
        }
        self.consumeSemicolon();
        return self.makeNode(.break_stmt, start, self.current.start, .{ .break_stmt = label });
    }

    fn parseContinueStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance();
        var label: ?[]const u8 = null;
        if (!self.hasSemicolon() and self.check(.identifier)) {
            label = self.current.value_str;
            _ = self.advance();
        }
        self.consumeSemicolon();
        return self.makeNode(.continue_stmt, start, self.current.start, .{ .continue_stmt = label });
    }

    fn parseThrowStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'throw'
        // ASI: throw cannot have a line terminator after it.
        if (self.current.line_terminator_before) {
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{
                    .message = "illegal newline after throw",
                    .line = self.current.line,
                    .column = self.current.column,
                };
            }
            return null;
        }
        const argument = self.parseExpression() orelse return null;
        self.consumeSemicolon();
        return self.makeNode(.throw_stmt, start, self.current.start, .{ .throw_stmt = argument });
    }

    fn parseTryStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'try'
        const block = self.parseBlock() orelse return null;

        var handler: ?ast.CatchClause = null;
        var finalizer: ?*Node = null;

        if (self.check(.kw_catch)) {
            _ = self.advance(); // consume 'catch'
            _ = self.expect(.left_paren) orelse return null;
            const param_tok = self.expect(.identifier) orelse return null;
            _ = self.expect(.right_paren) orelse return null;
            const catch_body = self.parseBlock() orelse return null;
            handler = ast.CatchClause{
                .param_name = param_tok.value_str,
                .body = catch_body,
            };
        }

        if (self.check(.kw_finally)) {
            _ = self.advance(); // consume 'finally'
            finalizer = self.parseBlock();
        }

        if (handler == null and finalizer == null) {
            if (!self.had_error) {
                self.had_error = true;
                self.error_info = ParseError{
                    .message = "try statement requires at least a catch or finally clause",
                    .line = self.current.line,
                    .column = self.current.column,
                };
            }
            return null;
        }

        return self.makeNode(.try_stmt, start, self.current.start, .{
            .try_stmt = .{ .block = block, .handler = handler, .finalizer = finalizer },
        });
    }

    fn parseExprStmt(self: *Parser) ?*Node {
        const start = self.current.start;
        const expr = self.parseExpression() orelse return null;
        self.consumeSemicolon();
        return self.makeNode(.expr_stmt, start, self.current.start, .{ .expr_stmt = expr });
    }

    // --------------------------------------------------------- expressions ---

    /// Parse a full expression (includes comma operator).
    fn parseExpression(self: *Parser) ?*Node {
        const start = self.current.start;
        var left = self.parseAssignmentExpr() orelse return null;
        if (self.check(.comma)) {
            var exprs = std.ArrayList(*Node){};
            exprs.append(self.arena, left) catch {
                self.had_error = true;
                return null;
            };
            while (self.match(.comma)) {
                const e = self.parseAssignmentExpr() orelse return null;
                exprs.append(self.arena, e) catch {
                    self.had_error = true;
                    return null;
                };
            }
            left = self.makeNode(.sequence_expr, start, self.current.start, .{
                .sequence_expr = .{ .exprs = exprs.items },
            }) orelse return null;
        }
        return left;
    }

    fn parseAssignmentExpr(self: *Parser) ?*Node {
        const start = self.current.start;
        // Conditional has higher precedence than assignment.
        const left = self.parseConditionalExpr() orelse return null;
        // ES2015 arrow function: params => body
        if (self.match(.arrow)) {
            const params = self.extractArrowParams(left) orelse return null;
            var body_nodes: []*Node = undefined;
            if (self.check(.left_brace)) {
                const blk = self.parseBlock() orelse return null;
                body_nodes = blk.data.block_stmt.body;
            } else {
                const expr_body = self.parseAssignmentExpr() orelse return null;
                const ret = self.makeNode(.return_stmt, expr_body.start, expr_body.end, .{
                    .return_stmt = expr_body,
                }) orelse return null;
                var one = std.ArrayList(*Node){};
                one.append(self.arena, ret) catch {
                    self.had_error = true;
                    return null;
                };
                body_nodes = one.items;
            }
            const is_strict = hasUseStrict(body_nodes);
            return self.makeNode(.function_expr, start, self.current.start, .{
                .function_expr = .{
                    .name = null,
                    .params = params,
                    .param_defaults = &[_]?*Node{},
                    .rest_param = null,
                    .body = body_nodes,
                    .is_arrow = true,
                    .is_strict = is_strict,
                },
            });
        }
        // Check for assignment operator.
        if (isAssignOp(self.current.kind)) {
            const op = tokenToAssignOp(self.current.kind);
            _ = self.advance();
            const right = self.parseAssignmentExpr() orelse return null; // right-assoc
            return self.makeNode(.assignment_expr, start, self.current.start, .{
                .assignment_expr = .{ .op = op, .target = left, .value = right },
            });
        }
        return left;
    }

    fn extractArrowParams(self: *Parser, lhs: *Node) ?[][]const u8 {
        var params = std.ArrayList([]const u8){};
        switch (lhs.kind) {
            .identifier => {
                params.append(self.arena, lhs.data.identifier) catch {
                    self.had_error = true;
                    return null;
                };
            },
            .sequence_expr => {
                for (lhs.data.sequence_expr.exprs) |e| {
                    if (e.kind != .identifier) {
                        if (!self.had_error) {
                            self.had_error = true;
                            self.error_info = ParseError{
                                .message = "invalid arrow parameter list",
                                .line = self.current.line,
                                .column = self.current.column,
                            };
                        }
                        return null;
                    }
                    params.append(self.arena, e.data.identifier) catch {
                        self.had_error = true;
                        return null;
                    };
                }
            },
            else => {
                if (!self.had_error) {
                    self.had_error = true;
                    self.error_info = ParseError{
                        .message = "invalid arrow parameter list",
                        .line = self.current.line,
                        .column = self.current.column,
                    };
                }
                return null;
            },
        }
        return params.items;
    }

    fn parseConditionalExpr(self: *Parser) ?*Node {
        const start = self.current.start;
        const test_ = self.parseBinaryExpr(Prec.comma) orelse return null;
        if (self.match(.question)) {
            const consequent = self.parseAssignmentExpr() orelse return null;
            _ = self.expect(.colon) orelse return null;
            const alternate = self.parseAssignmentExpr() orelse return null;
            return self.makeNode(.conditional_expr, start, self.current.start, .{
                .conditional_expr = .{ .test_ = test_, .consequent = consequent, .alternate = alternate },
            });
        }
        return test_;
    }

    /// Pratt-style binary expression parser.
    fn parseBinaryExpr(self: *Parser, min_prec: u8) ?*Node {
        var left = self.parseUnaryExpr() orelse return null;
        while (true) {
            const p = infixPrec(self.current.kind);
            if (p == 0 or p <= min_prec) break;
            if (self.current.kind == .left_paren or self.current.kind == .left_bracket or self.current.kind == .dot) {
                // Call/member — handled in parseUnaryExpr's postfix loop, not here.
                break;
            }
            const op_kind = self.current.kind;
            // ES2016: a UnaryExpression may not be the left operand of `**` (e.g. `-2 ** 2`).
            if (op_kind == .star_star and left.kind == .unary_expr and !left.paren) {
                if (!self.had_error) {
                    self.had_error = true;
                    self.error_info = ParseError{
                        .message = "unary operator not allowed as left operand of **",
                        .line = self.current.line,
                        .column = self.current.column,
                    };
                }
                return null;
            }
            _ = self.advance();
            // Exponentiation is right-associative: recurse at p-1 so same-prec ** binds rightward.
            const right = self.parseBinaryExpr(if (op_kind == .star_star) p - 1 else p) orelse return null;
            const start = left.start;
            left = switch (op_kind) {
                .amp_amp, .pipe_pipe => self.makeNode(.logical_expr, start, self.current.start, .{
                    .logical_expr = .{
                        .op = if (op_kind == .amp_amp) .and_ else .or_,
                        .left = left,
                        .right = right,
                    },
                }) orelse return null,
                else => self.makeNode(.binary_expr, start, self.current.start, .{
                    .binary_expr = .{
                        .op = tokenToBinaryOp(op_kind),
                        .left = left,
                        .right = right,
                    },
                }) orelse return null,
            };
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ?*Node {
        const start = self.current.start;
        // Phase 8: `await X` desugars to a call __await__(X) (synchronous-drain await).
        // Works at module top level and inside any function; no VM changes needed.
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.value_str, "await")) {
            _ = self.advance();
            const operand = self.parseUnaryExpr() orelse return null;
            const callee = self.makeNode(.identifier, start, start, .{ .identifier = "__await__" }) orelse return null;
            var args = std.ArrayList(*Node){};
            args.append(self.arena, operand) catch return null;
            return self.makeNode(.call_expr, start, self.current.start, .{
                .call_expr = .{ .callee = callee, .args = args.items },
            });
        }
        // Prefix unary
        switch (self.current.kind) {
            .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
                const op_kind = self.current.kind;
                _ = self.advance();
                const operand = self.parseUnaryExpr() orelse return null;
                return self.makeNode(.unary_expr, start, self.current.start, .{
                    .unary_expr = .{ .op = tokenToUnaryOp(op_kind), .operand = operand },
                });
            },
            .plus_plus => {
                _ = self.advance();
                const operand = self.parseUnaryExpr() orelse return null;
                return self.makeNode(.update_expr, start, self.current.start, .{
                    .update_expr = .{ .op = .inc, .operand = operand, .prefix = true },
                });
            },
            .minus_minus => {
                _ = self.advance();
                const operand = self.parseUnaryExpr() orelse return null;
                return self.makeNode(.update_expr, start, self.current.start, .{
                    .update_expr = .{ .op = .dec, .operand = operand, .prefix = true },
                });
            },
            .kw_new => {
                _ = self.advance();
                // For `new`, parse only member expressions (no call) as the callee,
                // then optionally consume argument list.
                const callee = self.parseNewCallee() orelse return null;
                var args: []*Node = &[_]*Node{};
                if (self.check(.left_paren)) {
                    args = self.parseArgs() orelse return null;
                }
                var new_node: *Node = self.makeNode(.new_expr, start, self.current.start, .{
                    .new_expr = .{ .callee = callee, .args = args },
                }) orelse return null;
                // Allow member access and calls on the result of `new`: e.g. new Foo().bar()
                while (true) {
                    if (self.check(.left_paren)) {
                        const call_args = self.parseArgs() orelse return null;
                        new_node = self.makeNode(.call_expr, new_node.start, self.current.start, .{
                            .call_expr = .{ .callee = new_node, .args = call_args },
                        }) orelse return null;
                    } else if (self.match(.dot)) {
                        const prop_tok2 = self.expect(.identifier) orelse return null;
                        const prop2 = self.makeNode(.identifier, prop_tok2.start, prop_tok2.end, .{
                            .identifier = prop_tok2.value_str,
                        }) orelse return null;
                        new_node = self.makeNode(.member_expr, new_node.start, self.current.start, .{
                            .member_expr = .{ .object = new_node, .property = prop2, .computed = false },
                        }) orelse return null;
                    } else if (self.match(.left_bracket)) {
                        const prop2 = self.parseExpression() orelse return null;
                        _ = self.expect(.right_bracket) orelse return null;
                        new_node = self.makeNode(.member_expr, new_node.start, self.current.start, .{
                            .member_expr = .{ .object = new_node, .property = prop2, .computed = true },
                        }) orelse return null;
                    } else {
                        break;
                    }
                }
                return new_node;
            },
            else => {},
        }

        // Postfix (++ --)
        var expr = self.parseCallMemberExpr() orelse return null;
        if (!self.current.line_terminator_before) {
            if (self.current.kind == .plus_plus) {
                _ = self.advance();
                expr = self.makeNode(.update_expr, start, self.current.start, .{
                    .update_expr = .{ .op = .inc, .operand = expr, .prefix = false },
                }) orelse return null;
            } else if (self.current.kind == .minus_minus) {
                _ = self.advance();
                expr = self.makeNode(.update_expr, start, self.current.start, .{
                    .update_expr = .{ .op = .dec, .operand = expr, .prefix = false },
                }) orelse return null;
            }
        }
        return expr;
    }

    /// Parse call, member access, subscript.
    fn parseCallMemberExpr(self: *Parser) ?*Node {
        var base = self.parsePrimaryExpr() orelse return null;
        while (true) {
            if (self.check(.left_paren)) {
                const args = self.parseArgs() orelse return null;
                const raw_call = self.makeNode(.call_expr, base.start, self.current.start, .{
                    .call_expr = .{ .callee = base, .args = args },
                }) orelse return null;
                base = self.rewriteSuperCall(raw_call) orelse return null;
            } else if (self.match(.dot)) {
                const prop_tok = self.expect(.identifier) orelse return null;
                const prop = self.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                    .identifier = prop_tok.value_str,
                }) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = false },
                }) orelse return null;
            } else if (self.match(.left_bracket)) {
                const prop = self.parseExpression() orelse return null;
                _ = self.expect(.right_bracket) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = true },
                }) orelse return null;
            } else {
                break;
            }
        }
        return base;
    }

    /// Rewrite super call sites into explicit .call(this, ...) form.
    /// - super(a, b) -> super.call(this, a, b)
    /// - super.m(a)  -> super.m.call(this, a)
    fn rewriteSuperCall(self: *Parser, call_node: *Node) ?*Node {
        if (call_node.kind != .call_expr) return call_node;
        const call = call_node.data.call_expr;
        const start = call_node.start;
        const end = call_node.end;

        // Case 1: direct super(...)
        if (call.callee.kind == .identifier and std.mem.eql(u8, call.callee.data.identifier, "super")) {
            const id_call = self.makeNode(.identifier, start, end, .{ .identifier = "call" }) orelse return null;
            const super_call = self.makeNode(.member_expr, start, end, .{
                .member_expr = .{ .object = call.callee, .property = id_call, .computed = false },
            }) orelse return null;
            const this_expr = self.makeNode(.this_expr, start, end, .{ .this_expr = {} }) orelse return null;
            var new_args = std.ArrayList(*Node){};
            new_args.append(self.arena, this_expr) catch return null;
            for (call.args) |a| new_args.append(self.arena, a) catch return null;
            return self.makeNode(.call_expr, start, end, .{
                .call_expr = .{ .callee = super_call, .args = new_args.items },
            });
        }

        // Case 2: super.method(...)
        if (call.callee.kind == .member_expr) {
            const me = call.callee.data.member_expr;
            const is_super_obj = me.object.kind == .identifier and std.mem.eql(u8, me.object.data.identifier, "super");
            const is_explicit_call = (!me.computed and me.property.kind == .identifier and std.mem.eql(u8, me.property.data.identifier, "call"));
            if (is_super_obj and !is_explicit_call) {
                const id_call = self.makeNode(.identifier, start, end, .{ .identifier = "call" }) orelse return null;
                const method_call = self.makeNode(.member_expr, start, end, .{
                    .member_expr = .{ .object = call.callee, .property = id_call, .computed = false },
                }) orelse return null;
                const this_expr = self.makeNode(.this_expr, start, end, .{ .this_expr = {} }) orelse return null;
                var new_args = std.ArrayList(*Node){};
                new_args.append(self.arena, this_expr) catch return null;
                for (call.args) |a| new_args.append(self.arena, a) catch return null;
                return self.makeNode(.call_expr, start, end, .{
                    .call_expr = .{ .callee = method_call, .args = new_args.items },
                });
            }
        }
        return call_node;
    }

    /// Parse a member expression without call expressions (for `new` callee).
    /// Handles dot and bracket access but NOT `(` argument lists.
    fn parseNewCallee(self: *Parser) ?*Node {
        var base = self.parsePrimaryExpr() orelse return null;
        while (true) {
            if (self.match(.dot)) {
                const prop_tok = self.expect(.identifier) orelse return null;
                const prop = self.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                    .identifier = prop_tok.value_str,
                }) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = false },
                }) orelse return null;
            } else if (self.match(.left_bracket)) {
                const prop = self.parseExpression() orelse return null;
                _ = self.expect(.right_bracket) orelse return null;
                base = self.makeNode(.member_expr, base.start, self.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = true },
                }) orelse return null;
            } else {
                break;
            }
        }
        return base;
    }

    fn parseArgs(self: *Parser) ?[]*Node {
        _ = self.expect(.left_paren) orelse return null;
        var args = std.ArrayList(*Node){};
        while (!self.check(.right_paren) and !self.check(.eof) and !self.had_error) {
            const has_spread = self.match(.ellipsis);
            const parsed = self.parseAssignmentExpr() orelse return null;
            const a = if (has_spread)
                (self.makeNode(.spread_expr, parsed.start, parsed.end, .{ .spread_expr = parsed }) orelse return null)
            else
                parsed;
            args.append(self.arena, a) catch {
                self.had_error = true;
                return null;
            };
            if (!self.match(.comma)) break;
        }
        _ = self.expect(.right_paren) orelse return null;
        return args.items;
    }

    fn parsePrimaryExpr(self: *Parser) ?*Node {
        const start = self.current.start;
        const end = self.current.end;
        switch (self.current.kind) {
            .number => {
                const v = self.current.value_num;
                _ = self.advance();
                return self.makeNode(.number_literal, start, end, .{ .number_literal = v });
            },
            .string => {
                const s = self.current.value_str;
                _ = self.advance();
                return self.makeNode(.string_literal, start, end, .{ .string_literal = s });
            },
            .kw_true => {
                _ = self.advance();
                return self.makeNode(.bool_literal, start, end, .{ .bool_literal = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.makeNode(.bool_literal, start, end, .{ .bool_literal = false });
            },
            .kw_null => {
                _ = self.advance();
                return self.makeNode(.null_literal, start, end, .{ .null_literal = {} });
            },
            .kw_this => {
                _ = self.advance();
                return self.makeNode(.this_expr, start, end, .{ .this_expr = {} });
            },
            .kw_super => {
                _ = self.advance();
                return self.makeNode(.identifier, start, end, .{ .identifier = "super" });
            },
            .kw_yield => {
                if (!self.in_generator_function) {
                    if (!self.had_error) {
                        self.had_error = true;
                        self.error_info = ParseError{
                            .message = "yield is only valid inside generator functions",
                            .line = self.current.line,
                            .column = self.current.column,
                        };
                    }
                    return null;
                }
                _ = self.advance();
                if (self.match(.star)) {
                    const delegated = self.parseAssignmentExpr() orelse {
                        if (!self.had_error) {
                            self.had_error = true;
                            self.error_info = ParseError{
                                .message = "expected expression after yield*",
                                .line = self.current.line,
                                .column = self.current.column,
                            };
                        }
                        return null;
                    };
                    const helper = self.makeNode(.identifier, start, self.current.start, .{ .identifier = "__yield_star__" }) orelse return null;
                    var args = std.ArrayList(*Node){};
                    args.append(self.arena, delegated) catch return null;
                    return self.makeNode(.call_expr, start, self.current.start, .{
                        .call_expr = .{ .callee = helper, .args = args.items },
                    });
                }
                const can_have_arg = !(self.current.line_terminator_before or self.check(.semicolon) or self.check(.right_brace) or self.check(.eof));
                const yielded = if (can_have_arg) self.parseAssignmentExpr() orelse return null else null;
                return self.makeNode(.yield_expr, start, self.current.start, .{ .yield_expr = yielded });
            },
            .identifier => {
                const name = self.current.value_str;
                _ = self.advance();
                // Special: 'undefined' identifier -> undefined literal
                if (std.mem.eql(u8, name, "undefined")) {
                    return self.makeNode(.undefined_literal, start, end, .{ .undefined_literal = {} });
                }
                return self.makeNode(.identifier, start, end, .{ .identifier = name });
            },
            .left_paren => {
                _ = self.advance();
                const expr = self.parseExpression() orelse return null;
                _ = self.expect(.right_paren) orelse return null;
                expr.paren = true;
                return expr;
            },
            .kw_function => {
                return self.parseFunctionExpr();
            },
            .left_brace => {
                return self.parseObjectLiteral();
            },
            .left_bracket => {
                return self.parseArrayLiteral();
            },
            .regex => {
                // Phase 4c: regex literal /pattern/flags
                const raw = self.current.value_str;
                _ = self.advance();
                // raw format: /pattern/flags — parse it
                const parsed = parseRegexRaw(raw);
                const owned_pat = self.arena.dupe(u8, parsed.pattern) catch return null;
                const owned_flags = self.arena.dupe(u8, parsed.flags) catch return null;
                return self.makeNode(.regex_literal, start, end, .{
                    .regex_literal = .{ .pattern = owned_pat, .flags = owned_flags },
                });
            },
            else => {
                if (!self.had_error) {
                    self.had_error = true;
                    var buf: [128]u8 = undefined;
                    const msg_s = std.fmt.bufPrint(&buf, "unexpected token '{s}' at line {d}", .{
                        @tagName(self.current.kind), self.current.line,
                    }) catch "unexpected token";
                    const owned = self.arena.dupe(u8, msg_s) catch "unexpected token";
                    self.error_info = ParseError{
                        .message = owned,
                        .line = self.current.line,
                        .column = self.current.column,
                    };
                }
                return null;
            },
        }
    }

    fn parseObjectLiteral(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.expect(.left_brace) orelse return null;
        var props = std.ArrayList(ast.ObjectProp){};
        while (!self.check(.right_brace) and !self.check(.eof) and !self.had_error) {
            // Key: identifier, string literal, or number literal.
            var key: []const u8 = undefined;
            if (self.check(.identifier)) {
                key = self.current.value_str;
                _ = self.advance();
            } else if (self.check(.string)) {
                key = self.current.value_str;
                _ = self.advance();
            } else if (self.check(.number)) {
                // Number key: convert to string.
                const n = self.current.value_num;
                _ = self.advance();
                // Simple integer check.
                if (n == @trunc(n) and n >= 0 and n < 1e15) {
                    const s = std.fmt.allocPrint(self.arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch {
                        self.had_error = true;
                        return null;
                    };
                    key = s;
                } else {
                    const s = std.fmt.allocPrint(self.arena, "{d}", .{n}) catch {
                        self.had_error = true;
                        return null;
                    };
                    key = s;
                }
            } else {
                if (!self.had_error) {
                    self.had_error = true;
                    self.error_info = ParseError{
                        .message = "expected property key",
                        .line = self.current.line,
                        .column = self.current.column,
                    };
                }
                return null;
            }
            _ = self.expect(.colon) orelse return null;
            const val_node = self.parseAssignmentExpr() orelse return null;
            props.append(self.arena, ast.ObjectProp{ .key = key, .value = val_node }) catch {
                self.had_error = true;
                return null;
            };
            if (!self.match(.comma)) break;
        }
        _ = self.expect(.right_brace) orelse return null;
        const end = self.current.start;
        return self.makeNode(.object_literal, start, end, .{
            .object_literal = .{ .properties = props.items },
        });
    }

    fn parseArrayLiteral(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.expect(.left_bracket) orelse return null;
        var elements = std.ArrayList(*Node){};
        while (!self.check(.right_bracket) and !self.check(.eof) and !self.had_error) {
            // Elision: treat as null literal (Phase 3a simplification).
            if (self.check(.comma)) {
                const null_node = self.makeNode(.null_literal, self.current.start, self.current.start, .{ .null_literal = {} }) orelse return null;
                elements.append(self.arena, null_node) catch {
                    self.had_error = true;
                    return null;
                };
                _ = self.advance(); // consume comma
                continue;
            }
            const has_spread = self.match(.ellipsis);
            const parsed = self.parseAssignmentExpr() orelse return null;
            const elem = if (has_spread)
                (self.makeNode(.spread_expr, parsed.start, parsed.end, .{ .spread_expr = parsed }) orelse return null)
            else
                parsed;
            elements.append(self.arena, elem) catch {
                self.had_error = true;
                return null;
            };
            if (!self.match(.comma)) break;
        }
        _ = self.expect(.right_bracket) orelse return null;
        const end = self.current.start;
        return self.makeNode(.array_literal, start, end, .{
            .array_literal = .{ .elements = elements.items },
        });
    }

    fn parseFunctionExpr(self: *Parser) ?*Node {
        const start = self.current.start;
        _ = self.advance(); // consume 'function'
        const is_generator = self.match(.star);
        var name: ?[]const u8 = null;
        if (self.check(.identifier)) {
            name = self.current.value_str;
            _ = self.advance();
        }
        const parsed_params = self.parseFunctionParams() orelse return null;
        const prev_gen = self.in_generator_function;
        self.in_generator_function = is_generator;
        const body = self.parseFunctionBody() orelse {
            self.in_generator_function = prev_gen;
            return null;
        };
        self.in_generator_function = prev_gen;
        const is_strict = hasUseStrict(body);
        return self.makeNode(.function_expr, start, self.current.start, .{
            .function_expr = .{
                .name = name,
                .params = parsed_params.params,
                .param_defaults = parsed_params.param_defaults,
                .rest_param = parsed_params.rest_param,
                .body = body,
                .is_arrow = false,
                .is_generator = is_generator,
                .is_strict = is_strict,
            },
        });
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

fn tokenToBinaryOp(kind: TokenKind) ast.BinaryOp {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .star_star => .exp,
        .slash => .div,
        .percent => .mod,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .lt_lt => .lshift,
        .gt_gt => .rshift,
        .gt_gt_gt => .urshift,
        .lt => .lt,
        .lt_eq => .lte,
        .gt => .gt,
        .gt_eq => .gte,
        .kw_instanceof => .instanceof,
        .kw_in => .in,
        .eq_eq => .eq,
        .bang_eq => .neq,
        .eq_eq_eq => .strict_eq,
        .bang_eq_eq => .strict_neq,
        else => .add, // unreachable in practice
    };
}

fn tokenToUnaryOp(kind: TokenKind) ast.UnaryOp {
    return switch (kind) {
        .minus => .neg,
        .plus => .pos,
        .bang => .not,
        .tilde => .bit_not,
        .kw_typeof => .typeof_,
        .kw_void => .void_,
        .kw_delete => .delete_,
        else => .neg,
    };
}

/// Phase 4c: parse raw regex token "/pattern/flags" into components.
/// The lexer stores the entire literal including slashes.
const RegexRaw = struct { pattern: []const u8, flags: []const u8 };

fn parseRegexRaw(raw: []const u8) RegexRaw {
    // raw = "/pattern/flags" or "/pattern/" with no flags.
    if (raw.len < 2 or raw[0] != '/') return .{ .pattern = raw, .flags = "" };
    // Find closing /. Scan past the opening slash.
    var i: usize = 1;
    var in_class = false;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '[') {
            in_class = true;
            i += 1;
            continue;
        }
        if (c == ']') {
            in_class = false;
            i += 1;
            continue;
        }
        if (c == '\\') {
            i += 2;
            continue;
        } // skip escaped char
        if (c == '/' and !in_class) {
            // Found closing slash at position i.
            const pattern = raw[1..i];
            const flags = raw[i + 1 ..];
            return .{ .pattern = pattern, .flags = flags };
        }
        i += 1;
    }
    // Unterminated — return body sans opening slash
    return .{ .pattern = raw[1..], .flags = "" };
}

fn tokenToAssignOp(kind: TokenKind) ast.AssignOp {
    return switch (kind) {
        .eq => .assign,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .star_star_eq => .exp,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .lt_lt_eq => .lshift,
        .gt_gt_eq => .rshift,
        .gt_gt_gt_eq => .urshift,
        else => .assign,
    };
}

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
