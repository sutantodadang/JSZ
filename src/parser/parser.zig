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
    /// ExpectedArgumentCount (§15.1.5) — the formal parameters before the first
    /// defaulted or rest one, i.e. what `fn.length` reports. Captured here
    /// because the default-parameter TDZ desugar in `parseFunctionParams`
    /// rewrites the initializers into the body and clears `param_defaults`.
    expected_argc: u16 = 0,
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

/// If `node` is a string-literal expression statement (a member of a directive
/// prologue), return its raw string value; otherwise null (the prologue ends at
/// the first non-string-literal statement).
pub fn directiveOf(node: *Node) ?[]const u8 {
    if (node.kind != .expr_stmt) return null;
    const inner = node.data.expr_stmt;
    if (inner.kind != .string_literal) return null;
    return inner.data.string_literal;
}

/// Future reserved words that are valid identifiers in sloppy mode but early
/// SyntaxErrors when used as a binding identifier in strict-mode code
/// (ES §12.7.2 + the `eval`/`arguments` binding restriction §13.1.1). `yield`
/// and `await` are handled separately (generator/module context).
pub fn isStrictReservedWord(name: []const u8) bool {
    const words = [_][]const u8{
        "implements", "interface", "let",       "package", "private",
        "protected",  "public",    "static",    "yield",   "eval",
        "arguments",
    };
    for (words) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// Reject a BindingIdentifier that strict-mode code may not bind (a future
/// reserved word, `eval` or `arguments` — ES 13.1.1 / 12.7.2). Returns true when
/// the name is legal; on rejection it records the early SyntaxError and the
/// caller must bail out. No-op in sloppy-mode code.
pub fn checkStrictBindingName(p: *Parser, name: []const u8, line: u32, column: u32) bool {
    if (!p.strict or !isStrictReservedWord(name)) return true;
    if (!p.had_error) {
        p.had_error = true;
        p.error_info = ParseError{
            .message = "unexpected strict-mode reserved word as binding name",
            .line = line,
            .column = column,
        };
    }
    return false;
}

/// True when `names` binds the same identifier twice. Parameter lists are short,
/// so the quadratic scan beats building a set.
pub fn hasDuplicateName(names: []const []const u8) bool {
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) return true;
        }
    }
    return false;
}

