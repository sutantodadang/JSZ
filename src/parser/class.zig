// SPDX-License-Identifier: Apache-2.0
//! Class and function-body parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const expr_mod = @import("./expr.zig");
const ast = @import("./ast.zig");
const Node = ast.Node;

pub const ParamParse = parser_file.ParamParse;

/// Rewrite every `this` in a derived-class constructor body to read the hidden
/// `__superthis` binding (the object returned by `super()`), which is the real
/// instance for a derived class. A derived constructor's lexical `this` is the
/// super-constructed object — and for built-in exotics (TypedArray, Map, …) that
/// object carries the internal slots, so `this.buffer` etc. must resolve to it,
/// not to the constructor function's raw this-binding. Descends into arrow
/// functions (they inherit `this`) but NOT into ordinary functions / methods /
/// function declarations, which establish their own `this`.
fn rewriteThisToSuperThis(node: *Node) void {
    switch (node.data) {
        .this_expr => {
            node.kind = .identifier;
            node.data = .{ .identifier = "__superthis" };
        },
        .unary_expr => |u| rewriteThisToSuperThis(u.operand),
        .binary_expr => |b| {
            rewriteThisToSuperThis(b.left);
            rewriteThisToSuperThis(b.right);
        },
        .logical_expr => |b| {
            rewriteThisToSuperThis(b.left);
            rewriteThisToSuperThis(b.right);
        },
        .assignment_expr => |a| {
            rewriteThisToSuperThis(a.target);
            rewriteThisToSuperThis(a.value);
        },
        .update_expr => |u| rewriteThisToSuperThis(u.operand),
        .conditional_expr => |c| {
            rewriteThisToSuperThis(c.test_);
            rewriteThisToSuperThis(c.consequent);
            rewriteThisToSuperThis(c.alternate);
        },
        .sequence_expr => |s| for (s.exprs) |e| rewriteThisToSuperThis(e),
        .spread_expr => |e| rewriteThisToSuperThis(e),
        .yield_expr => |e| if (e) |ee| rewriteThisToSuperThis(ee),
        .call_expr => |c| {
            rewriteThisToSuperThis(c.callee);
            for (c.args) |a| rewriteThisToSuperThis(a);
        },
        .new_expr => |n| {
            rewriteThisToSuperThis(n.callee);
            for (n.args) |a| rewriteThisToSuperThis(a);
        },
        .member_expr => |m| {
            rewriteThisToSuperThis(m.object);
            if (m.computed) rewriteThisToSuperThis(m.property);
        },
        .optional_chain => |e| rewriteThisToSuperThis(e),
        .function_expr => |f| if (f.is_arrow) {
            for (f.param_defaults) |d| if (d) |dd| rewriteThisToSuperThis(dd);
            for (f.body) |s| rewriteThisToSuperThis(s);
        },
        .object_literal => |o| for (o.properties) |pr| {
            rewriteThisToSuperThis(pr.value);
            if (pr.computed_key) |k| rewriteThisToSuperThis(k);
        },
        .array_literal => |a| for (a.elements) |e| rewriteThisToSuperThis(e),
        .expr_stmt => |e| rewriteThisToSuperThis(e),
        .block_stmt => |b| for (b.body) |s| rewriteThisToSuperThis(s),
        .var_decl => |v| if (v.init) |i| rewriteThisToSuperThis(i),
        .if_stmt => |i| {
            rewriteThisToSuperThis(i.test_);
            rewriteThisToSuperThis(i.consequent);
            if (i.alternate) |a| rewriteThisToSuperThis(a);
        },
        .while_stmt => |w| {
            rewriteThisToSuperThis(w.test_);
            rewriteThisToSuperThis(w.body);
        },
        .do_while_stmt => |w| {
            rewriteThisToSuperThis(w.body);
            rewriteThisToSuperThis(w.test_);
        },
        .for_stmt => |f| {
            if (f.init) |i| rewriteThisToSuperThis(i);
            if (f.test_) |t| rewriteThisToSuperThis(t);
            if (f.update) |u| rewriteThisToSuperThis(u);
            rewriteThisToSuperThis(f.body);
        },
        .return_stmt => |e| if (e) |ee| rewriteThisToSuperThis(ee),
        .throw_stmt => |e| rewriteThisToSuperThis(e),
        .try_stmt => |t| {
            rewriteThisToSuperThis(t.block);
            if (t.handler) |h| rewriteThisToSuperThis(h.body);
            if (t.finalizer) |f| rewriteThisToSuperThis(f);
        },
        .for_in_stmt => |f| {
            rewriteThisToSuperThis(f.left);
            rewriteThisToSuperThis(f.right);
            rewriteThisToSuperThis(f.body);
        },
        .switch_stmt => |s| {
            rewriteThisToSuperThis(s.discriminant);
            for (s.cases) |c| {
                if (c.test_) |t| rewriteThisToSuperThis(t);
                for (c.body) |st| rewriteThisToSuperThis(st);
            }
        },
        .labeled_stmt => |l| rewriteThisToSuperThis(l.body),
        .program => |pr| for (pr.body) |s| rewriteThisToSuperThis(s),
        // Ordinary functions/declarations bind their own `this`; literals and
        // identifiers have no children to rewrite.
        else => {},
    }
}

/// Route every explicit `return` in a derived constructor's own body through the
/// spec's return-override rule (§10.2.2 [[Construct]] step 13): an Object result
/// replaces the instance, `undefined` yields the super-constructed `this`, and
/// any other value — including `null` — is a TypeError. Without this the desugared
/// constructor is an ordinary function, so `new` would silently substitute `this`
/// for a primitive return, as it does for a *base* class.
///
/// `return;` becomes `return __superthis;` rather than `return undefined`, since
/// the enclosing function's own `this` is the raw allocated object, not the
/// instance the parent constructor produced.
///
/// Stops at every nested function boundary — including arrows, whose `return`
/// belongs to the arrow, not to the constructor.
fn rewriteDerivedReturns(p: *Parser, node: *Node) void {
    switch (node.data) {
        .return_stmt => |e| {
            const start = node.start;
            const superthis = nodeIdent(p, "__superthis") orelse return;
            const arg = e orelse {
                node.data = .{ .return_stmt = superthis };
                return;
            };
            const callee = nodeIdent(p, "__derivedReturn__") orelse return;
            var args = std.ArrayList(*Node){};
            args.append(p.arena, arg) catch return;
            args.append(p.arena, superthis) catch return;
            const call = p.makeNode(.call_expr, start, node.end, .{
                .call_expr = .{ .callee = callee, .args = args.items },
            }) orelse return;
            node.data = .{ .return_stmt = call };
        },
        .block_stmt => |b| for (b.body) |s| rewriteDerivedReturns(p, s),
        .if_stmt => |i| {
            rewriteDerivedReturns(p, i.consequent);
            if (i.alternate) |a| rewriteDerivedReturns(p, a);
        },
        .while_stmt => |w| rewriteDerivedReturns(p, w.body),
        .do_while_stmt => |w| rewriteDerivedReturns(p, w.body),
        .for_stmt => |f| rewriteDerivedReturns(p, f.body),
        .for_in_stmt => |f| rewriteDerivedReturns(p, f.body),
        .try_stmt => |t| {
            rewriteDerivedReturns(p, t.block);
            if (t.handler) |h| rewriteDerivedReturns(p, h.body);
            if (t.finalizer) |f| rewriteDerivedReturns(p, f);
        },
        .switch_stmt => |s| for (s.cases) |c| {
            for (c.body) |st| rewriteDerivedReturns(p, st);
        },
        .labeled_stmt => |l| rewriteDerivedReturns(p, l.body),
        // Expressions carry no constructor-level `return`; nested functions
        // (arrows included) own theirs.
        else => {},
    }
}

/// Build the NewTarget node for a derived constructor's `Reflect.construct(Super,
/// arguments, <newTarget>)` desugaring: `__new_target__ || ClassName`. The hidden
/// `__new_target__` binding (set by [[Construct]]) carries the ORIGINAL new.target
/// down a multi-level super chain (`class C extends B extends A`); using the
/// lexical class name alone would reset it at each level, giving the wrong
/// prototype and dropping built-in exotic internal slots (e.g. TypedArray). The
/// lexical name is kept as a fallback for any path that didn't bind it.
fn makeNewTargetNode(p: *Parser, start: u32, class_name: []const u8) ?*Node {
    const id_var = p.makeNode(.identifier, start, start, .{ .identifier = "__new_target__" }) orelse return null;
    const id_cls = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    return p.makeNode(.logical_expr, start, start, .{
        .logical_expr = .{ .op = .or_, .left = id_var, .right = id_cls },
    });
}

const AccessorKind = enum { none, get, set };

/// A parsed non-constructor class member. `computed_key` (when non-null) holds a
/// runtime key expression (`[expr]`); otherwise `name` is the literal key.
const ClassMember = struct {
    is_static: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    accessor: AccessorKind = .none,
    name: []const u8 = "",
    computed_key: ?*Node = null,
    params: [][]const u8 = &[_][]const u8{},
    param_defaults: []?*Node = &[_]?*Node{},
    /// ExpectedArgumentCount for `fn.length` (see parser.ParamParse).
    expected_argc: ?u16 = null,
    rest_param: ?[]const u8 = null,
    body: []*Node = &[_]*Node{},
    /// Source span of this member (name through end of body), captured in
    /// parseClassMembers at parse time — emitClassMember runs later, after
    /// `p.current` has moved on, so it cannot recover this itself. Both 0
    /// (default) means "no real span" → toString falls back to native format.
    src_start: u32 = 0,
    src_end: u32 = 0,
};

/// A parsed class field (`name = init;`, `#name = init;`, `[expr] = init;`,
/// or `static name = init;`). Methods are kept separately in ClassMember.
const ClassField = struct {
    is_static: bool = false,
    name: []const u8 = "",
    computed_key: ?*Node = null,
    /// Name of the hidden `var` holding the pre-evaluated property key for a
    /// computed field. Per spec the ClassElementName is evaluated once, at
    /// ClassDefinitionEvaluation time (in source order), not per instance — so
    /// the field initializers reference this binding instead of re-evaluating
    /// `computed_key`. Null for non-computed fields.
    key_var: ?[]const u8 = null,
    init: ?*Node = null,
    /// ES2022 static initialization block (`static { ... }`). Carries the block's
    /// statements instead of a key/initializer; kept in the same list as static
    /// fields because the two run interleaved, in source order.
    static_block: ?[]*Node = null,
};