/// Record the early SyntaxError for a parameter list that binds a name twice
/// (§15.1.2/§15.2.1/§15.3.1: duplicates survive only in a sloppy, simple
/// FormalParameters of a function declaration or expression).
pub fn rejectDuplicateParams(p: *Parser) void {
    if (p.had_error) return;
    p.had_error = true;
    p.error_info = ParseError{
        .message = "duplicate parameter name not allowed in this context",
        .line = p.current.line,
        .column = p.current.column,
    };
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
    source: []const u8,
    /// Lookahead token (already lexed).
    current: Token,
    /// End source offset of the most recently consumed token. Unlike
    /// `current.start`, this excludes trailing trivia (comments/whitespace)
    /// between the last real token and the next one — needed for precise
    /// Function.prototype.toString source spans.
    prev_end: u32 = 0,
    /// Start offset of an `async` contextual keyword the caller consumed just
    /// before delegating to parseFunctionDecl, so the function's source span
    /// (Function.prototype.toString) begins at `async`. 0 when not applicable.
    async_kw_start: u32 = 0,
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
    /// M16 Phase 5: aliased live exports, e.g. `export { local2 as renamed }` where
    /// local != exported. All uses of `local` are rewritten to `exports.exported`.
    live_export_aliases: std.ArrayList(struct { local: []const u8, exported: []const u8 }),
    /// M16 Phase 4: all exported names (deduplicated), collected so the module namespace
    /// exotic object can distinguish "uninitialized export" (TDZ → ReferenceError) from
    /// "not an export" (→ undefined), even on self-import before the export assignments run.
    all_export_names: std.ArrayList([]const u8),
    /// M16 Phase 5: nesting depth inside function bodies. 0 = top-level module code;
    /// incremented by parseFunctionBody so import hoisting only applies at top level.
    fn_nesting_depth: u32,
    /// Inside a class static initialization block, `await` is reserved: it is
    /// neither an identifier nor an operator there (§15.7.1). Cleared when a
    /// nested function body is entered — that body re-establishes its own rules,
    /// so `static { function f(await) {} }` is legal.
    await_is_reserved: bool = false,
    /// Innermost function-like scope is a class static initialization block, so
    /// `arguments` and `return` are Syntax Errors. Cleared, like
    /// `await_is_reserved`, when a nested function body is entered.
    in_static_block: bool = false,
    /// One-shot: the next `parseFunctionBody` call is a ClassStaticBlockBody,
    /// so it arms `await_is_reserved`/`in_static_block` instead of clearing them.
    next_body_is_static_block: bool = false,
    /// M16 Phase 5: import statements collected at top level (fn_nesting_depth == 0)
    /// to be inserted before entry body stmts, so require() runs before any assertions.
    hoisted_import_stmts: std.ArrayList(*Node),
    /// M16 Phase 5: set when `var __esm_hoist_point__=1;` is seen in the bundle header.
    /// Only then do we hoist imports — unit tests have no marker so they keep source order.
    hoist_point_seen: bool,
    /// M16 Phase 5: set when `var __esm_hoist_point_no_se__=1;` is emitted by buildBundle
    /// for sync entries with function exports.  Named imports are still hoisted (so their
    /// `var __esm_N__` lives at module scope before the IIFE), but bare side-effect imports
    /// (`import './dep'`) are NOT hoisted — they stay in the IIFE body and run AFTER the
    /// pre-hoist `exports.fn = fn` assignments, so circular deps can call the function.
    hoist_no_se: bool,
    /// M16 Phase 5: index into the stmt list after which hoisted imports are inserted.
    hoist_point_idx: usize,
    /// M16 Phase 5: name hint set by parseExportDecl for `export default class/function`
    /// anonymous expressions, consumed by parseClassExpr / parseFunctionExpr.
    export_default_name_hint: ?[]const u8,
    /// M16 TLA: set when an `await` is parsed at module top level (function
    /// nesting depth 0). The module then has top-level await and its top-level
    /// program is compiled/driven as an async body (real per-await suspension).
    saw_top_level_await: bool,
    /// Set by parsePrimary when a `super` token is parsed. parseObjectLiteral
    /// saves/clears it around each method body to detect object-method `super`
    /// usage so it can bind `super`/`__sproto__`/`__superthis` to the home
    /// object's prototype (object literals have no Super class binding).
    super_used: bool,
    /// Monotonic counter for the hidden `__home_N` capture var injected by
    /// parseObjectLiteral for object literals whose methods use `super`.
    home_obj_counter: u32,
    /// Arrow destructuring params: when an arrow parameter is an array/object
    /// pattern (`([a]) => …`, `({x}) => …`), extractArrowParams gives it a
    /// synthetic name and stashes the destructuring `const` decls here. The arrow
    /// builder snapshots+clears this immediately after extractArrowParams and
    /// prepends the decls to the body. Cleared per extraction so nested arrows
    /// don't cross-contaminate.
    arrow_prelude: std.ArrayList(*Node),
    /// Set by `extractArrowParams` when the cover list ends in a `...rest`
    /// element, so the arrow builders can carry the rest binding onto the
    /// `function_expr`. Reset at the start of each extraction.
    arrow_rest_param: ?[]const u8 = null,
    /// Monotonic counter for synthetic destructuring-param names (`__param_N`).
    param_destruct_counter: u32,
    /// Monotonic counter giving every class body that declares private elements a
    /// distinct PrivateEnvironment identity. `#x` is stored as the property key
    /// "#x", so two nested classes both declaring `#x` would otherwise share one
    /// key and defeat the brand check; `manglePrivateNames` rewrites each class's
    /// own private names to "#x\x01N" using this id. See `mangled_priv_sep`.
    private_class_counter: u32 = 0,
    /// Var-decl / for-of-head pattern destructuring: when set, `desugarParamPattern`
    /// / `bindPatternElement` emit their decls here instead of into `arrow_prelude`,
    /// and user-visible bindings use `destruct_kind` instead of a hardcoded `.let`
    /// (synthetic temps still always use `.let`). The caller (`parseVarDeclarator`,
    /// `parseForDestructuring`) saves/sets/restores both fields around the call so
    /// nested arrow-param destructuring inside a default value expression is
    /// unaffected (arrow params are parsed — and their own preludes emitted — before
    /// these fields are ever set).
    destruct_out: ?*std.ArrayList(*Node) = null,
    destruct_kind: ast.VarKind = .let,
    /// Destructuring-param `let` decls produced by `parseFunctionParams` for a
    /// non-arrow function, awaiting prepend by the immediately-following
    /// `parseFunctionBody`. Drained (set to empty) on consumption. Built into a
    /// local list per param-list so nested function/arrow defaults can't clobber it.
    pending_param_prelude: []const *Node = &.{},
    /// BoundNames of the FormalParameters just parsed, before the
    /// default-parameter TDZ desugar renames them to `__arg_N`. Read by the
    /// immediately-following `parseFunctionBody` to enforce §15.2.1: a
    /// body-level `let`/`const` may not redeclare a parameter.
    pending_param_names: []const []const u8 = &.{},
    /// True when those FormalParameters bound the same name twice. Legal in a
    /// sloppy, simple-parameter-list function declaration/expression, and an
    /// early SyntaxError everywhere else — including when the body turns out to
    /// carry a "use strict" prologue, which only `parseFunctionBody` can see.
    pending_params_duplicate: bool = false,
    /// Set by callers that parse UniqueFormalParameters (method definitions,
    /// accessors, class constructors), where duplicate BoundNames are an early
    /// SyntaxError regardless of strictness. Consumed by `parseFunctionParams`.
    require_unique_params: bool = false,
    /// [~In]: suppress `in` as a relational operator while parsing a `for` head's
    /// variable initializer, where it separates the head from the enumerated
    /// object instead (Annex B.3.5 `for (var a = 0 in obj)`). Saved/restored
    /// around the initializer so a parenthesized or nested expression — which
    /// re-enters the [+In] grammar — is unaffected.
    no_in: bool = false,
    /// True when parsing direct/indirect `eval()` code. Eval code is a Script
    /// (sec-scripts §A.5), so `import`/`export` *declarations* are early
    /// SyntaxErrors — unlike the CJS-desugar bundle source run via parseScript,
    /// which legitimately carries them. Set only by the `eval()` builtin.
    eval_code: bool,
    /// Set with `eval_code` for a *direct* eval whose calling context supplies a
    /// [[HomeObject]] — i.e. one nested in a method or a class field initializer,
    /// detected by the VM from the `__sproto__` binding in the caller's scope
    /// chain. Only then is SuperProperty (`super.x`) legal inside the eval'd
    /// code; SuperCall never is, and an indirect eval permits neither.
    eval_allow_super_prop: bool = false,
    /// Set with `eval_code` for a direct eval whose calling context is a function
    /// invocation, which is the only place `new.target` is legal (§13.3.12.1: it
    /// is a SyntaxError unless the code is contained in function code). The VM
    /// detects it from a `__new_target__` binding below the global scope, so an
    /// indirect eval — which is global code — never gets it.
    eval_allow_new_target: bool = false,
    /// True when the code currently being parsed is strict-mode code (a "use
    /// strict" directive prologue at script/eval/function scope, or module code).
    /// Drives the strict-only early SyntaxErrors: future-reserved words used as
    /// binding identifiers (`public`, `interface`, …) and assignment to
    /// `eval`/`arguments`. May be set by a host caller (e.g. direct `eval` in a
    /// strict caller) before parsing begins.
    strict: bool,

    pub fn init(source: []const u8, arena: std.mem.Allocator) Parser {
        var p = Parser{
            .lexer = Lexer.init(source, arena),
            .arena = arena,
            .source = source,
            .current = undefined,
            .had_error = false,
            .error_info = null,
            .in_generator_function = false,
            .is_module = false,
            .extra_stmts = .{},
            .live_imports = .{},
            .live_exports = .{},
            .live_export_aliases = .{},
            .all_export_names = .{},
            .fn_nesting_depth = 0,
            .hoisted_import_stmts = .{},
            .hoist_point_seen = false,
            .hoist_no_se = false,
            .hoist_point_idx = 0,
            .export_default_name_hint = null,
            .saw_top_level_await = false,
            .super_used = false,
            .home_obj_counter = 0,
            .arrow_prelude = .{},
            .param_destruct_counter = 0,
            .eval_code = false,
            .strict = false,
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
        self.prev_end = prev.end;
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

    /// Peek the second token after `current` (i.e. token after `peekNext`).
    /// Used for `await using <ident>` lookahead.
    pub fn peekNext2(self: *Parser) Token {
        var lx = self.lexer;
        _ = lx.next() catch return Token.initSimple(.eof, 0, 0, 1, 1, false);
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

    /// True when the current token is an IdentifierName: a plain identifier or a
    /// reserved word (`export`, `in`, `if`, …). Reserved words are valid in
    /// IdentifierName positions — property keys, method names — even though they
    /// cannot be used as bare Identifiers. Its spelling is in `current.value_str`.
    pub fn currentIsIdentifierName(self: *const Parser) bool {
        const k = self.current.kind;
        if (k == .identifier) return true;
        const i = @intFromEnum(k);
        return i >= @intFromEnum(TokenKind.kw_break) and i <= @intFromEnum(TokenKind.kw_null);
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

    /// Slice of the original source covering [start, end) — used to retain a
    /// function literal's exact source text for Function.prototype.toString.
    /// Returns null for degenerate/synthetic spans (start >= end, as produced
    /// by compiler-synthesized nodes with no real source) or an out-of-bounds
    /// end, so callers can fall back to the native-code format.
    ///
    /// `end` is conventionally `p.current.start` — the start of the NEXT
    /// lexed token, which the lexer already advanced past any intervening
    /// whitespace/comments to reach. That means [start, end) can include
    /// trailing whitespace between the construct's real last character and
    /// whatever follows (e.g. `function(){return 1} + {}` captures a
    /// trailing space before `+`) even though that whitespace was never part
    /// of the function literal. Trim it so the retained text matches the
    /// construct's real source exactly.
    pub fn sourceSlice(self: *const Parser, start: u32, end: u32) ?[]const u8 {
        if (start >= end or end > self.source.len) return null;
        return std.mem.trimRight(u8, self.source[start..end], " \t\r\n");
    }

    /// Build a string-literal AST node (e.g. for export-name array elements).
    pub fn mkStringLiteral(self: *Parser, value: []const u8) ?*Node {
        return self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = value });
    }

    /// Build a two-argument call `callee_name(arg1, arg2)`.
    pub fn mkCall2(self: *Parser, callee_name: []const u8, arg1: *Node, arg2: *Node) ?*Node {
        const callee = self.mkIdent(callee_name) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(self.arena, arg1) catch return null;
        args.append(self.arena, arg2) catch return null;
        return self.makeNode(.call_expr, self.current.start, self.current.start, .{ .call_expr = .{ .callee = callee, .args = args.items } });
    }

    /// Build an array-literal AST node `[elem1, elem2, ...]`.
    pub fn mkArrayLiteral(self: *Parser, elements: []*Node) ?*Node {
        return self.makeNode(.array_literal, self.current.start, self.current.start, .{ .array_literal = .{ .elements = elements } });
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
    /// Suspend the class-static-block restrictions (`await` reserved,
    /// `arguments`/`return` banned) for a nested function's parameter list or
    /// body — those establish their own rules, so `static { (x = await) => {} }`
    /// and `static { function f(){ arguments } }` are both legal. Pair with
    /// `restoreStaticBlock`.
    pub fn leaveStaticBlock(self: *Parser) [2]bool {
        const saved = [2]bool{ self.await_is_reserved, self.in_static_block };
        self.await_is_reserved = false;
        self.in_static_block = false;
        return saved;
    }

    pub fn restoreStaticBlock(self: *Parser, saved: [2]bool) void {
        self.await_is_reserved = saved[0];
        self.in_static_block = saved[1];
    }

    /// The early-error message for `name` used as an identifier directly inside
    /// a class static initialization block, or null when it is fine there.
    /// §15.7.1: the block has no `arguments` binding, and `await` is reserved.
    pub fn staticBlockReservedIdent(self: *Parser, name: []const u8) ?[]const u8 {
        if (self.await_is_reserved and std.mem.eql(u8, name, "await"))
            return "'await' is reserved in a class static initialization block";
        if (self.in_static_block and std.mem.eql(u8, name, "arguments"))
            return "'arguments' is not allowed in a class static initialization block";
        return null;
    }

    pub fn parseScript(self: *Parser) ParseResult {
        var stmts = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        const la_start = self.live_export_aliases.items.len;
        // Directive prologue: leading string-literal statements may carry a
        // "use strict" directive that makes the rest of the script strict code.
        // Detected before parsing any later statement, so the strict early-error
        // checks (reserved-word bindings, eval/arguments assignment) see it.
        var in_prologue = true;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            if (in_prologue) {
                if (directiveOf(s)) |dir| {
                    if (std.mem.eql(u8, dir, "use strict")) self.strict = true;
                } else in_prologue = false;
            }
            self.drainExtraStmts(&stmts);
            // M16 Phase 5: detect the bundle hoist-point marker. A buildBundle
            // output is CJS-desugared script source (run via parseScript), but it
            // still carries ES `import`/`export` statements and the
            // `__esm_hoist_point__` marker emitted right before the entry body.
            // Mirror parseModule so the entry's import bindings are hoisted and
            // their leaked `var local` declarations removed (so dependency factory
            // bodies don't see entry imports via the shared top-level scope).
            // Plain scripts have no marker, so this is a no-op for them.
            if (s.kind == .var_decl and
                std.mem.eql(u8, s.data.var_decl.name, "__esm_hoist_point__"))
            {
                self.hoist_point_seen = true;
                self.hoist_point_idx = stmts.items.len;
            }
            // M16 Phase 5: variant for sync entries with function exports — hoist
            // named imports but NOT bare side-effect imports (which must stay in the
            // IIFE body so they run after the pre-hoist `exports.fn = fn` assignments).
            if (s.kind == .var_decl and
                std.mem.eql(u8, s.data.var_decl.name, "__esm_hoist_point_no_se__"))
            {
                self.hoist_point_seen = true;
                self.hoist_no_se = true;
                self.hoist_point_idx = stmts.items.len;
            }
        }
        if (self.hoisted_import_stmts.items.len > 0) {
            var final_stmts = std.ArrayList(*Node){};
            final_stmts.appendSlice(self.arena, stmts.items[0..self.hoist_point_idx]) catch {
                self.had_error = true;
            };
            final_stmts.appendSlice(self.arena, self.hoisted_import_stmts.items) catch {
                self.had_error = true;
            };
            final_stmts.appendSlice(self.arena, stmts.items[self.hoist_point_idx..]) catch {
                self.had_error = true;
            };
            self.hoisted_import_stmts.clearRetainingCapacity();
            stmts = final_stmts;
        }
        self.applyLiveBindings(stmts.items, li_start, le_start, la_start);
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
        self.strict = true; // §11.2.2: module code is always strict.
        // Annex B.1.1 HTML-like comments are Script-only: `<!--` / `-->` in
        // module code are ordinary punctuators, i.e. a SyntaxError.
        self.lexer.allow_html_comments = false;
        var stmts = std.ArrayList(*Node){};
        const li_start = self.live_imports.items.len;
        const le_start = self.live_exports.items.len;
        const la_start = self.live_export_aliases.items.len;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&stmts);
            // M16 Phase 5: detect the hoist-point marker emitted by buildBundle right
            // before entry_src. Imports hoisted after this marker land after the full
            // bundle header (which initialises __modules__ / __initExports__) but before
            // entry body assertions that precede `import` declarations in source order.
            if (s.kind == .var_decl and
                std.mem.eql(u8, s.data.var_decl.name, "__esm_hoist_point__"))
            {
                self.hoist_point_seen = true;
                self.hoist_point_idx = stmts.items.len;
            }
            // M16 Phase 5: variant emitted for sync entries with function exports — hoist
            // named imports but NOT bare side-effect imports.
            if (s.kind == .var_decl and
                std.mem.eql(u8, s.data.var_decl.name, "__esm_hoist_point_no_se__"))
            {
                self.hoist_point_seen = true;
                self.hoist_no_se = true;
                self.hoist_point_idx = stmts.items.len;
            }
        }
        // M16 Phase 5: insert hoisted imports at the hoist point (after bundle header,
        // before entry body). Only active when the bundle marker was seen; unit tests
        // have no marker so hoisted_import_stmts is always empty for them.
        if (self.hoisted_import_stmts.items.len > 0) {
            var final_stmts = std.ArrayList(*Node){};
            final_stmts.appendSlice(self.arena, stmts.items[0..self.hoist_point_idx]) catch {
                self.had_error = true;
            };
            final_stmts.appendSlice(self.arena, self.hoisted_import_stmts.items) catch {
                self.had_error = true;
            };
            final_stmts.appendSlice(self.arena, stmts.items[self.hoist_point_idx..]) catch {
                self.had_error = true;
            };
            self.hoisted_import_stmts.clearRetainingCapacity();
            stmts = final_stmts;
        }
        self.applyLiveBindings(stmts.items, li_start, le_start, la_start);
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
    /// M16 Phase 5: Build `__liveReexport__(exports, 'name', source, 'prop')`
    /// for live re-exports (`export { X as Y } from './mod'`).  The getter makes
    /// the re-export a live binding to the source module's export, so circular
    /// dependencies resolve correctly — the value is read at access time, not
    /// at re-export time.
    pub fn mkExportGetter(self: *Parser, exported: []const u8, source: *Node) ?*Node {
        // source is already a member expression like __esm_X.A
        // We need to decompose it: source = __esm_X.A → source_obj=__esm_X, prop="A"
        if (source.kind != .member_expr or source.data.member_expr.computed) return null;
        const src_obj = source.data.member_expr.object;
        const src_prop = source.data.member_expr.property;
        if (src_obj.kind != .identifier or src_prop.kind != .identifier) return null;
        const src_obj_name = src_obj.data.identifier;
        const src_prop_name = src_prop.data.identifier;

        // __liveReexport__(exports, 'exported', __esm_X, 'A')
        const callee = self.mkIdent("__liveReexport__") orelse return null;
        const exports_arg = self.mkIdent("exports") orelse return null;
        const name_arg = self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = exported }) orelse return null;
        const source_arg = self.mkIdent(src_obj_name) orelse return null;
        const prop_arg = self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = src_prop_name }) orelse return null;

        const args = self.arena.alloc(*Node, 4) catch return null;
        args[0] = exports_arg;
        args[1] = name_arg;
        args[2] = source_arg;
        args[3] = prop_arg;
        const call = self.makeNode(.call_expr, self.current.start, self.current.start, .{
            .call_expr = .{ .callee = callee, .args = args },
        }) orelse return null;

        return self.makeNode(.expr_stmt, self.current.start, self.current.start, .{ .expr_stmt = call });
    }

    /// Build `__liveLocalExport__(exports, 'name', function() { return localName; })`
    /// for live local exports (e.g. `export default function fn()` where fn may
    /// be reassigned).  The getter reads the local binding at access time, so
    /// reassignments are reflected through the export.
    pub fn mkLiveLocalExport(self: *Parser, exported: []const u8, local_name: []const u8) ?*Node {
        const callee = self.mkIdent("__liveLocalExport__") orelse return null;
        const exports_arg = self.mkIdent("exports") orelse return null;
        const name_arg = self.makeNode(.string_literal, self.current.start, self.current.start, .{ .string_literal = exported }) orelse return null;
        // Build: function() { return localName; }
        const ret_ident = self.mkIdent(local_name) orelse return null;
        const ret_stmt = self.makeNode(.return_stmt, self.current.start, self.current.start, .{ .return_stmt = ret_ident }) orelse return null;
        const body_nodes = self.arena.alloc(*Node, 1) catch return null;
        body_nodes[0] = ret_stmt;
        const getter = self.makeNode(.function_expr, self.current.start, self.current.start, .{
            .function_expr = .{
                .name = null,
                .params = &.{},
                .param_defaults = &.{},
                .rest_param = null,
                .body = body_nodes,
                .is_generator = false,
                .is_async = false,
                .is_strict = false,
            },
        }) orelse return null;

        const args = self.arena.alloc(*Node, 3) catch return null;
        args[0] = exports_arg;
        args[1] = name_arg;
        args[2] = getter;
        const call = self.makeNode(.call_expr, self.current.start, self.current.start, .{
            .call_expr = .{ .callee = callee, .args = args },
        }) orelse return null;
        // Track the exported name for the namespace exotic.
        var dup = false;
        for (self.all_export_names.items) |n| {
            if (std.mem.eql(u8, n, exported)) { dup = true; break; }
        }
        if (!dup) self.all_export_names.append(self.arena, exported) catch {};
        return self.makeNode(.expr_stmt, self.current.start, self.current.start, .{ .expr_stmt = call });
    }

    pub fn mkExportAssign(self: *Parser, exported: []const u8, value: *Node) ?*Node {
        const exports_id = self.mkIdent("exports") orelse return null;
        const target = self.mkMember(exports_id, exported) orelse return null;
        const assign = self.makeNode(.assignment_expr, self.current.start, self.current.start, .{ .assignment_expr = .{ .op = .assign, .target = target, .value = value } }) orelse return null;
        // Track every exported name so the namespace exotic can distinguish
        // "uninitialized export" from "not an export" during self-/cyclic imports.
        var dup = false;
        for (self.all_export_names.items) |n| {
            if (std.mem.eql(u8, n, exported)) { dup = true; break; }
        }
        if (!dup) self.all_export_names.append(self.arena, exported) catch {};
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

    /// Register every `var`/`let`/`const` declarator name in an `export <decl>`
    /// as a live export, recursing into the `block_stmt` that a multi-declarator
    /// statement (`export let a, b, c;`) lowers to. Without walking the block,
    /// only the first declarator of a multi-name export would get a live binding,
    /// leaving later names (and assignments to them) invisible to importers.
    pub fn registerDeclLiveExports(self: *Parser, node: *Node) void {
        switch (node.kind) {
            .var_decl => {
                const vkind = node.data.var_decl.kind;
                if (vkind == .var_ or !self.is_module or self.fn_nesting_depth > 0 or self.hoist_point_seen) {
                    self.live_exports.append(self.arena, node.data.var_decl.name) catch {};
                }
            },
            .block_stmt => for (node.data.block_stmt.body) |c| self.registerDeclLiveExports(c),
            else => {},
        }
    }

    // Live bindings: rewrite each named/default import use-site to `ns.prop`, and each
    // `export let/var` use-site to `exports.name`, when the local name has no declaration
    // other than its own binding (count <= 1) — sound (no shadowing possible). Shadowed
    // names keep CJS-snapshot semantics.
    pub fn applyLiveBindings(self: *Parser, stmts: []*Node, li_start: usize, le_start: usize, la_start: usize) void {
        if (self.had_error) {
            // When inside a function body in bundle mode (IIFE wrapping the entry
            // body), don't shrink live_imports — the top-level applyLiveBindings
            // needs them to remove hoisted import var declarations.
            if (!(self.hoist_point_seen and self.fn_nesting_depth > 0)) {
                self.live_imports.shrinkRetainingCapacity(li_start);
            }
            self.live_exports.shrinkRetainingCapacity(le_start);
            self.live_export_aliases.shrinkRetainingCapacity(la_start);
            return;
        }
        const n = self.live_imports.items.len;
        const ne = self.live_exports.items.len;
        const na = self.live_export_aliases.items.len;
        if (n <= li_start and ne <= le_start and na <= la_start) return;
        var counts = std.StringHashMap(u32).init(self.arena);
        for (stmts) |s| self.countDecls(s, &counts);
        // M16: re-exports of named imports (`import {x} from 'm'; export {x}`) must
        // forward to m's binding (live re-export), not snapshot a fresh local — so
        // the star-export ambiguity check resolves them to the same root as
        // `export {x} from 'm'`.  Run before the import-rewrite pass (which would
        // otherwise rewrite the snapshot's RHS and defeat the matcher).
        var reexported_imports = std.StringHashMap(void).init(self.arena);
        {
            var ei = le_start;
            while (ei < ne) : (ei += 1) {
                const ename = self.live_exports.items[ei];
                for (self.live_imports.items[li_start..n]) |imp| {
                    if (std.mem.eql(u8, imp.name, ename) and !std.mem.eql(u8, imp.prop, "__ns__")) {
                        if (self.rewriteSnapshotToReexport(stmts, ename, ename, imp.ns, imp.prop)) {
                            reexported_imports.put(ename, {}) catch {};
                        }
                        break;
                    }
                }
            }
            var ai = la_start;
            while (ai < na) : (ai += 1) {
                const al = self.live_export_aliases.items[ai];
                for (self.live_imports.items[li_start..n]) |imp| {
                    if (std.mem.eql(u8, imp.name, al.local) and !std.mem.eql(u8, imp.prop, "__ns__")) {
                        if (self.rewriteSnapshotToReexport(stmts, al.local, al.exported, imp.ns, imp.prop)) {
                            reexported_imports.put(al.local, {}) catch {};
                        }
                        break;
                    }
                }
            }
        }
        var i = li_start;
        while (i < n) : (i += 1) {
            const imp = self.live_imports.items[i];
            if ((counts.get(imp.name) orelse 0) <= 1) {
                for (stmts) |s| self.rewriteName(s, imp.name, imp.ns, imp.prop);
                // In bundle mode (hoist_point_seen), clear the snapshot init
                // `var local = ns.prop` so TDZ exports don't throw — all uses
                // are already rewritten to `ns.prop` above. Not needed for unit
                // tests (no hoist) since imports run after their module is ready.
                if (self.hoist_point_seen) {
                    for (stmts) |s| {
                        if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, imp.name)) {
                            // M16 Phase 5: remove the import binding declaration
                            // entirely.  All uses of `imp.name` have been rewritten
                            // to `ns.prop` above, so the `var local = ns.prop`
                            // declaration is dead code.  Removing it prevents the
                            // entry module's import bindings (e.g. `var B` from
                            // `import { B }`) from leaking to the top-level scope
                            // and being visible inside dependency factory functions
                            // via the scope chain — which would cause tests expecting
                            // ReferenceError for re-export names to see `undefined`.
                            s.* = Node{ .kind = .empty_stmt, .start = s.start, .end = s.end, .data = .{ .empty_stmt = {} } };
                        }
                    }
                }
            }
        }
        var j = le_start;
        while (j < ne) : (j += 1) {
            const name = self.live_exports.items[j];
            if (reexported_imports.contains(name)) continue;
            if ((counts.get(name) orelse 0) <= 1) self.makeExportLive(stmts, name);
        }
        var k = la_start;
        while (k < na) : (k += 1) {
            const alias = self.live_export_aliases.items[k];
            if (reexported_imports.contains(alias.local)) continue;
            if ((counts.get(alias.local) orelse 0) <= 1) {
                self.makeExportLiveAlias(stmts, alias.local, alias.exported);
            }
        }
        // When inside a function body in bundle mode (IIFE wrapping the entry
        // body), don't shrink live_imports — the top-level applyLiveBindings
        // needs them to remove hoisted import var declarations from the
        // hoisted_import_stmts array (which is separate from the function body).
        if (!(self.hoist_point_seen and self.fn_nesting_depth > 0)) {
            self.live_imports.shrinkRetainingCapacity(li_start);
        }
        self.live_exports.shrinkRetainingCapacity(le_start);
        self.live_export_aliases.shrinkRetainingCapacity(la_start);
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
        //
        // If NO binding is found at the top level (has_var_decl=false AND
        // has_func_decl=false), the export lives inside a bundle dependency factory
        // function body (fn_nesting_depth > 0 during parse). `makeExportLive` operates
        // on top-level stmts only — it can't find the var_decl inside the function_expr
        // to rewrite it, but `rewriteName` DOES recurse into function bodies, which
        // would break references (e.g. rewriting `results.push(...)` to
        // `exports.results.push(...)` while `exports.results` is still a TDZ marker).
        // Return early to preserve the CJS snapshot for factory-body and class exports.
        var has_var_decl = false;
        var has_func_decl = false;
        for (stmts) |s| {
            if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, name)) has_var_decl = true;
            if (s.kind == .function_decl and std.mem.eql(u8, s.data.function_decl.name, name)) has_func_decl = true;
        }
        if (has_func_decl and !has_var_decl) return;
        if (!has_var_decl and !has_func_decl) return;
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

    /// Like `makeExportLive` but for `export { local as exported }` where local != exported.
    /// Rewrites all uses of `local` to `exports.exported` and seeds the initializer.
    pub fn makeExportLiveAlias(self: *Parser, stmts: []*Node, local: []const u8, exported: []const u8) void {
        var has_var_decl = false;
        var has_func_decl = false;
        for (stmts) |s| {
            if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, local)) has_var_decl = true;
            if (s.kind == .function_decl and std.mem.eql(u8, s.data.function_decl.name, local)) has_func_decl = true;
        }
        if (has_func_decl and !has_var_decl) return;
        if (!has_var_decl and !has_func_decl) return; // factory-body/class export: preserve snapshot
        for (stmts) |s| {
            // Remove snapshot `exports.exported = local`
            if (s.kind == .expr_stmt) {
                const e = s.data.expr_stmt;
                if (e.kind == .assignment_expr) {
                    const a = e.data.assignment_expr;
                    if (a.value.kind == .identifier and std.mem.eql(u8, a.value.data.identifier, local)) {
                        const t = a.target;
                        if (t.kind == .member_expr and !t.data.member_expr.computed) {
                            const obj = t.data.member_expr.object;
                            const prop = t.data.member_expr.property;
                            if (obj.kind == .identifier and std.mem.eql(u8, obj.data.identifier, "exports") and
                                prop.kind == .identifier and std.mem.eql(u8, prop.data.identifier, exported))
                            {
                                s.* = Node{ .kind = .empty_stmt, .start = s.start, .end = s.end, .data = .{ .empty_stmt = {} } };
                                continue;
                            }
                        }
                    }
                }
            }
            // Convert `var local = init` → `exports.exported = init`
            if (s.kind == .var_decl and std.mem.eql(u8, s.data.var_decl.name, local)) {
                const obj = self.makeNode(.identifier, s.start, s.start, .{ .identifier = "exports" }) orelse continue;
                const ep = self.makeNode(.identifier, s.start, s.start, .{ .identifier = exported }) orelse continue;
                const tgt = self.makeNode(.member_expr, s.start, s.start, .{ .member_expr = .{ .object = obj, .property = ep, .computed = false } }) orelse continue;
                if (s.data.var_decl.init) |init_node| {
                    const asn = self.makeNode(.assignment_expr, s.start, s.start, .{ .assignment_expr = .{ .op = .assign, .target = tgt, .value = init_node } }) orelse continue;
                    s.* = Node{ .kind = .expr_stmt, .start = s.start, .end = s.end, .data = .{ .expr_stmt = asn } };
                } else {
                    const undef = self.makeNode(.identifier, s.start, s.start, .{ .identifier = "undefined" }) orelse continue;
                    const asn = self.makeNode(.assignment_expr, s.start, s.start, .{ .assignment_expr = .{ .op = .assign, .target = tgt, .value = undef } }) orelse continue;
                    s.* = Node{ .kind = .expr_stmt, .start = s.start, .end = s.end, .data = .{ .expr_stmt = asn } };
                }
            }
        }
        for (stmts) |s| self.rewriteName(s, local, "exports", exported);
    }

    /// M16: `export { local as exported }` where `local` is a *named* import
    /// (`import { local } from 'm'`) is — per spec §16.2.1.7.1 step 10.1.ii.3 — an
    /// indirect re-export of m's binding, identical to `export { local as exported }
    /// from 'm'`.  Rewrite the generated snapshot `exports.exported = local` into a
    /// live re-export getter that forwards to the import's namespace (`__esm_X.prop`),
    /// so the star-export ambiguity check (__starRoot__) traces both forms to the
    /// SAME (module, name) root.  Returns true when the snapshot was found+rewritten.
    pub fn rewriteSnapshotToReexport(self: *Parser, stmts: []*Node, local: []const u8, exported: []const u8, ns_name: []const u8, prop: []const u8) bool {
        for (stmts) |s| {
            if (s.kind != .expr_stmt) continue;
            const e = s.data.expr_stmt;
            if (e.kind != .assignment_expr) continue;
            const a = e.data.assignment_expr;
            if (a.op != .assign) continue;
            if (a.value.kind != .identifier or !std.mem.eql(u8, a.value.data.identifier, local)) continue;
            const t = a.target;
            if (t.kind != .member_expr or t.data.member_expr.computed) continue;
            const obj = t.data.member_expr.object;
            const propn = t.data.member_expr.property;
            if (obj.kind != .identifier or !std.mem.eql(u8, obj.data.identifier, "exports")) continue;
            if (propn.kind != .identifier or !std.mem.eql(u8, propn.data.identifier, exported)) continue;
            const ns_id = self.mkIdent(ns_name) orelse return false;
            const member = self.mkMember(ns_id, prop) orelse return false;
            const getter_stmt = self.mkExportGetter(exported, member) orelse return false;
            s.* = getter_stmt.*;
            return true;
        }
        return false;
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
                // Only count the function's own name (it creates an outer-scope
                // binding). Params and body vars are function-scoped — counting
                // them would inflate counts and block live-binding rewrites for
                // same-named identifiers in the outer (entry) scope.
                self.incCount(counts, f.name);
            },
            .function_expr => {
                // Function expressions create no outer-scope bindings. Skip all
                // (dep-factory or user function): their params and body vars are
                // function-scoped and must not inflate entry-module counts.
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

    /// Returns true if any `var <name>` declaration appears anywhere in `stmts`,
    /// recursing through blocks/if/for/etc. but NOT into nested function bodies
    /// (those create their own scope). Used by `rewriteName` to avoid rewriting
    /// identifiers inside functions that shadow the module-level binding with a
    /// local `var`.
    fn fnBodyHasVar(stmts: []*Node, name: []const u8) bool {
        for (stmts) |s| {
            if (fnNodeHasVar(s, name)) return true;
        }
        return false;
    }

    fn fnNodeHasVar(n: *Node, name: []const u8) bool {
        switch (n.kind) {
            .var_decl => return std.mem.eql(u8, n.data.var_decl.name, name),
            .block_stmt => return fnBodyHasVar(n.data.block_stmt.body, name),
            .if_stmt => {
                const i = n.data.if_stmt;
                if (fnNodeHasVar(i.consequent, name)) return true;
                if (i.alternate) |a| return fnNodeHasVar(a, name);
                return false;
            },
            .while_stmt => return fnNodeHasVar(n.data.while_stmt.body, name),
            .do_while_stmt => return fnNodeHasVar(n.data.do_while_stmt.body, name),
            .for_stmt => {
                const f = n.data.for_stmt;
                if (f.init) |x| if (fnNodeHasVar(x, name)) return true;
                return fnNodeHasVar(f.body, name);
            },
            .for_in_stmt => {
                const f = n.data.for_in_stmt;
                if (fnNodeHasVar(f.left, name)) return true;
                return fnNodeHasVar(f.body, name);
            },
            .try_stmt => {
                const t = n.data.try_stmt;
                if (fnNodeHasVar(t.block, name)) return true;
                if (t.handler) |h| {
                    if (std.mem.eql(u8, h.param_name, name)) return true;
                    if (fnNodeHasVar(h.body, name)) return true;
                }
                if (t.finalizer) |fz| return fnNodeHasVar(fz, name);
                return false;
            },
            .switch_stmt => {
                for (n.data.switch_stmt.cases) |c| {
                    for (c.body) |st| if (fnNodeHasVar(st, name)) return true;
                }
                return false;
            },
            .labeled_stmt => return fnNodeHasVar(n.data.labeled_stmt.body, name),
            // function_decl / function_expr: separate scope — stop here
            .function_decl, .function_expr => return false,
            else => return false,
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
            .function_decl => {
                const fd = n.data.function_decl;
                // Skip if a param or local var shadows the name (inner scope).
                for (fd.params) |p| if (std.mem.eql(u8, p, name)) return;
                if (fd.rest_param) |r| if (std.mem.eql(u8, r, name)) return;
                if (fnBodyHasVar(fd.body, name)) return;
                for (fd.body) |s| self.rewriteName(s, name, ns, prop);
            },
            .function_expr => {
                // M16 Phase 5: skip bundle dependency factory functions — they
                // have params (require, module, exports) and represent separate
                // module scopes. Rewriting inside them conflates the entry
                // module's import/export names with the dependency's own free
                // variables (e.g. the fixture's `A` in `try { A; }` is NOT the
                // entry's export `A`). User nested functions (no such params)
                // are still recursed into so closures see live bindings, but
                // we skip if a param shadows the name being rewritten.
                const fe = n.data.function_expr;
                if (fe.params.len == 3 and
                    std.mem.eql(u8, fe.params[0], "require") and
                    std.mem.eql(u8, fe.params[1], "module") and
                    std.mem.eql(u8, fe.params[2], "exports"))
                {
                    return;
                }
                for (fe.params) |p| if (std.mem.eql(u8, p, name)) return;
                if (fe.rest_param) |r| if (std.mem.eql(u8, r, name)) return;
                if (fnBodyHasVar(fe.body, name)) return;
                for (fe.body) |s| self.rewriteName(s, name, ns, prop);
            },
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

    pub fn parseWithStmt(self: *Parser) ?*Node {
        return stmt_mod.parseWithStmt(self);
    }

    pub fn parseForStmt(self: *Parser) ?*Node {
        return stmt_mod.parseForStmt(self);
    }

    pub fn parseForDestructuring(self: *Parser, start: u32, kind: ast.VarKind, for_await: bool) ?*Node {
        return stmt_mod.parseForDestructuring(self, start, kind, for_await);
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

    pub fn rewriteSuperPropAssign(self: *Parser, op: ast.AssignOp, target: *Node, value: *Node, start: u32, end: u32) ?*Node {
        return expr_mod.rewriteSuperPropAssign(self, op, target, value, start, end);
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
        const la_start = self.live_export_aliases.items.len;
        while (!self.check(.eof) and !self.had_error) {
            const s = self.parseStatement() orelse break;
            stmts.append(self.arena, s) catch {
                self.had_error = true;
                break;
            };
            self.drainExtraStmts(&stmts);
        }
        self.applyLiveBindings(stmts.items, li_start, le_start, la_start);
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