const ClassBodyParse = struct {
    ctor_params: [][]const u8 = &[_][]const u8{},
    ctor_rest: ?[]const u8 = null,
    ctor_body: []*Node = &[_]*Node{},
    // Distinguishes an explicit `constructor() {}` (empty body, but present —
    // must NOT auto-call super) from a class with no constructor at all (which
    // synthesizes the default `return Reflect.construct(Super, ...)`).
    has_ctor: bool = false,
    members: []ClassMember = &[_]ClassMember{},
    fields: []ClassField = &[_]ClassField{},
};

/// True when the token after `current` means `current` (a contextual keyword like
/// `static`/`get`/`set`) is being used as the member NAME rather than a modifier
/// (e.g. `static() {}`, `get = 1`, a bare `get;`).
fn nextTokenEndsName(p: *Parser) bool {
    const k = p.peekNext().kind;
    return k == .left_paren or k == .eq or k == .semicolon or k == .right_brace;
}

/// Parse `static { ... }` — the ClassStaticBlockBody statement list, with `{`
/// as the current token. It is its own function-like scope, so the body is
/// parsed the same way a function body is; the extra rules are that `await` is
/// reserved throughout (a nested function re-enables it, which
/// `parseFunctionBody` handles by saving the flag), and `arguments` and
/// `return` are Syntax Errors — the block has neither.
fn parseStaticBlockBody(p: *Parser) ?[]*Node {
    p.next_body_is_static_block = true;
    return parseFunctionBody(p);
}

/// Parse the body of a class (`{` already consumed). Consumes the closing `}`.
/// Handles `static`, `get`/`set` accessors, and computed `[expr]` keys.
fn parseClassMembers(p: *Parser) ?ClassBodyParse {
    var res = ClassBodyParse{};
    var members = std.ArrayList(ClassMember){};
    var fields = std.ArrayList(ClassField){};
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        if (p.match(.semicolon)) continue;

        var is_static = false;
        if (p.check(.identifier) and std.mem.eql(u8, p.current.value_str, "static") and !nextTokenEndsName(p)) {
            is_static = true;
            _ = p.advance();
        }
        // ES2022 static initialization block: `static { ... }`. Its body is a
        // statement list evaluated once at class-definition time with `this`
        // bound to the constructor, so it is kept alongside the static fields
        // (which it interleaves with) rather than as a member.
        if (is_static and p.check(.left_brace)) {
            const block = parseStaticBlockBody(p) orelse return null;
            fields.append(p.arena, .{ .is_static = true, .static_block = block }) catch {
                p.had_error = true;
                return null;
            };
            continue;
        }

        // Method [[SourceText]] excludes the `static` ClassElement prefix, so the
        // source span begins at the first token after `static` (the `async`/`*`/
        // `get`/`set` modifier or the method key itself).
        const member_start = p.current.start;

        // ES2015/2017 `*`/`async` method modifiers (after optional `static`).
        // `async` is contextual: only a modifier when a method-key follows on
        // the same line (else it is a method/field named `async`).
        var is_generator = false;
        var is_async = false;
        if (p.currentIsAsyncKw() and !p.peekNext().line_terminator_before and
            expr_mod.isMethodKeyStart(p.peekNext().kind))
        {
            is_async = true;
            _ = p.advance(); // consume `async`
        }
        if (p.match(.star)) is_generator = true;

        var accessor: AccessorKind = .none;
        if (p.check(.identifier) and !nextTokenEndsName(p)) {
            if (std.mem.eql(u8, p.current.value_str, "get")) {
                accessor = .get;
                _ = p.advance();
            } else if (std.mem.eql(u8, p.current.value_str, "set")) {
                accessor = .set;
                _ = p.advance();
            }
        }

        var computed_key: ?*Node = null;
        var name: []const u8 = "";
        if (p.check(.left_bracket)) {
            _ = p.advance();
            const key_expr = p.parseAssignmentExpr() orelse return null;
            _ = p.expect(.right_bracket) orelse return null;
            computed_key = key_expr;
        } else if (p.check(.number)) {
            // A NumericLiteral class-element name keys on its *value*: `get 0x10()`
            // and `get 16()` define the same accessor (and `1e2` is "100", not
            // "1e2"). The raw spelling would key a distinct, unreachable property.
            name = expr_mod.numericLiteralKey(p) orelse return null;
        } else if (p.check(.identifier) or p.check(.string)) {
            name = p.current.value_str;
            _ = p.advance();
        } else if (p.currentIsIdentifierName()) {
            // A reserved word (`export`, `in`, …) is a valid IdentifierName as a
            // member name — also the form produced by an escaped keyword like
            // `export`, which the lexer decodes to the keyword token.
            name = p.current.value_str;
            _ = p.advance();
        } else {
            // Unsupported member start (e.g. a generator `*`): skip one token so
            // the loop can't spin, matching the prior lenient behaviour.
            _ = p.advance();
            continue;
        }

        // Field vs method: a method is followed by a parameter list `(...)`.
        // Anything else (`= init`, `;`, `}`, or the next member) is a class
        // field. Accessors (`get`/`set`) are always methods.
        if (accessor == .none and !p.check(.left_paren)) {
            var init_expr: ?*Node = null;
            if (p.match(.eq)) {
                init_expr = p.parseAssignmentExpr() orelse return null;
            }
            _ = p.match(.semicolon); // optional ASI
            fields.append(p.arena, .{
                .is_static = is_static,
                .name = name,
                .computed_key = computed_key,
                .init = init_expr,
            }) catch return null;
            continue;
        }

        // A MethodDefinition takes UniqueFormalParameters (§15.4.1).
        p.require_unique_params = true;
        const mparams = p.parseFunctionParams() orelse return null;
        const prev_gen = p.in_generator_function;
        p.in_generator_function = is_generator;
        const mbody = p.parseFunctionBody() orelse {
            p.in_generator_function = prev_gen;
            return null;
        };
        p.in_generator_function = prev_gen;
        if (!parser_file.checkStrictDirectiveSimpleParams(p, mparams.non_simple, mbody)) return null;
        const member_end = p.prev_end;

        if (!is_static and accessor == .none and computed_key == null and std.mem.eql(u8, name, "constructor")) {
            res.ctor_params = mparams.params;
            res.ctor_rest = mparams.rest_param;
            res.ctor_body = mbody;
            res.has_ctor = true;
        } else {
            members.append(p.arena, .{
                .is_static = is_static,
                .is_generator = is_generator,
                .is_async = is_async,
                .accessor = accessor,
                .name = name,
                .computed_key = computed_key,
                .params = mparams.params,
                .param_defaults = mparams.param_defaults,
                .expected_argc = mparams.expected_argc,
                .rest_param = mparams.rest_param,
                .body = mbody,
                .src_start = member_start,
                .src_end = member_end,
            }) catch return null;
        }
    }
    _ = p.expect(.right_brace) orelse return null;
    res.members = members.items;
    res.fields = fields.items;
    return res;
}

/// Separator between a private name and its PrivateEnvironment id in a mangled
/// key ("#x\x01" ++ id). U+0001 cannot appear in source, so a mangled key can
/// never collide with a user-written property key; `privateDisplayName` strips
/// the suffix again for diagnostics.
pub const mangled_priv_sep: u8 = 0x01;

/// The user-facing spelling of a (possibly mangled) private key: "#x\x014" → "#x".
pub fn privateDisplayName(key: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, key, mangled_priv_sep) orelse return key;
    return key[0..i];
}

fn isPrivateName(name: []const u8) bool {
    return name.len > 0 and name[0] == '#';
}

/// Flag a desugared `<obj>.#x` assignment target as a private-element
/// *installation* site (PrivateFieldAdd / PrivateMethodOrAccessorAdd) so it
/// compiles to DEFINE_PRIVATE. Every other private write is a PrivateSet, which
/// requires the element to already exist. Passes non-private targets through.
fn markPrivateDefine(n: *Node, is_method: bool) *Node {
    if (n.kind == .member_expr and !n.data.member_expr.computed and
        n.data.member_expr.property.kind == .identifier and
        isPrivateName(n.data.member_expr.property.data.identifier))
    {
        n.data.member_expr.private_define = true;
        n.data.member_expr.private_method = is_method;
    } else if (n.kind == .member_expr and !is_method) {
        // A public field is DefineField: CreateDataPropertyOrThrow, not [[Set]].
        n.data.member_expr.define_data = true;
    }
    return n;
}

/// Rewrites the private names declared by one class body to that class's
/// mangled keys. Every `#x` still spelled raw at this point either belongs to
/// this class or to an enclosing one: a nested class is fully parsed (and
/// therefore already mangled) before the enclosing body's pass runs, so its own
/// `#x` reads no longer match and shadowing resolves innermost-first.
const PrivateRewriter = struct {
    raw: [][]const u8,
    mangled: [][]const u8,

    fn map(self: PrivateRewriter, name: []const u8) []const u8 {
        for (self.raw, self.mangled) |r, m| {
            if (std.mem.eql(u8, r, name)) return m;
        }
        return name;
    }

    fn walkOpt(self: PrivateRewriter, node: ?*Node) void {
        if (node) |n| self.walk(n);
    }

    /// Descends through every construct, including ordinary function bodies and
    /// nested class desugarings — a private name is in scope for the whole class
    /// body regardless of intervening function boundaries.
    fn walk(self: PrivateRewriter, node: *Node) void {
        switch (node.data) {
            .identifier => |name| node.data = .{ .identifier = self.map(name) },
            .unary_expr => |u| self.walk(u.operand),
            .binary_expr => |b| {
                // `#x in obj` keeps `#x` as an identifier (see parseBinaryRhs), so
                // the `.identifier` branch mangles it like `this.#x`. A genuine
                // string literal `"#x"` is left untouched, so `"#x" in obj` is a
                // plain string HasProperty (never matches a private element).
                self.walk(b.left);
                self.walk(b.right);
            },
            .logical_expr => |b| {
                self.walk(b.left);
                self.walk(b.right);
            },
            .assignment_expr => |a| {
                self.walk(a.target);
                self.walk(a.value);
            },
            .update_expr => |u| self.walk(u.operand),
            .conditional_expr => |c| {
                self.walk(c.test_);
                self.walk(c.consequent);
                self.walk(c.alternate);
            },
            .sequence_expr => |s| for (s.exprs) |e| self.walk(e),
            .spread_expr => |e| self.walk(e),
            .yield_expr => |e| self.walkOpt(e),
            .call_expr => |c| {
                self.walk(c.callee);
                for (c.args) |a| self.walk(a);
            },
            .new_expr => |n| {
                self.walk(n.callee);
                for (n.args) |a| self.walk(a);
            },
            // Both parts: a non-computed `obj.#x` keeps the private name in the
            // property identifier node.
            .member_expr => |m| {
                self.walk(m.object);
                self.walk(m.property);
            },
            .optional_chain => |e| self.walk(e),
            .function_expr => |f| {
                for (f.param_defaults) |d| self.walkOpt(d);
                for (f.body) |s| self.walk(s);
            },
            .function_decl => |f| {
                for (f.param_defaults) |d| self.walkOpt(d);
                for (f.body) |s| self.walk(s);
            },
            .object_literal => |o| for (o.properties) |pr| {
                self.walk(pr.value);
                self.walkOpt(pr.computed_key);
            },
            .array_literal => |a| for (a.elements) |e| self.walk(e),
            .program => |pr| for (pr.body) |s| self.walk(s),
            .expr_stmt => |e| self.walk(e),
            .block_stmt => |b| for (b.body) |s| self.walk(s),
            .var_decl => |v| self.walkOpt(v.init),
            .if_stmt => |i| {
                self.walk(i.test_);
                self.walk(i.consequent);
                self.walkOpt(i.alternate);
            },
            .while_stmt => |w| {
                self.walk(w.test_);
                self.walk(w.body);
            },
            .do_while_stmt => |w| {
                self.walk(w.body);
                self.walk(w.test_);
            },
            .with_stmt => |w| {
                self.walk(w.object);
                self.walk(w.body);
            },
            .for_stmt => |f| {
                self.walkOpt(f.init);
                self.walkOpt(f.test_);
                self.walkOpt(f.update);
                self.walk(f.body);
            },
            .return_stmt => |e| self.walkOpt(e),
            .throw_stmt => |e| self.walk(e),
            .try_stmt => |t| {
                self.walk(t.block);
                if (t.handler) |h| self.walk(h.body);
                self.walkOpt(t.finalizer);
            },
            .for_in_stmt => |f| {
                self.walk(f.left);
                self.walk(f.right);
                self.walk(f.body);
            },
            .switch_stmt => |s| {
                self.walk(s.discriminant);
                for (s.cases) |c| {
                    self.walkOpt(c.test_);
                    for (c.body) |st| self.walk(st);
                }
            },
            .labeled_stmt => |l| self.walk(l.body),
            else => {},
        }
    }
};

/// Give this class body's private elements a PrivateEnvironment-unique key, so
/// `o.#x` only resolves on instances branded by *this* class (spec
/// PrivateEnvironment / PrivateNameResolution). Without it two classes that both
/// declare `#x` share the key "#x" and each accepts the other's instances.
/// Returns false only on allocation failure.
fn manglePrivateNames(p: *Parser, parsed: *ClassBodyParse) bool {
    var raw = std.ArrayList([]const u8){};
    // Dedupe: an instance and a static element, or a `get #x`/`set #x` pair,
    // spell the same private name and must map to the same mangled key.
    for (parsed.fields) |f| {
        if (f.computed_key == null and isPrivateName(f.name)) {
            var seen = false;
            for (raw.items) |r| {
                if (std.mem.eql(u8, r, f.name)) seen = true;
            }
            if (!seen) raw.append(p.arena, f.name) catch return false;
        }
    }
    for (parsed.members) |m| {
        if (m.computed_key == null and isPrivateName(m.name)) {
            var seen = false;
            for (raw.items) |r| {
                if (std.mem.eql(u8, r, m.name)) seen = true;
            }
            if (!seen) raw.append(p.arena, m.name) catch return false;
        }
    }
    if (raw.items.len == 0) return true;

    const id = p.private_class_counter;
    p.private_class_counter += 1;
    var mangled = std.ArrayList([]const u8){};
    for (raw.items) |r| {
        const m = std.fmt.allocPrint(p.arena, "{s}{c}{d}", .{ r, mangled_priv_sep, id }) catch return false;
        mangled.append(p.arena, m) catch return false;
    }
    const rw = PrivateRewriter{ .raw = raw.items, .mangled = mangled.items };

    for (parsed.fields) |*f| {
        if (f.computed_key == null) f.name = rw.map(f.name);
        rw.walkOpt(f.computed_key);
        rw.walkOpt(f.init);
    }
    for (parsed.members) |*m| {
        if (m.computed_key == null) m.name = rw.map(m.name);
        rw.walkOpt(m.computed_key);
        for (m.param_defaults) |d| rw.walkOpt(d);
        for (m.body) |s| rw.walk(s);
    }
    for (parsed.ctor_body) |s| rw.walk(s);
    return true;
}

/// IsAnonymousFunctionDefinition(expr): the shapes whose `.name` comes from the
/// surrounding definition. Mirrors the compiler's check of the same name.
fn isAnonFnDef(node: *Node) bool {
    return switch (node.kind) {
        .function_expr => node.data.function_expr.name == null,
        .call_expr => node.data.call_expr.anon_class_iife,
        else => false,
    };
}

/// A class field's initializer, wrapped in `__nameFn__(init, "<name>")` when it
/// is an anonymous function definition — `class C { f = () => {} }` names the
/// arrow "f", which the plain `this.f = () => {}` the field desugars to would
/// not do. Computed keys are left alone: naming them would mean evaluating the
/// key expression a second time.
fn namedFieldInit(p: *Parser, f: ClassField, val: *Node) ?*Node {
    return namedFieldInitOf(p, f, val, val);
}

/// As `namedFieldInit`, but for the static-field shape where the initializer has
/// already been wrapped in `(function(){ return <init>; }).call(C)`: the
/// anonymity test looks at the original `check` node while the wrapper `val` is
/// what gets named.
fn namedFieldInitOf(p: *Parser, f: ClassField, val: *Node, check: *Node) ?*Node {
    if (f.computed_key != null or !isAnonFnDef(check)) return val;
    const s = p.current.start;
    const callee = nodeIdent(p, "__nameFn__") orelse return null;
    // A private field's `f.name` has been mangled (e.g. "#field\x010"); the
    // inferred function name must be the source-level private name ("#field").
    const key = p.makeNode(.string_literal, s, s, .{ .string_literal = privateDisplayName(f.name) }) orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, val) catch return null;
    args.append(p.arena, key) catch return null;
    return p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } });
}

/// Build an instance-field initializer statement: `this.<name> = <init>` (or
/// `this[<computed>] = <init>`), with `undefined` when there is no initializer.
/// A private name (`#x`) is emitted as a non-computed member, so it resolves to
/// the property key "#x" — matching how `obj.#x` reads are parsed.
fn makeInstanceFieldInit(p: *Parser, f: ClassField) ?*Node {
    const this_node = p.makeNode(.this_expr, p.current.start, p.current.start, .{ .this_expr = {} }) orelse return null;
    return makeFieldDefineOn(p, f, this_node);
}

/// Emit an instance-field initializer that installs the field on `target` using
/// CreateDataProperty semantics (`Object.defineProperty`) for a public field, or
/// PrivateFieldAdd (`target.#name = init`) for a private one. `target` is `this`
/// for a base class and `__superthis` for a derived class. A computed field's
/// key is read from its pre-evaluated hidden binding (`f.key_var`) so the key
/// object's @@toPrimitive is observed once, at class-definition time.
fn makeFieldDefineOn(p: *Parser, f: ClassField, target: *Node) ?*Node {
    const s = p.current.start;
    const raw = f.init orelse (p.makeNode(.undefined_literal, s, s, .{ .undefined_literal = {} }) orelse return null);
    const val = namedFieldInit(p, f, raw) orelse return null;

    // Private fields: `target.#name = init` (member assignment → PrivateFieldAdd).
    if (f.computed_key == null and f.name.len > 0 and f.name[0] == '#') {
        const lhs = markPrivateDefine(nodeMember(p, target, f.name) orelse return null, false);
        const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = val } }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
    }

    // Public fields: Object.defineProperty(target, key,
    //   { value: init, writable: true, enumerable: true, configurable: true }).
    const key_val = fieldKeyNode(p, f) orelse return null;
    var props = std.ArrayList(ast.ObjectProp){};
    props.append(p.arena, .{ .key = "value", .value = val }) catch return null;
    props.append(p.arena, .{ .key = "writable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    props.append(p.arena, .{ .key = "enumerable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    props.append(p.arena, .{ .key = "configurable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;

    const id_obj = nodeIdent(p, "Object") orelse return null;
    const callee = nodeMember(p, id_obj, "defineProperty") orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, target) catch return null;
    args.append(p.arena, key_val) catch return null;
    args.append(p.arena, desc) catch return null;
    const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
}

/// The key expression for a field's install: the pre-evaluated hidden binding
/// for a computed field, else a string literal of the field name.
fn fieldKeyNode(p: *Parser, f: ClassField) ?*Node {
    const s = p.current.start;
    if (f.key_var) |kv| return nodeIdent(p, kv);
    if (f.computed_key) |k| return k; // no hoisting slot assigned (fallback)
    return p.makeNode(.string_literal, s, s, .{ .string_literal = f.name });
}

/// Build a derived-class instance-field initializer targeting `__superthis`
/// (the object returned by `super()`), which is the `this` of a derived class
/// once the parent constructor has run. Unlike a base class — where fields are
/// prepended to the constructor body and assigned via `this.<f> = init` — a
/// derived class has no usable `this` until after `super()`, so the field must
/// be installed on `__superthis`.
///
/// Public fields use [[DefineOwnProperty]] (CreateDataProperty semantics:
/// `Object.defineProperty(__superthis, key, {value, writable, enumerable,
/// configurable})`), not [[Set]] — class fields define own data properties and
/// must not invoke inherited setters or be intercepted by an exotic [[Set]]
/// (e.g. a module namespace returned from the base ctor, where the define is the
/// operation that triggers deferred evaluation). Private fields keep the
/// member-assignment form (`__superthis.#name = init`), which is PrivateFieldAdd.
fn makeDerivedInstanceFieldInit(p: *Parser, f: ClassField) ?*Node {
    const superthis = nodeIdent(p, "__superthis") orelse return null;
    return makeFieldDefineOn(p, f, superthis);
}

/// Append derived-class instance-field initializers (skipping static fields) to
/// `list`. Returns false on allocation failure.
fn appendDerivedInstanceFields(p: *Parser, list: *std.ArrayList(*Node), fields: []const ClassField) bool {
    for (fields) |f| {
        if (f.is_static) continue;
        const st = makeDerivedInstanceFieldInit(p, f) orelse return false;
        list.append(p.arena, st) catch return false;
    }
    return true;
}

/// Build a static-field initializer statement: `ClassName.<name> = <init>`.
///
/// Per spec (ClassFieldDefinitionEvaluation / static field initializer), the
/// initializer is evaluated with `this` bound to the class constructor — so
/// `static f = this.name` must see the class, not the surrounding `this`. The
/// initializer is therefore wrapped in `(function(){ return <init>; }).call(C)`
/// rather than assigned directly. A bare `static f = 1` (no `this`) gets the
/// same wrapper; the result is identical.
fn makeStaticFieldInit(p: *Parser, class_name: []const u8, f: ClassField) ?*Node {
    const s = p.current.start;
    // ES2022 static initialization block: same `this`-is-the-class wrapper as a
    // static field, but the block's whole statement list is the body and there
    // is nothing to assign. `(function () { <body> }).call(ClassName);`
    if (f.static_block) |block| {
        const blk_fn = p.makeNode(.function_expr, s, s, .{ .function_expr = .{
            .name = null,
            .params = &[_][]const u8{},
            .body = block,
            .is_arrow = false,
        } }) orelse return null;
        const blk_call_member = nodeMember(p, blk_fn, "call") orelse return null;
        const blk_args = p.arena.alloc(*Node, 1) catch return null;
        blk_args[0] = nodeIdent(p, class_name) orelse return null;
        const blk_call = p.makeNode(.call_expr, s, s, .{
            .call_expr = .{ .callee = blk_call_member, .args = blk_args },
        }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = blk_call });
    }
    const raw_init = f.init orelse (p.makeNode(.undefined_literal, s, s, .{ .undefined_literal = {} }) orelse return null);

    // Wrap: (function () { return <init>; }).call(ClassName)
    const ret_stmt = p.makeNode(.return_stmt, s, s, .{ .return_stmt = raw_init }) orelse return null;
    const body = p.arena.alloc(*Node, 1) catch return null;
    body[0] = ret_stmt;
    const init_fn = p.makeNode(.function_expr, s, s, .{ .function_expr = .{
        .name = null,
        .params = &[_][]const u8{},
        .body = body,
        .is_arrow = false,
    } }) orelse return null;
    const call_member = nodeMember(p, init_fn, "call") orelse return null;
    const this_arg = nodeIdent(p, class_name) orelse return null;
    const call_args = p.arena.alloc(*Node, 1) catch return null;
    call_args[0] = this_arg;
    const call_val = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = call_member, .args = call_args } }) orelse return null;
    const val = namedFieldInitOf(p, f, call_val, raw_init) orelse return null;

    // Private static field: `ClassName.#name = init` (PrivateFieldAdd).
    if (f.computed_key == null and f.name.len > 0 and f.name[0] == '#') {
        const cls = nodeIdent(p, class_name) orelse return null;
        const lhs = markPrivateDefine(nodeMember(p, cls, f.name) orelse return null, false);
        const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = val } }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
    }

    // Public static field: CreateDataProperty via Object.defineProperty(ClassName,
    // key, { value, writable, enumerable, configurable }) with the pre-evaluated key.
    const key_val = fieldKeyNode(p, f) orelse return null;
    var props = std.ArrayList(ast.ObjectProp){};
    props.append(p.arena, .{ .key = "value", .value = val }) catch return null;
    props.append(p.arena, .{ .key = "writable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    props.append(p.arena, .{ .key = "enumerable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    props.append(p.arena, .{ .key = "configurable", .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null }) catch return null;
    const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;
    const id_obj = nodeIdent(p, "Object") orelse return null;
    const dp_callee = nodeMember(p, id_obj, "defineProperty") orelse return null;
    var dp_args = std.ArrayList(*Node){};
    dp_args.append(p.arena, nodeIdent(p, class_name) orelse return null) catch return null;
    dp_args.append(p.arena, key_val) catch return null;
    dp_args.append(p.arena, desc) catch return null;
    const dp_call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = dp_callee, .args = dp_args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = dp_call });
}

/// Prepend instance-field initializers to a base-class constructor body. Returns
/// the new body. Only used for base classes (no `extends`); for derived classes
/// `this` is not available until after `super()` so field init is skipped.
fn prependInstanceFields(p: *Parser, ctor_body: []*Node, fields: []const ClassField) ?[]*Node {
    var any = false;
    for (fields) |f| {
        if (!f.is_static) any = true;
    }
    if (!any) return ctor_body;
    var stmts = std.ArrayList(*Node){};
    for (fields) |f| {
        if (f.is_static) continue;
        const st = makeInstanceFieldInit(p, f) orelse return null;
        stmts.append(p.arena, st) catch return null;
    }
    for (ctor_body) |st| stmts.append(p.arena, st) catch return null;
    return stmts.items;
}

fn nodeIdent(p: *Parser, name: []const u8) ?*Node {
    const s = p.current.start;
    return p.makeNode(.identifier, s, s, .{ .identifier = name });
}

fn nodeMember(p: *Parser, obj: *Node, prop: []const u8) ?*Node {
    const s = p.current.start;
    const pid = nodeIdent(p, prop) orelse return null;
    return p.makeNode(.member_expr, s, s, .{ .member_expr = .{ .object = obj, .property = pid, .computed = false } });
}

/// `Object.defineProperty(<Cls>.prototype, "constructor",
///      { value: <Cls>, writable: true, enumerable: false, configurable: true })`
///
/// A plain `Cls.prototype.constructor = Cls` is enough for a BASE class: the
/// function's auto-created prototype already carries a non-enumerable
/// `constructor`, and assigning to an existing data property keeps its
/// attributes. A DERIVED class replaces `prototype` with a fresh
/// `Object.create(Super.prototype)` that has no such slot, so the same
/// assignment would create an enumerable one and leak `constructor` into
/// for-in over every instance. Defining it explicitly makes both paths agree.
fn makeCtorBackLink(p: *Parser, class_name: []const u8) ?*Node {
    const s = p.current.start;
    const id_class = nodeIdent(p, class_name) orelse return null;
    const target = nodeMember(p, id_class, "prototype") orelse return null;
    const key_val = p.makeNode(.string_literal, s, s, .{ .string_literal = "constructor" }) orelse return null;

    var props = std.ArrayList(ast.ObjectProp){};
    props.append(p.arena, .{
        .key = "value",
        .value = nodeIdent(p, class_name) orelse return null,
    }) catch return null;
    props.append(p.arena, .{
        .key = "writable",
        .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null,
    }) catch return null;
    props.append(p.arena, .{
        .key = "enumerable",
        .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = false }) orelse return null,
    }) catch return null;
    props.append(p.arena, .{
        .key = "configurable",
        .value = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null,
    }) catch return null;
    const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;

    const id_obj = nodeIdent(p, "Object") orelse return null;
    const callee = nodeMember(p, id_obj, "defineProperty") orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, target) catch return null;
    args.append(p.arena, key_val) catch return null;
    args.append(p.arena, desc) catch return null;
    const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
}

/// Desugar one class member into a single statement (a property assignment for
/// methods, or `Object.defineProperty(target, key, { get|set, configurable,
/// enumerable })` for accessors). `target` is the constructor for static members
/// and `ClassName.prototype` otherwise.
fn emitClassMember(p: *Parser, class_name: []const u8, super_name: ?[]const u8, m: ClassMember) ?*Node {
    const s = p.current.start;

    // Instance methods of a derived class may use `super.foo()`; bind
    // `super = Super.prototype` at the top of the body (static members don't).
    var body = m.body;
    if (super_name) |sname| {
        if (!m.is_static) {
            const sup_cls = nodeIdent(p, sname) orelse return null;
            const sup_proto_raw = nodeMember(p, sup_cls, "prototype") orelse return null;
            const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            const sup_proto = nullHeritageGuard(p, sname, sup_proto_raw, sup_null, s) orelse return null;
            const sup_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "super", .init = sup_proto } }) orelse return null;
            // Bindings used by `super.PROP = V` desugar (rewriteSuperPropAssign):
            // `__sproto__` is the parent prototype (Set base) and `__superthis`
            // the Receiver — here `this`, the method's receiver.
            const sup_cls2 = nodeIdent(p, sname) orelse return null;
            const sup_proto2_raw = nodeMember(p, sup_cls2, "prototype") orelse return null;
            const sup_null2 = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            const sup_proto2 = nullHeritageGuard(p, sname, sup_proto2_raw, sup_null2, s) orelse return null;
            const sproto_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__sproto__", .init = sup_proto2 } }) orelse return null;
            const this_node = p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return null;
            const sthis_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__superthis", .init = this_node } }) orelse return null;
            var wb = std.ArrayList(*Node){};
            wb.append(p.arena, sup_decl) catch return null;
            wb.append(p.arena, sproto_decl) catch return null;
            wb.append(p.arena, sthis_decl) catch return null;
            for (m.body) |st| wb.append(p.arena, st) catch return null;
            body = wb.items;
        }
    }

    // The method function's `.name` property is the property key (SetFunctionName
    // in MethodDefinitionEvaluation). Set it directly and mark is_method so the
    // name is NOT self-bound inside the body (unlike a named function expression),
    // and so the descriptor object-literal's NamedEvaluation ({ value: fn }) does
    // not misname it "value". Computed keys are named at runtime (left null here).
    // Accessors get a "get "/"set " prefix, applied in the accessor branch below.
    // A private method's `.name` is its source spelling ("#m"), not the mangled
    // PrivateEnvironment key it is stored under.
    const key_name = privateDisplayName(m.name);
    const method_name: ?[]const u8 = if (m.computed_key != null) null else switch (m.accessor) {
        .none => key_name,
        .get => std.fmt.allocPrint(p.arena, "get {s}", .{key_name}) catch return null,
        .set => std.fmt.allocPrint(p.arena, "set {s}", .{key_name}) catch return null,
    };
    const fn_expr = p.makeNode(.function_expr, s, s, .{ .function_expr = .{
        .name = method_name,
        .params = m.params,
        .param_defaults = m.param_defaults,
        .expected_argc = m.expected_argc,
        .rest_param = m.rest_param,
        .body = body,
        .is_arrow = false,
        .is_method = true,
        .is_generator = m.is_generator,
        .is_async = m.is_async,
        .source_text = p.sourceSlice(m.src_start, m.src_end),
    } }) orelse return null;

    const target = if (m.is_static)
        (nodeIdent(p, class_name) orelse return null)
    else
        (nodeMember(p, nodeIdent(p, class_name) orelse return null, "prototype") orelse return null);

    if (m.accessor == .none) {
        // Class methods are non-enumerable own data properties (writable +
        // configurable), per MethodDefinitionEvaluation → CreateMethodProperty
        // (enumerable:false). A plain `target.name = fn` assignment creates an
        // *enumerable* property, failing every propertyHelper enumerability
        // check. Private names (`#x`) keep the member-assignment form
        // (PrivateMethodAdd — not a real enumerable-checkable property).
        if (m.computed_key == null and m.name.len > 0 and m.name[0] == '#') {
            const lhs = markPrivateDefine(nodeMember(p, target, m.name) orelse return null, true);
            const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = fn_expr } }) orelse return null;
            return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
        }
        const key_val = if (m.computed_key) |k| k else (p.makeNode(.string_literal, s, s, .{ .string_literal = m.name }) orelse return null);
        const t_val = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null;
        const f_val = p.makeNode(.bool_literal, s, s, .{ .bool_literal = false }) orelse return null;
        var props = std.ArrayList(ast.ObjectProp){};
        props.append(p.arena, .{ .key = "value", .value = fn_expr }) catch return null;
        props.append(p.arena, .{ .key = "writable", .value = t_val }) catch return null;
        props.append(p.arena, .{ .key = "enumerable", .value = f_val }) catch return null;
        props.append(p.arena, .{ .key = "configurable", .value = t_val }) catch return null;
        const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;
        const callee = defineMethodCallee(p, m.computed_key != null) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(p.arena, target) catch return null;
        args.append(p.arena, key_val) catch return null;
        args.append(p.arena, desc) catch return null;
        const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
    }

    // Accessor: Object.defineProperty(target, key, { get|set: fn, configurable: true, enumerable: false })
    const key_val = if (m.computed_key) |k| k else (p.makeNode(.string_literal, s, s, .{ .string_literal = m.name }) orelse return null);
    const t_val = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null;
    const f_val = p.makeNode(.bool_literal, s, s, .{ .bool_literal = false }) orelse return null;
    var props = std.ArrayList(ast.ObjectProp){};
    props.append(p.arena, .{ .key = if (m.accessor == .get) "get" else "set", .value = fn_expr }) catch return null;
    props.append(p.arena, .{ .key = "configurable", .value = t_val }) catch return null;
    props.append(p.arena, .{ .key = "enumerable", .value = f_val }) catch return null;
    const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;

    const callee = defineMethodCallee(p, m.computed_key != null) orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, target) catch return null;
    args.append(p.arena, key_val) catch return null;
    args.append(p.arena, desc) catch return null;
    const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
}

/// Callee for the `Object.defineProperty(target, key, desc)` a class method
/// desugars to. A computed key routes through `__defineNamedMethod__` instead:
/// the method's `.name` is its property key, which is only known once the key
/// expression has run, and that helper applies SetFunctionName before defining.
fn defineMethodCallee(p: *Parser, computed: bool) ?*Node {
    if (computed) return nodeIdent(p, "__defineNamedMethod__");
    const id_obj = nodeIdent(p, "Object") orelse return null;
    return nodeMember(p, id_obj, "defineProperty");
}

pub fn parseClassDeclStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // class
    const name_tok = p.expect(.identifier) orelse return null;
    const class_name = name_tok.value_str;

    const heritage = parseHeritage(p) orelse return null;
    _ = p.expect(.left_brace) orelse return null;
    var parsed = parseClassMembers(p) orelse return null;
    if (!manglePrivateNames(p, &parsed)) return null;

    const out = emitClassStatements(p, .{
        .class_name = class_name,
        .ctor_fn_name = class_name,
    }, heritage, parsed, start) orelse return null;

    if (out.items.len == 1) return out.items[0];
    // Transparent container: the `let <ClassName>` binding (and helpers) belong
    // to the enclosing scope, not a fresh block scope, so a following
    // `class B extends A` can resolve `A`.
    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = out.items, .lexical_scope = false },
    });
}

/// `<super> === null ? <null_alt> : <super_expr>` — a class may extend `null`,
/// in which case the prototype parent is `null` and the constructor's
/// [[Prototype]] is %Function.prototype%, not the heritage value. The desugar
/// is source-level, so the branch is emitted as a conditional expression rather
/// than resolved at parse time (`extends (cond ? null : Base)` is legal).
fn nullHeritageGuard(p: *Parser, super_name: []const u8, super_expr: *Node, null_alt: *Node, at: u32) ?*Node {
    const lhs = p.makeNode(.identifier, at, at, .{ .identifier = super_name }) orelse return null;
    const rhs = p.makeNode(.null_literal, at, at, .{ .null_literal = {} }) orelse return null;
    const test_ = p.makeNode(.binary_expr, at, at, .{
        .binary_expr = .{ .op = .strict_eq, .left = lhs, .right = rhs },
    }) orelse return null;
    return p.makeNode(.conditional_expr, at, at, .{
        .conditional_expr = .{ .test_ = test_, .consequent = null_alt, .alternate = super_expr },
    });
}

/// The parsed `extends` clause. A non-identifier heritage expression (e.g.
/// `extends fn(await x)`) is hoisted into a `var __super__ = <expr>;` emitted
/// before the class body, so everything downstream can refer to it by name.
const Heritage = struct {
    super_name: ?[]const u8 = null,
    expr: ?*Node = null,
};

fn parseHeritage(p: *Parser) ?Heritage {
    if (!p.match(.kw_extends)) return Heritage{};
    const h = p.parseCallMemberExpr() orelse return null;
    // Always snapshot into a fresh binding, even for a bare identifier: the
    // ClassHeritage is evaluated once at class-definition time, but `super()`
    // and the prototype wiring below read the name later. `chain = class
    // extends chain {}` would otherwise make the class its own superclass
    // (infinite `super()` recursion), and two classes in one scope would share
    // a single `__super__`.
    const name = std.fmt.allocPrint(p.arena, "__super_{d}__", .{p.param_destruct_counter}) catch {
        p.had_error = true;
        return null;
    };
    p.param_destruct_counter += 1;
    return Heritage{ .super_name = name, .expr = h };
}

/// How a class's constructor is named and bound. The declaration form
/// (`class C {}`) introduces a `let C` in the enclosing scope; the expression
/// form (`x = class {}`) wraps the same statements in an IIFE, where the binding
/// name is an internal detail and the constructor carries the NamedEvaluation
/// name (`""` for a genuinely anonymous class).
const ClassForm = struct {
    /// Identifier the desugared statements refer to the constructor by.
    class_name: []const u8,
    /// `.name` of the constructor function object (SetFunctionName).
    ctor_fn_name: ?[]const u8,
};

/// Emit the statements a class desugars to: the constructor binding, the
/// static/prototype chain wiring, the `constructor` back-link, methods and
/// static fields. Shared by `parseClassDeclStmt` and `parseClassExpr` — the two
/// forms differ only in `form` and in what they wrap the result in. Keeping one
/// implementation matters: the expression form previously carried a stale copy
/// that scoped `__superthis` inside the `super()` helper (so every derived class
/// *expression* with an explicit constructor threw a ReferenceError) and dropped
/// constructor rest parameters, `__sproto__`, and derived instance fields.
fn emitClassStatements(
    p: *Parser,
    form: ClassForm,
    heritage: Heritage,
    parsed: ClassBodyParse,
    start: u32,
) ?std.ArrayList(*Node) {
    const class_name = form.class_name;
    const super_name = heritage.super_name;
    const heritage_expr = heritage.expr;
    const ctor_params: [][]const u8 = parsed.ctor_params;
    const ctor_rest: ?[]const u8 = parsed.ctor_rest;
    var ctor_body: []*Node = parsed.ctor_body;
    const members = parsed.members;
    const fields = parsed.fields;

    // Pre-evaluate computed field NAMES once, at class-definition time, in source
    // order (ClassElementName evaluation). Each computed field's key is stored in
    // a hidden `var` the field initializers read, so a key object's @@toPrimitive
    // is observed exactly once and any abrupt completion (ReferenceError, a
    // throwing toString) surfaces at the class definition, not per instance.
    // Collected now, before the field-install desugar below (which runs while
    // building the constructor body) references `key_var`.
    var key_evals = std.ArrayList(*Node){};
    for (parsed.fields) |*f| {
        const k = f.computed_key orelse continue;
        const kv = std.fmt.allocPrint(p.arena, "__ck_{d}__", .{p.param_destruct_counter}) catch return null;
        p.param_destruct_counter += 1;
        f.key_var = kv;
        const helper = nodeIdent(p, "__toPropertyKey__") orelse return null;
        var ck_args = std.ArrayList(*Node){};
        ck_args.append(p.arena, k) catch return null;
        const call = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = helper, .args = ck_args.items } }) orelse return null;
        const decl = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = .var_, .name = kv, .init = call } }) orelse return null;
        key_evals.append(p.arena, decl) catch return null;
    }

    if (!parsed.has_ctor) {
        if (super_name) |sname| {
            // Derived default constructor: `return Reflect.construct(Super,
            // arguments, ClassName)`. Constructs the parent (incl. built-in
            // exotics like TypedArray) with NewTarget = the subclass, so the
            // result carries the parent's internal slots AND the subclass
            // prototype. The [[Construct]] path adopts the object return.
            const id_reflect = p.makeNode(.identifier, start, start, .{ .identifier = "Reflect" }) orelse return null;
            const id_construct = p.makeNode(.identifier, start, start, .{ .identifier = "construct" }) orelse return null;
            const callee = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_reflect, .property = id_construct, .computed = false },
            }) orelse return null;
            const id_super_p = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const id_args = p.makeNode(.identifier, start, start, .{ .identifier = "arguments" }) orelse return null;
            const id_nt = makeNewTargetNode(p, start, class_name) orelse return null;
            var rc_args = std.ArrayList(*Node){};
            rc_args.append(p.arena, id_super_p) catch return null;
            rc_args.append(p.arena, id_args) catch return null;
            rc_args.append(p.arena, id_nt) catch return null;
            const rc_call = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee, .args = rc_args.items },
            }) orelse return null;
            var has_instance_field = false;
            for (fields) |f| {
                if (!f.is_static) has_instance_field = true;
            }
            var body = std.ArrayList(*Node){};
            if (has_instance_field) {
                // Derived class with instance fields: capture the parent result in
                // `__superthis`, install the fields on it (DefineOwnProperty), and
                // let the constructor wrapper below emit `return __superthis;`.
                const id_st = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
                const assign = p.makeNode(.assignment_expr, start, start, .{
                    .assignment_expr = .{ .op = .assign, .target = id_st, .value = rc_call },
                }) orelse return null;
                const assign_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign }) orelse return null;
                body.append(p.arena, assign_stmt) catch return null;
                if (!appendDerivedInstanceFields(p, &body, fields)) return null;
            } else {
                const ret_stmt = p.makeNode(.return_stmt, start, start, .{ .return_stmt = rc_call }) orelse return null;
                body.append(p.arena, ret_stmt) catch return null;
            }
            ctor_body = body.items;
        } else {
            ctor_body = &[_]*Node{};
        }
    }

    var out = std.ArrayList(*Node){};
    if (heritage_expr) |he| {
        const hv = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = super_name.?, .init = he },
        }) orelse return null;
        out.append(p.arena, hv) catch return null;
    }

    var ctor_body_effective = ctor_body;
    if (super_name) |sname| {
        // Explicit derived constructor. Bind `super` to a helper that performs a
        // real parent [[Construct]] (so built-in exotics like TypedArray work) and
        // captures the result in `__superthis`; the ctor returns `__superthis` so
        // [[Construct]] adopts the proper instance. Desugar:
        //   var __superthis;
        //   var super = function () {
        //     __superthis = Reflect.construct(Super, arguments, ClassName);
        //     return __superthis;
        //   };
        //   <original body>
        //   return __superthis;
        var ctor_stmts = std.ArrayList(*Node){};
        // var __superthis;
        const st_decl = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = "__superthis", .init = null },
        }) orelse return null;
        ctor_stmts.append(p.arena, st_decl) catch return null;
        // `var __sproto__ = Super.prototype;` — the Set base for `super.PROP = V`
        // inside the constructor (rewriteSuperPropAssign). The Receiver is
        // `__superthis`, the object returned by the super() call above.
        {
            const sp_cls = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const sp_proto_raw = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = sp_cls, .property = (p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null), .computed = false },
            }) orelse return null;
            const sp_null = p.makeNode(.null_literal, start, start, .{ .null_literal = {} }) orelse return null;
            const sp_proto = nullHeritageGuard(p, sname, sp_proto_raw, sp_null, start) orelse return null;
            const sproto_decl = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "__sproto__", .init = sp_proto },
            }) orelse return null;
            ctor_stmts.append(p.arena, sproto_decl) catch return null;
        }
        // Reflect.construct(Super, arguments, ClassName)
        const id_reflect = p.makeNode(.identifier, start, start, .{ .identifier = "Reflect" }) orelse return null;
        const id_construct = p.makeNode(.identifier, start, start, .{ .identifier = "construct" }) orelse return null;
        const rc_callee = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_reflect, .property = id_construct, .computed = false },
        }) orelse return null;
        const id_super_p = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
        const id_args = p.makeNode(.identifier, start, start, .{ .identifier = "arguments" }) orelse return null;
        const id_nt = makeNewTargetNode(p, start, class_name) orelse return null;
        var rc_args = std.ArrayList(*Node){};
        rc_args.append(p.arena, id_super_p) catch return null;
        rc_args.append(p.arena, id_args) catch return null;
        rc_args.append(p.arena, id_nt) catch return null;
        const rc_call = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = rc_callee, .args = rc_args.items },
        }) orelse return null;
        // __superthis = <rc_call>
        const id_st_t = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
        const assign = p.makeNode(.assignment_expr, start, start, .{
            .assignment_expr = .{ .op = .assign, .target = id_st_t, .value = rc_call },
        }) orelse return null;
        const assign_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign }) orelse return null;
        const id_st_r = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
        const helper_ret = p.makeNode(.return_stmt, start, start, .{ .return_stmt = id_st_r }) orelse return null;
        var helper_body = std.ArrayList(*Node){};
        // Double super() is a ReferenceError: BindThisValue throws when
        // [[ThisBindingStatus]] is already "initialized" (§9.1.1.3.1). Once the
        // first super() ran, `__superthis` holds the (object) instance, so guard:
        //   if (__superthis !== undefined)
        //     throw new ReferenceError("Super constructor may only be called once");
        {
            const g_lhs = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
            const g_rhs = p.makeNode(.identifier, start, start, .{ .identifier = "undefined" }) orelse return null;
            const g_test = p.makeNode(.binary_expr, start, start, .{
                .binary_expr = .{ .op = .strict_neq, .left = g_lhs, .right = g_rhs },
            }) orelse return null;
            const g_re = p.makeNode(.identifier, start, start, .{ .identifier = "ReferenceError" }) orelse return null;
            const g_msg = p.makeNode(.string_literal, start, start, .{
                .string_literal = "Super constructor may only be called once",
            }) orelse return null;
            var g_args = std.ArrayList(*Node){};
            g_args.append(p.arena, g_msg) catch return null;
            const g_new = p.makeNode(.new_expr, start, start, .{
                .new_expr = .{ .callee = g_re, .args = g_args.items },
            }) orelse return null;
            const g_throw = p.makeNode(.throw_stmt, start, start, .{ .throw_stmt = g_new }) orelse return null;
            const g_if = p.makeNode(.if_stmt, start, start, .{
                .if_stmt = .{ .test_ = g_test, .consequent = g_throw, .alternate = null },
            }) orelse return null;
            helper_body.append(p.arena, g_if) catch return null;
        }
        helper_body.append(p.arena, assign_stmt) catch return null;
        // Install instance fields on `__superthis` right after the parent ctor
        // returns — the spec point where a derived class initializes its fields.
        if (!appendDerivedInstanceFields(p, &helper_body, fields)) return null;
        helper_body.append(p.arena, helper_ret) catch return null;
        const helper_fn = p.makeNode(.function_expr, start, start, .{
            .function_expr = .{
                .name = null,
                .params = &[_][]const u8{},
                .param_defaults = &[_]?*Node{},
                .rest_param = null,
                .body = helper_body.items,
                .is_arrow = false,
                .is_strict = false,
                .requires_super = false,
            },
        }) orelse return null;
        const super_decl = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = "super", .init = helper_fn },
        }) orelse return null;
        ctor_stmts.append(p.arena, super_decl) catch return null;
        // Bind `this` to the super-constructed instance (`__superthis`).
        for (ctor_body) |st| rewriteThisToSuperThis(st);
        // Only a *written* constructor can carry a return-override; the default
        // derived body synthesized above already returns the parent's result.
        if (parsed.has_ctor) for (ctor_body) |st| rewriteDerivedReturns(p, st);
        for (ctor_body) |st| ctor_stmts.append(p.arena, st) catch return null;
        // `this` TDZ: a derived constructor that returns without having called
        // super() leaves `__superthis` unassigned (undefined). Reading `this`
        // (the implicit `return this`) must throw a ReferenceError. Emit:
        //   if (__superthis === undefined)
        //     throw new ReferenceError("must call super constructor ...");
        {
            const guard_lhs = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
            const guard_rhs = p.makeNode(.identifier, start, start, .{ .identifier = "undefined" }) orelse return null;
            const guard_test = p.makeNode(.binary_expr, start, start, .{
                .binary_expr = .{ .op = .strict_eq, .left = guard_lhs, .right = guard_rhs },
            }) orelse return null;
            const id_re = p.makeNode(.identifier, start, start, .{ .identifier = "ReferenceError" }) orelse return null;
            const re_msg = p.makeNode(.string_literal, start, start, .{
                .string_literal = "must call super constructor before accessing 'this'",
            }) orelse return null;
            var re_args = std.ArrayList(*Node){};
            re_args.append(p.arena, re_msg) catch return null;
            const re_new = p.makeNode(.new_expr, start, start, .{
                .new_expr = .{ .callee = id_re, .args = re_args.items },
            }) orelse return null;
            const throw_st = p.makeNode(.throw_stmt, start, start, .{ .throw_stmt = re_new }) orelse return null;
            const guard_if = p.makeNode(.if_stmt, start, start, .{
                .if_stmt = .{ .test_ = guard_test, .consequent = throw_st, .alternate = null },
            }) orelse return null;
            ctor_stmts.append(p.arena, guard_if) catch return null;
        }
        // return __superthis;
        const id_st_final = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
        const final_ret = p.makeNode(.return_stmt, start, start, .{ .return_stmt = id_st_final }) orelse return null;
        ctor_stmts.append(p.arena, final_ret) catch return null;
        ctor_body_effective = ctor_stmts.items;
    } else {
        // Base class: instance fields initialize at the start of the constructor.
        ctor_body_effective = prependInstanceFields(p, ctor_body_effective, fields) orelse return null;
    }

    // var ClassName = function ClassName(...) { ... }
    const ctor_fn = p.makeNode(.function_expr, start, p.current.start, .{
        .function_expr = .{
            .name = form.ctor_fn_name,
            .params = ctor_params,
            .param_defaults = &[_]?*Node{},
            .rest_param = ctor_rest,
            .body = ctor_body_effective,
            .is_arrow = false,
            .is_strict = parser_file.hasUseStrict(ctor_body_effective),
            .requires_super = super_name != null,
            .source_text = p.sourceSlice(start, p.prev_end),
        },
    }) orelse return null;
    const ctor_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = .let, .name = class_name, .init = ctor_fn },
    }) orelse return null;
    out.append(p.arena, ctor_decl) catch return null;

    // Emit the pre-evaluated computed-key bindings now: after the constructor is
    // bound (so a key may reference the class name) but before static field value
    // initializers and any `new ClassName()`, so every ClassElementName is
    // evaluated exactly once, in source order, at class-definition time.
    for (key_evals.items) |kd| out.append(p.arena, kd) catch return null;

    if (super_name) |sname| {
        // Object.setPrototypeOf(ClassName, Super) — static inheritance
        // (BYTES_PER_ELEMENT, from, of, @@species flow to the subclass ctor).
        {
            const id_o = p.makeNode(.identifier, start, start, .{ .identifier = "Object" }) orelse return null;
            const id_sp = p.makeNode(.identifier, start, start, .{ .identifier = "setPrototypeOf" }) orelse return null;
            const callee_sp = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_o, .property = id_sp, .computed = false },
            }) orelse return null;
            const a_cls = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const a_sup_raw = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const fn_id = p.makeNode(.identifier, start, start, .{ .identifier = "Function" }) orelse return null;
            const fn_proto_id = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const fn_proto = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = fn_id, .property = fn_proto_id, .computed = false },
            }) orelse return null;
            const a_sup = nullHeritageGuard(p, sname, a_sup_raw, fn_proto, start) orelse return null;
            var sp_args = std.ArrayList(*Node){};
            sp_args.append(p.arena, a_cls) catch return null;
            sp_args.append(p.arena, a_sup) catch return null;
            const sp_call = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee_sp, .args = sp_args.items },
            }) orelse return null;
            const sp_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = sp_call }) orelse return null;
            out.append(p.arena, sp_stmt) catch return null;
        }
        // ClassName.prototype = Object.create(Super.prototype)
        const id_class = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const id_proto = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const lhs_proto = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_class, .property = id_proto, .computed = false },
        }) orelse return null;

        const id_obj = p.makeNode(.identifier, start, start, .{ .identifier = "Object" }) orelse return null;
        const id_create = p.makeNode(.identifier, start, start, .{ .identifier = "create" }) orelse return null;
        const callee_create = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_obj, .property = id_create, .computed = false },
        }) orelse return null;

        const id_super = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
        const id_super_proto = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const super_proto = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_super, .property = id_super_proto, .computed = false },
        }) orelse return null;

        const null_proto = p.makeNode(.null_literal, start, start, .{ .null_literal = {} }) orelse return null;
        const create_arg = nullHeritageGuard(p, sname, super_proto, null_proto, start) orelse return null;
        var args_create = std.ArrayList(*Node){};
        args_create.append(p.arena, create_arg) catch return null;
        const rhs_create = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = callee_create, .args = args_create.items },
        }) orelse return null;

        const assign_proto = p.makeNode(.assignment_expr, start, start, .{
            .assignment_expr = .{ .op = .assign, .target = lhs_proto, .value = rhs_create },
        }) orelse return null;
        const stmt_proto = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_proto }) orelse return null;
        out.append(p.arena, stmt_proto) catch return null;
    }

    // Constructor back-link, defined non-enumerable (see makeCtorBackLink).
    const stmt_ctor = makeCtorBackLink(p, class_name) orelse return null;
    out.append(p.arena, stmt_ctor) catch return null;

    // prototype + static methods/accessors
    for (members) |m| {
        const stmt = emitClassMember(p, class_name, super_name, m) orelse return null;
        out.append(p.arena, stmt) catch return null;
    }

    // static fields: `ClassName.<name> = <init>` after the class is defined.
    for (fields) |f| {
        if (!f.is_static) continue;
        const stmt = makeStaticFieldInit(p, class_name, f) orelse return null;
        out.append(p.arena, stmt) catch return null;
    }

    return out;
}

/// Class expression (named or anonymous): `class [Name] [extends Super] { ... }`
/// For anonymous classes, uses a synthetic __AnonClass name internally.
/// Wraps the class definition in an IIFE that returns the constructor.
pub fn parseClassExpr(p: *Parser) ?*Node {
    const start = p.current.start;
    const synthetic_name = "__AnonClassExpr";

    // Consume 'class' first, THEN check for an identifier name.
    // p.current starts at the 'class' keyword token.
    _ = p.advance(); // consume 'class'

    // After consuming 'class', check if next token is an identifier (class name).
    // Named:   `class MyName [extends] ...` (identifier always means named class)
    // Anon:    `class [extends] ...` or `class { ... }`
    const has_name = p.check(.identifier);
    const class_name = if (has_name) blk: {
        const name = p.current.value_str;
        _ = p.advance(); // consume the class name identifier
        break :blk name;
    } else synthetic_name;

    // Capture the NamedEvaluation hint (`let x = class{}` / `export default
    // class{}`) NOW, before parsing the heritage/body — otherwise a nested
    // anonymous class/function expression inside a method or field initializer
    // would consume it first and steal this class's name.
    const anon_name_hint: ?[]const u8 = blk: {
        const h = p.export_default_name_hint;
        p.export_default_name_hint = null;
        break :blk h;
    };

    const heritage = parseHeritage(p) orelse return null;
    _ = p.expect(.left_brace) orelse return null;
    var parsed = parseClassMembers(p) orelse return null;
    if (!manglePrivateNames(p, &parsed)) return null;

    // Named class → ctor name = class_name; anonymous with a NamedEvaluation
    // hint (`let x = class{}`, `export default`) → that name; else the empty
    // string. The explicit "" matters: the ctor is bound as `<synthetic_name> =
    // <ctor fn>` inside the IIFE, and without it the compiler's NamedEvaluation
    // would leak that synthetic binding name onto a genuinely anonymous class.
    var out = emitClassStatements(p, .{
        .class_name = class_name,
        .ctor_fn_name = if (has_name) class_name else (anon_name_hint orelse ""),
    }, heritage, parsed, start) orelse return null;

    // The IIFE evaluates to the constructor.
    const ret_id = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    const ret_stmt = p.makeNode(.return_stmt, start, start, .{ .return_stmt = ret_id }) orelse return null;
    out.append(p.arena, ret_stmt) catch return null;

    const fn_expr = p.makeNode(.function_expr, start, p.current.start, .{
        .function_expr = .{ .name = null, .params = &[_][]const u8{}, .body = out.items, .is_arrow = false },
    }) orelse return null;
    return p.makeNode(.call_expr, start, p.current.start, .{
        .call_expr = .{
            .callee = fn_expr,
            .args = &[_]*Node{},
            .anon_class_iife = !has_name and anon_name_hint == null,
        },
    });
}

pub fn parseFunctionParams(p: *Parser) ?parser_file.ParamParse {
    // Formal parameters belong to the function being parsed, not to an enclosing
    // class static initialization block, so a default like `x = await` or
    // `{y = arguments}` is fine there.
    const sb_saved = p.leaveStaticBlock();
    defer p.restoreStaticBlock(sb_saved);
    _ = p.expect(.left_paren) orelse return null;
    var params = std.ArrayList([]const u8){};
    var defaults = std.ArrayList(?*Node){};
    // Destructuring-param decls accumulated locally, then published to
    // p.pending_param_prelude at the end so default exprs containing nested
    // functions/arrows (which reuse p.arrow_prelude) can't clobber them.
    var param_prelude = std.ArrayList(*Node){};
    var saw_rest = false;
    var saw_destructuring = false;
    var rest_param: ?[]const u8 = null;
    while (!p.check(.right_paren) and !p.check(.eof) and !p.had_error) {
        var is_rest = false;
        if (p.match(.ellipsis)) is_rest = true;
        // Destructuring parameter: `[...]` / `{...}` binding pattern (with an
        // optional `= default`). Desugared to a synthetic `__param_N` name plus
        // `let` decls prepended to the body, mirroring the arrow-param path.
        if (!is_rest and (p.check(.left_bracket) or p.check(.left_brace))) {
            saw_destructuring = true;
            const pat = p.parseAssignmentExpr() orelse return null;
            const tmp_name = std.fmt.allocPrint(p.arena, "__param_{d}", .{p.param_destruct_counter}) catch {
                p.had_error = true;
                return null;
            };
            p.param_destruct_counter += 1;
            params.append(p.arena, tmp_name) catch {
                p.had_error = true;
                return null;
            };
            var pattern_node = pat;
            var default_expr: ?*Node = null;
            if (pat.kind == .assignment_expr and pat.data.assignment_expr.op == .assign) {
                pattern_node = pat.data.assignment_expr.target;
                default_expr = pat.data.assignment_expr.value;
            }
            defaults.append(p.arena, default_expr) catch {
                p.had_error = true;
                return null;
            };
            const src = p.makeNode(.identifier, pat.start, pat.start, .{ .identifier = tmp_name }) orelse return null;
            p.arrow_prelude = .{};
            if (!expr_mod.desugarParamPattern(p, pattern_node, src)) return null;
            param_prelude.appendSlice(p.arena, p.arrow_prelude.items) catch {
                p.had_error = true;
                return null;
            };
            p.arrow_prelude = .{};
            if (!p.match(.comma)) break;
            continue;
        }
        const param_tok = p.expect(.identifier) orelse return null;
        if (!parser_file.checkStrictBindingName(p, param_tok.value_str, param_tok.line, param_tok.column)) return null;
        if (is_rest) {
            saw_rest = true;
            rest_param = param_tok.value_str;
            if (p.match(.eq)) {
                if (!p.had_error) {
                    p.had_error = true;
                    p.error_info = parser_file.ParseError{
                        .message = "rest parameter cannot have a default value",
                        .line = p.current.line,
                        .column = p.current.column,
                    };
                }
                return null;
            }
            if (!p.check(.right_paren)) {
                if (!p.had_error) {
                    p.had_error = true;
                    p.error_info = parser_file.ParseError{
                        .message = "rest parameter must be last",
                        .line = p.current.line,
                        .column = p.current.column,
                    };
                }
                return null;
            }
            break;
        }
        params.append(p.arena, param_tok.value_str) catch {
            p.had_error = true;
            return null;
        };
        var default_expr: ?*Node = null;
        if (p.match(.eq)) {
            // NamedEvaluation: `function f(cls = class {})` names the anonymous
            // class "cls" (§8.6.3 — the default is an Initializer whose target
            // is a single BindingIdentifier). A class is named at parse time,
            // so the hint has to be set here rather than in the compiler.
            const set_class_hint = p.check(.kw_class) and p.export_default_name_hint == null;
            if (set_class_hint) p.export_default_name_hint = param_tok.value_str;
            default_expr = p.parseAssignmentExpr() orelse return null;
            if (set_class_hint) p.export_default_name_hint = null;
        }
        defaults.append(p.arena, default_expr) catch return null;
        if (saw_rest) break;
        if (!p.match(.comma)) break;
    }
    _ = p.expect(.right_paren) orelse return null;
    // Duplicate BoundNames. Decided here, on the names as written: the TDZ
    // desugar below rewrites them to `__arg_N`, and a destructuring parameter
    // already carries a unique synthetic `__param_N`. A sloppy, simple
    // parameter list of a function declaration/expression may repeat a name;
    // UniqueFormalParameters (methods, accessors) and any non-simple list may
    // not, and neither may strict code. A "use strict" prologue in the body is
    // only visible later, so `parseFunctionBody` re-checks the saved flag.
    const unique_required = p.require_unique_params;
    p.require_unique_params = false;
    var bound = std.ArrayList([]const u8){};
    bound.appendSlice(p.arena, params.items) catch {
        p.had_error = true;
        return null;
    };
    if (rest_param) |r| bound.append(p.arena, r) catch {
        p.had_error = true;
        return null;
    };
    const simple = rest_param == null and param_prelude.items.len == 0 and blk: {
        for (defaults.items) |d| {
            if (d != null) break :blk false;
        }
        break :blk true;
    };
    p.pending_param_names = bound.items;
    p.pending_params_duplicate = parser_file.hasDuplicateName(bound.items);
    if (p.pending_params_duplicate and (unique_required or p.strict or !simple)) {
        parser_file.rejectDuplicateParams(p);
        return null;
    }
    // ExpectedArgumentCount, captured before the TDZ desugar below clears the
    // initializers: the parameters up to (not including) the first defaulted
    // one. A rest parameter is already outside `params`.
    const expected_argc: u16 = blk: {
        var n: u16 = 0;
        for (defaults.items) |d| {
            if (d != null) break;
            n += 1;
        }
        break :blk n;
    };
    // TDZ for default parameters: a non-simple parameter list (one with a
    // default) puts every parameter in a TDZ until its own initializer, so a
    // default referencing a not-yet-initialized parameter is a ReferenceError
    // (`function f(x = x)`, `function f(x = y, y)`). Model it by renaming each
    // parameter to a synthetic positional `__arg_N` and rebinding the real name
    // as a body-scoped `let` initialized from it — the existing let TDZ + hoisting
    // does the rest. Scoped to simple-named param lists (no destructuring / rest),
    // which is where these tests live; mixed lists keep the prior behavior.
    var any_default = false;
    for (defaults.items) |d| {
        if (d != null) {
            any_default = true;
            break;
        }
    }
    if (any_default and rest_param == null and param_prelude.items.len == 0) {
        var lets = std.ArrayList(*Node){};
        for (params.items, 0..) |orig, i| {
            const synth = std.fmt.allocPrint(p.arena, "__arg_{d}", .{i}) catch {
                p.had_error = true;
                return null;
            };
            var init_node: *Node = undefined;
            if (defaults.items[i]) |dexpr| {
                const ar1 = p.makeNode(.identifier, 0, 0, .{ .identifier = synth }) orelse return null;
                const undef = p.makeNode(.undefined_literal, 0, 0, .{ .undefined_literal = {} }) orelse return null;
                const test_ = p.makeNode(.binary_expr, 0, 0, .{ .binary_expr = .{ .op = .strict_neq, .left = ar1, .right = undef } }) orelse return null;
                const ar2 = p.makeNode(.identifier, 0, 0, .{ .identifier = synth }) orelse return null;
                init_node = p.makeNode(.conditional_expr, 0, 0, .{ .conditional_expr = .{ .test_ = test_, .consequent = ar2, .alternate = dexpr } }) orelse return null;
            } else {
                init_node = p.makeNode(.identifier, 0, 0, .{ .identifier = synth }) orelse return null;
            }
            const vd = p.makeNode(.var_decl, 0, 0, .{ .var_decl = .{ .kind = .let, .name = orig, .init = init_node, .param_init = true } }) orelse return null;
            lets.append(p.arena, vd) catch {
                p.had_error = true;
                return null;
            };
            params.items[i] = synth;
            defaults.items[i] = null;
        }
        param_prelude = lets;
    }
    p.pending_param_prelude = param_prelude.items;
    return parser_file.ParamParse{
        .params = params.items,
        .param_defaults = defaults.items,
        .rest_param = rest_param,
        .expected_argc = expected_argc,
        .non_simple = rest_param != null or any_default or saw_destructuring,
    };
}

pub fn parseFunctionBody(p: *Parser) ?[]*Node {
    // Capture (and clear) any destructuring-param prelude produced by the
    // preceding parseFunctionParams before parsing the body, since nested
    // functions/arrows inside the body reuse the same staging field.
    const param_prelude = p.pending_param_prelude;
    p.pending_param_prelude = &.{};
    // Same staging discipline as the prelude: a nested function/arrow in this
    // body parses its own parameters and would otherwise overwrite these.
    const param_names = p.pending_param_names;
    const params_duplicate = p.pending_params_duplicate;
    p.pending_param_names = &.{};
    p.pending_params_duplicate = false;
    _ = p.expect(.left_brace) orelse return null;
    p.fn_nesting_depth += 1;
    // A function body starts its own break/continue scope: an enclosing loop or
    // switch does not extend into it.
    const saved_iter_depth = p.iteration_depth;
    const saved_switch_depth = p.switch_depth;
    p.iteration_depth = 0;
    p.switch_depth = 0;
    defer {
        p.iteration_depth = saved_iter_depth;
        p.switch_depth = saved_switch_depth;
    }
    // A nested function body establishes its own rules: a class static
    // initialization block's restrictions on `await`, `arguments` and `return`
    // stop at its boundary (`static { function f(await) {} }` is legal).
    // parseStaticBlockBody re-arms them around its own call to this function.
    const is_static_block = p.next_body_is_static_block;
    p.next_body_is_static_block = false;
    const saved_await_reserved = p.await_is_reserved;
    const saved_in_static_block = p.in_static_block;
    p.await_is_reserved = is_static_block;
    p.in_static_block = is_static_block;
    defer {
        p.await_is_reserved = saved_await_reserved;
        p.in_static_block = saved_in_static_block;
    }
    // A function body is strict if it inherits strictness from the enclosing
    // code or carries its own "use strict" directive prologue. Restored on exit
    // so a strict function nested in sloppy code doesn't leak strictness back.
    const saved_strict = p.strict;
    var body = std.ArrayList(*Node){};
    const li_start = p.live_imports.items.len;
    const le_start = p.live_exports.items.len;
    const la_start = p.live_export_aliases.items.len;
    var in_prologue = true;
    var body_use_strict = false;
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        const s = p.parseStatement() orelse break;
        body.append(p.arena, s) catch {
            p.had_error = true;
            break;
        };
        if (in_prologue) {
            if (parser_file.directiveOf(s)) |dir| {
                if (std.mem.eql(u8, dir, "use strict")) {
                    p.strict = true;
                    body_use_strict = true;
                }
            } else in_prologue = false;
        }
        p.drainExtraStmts(&body);
    }
    // Surface this body's own "use strict" directive for the caller's §15.2.1
    // non-simple-parameter early-error check (see pending_body_use_strict).
    p.pending_body_use_strict = body_use_strict;
    p.applyLiveBindings(body.items, li_start, le_start, la_start);
    // §15.2.1: a "use strict" prologue makes the *whole* function strict, which
    // retroactively outlaws a duplicate parameter name; and a body-level
    // `let`/`const` may never redeclare a parameter (LexicallyDeclaredNames of
    // the FunctionStatementList must be disjoint from BoundNames of the
    // FormalParameters). Both are only decidable once the body has been read.
    if (!p.had_error) {
        if (params_duplicate and p.strict) {
            parser_file.rejectDuplicateParams(p);
        } else if (param_names.len > 0) {
            for (body.items) |s| {
                if (s.kind != .var_decl) continue;
                const vd = s.data.var_decl;
                if (vd.kind != .let and vd.kind != .const_) continue;
                for (param_names) |pn| {
                    if (!std.mem.eql(u8, pn, vd.name)) continue;
                    p.had_error = true;
                    p.error_info = parser_file.ParseError{
                        .message = "lexical declaration cannot redeclare a parameter",
                        .line = p.current.line,
                        .column = p.current.column,
                    };
                    break;
                }
                if (p.had_error) break;
            }
        }
    }
    p.strict = saved_strict;
    p.fn_nesting_depth -= 1;
    _ = p.expect(.right_brace) orelse return null;
    // Prepend destructuring-param decls (binding the synthetic `__param_N`
    // names) so they run before the function body proper. A `params_done` marker
    // always separates parameter initialization from the body: for generators the
    // build driver runs everything up to it eagerly at call time (so destructuring
    // AND default-parameter side effects — e.g. `g.prototype = null` — happen
    // during FunctionDeclarationInstantiation, before OrdinaryCreateFromConstructor).
    // Default-param inits are prepended later (applyParamDefaults), landing in
    // front of the prelude and thus still before the marker. Only generators get
    // the marker (gated on in_generator_function) so a regular function's body
    // structure — and tail-call analysis — is unchanged. A destructuring prelude
    // outside a generator is still prepended (it just runs as ordinary body code).
    if (p.in_generator_function) {
        var combined = std.ArrayList(*Node){};
        combined.appendSlice(p.arena, param_prelude) catch {
            p.had_error = true;
            return null;
        };
        const marker = p.makeNode(.params_done, 0, 0, .{ .params_done = {} }) orelse return null;
        combined.append(p.arena, marker) catch {
            p.had_error = true;
            return null;
        };
        combined.appendSlice(p.arena, body.items) catch {
            p.had_error = true;
            return null;
        };
        return combined.items;
    }
    if (param_prelude.len > 0) {
        var combined = std.ArrayList(*Node){};
        combined.appendSlice(p.arena, param_prelude) catch {
            p.had_error = true;
            return null;
        };
        combined.appendSlice(p.arena, body.items) catch {
            p.had_error = true;
            return null;
        };
        return combined.items;
    }
    return body.items;
}
