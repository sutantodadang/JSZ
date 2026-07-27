// SPDX-License-Identifier: Apache-2.0
//! Class and function-body parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const expr_mod = @import("./expr.zig");
const stmt_mod = @import("./stmt.zig");
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
/// True when `callee` is the desugared *super constructor call* form
/// `super.call` (produced by rewriteSuperCall Case 1 for `super(...)`). Its
/// leading `this` argument is a synthetic receiver the super helper ignores, so
/// it must stay `__superthis` rather than a TDZ-guarded read.
///
/// Deliberately does NOT match `super.<method>.call` (Case 2, a super *method*
/// call): there the leading `this` is the real call receiver, and per spec
/// evaluating `super.m()` before `super()` needs the uninitialized this-binding,
/// so that `this` must route through the TDZ `__checkthis__()` guard.
fn isSuperDotCall(callee: *Node) bool {
    if (callee.kind != .member_expr) return false;
    const m = callee.data.member_expr;
    if (m.computed) return false;
    if (!(m.property.kind == .identifier and std.mem.eql(u8, m.property.data.identifier, "call"))) return false;
    const obj = m.object;
    return obj.kind == .identifier and std.mem.eql(u8, obj.data.identifier, "super");
}

/// True when `node` is the desugared super-property *read* or *write* form,
/// i.e. `Reflect.get(__sproto__, KEY, __superthis)` or
/// `Reflect.set(__sproto__, KEY, VALUE, __superthis)` (produced by
/// rewriteSuperPropRead / rewriteSuperPropAssign). Identified by a `Reflect.get`
/// / `Reflect.set` callee, a `__sproto__` first argument, and an `__superthis`
/// receiver as the last argument. Super *method* calls are excluded: their
/// Reflect.get receiver is a `this` expression (which this pass turns into a
/// `__checkthis__()` call), never the bare `__superthis` identifier.
fn isSuperPropReflect(node: *Node) bool {
    if (node.kind != .call_expr) return false;
    const c = node.data.call_expr;
    if (c.callee.kind != .member_expr) return false;
    const m = c.callee.data.member_expr;
    if (m.computed) return false;
    if (!(m.object.kind == .identifier and std.mem.eql(u8, m.object.data.identifier, "Reflect"))) return false;
    if (!(m.property.kind == .identifier and
        (std.mem.eql(u8, m.property.data.identifier, "get") or std.mem.eql(u8, m.property.data.identifier, "set")))) return false;
    if (c.args.len < 3) return false;
    if (!(c.args[0].kind == .identifier and std.mem.eql(u8, c.args[0].data.identifier, "__sproto__"))) return false;
    const last = c.args[c.args.len - 1];
    return last.kind == .identifier and std.mem.eql(u8, last.data.identifier, "__superthis");
}

/// True when `node` is a `super.x` / `super[e]` member access (object is the
/// literal `super` identifier). Compound assignments (`super[e] += v`) and
/// updates (`super[e]++`) keep this member form — they are not rewritten to a
/// Reflect call — so a derived-constructor TDZ guard must be attached here too.
fn isSuperMember(node: *Node) bool {
    if (node.kind != .member_expr) return false;
    const m = node.data.member_expr;
    return m.object.kind == .identifier and std.mem.eql(u8, m.object.data.identifier, "super");
}

/// Wrap `node` (already rewritten in place) as `(__checkthis__(), <node>)` so
/// that in a derived constructor the this-binding is fetched — throwing a
/// ReferenceError while `this` is still in its TDZ — before the rest of the
/// expression (e.g. the property key) is evaluated.
fn guardWithCheckThis(p: *Parser, node: *Node) void {
    const s = node.start;
    const guard_callee = p.makeNode(.identifier, s, s, .{ .identifier = "__checkthis__" }) orelse return;
    const guard = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = guard_callee, .args = &[_]*Node{} } }) orelse return;
    const orig = p.makeNode(node.kind, node.start, node.end, node.data) orelse return;
    var seq = std.ArrayList(*Node){};
    seq.append(p.arena, guard) catch return;
    seq.append(p.arena, orig) catch return;
    node.kind = .sequence_expr;
    node.data = .{ .sequence_expr = .{ .exprs = seq.items } };
}

fn rewriteThisToSuperThis(p: *Parser, node: *Node) void {
    switch (node.data) {
        .this_expr => {
            // `this` → `__checkthis__(__superthis)`. Reading `this` in a derived
            // constructor before `super()` is a ReferenceError (the `this`
            // binding is in its TDZ); `__checkthis__` throws when `__superthis`
            // is still undefined. Mutate this node into the call in place.
            const s = node.start;
            const callee = p.makeNode(.identifier, s, s, .{ .identifier = "__checkthis__" }) orelse return;
            node.kind = .call_expr;
            node.data = .{ .call_expr = .{ .callee = callee, .args = &[_]*Node{} } };
        },
        .unary_expr => |u| rewriteThisToSuperThis(p, u.operand),
        .binary_expr => |b| {
            rewriteThisToSuperThis(p, b.left);
            rewriteThisToSuperThis(p, b.right);
        },
        .logical_expr => |b| {
            rewriteThisToSuperThis(p, b.left);
            rewriteThisToSuperThis(p, b.right);
        },
        .assignment_expr => |a| {
            const super_target = isSuperMember(a.target);
            rewriteThisToSuperThis(p, a.target);
            rewriteThisToSuperThis(p, a.value);
            // A compound assignment to a super property (`super[e] += v`) keeps
            // the member form (only `=` is Reflect-desugared), so guard the TDZ
            // here: the this-binding is read before the key `e` is evaluated.
            if (super_target) guardWithCheckThis(p, node);
        },
        .update_expr => |u| {
            const super_target = isSuperMember(u.operand);
            rewriteThisToSuperThis(p, u.operand);
            if (super_target) guardWithCheckThis(p, node);
        },
        .conditional_expr => |c| {
            rewriteThisToSuperThis(p, c.test_);
            rewriteThisToSuperThis(p, c.consequent);
            rewriteThisToSuperThis(p, c.alternate);
        },
        .sequence_expr => |s| for (s.exprs) |e| rewriteThisToSuperThis(p, e),
        .spread_expr => |e| rewriteThisToSuperThis(p, e),
        .yield_expr => |e| if (e) |ee| rewriteThisToSuperThis(p, ee),
        .call_expr => |c| {
            rewriteThisToSuperThis(p, c.callee);
            // `super(...)` / `super.m(...)` were parse-time rewritten to
            // `super.call(this, ...)` / `super.m.call(this, ...)`. That leading
            // `this` is the synthetic receiver for the super helper (which
            // ignores it), NOT a user `this` read — keep it as `__superthis`
            // (undefined pre-super) rather than route it through the TDZ
            // `__checkthis__()` guard, which would throw on the very super() call
            // that initializes `this`.
            var start_i: usize = 0;
            if (isSuperDotCall(c.callee) and c.args.len > 0 and c.args[0].kind == .this_expr) {
                c.args[0].kind = .identifier;
                c.args[0].data = .{ .identifier = "__superthis" };
                start_i = 1;
            }
            for (c.args[start_i..]) |a| rewriteThisToSuperThis(p, a);
            // A super-property read/write (`super.x` / `super[e]` / `super.x = v`)
            // desugars to `Reflect.get/set(__sproto__, KEY, …, __superthis)`. Per
            // spec (SuperProperty evaluation) the this-binding is fetched — and a
            // ReferenceError thrown if `this` is still in its TDZ (before super())
            // — BEFORE the property key/value is evaluated. Reflect.get/set would
            // instead evaluate KEY first. Force the check ahead of everything by
            // rewriting the call to `(__checkthis__(), <call>)`: the comma
            // evaluates the guard first, then the reflect call (which reads the
            // now-safe `__superthis` receiver).
            if (isSuperPropReflect(node)) guardWithCheckThis(p, node);
        },
        .new_expr => |n| {
            rewriteThisToSuperThis(p, n.callee);
            for (n.args) |a| rewriteThisToSuperThis(p, a);
        },
        .member_expr => |m| {
            rewriteThisToSuperThis(p, m.object);
            if (m.computed) rewriteThisToSuperThis(p, m.property);
        },
        .optional_chain => |e| rewriteThisToSuperThis(p, e),
        .function_expr => |f| if (f.is_arrow) {
            for (f.param_defaults) |d| if (d) |dd| rewriteThisToSuperThis(p, dd);
            for (f.body) |s| rewriteThisToSuperThis(p, s);
        },
        .object_literal => |o| for (o.properties) |pr| {
            rewriteThisToSuperThis(p, pr.value);
            if (pr.computed_key) |k| rewriteThisToSuperThis(p, k);
        },
        .array_literal => |a| for (a.elements) |e| rewriteThisToSuperThis(p, e),
        .expr_stmt => |e| rewriteThisToSuperThis(p, e),
        .block_stmt => |b| for (b.body) |s| rewriteThisToSuperThis(p, s),
        .var_decl => |v| if (v.init) |i| rewriteThisToSuperThis(p, i),
        .if_stmt => |i| {
            rewriteThisToSuperThis(p, i.test_);
            rewriteThisToSuperThis(p, i.consequent);
            if (i.alternate) |a| rewriteThisToSuperThis(p, a);
        },
        .while_stmt => |w| {
            rewriteThisToSuperThis(p, w.test_);
            rewriteThisToSuperThis(p, w.body);
        },
        .do_while_stmt => |w| {
            rewriteThisToSuperThis(p, w.body);
            rewriteThisToSuperThis(p, w.test_);
        },
        .for_stmt => |f| {
            if (f.init) |i| rewriteThisToSuperThis(p, i);
            if (f.test_) |t| rewriteThisToSuperThis(p, t);
            if (f.update) |u| rewriteThisToSuperThis(p, u);
            rewriteThisToSuperThis(p, f.body);
        },
        .return_stmt => |e| if (e) |ee| rewriteThisToSuperThis(p, ee),
        .throw_stmt => |e| rewriteThisToSuperThis(p, e),
        .try_stmt => |t| {
            rewriteThisToSuperThis(p, t.block);
            if (t.handler) |h| rewriteThisToSuperThis(p, h.body);
            if (t.finalizer) |f| rewriteThisToSuperThis(p, f);
        },
        .for_in_stmt => |f| {
            rewriteThisToSuperThis(p, f.left);
            rewriteThisToSuperThis(p, f.right);
            rewriteThisToSuperThis(p, f.body);
        },
        .switch_stmt => |s| {
            rewriteThisToSuperThis(p, s.discriminant);
            for (s.cases) |c| {
                if (c.test_) |t| rewriteThisToSuperThis(p, t);
                for (c.body) |st| rewriteThisToSuperThis(p, st);
            }
        },
        .labeled_stmt => |l| rewriteThisToSuperThis(p, l.body),
        .program => |pr| for (pr.body) |s| rewriteThisToSuperThis(p, s),
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

/// Like `makeNewTargetNode`, but reads the `__supernt__` capture (the enclosing
/// constructor's NewTarget, saved into a local before the `super()` helper) so a
/// nested helper function does not shadow it with its own `__new_target__`.
fn makeCapturedNtNode(p: *Parser, start: u32, class_name: []const u8) ?*Node {
    const id_var = p.makeNode(.identifier, start, start, .{ .identifier = "__supernt__" }) orelse return null;
    const id_cls = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    return p.makeNode(.logical_expr, start, start, .{
        .logical_expr = .{ .op = .or_, .left = id_var, .right = id_cls },
    });
}

/// `throw new ReferenceError(<msg>);`
fn makeRefErrorThrow(p: *Parser, start: u32, msg: []const u8) ?*Node {
    const id_re = p.makeNode(.identifier, start, start, .{ .identifier = "ReferenceError" }) orelse return null;
    const re_msg = p.makeNode(.string_literal, start, start, .{ .string_literal = msg }) orelse return null;
    var re_args = std.ArrayList(*Node){};
    re_args.append(p.arena, re_msg) catch return null;
    const re_new = p.makeNode(.new_expr, start, start, .{
        .new_expr = .{ .callee = id_re, .args = re_args.items },
    }) orelse return null;
    return p.makeNode(.throw_stmt, start, start, .{ .throw_stmt = re_new });
}

/// `if (__superthis <op> undefined) throw new ReferenceError(<msg>);`
/// `op` is `.strict_eq` (TDZ read guard) or `.strict_neq` (super-called-once guard).
fn makeSuperthisGuard(p: *Parser, start: u32, op: ast.BinaryOp, msg: []const u8) ?*Node {
    const lhs = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
    const rhs = p.makeNode(.identifier, start, start, .{ .identifier = "undefined" }) orelse return null;
    const test_ = p.makeNode(.binary_expr, start, start, .{
        .binary_expr = .{ .op = op, .left = lhs, .right = rhs },
    }) orelse return null;
    const throw_st = makeRefErrorThrow(p, start, msg) orelse return null;
    return p.makeNode(.if_stmt, start, start, .{
        .if_stmt = .{ .test_ = test_, .consequent = throw_st, .alternate = null },
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
    /// Hidden `var` holding the pre-evaluated property key for a computed method/
    /// accessor key (`__ck_N__`). Like ClassField.key_var, the ClassElementName is
    /// evaluated once at class-definition time, in the enclosing execution context
    /// (so `[yield]`/`[await]` work), rather than inline inside the class body.
    key_var: ?[]const u8 = null,
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
    /// This member's body contains a SuperProperty. A base class has a home
    /// object too, so `super.x` is legal in it, but binding `__sproto__` in
    /// every method would cost an `Object.getPrototypeOf` per call — emit it
    /// only where it is read. See Parser.super_prop_count.
    uses_super_prop: bool = false,
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
    /// See ClassMember.uses_super_prop.
    uses_super_prop: bool = false,
};

const ClassBodyParse = struct {
    ctor_params: [][]const u8 = &[_][]const u8{},
    ctor_rest: ?[]const u8 = null,
    ctor_body: []*Node = &[_]*Node{},
    // Distinguishes an explicit `constructor() {}` (empty body, but present —
    // must NOT auto-call super) from a class with no constructor at all (which
    // synthesizes the default `return Reflect.construct(Super, ...)`).
    has_ctor: bool = false,
    /// The constructor body references `super.x` / `super[e]` (a super *property*,
    /// not a `super()` call). A base class must still bind `__sproto__` for it.
    ctor_uses_super: bool = false,
    members: []ClassMember = &[_]ClassMember{},
    fields: []ClassField = &[_]ClassField{},
    /// This class body's PrivateEnvironment, filled in by `manglePrivateNames`.
    /// The desugared statements get it stamped onto every function they contain
    /// (`attachPrivScope`) so a direct `eval` inside a method can resolve `#x`.
    priv_names: []const ast.PrivName = &.{},
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

        // Snapshot: any SuperProperty desugared while parsing this member's
        // initializer/body belongs to it, so `__sproto__` gets bound there.
        const super_mark = p.super_prop_count;
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
        // `get`/`set` is a modifier only when a ClassElementName follows. A `*`
        // does not start one, so `get \n *a() {}` is a field named "get"
        // (terminated by ASI) followed by a generator method — not a malformed
        // accessor.
        if (p.check(.identifier) and !nextTokenEndsName(p) and p.peekNext().kind != .star) {
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
        } else if (p.check(.bigint)) {
            // A BigInt-literal class-element name keys on ToString of its value
            // (`1n` → "1"), mirroring the NumericLiteral case above.
            name = expr_mod.bigintLiteralKey(p) orelse return null;
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
                .uses_super_prop = p.super_prop_count != super_mark,
            }) catch return null;
            continue;
        }

        // A MethodDefinition takes UniqueFormalParameters (§15.4.1).
        p.require_unique_params = true;
        const mparams = p.parseFunctionParams() orelse return null;
        // §15.4.1: a getter takes no parameters; a setter takes exactly one (not
        // a rest parameter).
        if (accessor == .get and (mparams.params.len != 0 or mparams.rest_param != null)) {
            _ = p.fail("getter functions must have no arguments");
            return null;
        }
        if (accessor == .set and (mparams.params.len != 1 or mparams.rest_param != null)) {
            _ = p.fail("setter functions must have exactly one argument");
            return null;
        }
        const prev_gen = p.in_generator_function;
        p.in_generator_function = is_generator;
        const mbody = p.parseFunctionBody() orelse {
            p.in_generator_function = prev_gen;
            return null;
        };
        p.in_generator_function = prev_gen;
        const member_end = p.prev_end;

        if (!is_static and accessor == .none and computed_key == null and std.mem.eql(u8, name, "constructor")) {
            res.ctor_params = mparams.params;
            res.ctor_rest = mparams.rest_param;
            res.ctor_body = mbody;
            res.has_ctor = true;
            res.ctor_uses_super = p.super_prop_count != super_mark;
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
                .uses_super_prop = p.super_prop_count != super_mark,
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
    pairs: []const ast.PrivName,
    /// Direct-eval mode: records the first `#x` that no enclosing class declares,
    /// so the caller can raise the early SyntaxError the spec requires
    /// (PrivateNameResolution has no binding for it). Null in the ordinary
    /// class-body pass, where an unmatched `#x` belongs to an enclosing class
    /// whose own pass has not run yet.
    unresolved: ?*?[]const u8 = null,

    fn map(self: PrivateRewriter, name: []const u8) []const u8 {
        for (self.pairs) |e| {
            if (std.mem.eql(u8, e.raw, name)) return e.mangled;
        }
        if (self.unresolved) |slot| {
            // Already-mangled names come from a class defined *inside* the eval
            // and are resolved; only a still-raw `#x` is unbound.
            if (slot.* == null and isPrivateName(name) and
                std.mem.indexOfScalar(u8, name, mangled_priv_sep) == null)
                slot.* = name;
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

/// Flag every direct `eval(...)` lexically inside a class field initializer so
/// PerformEval applies the "eval inside initializer" ContainsArguments early
/// error (§sec-performeval-rules-in-initializer). The initializer region extends
/// through arrow functions (an arrow has no own `arguments`), but a non-arrow
/// FunctionExpression/Declaration/method establishes a fresh `arguments` binding
/// and ends the region — so this walk descends into arrows but stops at those.
const InitEvalMarker = struct {
    fn walkOpt(node: ?*Node) void {
        if (node) |n| walk(n);
    }
    fn walk(node: *Node) void {
        switch (node.data) {
            .unary_expr => |u| walk(u.operand),
            .binary_expr => |b| {
                walk(b.left);
                walk(b.right);
            },
            .logical_expr => |b| {
                walk(b.left);
                walk(b.right);
            },
            .assignment_expr => |a| {
                walk(a.target);
                walk(a.value);
            },
            .update_expr => |u| walk(u.operand),
            .conditional_expr => |c| {
                walk(c.test_);
                walk(c.consequent);
                walk(c.alternate);
            },
            .sequence_expr => |s| for (s.exprs) |e| walk(e),
            .spread_expr => |e| walk(e),
            .yield_expr => |e| walkOpt(e),
            .call_expr => |c| {
                // A bare `eval(...)` callee (not `x?.()`) is a direct eval; mark it.
                if (!c.optional and c.callee.kind == .identifier and
                    std.mem.eql(u8, c.callee.data.identifier, "eval"))
                    node.data.call_expr.field_init_eval = true;
                walk(c.callee);
                for (c.args) |a| walk(a);
            },
            .new_expr => |n| {
                walk(n.callee);
                for (n.args) |a| walk(a);
            },
            .member_expr => |m| {
                walk(m.object);
                walk(m.property);
            },
            .optional_chain => |e| walk(e),
            // Arrows keep the enclosing `arguments`, so the region continues into them.
            .function_expr => |f| if (f.is_arrow) {
                for (f.param_defaults) |d| walkOpt(d);
                for (f.body) |s| walk(s);
            },
            // A named function declaration is never an arrow; it ends the region.
            .function_decl => {},
            .object_literal => |o| for (o.properties) |pr| {
                walk(pr.value);
                walkOpt(pr.computed_key);
            },
            .array_literal => |a| for (a.elements) |e| walk(e),
            .expr_stmt => |e| walk(e),
            .block_stmt => |b| for (b.body) |s| walk(s),
            .var_decl => |v| walkOpt(v.init),
            .if_stmt => |i| {
                walk(i.test_);
                walk(i.consequent);
                walkOpt(i.alternate);
            },
            .while_stmt => |w| {
                walk(w.test_);
                walk(w.body);
            },
            .do_while_stmt => |w| {
                walk(w.body);
                walk(w.test_);
            },
            .with_stmt => |w| {
                walk(w.object);
                walk(w.body);
            },
            .for_stmt => |f| {
                walkOpt(f.init);
                walkOpt(f.test_);
                walkOpt(f.update);
                walk(f.body);
            },
            .return_stmt => |e| walkOpt(e),
            .throw_stmt => |e| walk(e),
            .try_stmt => |t| {
                walk(t.block);
                if (t.handler) |h| walk(h.body);
                walkOpt(t.finalizer);
            },
            .for_in_stmt => |f| {
                walk(f.left);
                walk(f.right);
                walk(f.body);
            },
            .switch_stmt => |s| {
                walk(s.discriminant);
                for (s.cases) |c| {
                    walkOpt(c.test_);
                    for (c.body) |st| walk(st);
                }
            },
            .labeled_stmt => |l| walk(l.body),
            else => {},
        }
    }
};

/// Mark direct-eval calls inside a class field initializer expression (see
/// `InitEvalMarker`). Runs for every class with fields, before the field
/// initializers are desugared into constructor/`__superthis` assignments.
pub fn markInitializerEvalCalls(init: ?*Node) void {
    if (init) |n| InitEvalMarker.walk(n);
}

/// ContainsArguments (§sec-static-semantics-containsarguments) over an eval
/// body: true if an IdentifierReference to `arguments` appears anywhere,
/// descending into arrow functions (which have no own `arguments`) but stopping
/// at a non-arrow FunctionExpression/Declaration (which binds its own). A
/// non-computed member property name is a property key, not a reference, so it
/// is skipped. Used for the "eval inside initializer" early error.
const ArgumentsScanner = struct {
    fn scanOpt(node: ?*Node) bool {
        return if (node) |n| scan(n) else false;
    }
    fn scan(node: *Node) bool {
        switch (node.data) {
            .identifier => |name| return std.mem.eql(u8, name, "arguments"),
            .unary_expr => |u| return scan(u.operand),
            .binary_expr => |b| return scan(b.left) or scan(b.right),
            .logical_expr => |b| return scan(b.left) or scan(b.right),
            .assignment_expr => |a| return scan(a.target) or scan(a.value),
            .update_expr => |u| return scan(u.operand),
            .conditional_expr => |c| return scan(c.test_) or scan(c.consequent) or scan(c.alternate),
            .sequence_expr => |s| {
                for (s.exprs) |e| if (scan(e)) return true;
                return false;
            },
            .spread_expr => |e| return scan(e),
            .yield_expr => |e| return scanOpt(e),
            .call_expr => |c| {
                if (scan(c.callee)) return true;
                for (c.args) |a| if (scan(a)) return true;
                return false;
            },
            .new_expr => |n| {
                if (scan(n.callee)) return true;
                for (n.args) |a| if (scan(a)) return true;
                return false;
            },
            .member_expr => |m| {
                if (scan(m.object)) return true;
                // Only a computed key is an evaluated expression; `x.arguments`
                // is a property name, not a reference.
                if (m.computed) return scan(m.property);
                return false;
            },
            .optional_chain => |e| return scan(e),
            .function_expr => |f| {
                if (!f.is_arrow) return false;
                for (f.param_defaults) |d| if (scanOpt(d)) return true;
                for (f.body) |s| if (scan(s)) return true;
                return false;
            },
            .function_decl => return false,
            .object_literal => |o| {
                for (o.properties) |pr| {
                    if (scan(pr.value)) return true;
                    if (scanOpt(pr.computed_key)) return true;
                }
                return false;
            },
            .array_literal => |a| {
                for (a.elements) |e| if (scan(e)) return true;
                return false;
            },
            .expr_stmt => |e| return scan(e),
            .block_stmt => |b| {
                for (b.body) |s| if (scan(s)) return true;
                return false;
            },
            .var_decl => |v| return scanOpt(v.init),
            .if_stmt => |i| return scan(i.test_) or scan(i.consequent) or scanOpt(i.alternate),
            .while_stmt => |w| return scan(w.test_) or scan(w.body),
            .do_while_stmt => |w| return scan(w.body) or scan(w.test_),
            .with_stmt => |w| return scan(w.object) or scan(w.body),
            .for_stmt => |f| return scanOpt(f.init) or scanOpt(f.test_) or scanOpt(f.update) or scan(f.body),
            .return_stmt => |e| return scanOpt(e),
            .throw_stmt => |e| return scan(e),
            .try_stmt => |t| {
                if (scan(t.block)) return true;
                if (t.handler) |h| if (scan(h.body)) return true;
                return scanOpt(t.finalizer);
            },
            .for_in_stmt => |f| return scan(f.left) or scan(f.right) or scan(f.body),
            .switch_stmt => |s| {
                if (scan(s.discriminant)) return true;
                for (s.cases) |c| {
                    if (scanOpt(c.test_)) return true;
                    for (c.body) |st| if (scan(st)) return true;
                }
                return false;
            },
            .labeled_stmt => |l| return scan(l.body),
            else => return false,
        }
    }
};

/// True if an eval body ContainsArguments — see `ArgumentsScanner`.
pub fn evalBodyContainsArguments(stmts: []const *Node) bool {
    for (stmts) |s| if (ArgumentsScanner.scan(s)) return true;
    return false;
}

/// Resolve the private names a direct `eval`'s code refers to against the
/// PrivateEnvironment its calling context carries (`BcFunction.priv_names`).
///
/// The eval parser has no lexical view of the enclosing class body, so `#x`
/// survives parsing as a raw identifier; this rewrites it to the same mangled
/// key the class body's own code uses, and stamps the environment onto every
/// function in the eval'd source so a *nested* eval resolves it too.
///
/// Returns the first `#x` no enclosing class declares — the caller turns that
/// into the early SyntaxError §13.2.5.1 requires — or null when all resolved.
pub fn resolveEvalPrivateNames(
    arena: std.mem.Allocator,
    stmts: []const *Node,
    pairs: []const ast.PrivName,
) ?[]const u8 {
    var unresolved: ?[]const u8 = null;
    const rw = PrivateRewriter{ .pairs = pairs, .unresolved = &unresolved };
    for (stmts) |s| rw.walk(s);
    if (unresolved != null) return unresolved;
    attachPrivScope(arena, stmts, pairs);
    return null;
}

/// Stamp `pairs` onto every function nested in the desugared class statements,
/// so a direct `eval` running inside one of them can resolve the class's private
/// names (the eval parser has no lexical view of the class body). Appending —
/// rather than prepending — keeps innermost-first order: a nested class is fully
/// desugared before the enclosing body's pass runs, so its own pairs are already
/// at the front and win the first-match lookup.
pub fn attachPrivScope(p: std.mem.Allocator, nodes: []const *Node, pairs: []const ast.PrivName) void {
    if (pairs.len == 0) return;
    for (nodes) |n| attachPrivScopeNode(p, n, pairs);
}

fn attachPrivScopeOpt(p: std.mem.Allocator, node: ?*Node, pairs: []const ast.PrivName) void {
    if (node) |n| attachPrivScopeNode(p, n, pairs);
}

fn extendPrivNames(p: std.mem.Allocator, existing: []const ast.PrivName, pairs: []const ast.PrivName) []const ast.PrivName {
    const out = p.alloc(ast.PrivName, existing.len + pairs.len) catch return existing;
    @memcpy(out[0..existing.len], existing);
    @memcpy(out[existing.len..], pairs);
    return out;
}

fn attachPrivScopeNode(p: std.mem.Allocator, node: *Node, pairs: []const ast.PrivName) void {
    switch (node.data) {
        .function_expr => |f| {
            node.data.function_expr.priv_names = extendPrivNames(p, f.priv_names, pairs);
            for (f.param_defaults) |d| attachPrivScopeOpt(p, d, pairs);
            attachPrivScope(p, f.body, pairs);
        },
        .function_decl => |f| {
            node.data.function_decl.priv_names = extendPrivNames(p, f.priv_names, pairs);
            for (f.param_defaults) |d| attachPrivScopeOpt(p, d, pairs);
            attachPrivScope(p, f.body, pairs);
        },
        .unary_expr => |u| attachPrivScopeNode(p, u.operand, pairs),
        .binary_expr => |b| {
            attachPrivScopeNode(p, b.left, pairs);
            attachPrivScopeNode(p, b.right, pairs);
        },
        .logical_expr => |b| {
            attachPrivScopeNode(p, b.left, pairs);
            attachPrivScopeNode(p, b.right, pairs);
        },
        .assignment_expr => |a| {
            attachPrivScopeNode(p, a.target, pairs);
            attachPrivScopeNode(p, a.value, pairs);
        },
        .update_expr => |u| attachPrivScopeNode(p, u.operand, pairs),
        .conditional_expr => |c| {
            attachPrivScopeNode(p, c.test_, pairs);
            attachPrivScopeNode(p, c.consequent, pairs);
            attachPrivScopeNode(p, c.alternate, pairs);
        },
        .sequence_expr => |s| attachPrivScope(p, s.exprs, pairs),
        .spread_expr => |e| attachPrivScopeNode(p, e, pairs),
        .yield_expr => |e| attachPrivScopeOpt(p, e, pairs),
        .call_expr => |c| {
            attachPrivScopeNode(p, c.callee, pairs);
            attachPrivScope(p, c.args, pairs);
        },
        .new_expr => |n| {
            attachPrivScopeNode(p, n.callee, pairs);
            attachPrivScope(p, n.args, pairs);
        },
        .member_expr => |m| attachPrivScopeNode(p, m.object, pairs),
        .optional_chain => |e| attachPrivScopeNode(p, e, pairs),
        .object_literal => |o| for (o.properties) |pr| {
            attachPrivScopeNode(p, pr.value, pairs);
            attachPrivScopeOpt(p, pr.computed_key, pairs);
        },
        .array_literal => |a| attachPrivScope(p, a.elements, pairs),
        .program => |pr| attachPrivScope(p, pr.body, pairs),
        .expr_stmt => |e| attachPrivScopeNode(p, e, pairs),
        .block_stmt => |b| attachPrivScope(p, b.body, pairs),
        .var_decl => |v| attachPrivScopeOpt(p, v.init, pairs),
        .if_stmt => |i| {
            attachPrivScopeNode(p, i.test_, pairs);
            attachPrivScopeNode(p, i.consequent, pairs);
            attachPrivScopeOpt(p, i.alternate, pairs);
        },
        .while_stmt => |w| {
            attachPrivScopeNode(p, w.test_, pairs);
            attachPrivScopeNode(p, w.body, pairs);
        },
        .do_while_stmt => |w| {
            attachPrivScopeNode(p, w.body, pairs);
            attachPrivScopeNode(p, w.test_, pairs);
        },
        .with_stmt => |w| {
            attachPrivScopeNode(p, w.object, pairs);
            attachPrivScopeNode(p, w.body, pairs);
        },
        .for_stmt => |f| {
            attachPrivScopeOpt(p, f.init, pairs);
            attachPrivScopeOpt(p, f.test_, pairs);
            attachPrivScopeOpt(p, f.update, pairs);
            attachPrivScopeNode(p, f.body, pairs);
        },
        .return_stmt => |e| attachPrivScopeOpt(p, e, pairs),
        .throw_stmt => |e| attachPrivScopeNode(p, e, pairs),
        .try_stmt => |t| {
            attachPrivScopeNode(p, t.block, pairs);
            if (t.handler) |h| attachPrivScopeNode(p, h.body, pairs);
            attachPrivScopeOpt(p, t.finalizer, pairs);
        },
        .for_in_stmt => |f| {
            attachPrivScopeNode(p, f.left, pairs);
            attachPrivScopeNode(p, f.right, pairs);
            attachPrivScopeNode(p, f.body, pairs);
        },
        .switch_stmt => |s| {
            attachPrivScopeNode(p, s.discriminant, pairs);
            for (s.cases) |c| {
                attachPrivScopeOpt(p, c.test_, pairs);
                attachPrivScope(p, c.body, pairs);
            }
        },
        .labeled_stmt => |l| attachPrivScopeNode(p, l.body, pairs),
        else => {},
    }
}

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
    var pairs = std.ArrayList(ast.PrivName){};
    for (raw.items, mangled.items) |r, m| {
        pairs.append(p.arena, .{ .raw = r, .mangled = m }) catch return false;
    }
    parsed.priv_names = pairs.items;
    const rw = PrivateRewriter{ .pairs = pairs.items };

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
    if (!isAnonFnDef(check)) return val;
    const s = p.current.start;
    // A computed field is still named — after its *pre-evaluated* key binding, so
    // the key object's @@toPrimitive is not observed a second time. Without this
    // wrap the desugared descriptor `{ value: init }` would name the anonymous
    // function "value" (NamedEvaluation of the object-literal data property).
    // Fields with no hidden key binding (fallback path) are left unnamed.
    if (f.computed_key != null) {
        const kv = f.key_var orelse return val;
        const callee = nodeIdent(p, "__nameFn__") orelse return null;
        const key_ident = nodeIdent(p, kv) orelse return null;
        var cargs = std.ArrayList(*Node){};
        cargs.append(p.arena, val) catch return null;
        cargs.append(p.arena, key_ident) catch return null;
        return p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = cargs.items } });
    }
    const callee = nodeIdent(p, "__nameFn__") orelse return null;
    // A private field names its function after the *source* spelling ("#x"), not
    // the PrivateEnvironment-mangled key the property table uses.
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
fn appendDerivedInstanceFields(
    p: *Parser,
    list: *std.ArrayList(*Node),
    fields: []const ClassField,
    priv_plan: []const PrivInstance,
) bool {
    // InitializeInstanceElements adds the private methods/accessors BEFORE
    // running any field initializer, so a field's initializer may call `this.#m`.
    if (!appendPrivInstanceInstalls(p, list, priv_plan, "__superthis")) return false;
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
fn makeStaticFieldInit(p: *Parser, class_name: []const u8, super_name: ?[]const u8, f: ClassField) ?*Node {
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
    const body = blk_body: {
        if (!f.uses_super_prop) {
            const b = p.arena.alloc(*Node, 1) catch return null;
            b[0] = ret_stmt;
            break :blk_body b;
        }
        // The initializer's home object is the constructor, so `super.x` reads
        // through its [[Prototype]] — the superclass for a derived class, and
        // %Function.prototype% (via getPrototypeOf) for a base one.
        const b = p.arena.alloc(*Node, 3) catch return null;
        b[0] = superProtoDecl(p, class_name, super_name, true) orelse return null;
        b[1] = superThisDecl(p) orelse return null;
        b[2] = ret_stmt;
        break :blk_body b;
    };
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
fn prependInstanceFields(
    p: *Parser,
    class_name: []const u8,
    ctor_body: []*Node,
    fields: []const ClassField,
    priv_plan: []const PrivInstance,
    ctor_uses_super: bool,
) ?[]*Node {
    var any = false;
    var any_super = ctor_uses_super;
    for (fields) |f| {
        if (f.is_static) continue;
        any = true;
        if (f.uses_super_prop) any_super = true;
    }
    // The constructor body's own `super.x` needs `__sproto__` even when there
    // are no instance fields or private members to install.
    if (!any and priv_plan.len == 0 and !ctor_uses_super) return ctor_body;
    var stmts = std.ArrayList(*Node){};
    // Private methods/accessors are added before any field initializer runs.
    if (!appendPrivInstanceInstalls(p, &stmts, priv_plan, null)) return null;
    // An instance field of a base class has `C.prototype` as its home object, so
    // `super.x` in an initializer reads through that object's [[Prototype]].
    // Bound once at the head of the constructor, ahead of every field install.
    if (any_super) {
        stmts.append(p.arena, superProtoDecl(p, class_name, null, false) orelse return null) catch return null;
        stmts.append(p.arena, superThisDecl(p) orelse return null) catch return null;
    }
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

/// `var __sproto__ = <property base for super.x>` — the superclass prototype (or
/// the superclass itself, for a static element) when there is a heritage clause,
/// otherwise the home object's own [[Prototype]]. See `homeObjectNode`.
fn superProtoDecl(p: *Parser, class_name: []const u8, super_name: ?[]const u8, is_static: bool) ?*Node {
    const s = p.current.start;
    const base: *Node = if (super_name) |sname| blk: {
        const sup = nodeIdent(p, sname) orelse return null;
        const raw = if (is_static) sup else (nodeMember(p, sup, "prototype") orelse return null);
        const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
        break :blk nullHeritageGuard(p, sname, raw, sup_null, s) orelse return null;
    } else homeObjectNode(p, class_name, is_static) orelse return null;
    return p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__sproto__", .init = base } });
}

/// `var __superthis = this` — the Receiver a `super.x` read/write uses.
fn superThisDecl(p: *Parser) ?*Node {
    const s = p.current.start;
    const this_node = p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return null;
    return p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__superthis", .init = this_node } });
}

/// `Object.getPrototypeOf(<Cls>.prototype)` — or `Object.getPrototypeOf(<Cls>)`
/// for a static element. This is the property base `super.x` reads in a BASE
/// class: its home object is the class prototype (resp. the constructor), and
/// SuperProperty resolves against that object's [[Prototype]].
fn homeObjectNode(p: *Parser, class_name: []const u8, is_static: bool) ?*Node {
    const s = p.current.start;
    const cls = nodeIdent(p, class_name) orelse return null;
    const home = if (is_static) cls else (nodeMember(p, cls, "prototype") orelse return null);
    const id_obj = nodeIdent(p, "Object") orelse return null;
    const callee = nodeMember(p, id_obj, "getPrototypeOf") orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, home) catch return null;
    return p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } });
}

/// Desugar one class member into a single statement (a property assignment for
/// methods, or `Object.defineProperty(target, key, { get|set, configurable,
/// enumerable })` for accessors). `target` is the constructor for static members
/// and `ClassName.prototype` otherwise.
fn emitClassMember(p: *Parser, class_name: []const u8, super_name: ?[]const u8, m: ClassMember, hidden: ?[]const u8) ?*Node {
    const s = p.current.start;

    // Instance methods of a derived class may use `super.foo()`; bind
    // `super = Super.prototype` at the top of the body (static members don't).
    var body = m.body;
    if (super_name) |sname| {
        // The home object for `super` inside a method: the parent *prototype*
        // for an instance method (`Super.prototype`), the parent *constructor*
        // for a static method (`Super`). Both bind `super`/`__sproto__` (the
        // property base) and `__superthis` (the Receiver — the method's `this`).
        const base_node: *Node = if (m.is_static) blk: {
            const sup_ctor = nodeIdent(p, sname) orelse return null;
            const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            break :blk nullHeritageGuard(p, sname, sup_ctor, sup_null, s) orelse return null;
        } else blk: {
            const sup_cls = nodeIdent(p, sname) orelse return null;
            const sup_proto_raw = nodeMember(p, sup_cls, "prototype") orelse return null;
            const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            break :blk nullHeritageGuard(p, sname, sup_proto_raw, sup_null, s) orelse return null;
        };
        const base_node2: *Node = if (m.is_static) blk: {
            const sup_ctor = nodeIdent(p, sname) orelse return null;
            const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            break :blk nullHeritageGuard(p, sname, sup_ctor, sup_null, s) orelse return null;
        } else blk: {
            const sup_cls = nodeIdent(p, sname) orelse return null;
            const sup_proto_raw = nodeMember(p, sup_cls, "prototype") orelse return null;
            const sup_null = p.makeNode(.null_literal, s, s, .{ .null_literal = {} }) orelse return null;
            break :blk nullHeritageGuard(p, sname, sup_proto_raw, sup_null, s) orelse return null;
        };
        const sup_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "super", .init = base_node } }) orelse return null;
        const sproto_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__sproto__", .init = base_node2 } }) orelse return null;
        const this_node = p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return null;
        const sthis_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__superthis", .init = this_node } }) orelse return null;
        var wb = std.ArrayList(*Node){};
        wb.append(p.arena, sup_decl) catch return null;
        wb.append(p.arena, sproto_decl) catch return null;
        wb.append(p.arena, sthis_decl) catch return null;
        for (m.body) |st| wb.append(p.arena, st) catch return null;
        body = wb.items;
    } else if (m.uses_super_prop) {
        // A BASE class has a home object too (`C.prototype`, or `C` for a static
        // member), so `super.x` is legal in its methods — it just reads through
        // the home object's own [[Prototype]] rather than a named superclass.
        // Only emitted where the body actually mentions `super`.
        const home = homeObjectNode(p, class_name, m.is_static) orelse return null;
        const sproto_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__sproto__", .init = home } }) orelse return null;
        const this_node = p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return null;
        const sthis_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "__superthis", .init = this_node } }) orelse return null;
        var wb = std.ArrayList(*Node){};
        wb.append(p.arena, sproto_decl) catch return null;
        wb.append(p.arena, sthis_decl) catch return null;
        for (m.body) |st| wb.append(p.arena, st) catch return null;
        body = wb.items;
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
            // A private *instance* method is created once here but installed on
            // each instance by the constructor (see PrivInstance), so bind the
            // function rather than adding it to the prototype. Static private
            // methods still live on the constructor object.
            if (hidden) |hv| {
                return p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = hv, .init = fn_expr } });
            }
            const lhs = markPrivateDefine(nodeMember(p, target, m.name) orelse return null, true);
            const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = fn_expr } }) orelse return null;
            return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
        }
        const key_val = if (m.key_var) |kv| (nodeIdent(p, kv) orelse return null) else if (m.computed_key) |k| k else (p.makeNode(.string_literal, s, s, .{ .string_literal = m.name }) orelse return null);
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

    // A private instance accessor half is bound here and merged into a single
    // private element per instance by `__privInstallAcc__`.
    if (hidden) |hv| {
        return p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = hv, .init = fn_expr } });
    }

    // Accessor: Object.defineProperty(target, key, { get|set: fn, configurable: true, enumerable: false })
    const key_val = if (m.key_var) |kv| (nodeIdent(p, kv) orelse return null) else if (m.computed_key) |k| k else (p.makeNode(.string_literal, s, s, .{ .string_literal = m.name }) orelse return null);
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

    // The class name has TWO bindings: the immutable *inner* binding (visible to
    // methods, static/instance field initializers) and the mutable *outer*
    // declaration binding in the enclosing scope. The class body is wrapped in an
    // IIFE whose local `let <ClassName>` is the inner binding, and the outer
    // declaration `let <ClassName> = <iife>()` receives the constructed class. A
    // user reassignment of the outer name (`C = null`) then no longer affects
    // what the class body sees — matching ClassDefinitionEvaluation's classScope.
    //
    // Context-sensitive evaluations (the `extends` heritage and computed key
    // names, which may contain yield/await) are routed to `prelude` and emitted
    // BEFORE the IIFE, in the enclosing execution context.
    var prelude = std.ArrayList(*Node){};
    var out = emitClassStatements(p, .{
        .class_name = class_name,
        .ctor_fn_name = class_name,
    }, heritage, parsed, start, &prelude) orelse return null;
    attachPrivScope(p.arena, out.items, parsed.priv_names);

    const ret_id = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    const ret_stmt = p.makeNode(.return_stmt, start, start, .{ .return_stmt = ret_id }) orelse return null;
    out.append(p.arena, ret_stmt) catch return null;
    const fn_expr = p.makeNode(.function_expr, start, p.current.start, .{
        .function_expr = .{ .name = null, .params = &[_][]const u8{}, .body = out.items, .is_arrow = false },
    }) orelse return null;
    const iife = p.makeNode(.call_expr, start, p.current.start, .{
        .call_expr = .{ .callee = fn_expr, .args = &[_]*Node{} },
    }) orelse return null;
    const class_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = .let, .name = class_name, .init = iife },
    }) orelse return null;

    if (prelude.items.len == 0) return class_decl;
    // Transparent container: the prelude helpers and the `let <ClassName>` binding
    // belong to the enclosing scope (not a fresh block), so a following
    // `class B extends A` still resolves `A`.
    prelude.append(p.arena, class_decl) catch return null;
    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = prelude.items, .lexical_scope = false },
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
    const h_raw = p.parseCallMemberExpr() orelse return null;
    // `__checkHeritage__(<expr>)` — ClassDefinitionEvaluation rejects a heritage
    // value that is neither `null` nor a constructor, and does so *before* the
    // `.prototype` read below, so `class C extends (() => {})` throws a TypeError
    // rather than tripping a `prototype` getter on the arrow.
    const h = blk: {
        const s = p.current.start;
        const callee = nodeIdent(p, "__checkHeritage__") orelse return null;
        var cargs = std.ArrayList(*Node){};
        cargs.append(p.arena, h_raw) catch return null;
        break :blk p.makeNode(.call_expr, s, s, .{
            .call_expr = .{ .callee = callee, .args = cargs.items },
        }) orelse return null;
    };
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

/// One private instance method/accessor group, hoisted out of the class body.
///
/// A private method is NOT a prototype property: InitializeInstanceElements
/// adds it to each *instance* (PrivateMethodOrAccessorAdd), which is what makes
/// `this.#m()` throw when the instance has not been branded yet — notably
/// inside a base constructor that runs before the derived `super()` returns.
/// The function object is still created once per class evaluation, so it is
/// hoisted into a hidden binding here and only *installed* per instance.
///
/// `get #x` and `set #x` form a SINGLE private element, so the two halves share
/// one entry and one install call.
const PrivInstance = struct {
    /// Mangled PrivateEnvironment key ("#x\x01N").
    key: []const u8,
    /// Hidden binding holding the method function, or null for an accessor.
    method_var: ?[]const u8 = null,
    getter_var: ?[]const u8 = null,
    setter_var: ?[]const u8 = null,
};

/// Assign a hidden binding name to every private instance method/accessor in
/// `members`, grouping `get #x`/`set #x` under one entry. Returns the entries in
/// source order; `hidden_of[i]` is the binding name for `members[i]` (null when
/// that member is not a private instance element and so installs normally).
fn planPrivInstance(
    p: *Parser,
    members: []const ClassMember,
    hidden_of: [][]const u8,
) ?[]PrivInstance {
    var out = std.ArrayList(PrivInstance){};
    for (members, 0..) |m, i| {
        hidden_of[i] = "";
        if (m.is_static or m.computed_key != null) continue;
        if (!isPrivateName(m.name)) continue;
        const hidden = std.fmt.allocPrint(p.arena, "__pm{d}__", .{p.param_destruct_counter}) catch return null;
        p.param_destruct_counter += 1;
        hidden_of[i] = hidden;
        // Reuse the existing entry for the other half of a get/set pair.
        var found = false;
        for (out.items) |*e| {
            if (!std.mem.eql(u8, e.key, m.name)) continue;
            found = true;
            switch (m.accessor) {
                .none => e.method_var = hidden,
                .get => e.getter_var = hidden,
                .set => e.setter_var = hidden,
            }
        }
        if (found) continue;
        var e = PrivInstance{ .key = m.name };
        switch (m.accessor) {
            .none => e.method_var = hidden,
            .get => e.getter_var = hidden,
            .set => e.setter_var = hidden,
        }
        out.append(p.arena, e) catch return null;
    }
    return out.items;
}

/// The per-instance install statements for `plan`, targeting `target` (`this`
/// for a base class, `__superthis` for a derived one). Methods go through
/// DEFINE_PRIVATE (`target.#m = __pmN`); accessors need the merged-pair helper.
fn appendPrivInstanceInstalls(
    p: *Parser,
    list: *std.ArrayList(*Node),
    plan: []const PrivInstance,
    target_name: ?[]const u8,
) bool {
    const s = p.current.start;
    for (plan) |e| {
        const target: *Node = if (target_name) |n|
            (nodeIdent(p, n) orelse return false)
        else
            (p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return false);
        if (e.method_var) |mv| {
            const lhs = markPrivateDefine(nodeMember(p, target, e.key) orelse return false, true);
            const rhs = nodeIdent(p, mv) orelse return false;
            const assign = p.makeNode(.assignment_expr, s, s, .{
                .assignment_expr = .{ .op = .assign, .target = lhs, .value = rhs },
            }) orelse return false;
            const st = p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign }) orelse return false;
            list.append(p.arena, st) catch return false;
            continue;
        }
        const callee = nodeIdent(p, "__privInstallAcc__") orelse return false;
        const key_node = p.makeNode(.string_literal, s, s, .{ .string_literal = e.key }) orelse return false;
        const undef = struct {
            fn go(pp: *Parser, at: u32) ?*Node {
                return pp.makeNode(.undefined_literal, at, at, .{ .undefined_literal = {} });
            }
        }.go;
        const g: *Node = if (e.getter_var) |gv| (nodeIdent(p, gv) orelse return false) else (undef(p, s) orelse return false);
        const st_fn: *Node = if (e.setter_var) |sv| (nodeIdent(p, sv) orelse return false) else (undef(p, s) orelse return false);
        var args = std.ArrayList(*Node){};
        args.append(p.arena, target) catch return false;
        args.append(p.arena, key_node) catch return false;
        args.append(p.arena, g) catch return false;
        args.append(p.arena, st_fn) catch return false;
        const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return false;
        const st = p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call }) orelse return false;
        list.append(p.arena, st) catch return false;
    }
    return true;
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
    // When non-null, the context-sensitive evaluations — the ClassHeritage
    // (`extends <expr>`) and the computed ClassElementName keys — are routed here
    // instead of into `out`. These may contain `yield`/`await` and must run in the
    // enclosing execution context; the declaration form emits them OUTSIDE the
    // inner-name-binding IIFE for that reason. Null keeps them inline (expression
    // form, whose IIFE already is the enclosing evaluation).
    prelude: ?*std.ArrayList(*Node),
) ?std.ArrayList(*Node) {
    const class_name = form.class_name;
    const super_name = heritage.super_name;
    const heritage_expr = heritage.expr;
    const ctor_params: [][]const u8 = parsed.ctor_params;
    const ctor_rest: ?[]const u8 = parsed.ctor_rest;
    var ctor_body: []*Node = parsed.ctor_body;
    const members = parsed.members;
    const fields = parsed.fields;

    // Flag direct evals inside each field initializer so PerformEval applies the
    // "eval inside initializer" ContainsArguments early error. Done here (before
    // the initializers are desugared into constructor assignments and lose their
    // field-initializer identity) and for every class, private names or not.
    for (fields) |f| markInitializerEvalCalls(f.init);

    // Private instance methods/accessors are installed per instance, not on the
    // prototype (see PrivInstance). Plan the hidden bindings now: the member
    // loop below defines them, and the constructor installs them.
    const hidden_of = p.arena.alloc([]const u8, members.len) catch return null;
    const priv_plan = planPrivInstance(p, members, hidden_of) orelse return null;

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
    // Likewise pre-evaluate computed method/accessor keys (`get [expr]() {}`).
    // Evaluating them inline inside the body would place a `[yield]`/`[await]`
    // key in the wrong (non-generator/non-async) execution context once the body
    // is wrapped in the inner-name-binding IIFE; the pre-eval runs in the
    // enclosing context via the prelude and emitClassMember reads `key_var`.
    // Only for the IIFE-wrapped declaration form (prelude != null); the
    // expression form keeps its existing inline evaluation order.
    if (prelude != null) {
        for (parsed.members) |*m| {
            const k = m.computed_key orelse continue;
            const kv = std.fmt.allocPrint(p.arena, "__ck_{d}__", .{p.param_destruct_counter}) catch return null;
            p.param_destruct_counter += 1;
            m.key_var = kv;
            const helper = nodeIdent(p, "__toPropertyKey__") orelse return null;
            var ck_args = std.ArrayList(*Node){};
            ck_args.append(p.arena, k) catch return null;
            const call = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = helper, .args = ck_args.items } }) orelse return null;
            const decl = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = .var_, .name = kv, .init = call } }) orelse return null;
            key_evals.append(p.arena, decl) catch return null;
        }
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
            // Private instance methods need the same `__superthis` capture as
            // fields: they are installed on the object the parent ctor returned.
            if (has_instance_field or priv_plan.len > 0) {
                // Derived class with instance fields: capture the parent result in
                // `__superthis`, install the fields on it (DefineOwnProperty), and
                // let the constructor wrapper below emit `return __superthis;`.
                const id_st = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
                const assign = p.makeNode(.assignment_expr, start, start, .{
                    .assignment_expr = .{ .op = .assign, .target = id_st, .value = rc_call },
                }) orelse return null;
                const assign_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign }) orelse return null;
                body.append(p.arena, assign_stmt) catch return null;
                if (!appendDerivedInstanceFields(p, &body, fields, priv_plan)) return null;
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
        // Heritage may contain yield/await → keep it in the enclosing context.
        (prelude orelse &out).append(p.arena, hv) catch return null;
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
        // `var __supernt__ = __new_target__;` — capture the constructor's own
        // NewTarget into a distinctly-named local. The `super()` helper below is
        // a real function whose own call binds a fresh `__new_target__` (undefined
        // for a plain call), which would shadow the constructor's via closure. A
        // uniquely-named capture is read unshadowed through the closure chain, so
        // NewTarget forwards correctly down a multi-level super chain.
        {
            const cap_init = p.makeNode(.identifier, start, start, .{ .identifier = "__new_target__" }) orelse return null;
            const cap_decl = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "__supernt__", .init = cap_init },
            }) orelse return null;
            ctor_stmts.append(p.arena, cap_decl) catch return null;
        }
        // `var __checkthis__ = function () {
        //     if (__superthis === undefined) throw new ReferenceError(...);
        //     return __superthis;
        //  };`
        // Each `this` read in the body is rewritten to `__checkthis__()`, giving
        // the derived-constructor `this` TDZ: reading it before `super()` throws.
        {
            const guard = makeSuperthisGuard(p, start, .strict_eq, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor") orelse return null;
            const ret_id = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
            const ret_st = p.makeNode(.return_stmt, start, start, .{ .return_stmt = ret_id }) orelse return null;
            var ck_body = std.ArrayList(*Node){};
            ck_body.append(p.arena, guard) catch return null;
            ck_body.append(p.arena, ret_st) catch return null;
            const ck_fn = p.makeNode(.function_expr, start, start, .{
                .function_expr = .{
                    .name = null,
                    .params = &[_][]const u8{},
                    .param_defaults = &[_]?*Node{},
                    .rest_param = null,
                    .body = ck_body.items,
                    .is_arrow = false,
                    .is_strict = false,
                    .requires_super = false,
                },
            }) orelse return null;
            const ck_decl = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "__checkthis__", .init = ck_fn },
            }) orelse return null;
            ctor_stmts.append(p.arena, ck_decl) catch return null;
        }
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
        // `__supernt__ || ClassName` — the captured NewTarget (see above), read
        // through the helper's closure without shadowing.
        const id_nt = makeCapturedNtNode(p, start, class_name) orelse return null;
        var rc_args = std.ArrayList(*Node){};
        rc_args.append(p.arena, id_super_p) catch return null;
        rc_args.append(p.arena, id_args) catch return null;
        rc_args.append(p.arena, id_nt) catch return null;
        const rc_call = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = rc_callee, .args = rc_args.items },
        }) orelse return null;
        // `var __superresult__ = Reflect.construct(Super, arguments, nt);` — the
        // parent [[Construct]] runs FIRST (§SuperCall: Construct precedes
        // BindThisValue), so its side effects happen even on a second super().
        const tmp_decl = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = "__superresult__", .init = rc_call },
        }) orelse return null;
        // `__superthis = __superresult__;` — bind `this` to the constructed value.
        const id_st_t = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
        const id_res = p.makeNode(.identifier, start, start, .{ .identifier = "__superresult__" }) orelse return null;
        const assign = p.makeNode(.assignment_expr, start, start, .{
            .assignment_expr = .{ .op = .assign, .target = id_st_t, .value = id_res },
        }) orelse return null;
        const assign_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign }) orelse return null;
        const id_st_r = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
        const helper_ret = p.makeNode(.return_stmt, start, start, .{ .return_stmt = id_st_r }) orelse return null;
        var helper_body = std.ArrayList(*Node){};
        helper_body.append(p.arena, tmp_decl) catch return null;
        // `if (__superthis !== undefined) throw new ReferenceError(...);` — a
        // second `super()` when `this` is already initialized is a ReferenceError
        // (BindThisValue: [[thisValue]] must be uninitialized). This runs AFTER
        // the parent Construct above, so its side effects (e.g. the base
        // constructor being invoked) are observable even when the guard throws.
        {
            const twice_guard = makeSuperthisGuard(p, start, .strict_neq, "Super constructor may only be called once") orelse return null;
            helper_body.append(p.arena, twice_guard) catch return null;
        }
        helper_body.append(p.arena, assign_stmt) catch return null;
        // Install instance fields on `__superthis` right after the parent ctor
        // returns — the spec point where a derived class initializes its fields.
        if (!appendDerivedInstanceFields(p, &helper_body, fields, priv_plan)) return null;
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
        for (ctor_body) |st| rewriteThisToSuperThis(p, st);
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
        ctor_body_effective = prependInstanceFields(p, class_name, ctor_body_effective, fields, priv_plan, parsed.ctor_uses_super) orelse return null;
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
            // Class bodies are always strict mode code (§11.2.2), regardless of
            // a "use strict" directive.
            .is_strict = true,
            .is_class = true,
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
    // Computed ClassElementName keys may contain yield/await → keep them in the
    // enclosing context (prelude) when the caller wraps the body in an IIFE. The
    // static/instance field initializers inside read the resulting `__ck_N__`
    // bindings through the closure.
    for (key_evals.items) |kd| (prelude orelse &out).append(p.arena, kd) catch return null;

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
        // Object.setPrototypeOf(ClassName.prototype, Super.prototype)
        //
        // A class constructor's own `.prototype` is non-writable
        // (MakeConstructor, writablePrototype=false), so we reparent the
        // existing auto-created prototype object rather than replacing it via
        // `ClassName.prototype = Object.create(...)` (a plain assignment that
        // would now silently fail). The auto prototype already carries the
        // non-enumerable `constructor` back-link.
        const id_class = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const id_proto = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const lhs_proto = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_class, .property = id_proto, .computed = false },
        }) orelse return null;

        const id_obj = p.makeNode(.identifier, start, start, .{ .identifier = "Object" }) orelse return null;
        const id_setp = p.makeNode(.identifier, start, start, .{ .identifier = "setPrototypeOf" }) orelse return null;
        const callee_setp = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_obj, .property = id_setp, .computed = false },
        }) orelse return null;

        const id_super = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
        const id_super_proto = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const super_proto = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_super, .property = id_super_proto, .computed = false },
        }) orelse return null;

        // `extends null` → the prototype's parent is null.
        const null_proto = p.makeNode(.null_literal, start, start, .{ .null_literal = {} }) orelse return null;
        const parent_arg = nullHeritageGuard(p, sname, super_proto, null_proto, start) orelse return null;
        var sp2_args = std.ArrayList(*Node){};
        sp2_args.append(p.arena, lhs_proto) catch return null;
        sp2_args.append(p.arena, parent_arg) catch return null;
        const sp2_call = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = callee_setp, .args = sp2_args.items },
        }) orelse return null;
        const stmt_proto = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = sp2_call }) orelse return null;
        out.append(p.arena, stmt_proto) catch return null;
    }

    // Constructor back-link, defined non-enumerable (see makeCtorBackLink).
    const stmt_ctor = makeCtorBackLink(p, class_name) orelse return null;
    out.append(p.arena, stmt_ctor) catch return null;

    // prototype + static methods/accessors
    for (members, 0..) |m, mi| {
        const hidden: ?[]const u8 = if (hidden_of[mi].len > 0) hidden_of[mi] else null;
        const stmt = emitClassMember(p, class_name, super_name, m, hidden) orelse return null;
        out.append(p.arena, stmt) catch return null;
    }

    // static fields: `ClassName.<name> = <init>` after the class is defined.
    for (fields) |f| {
        if (!f.is_static) continue;
        const stmt = makeStaticFieldInit(p, class_name, super_name, f) orelse return null;
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
    }, heritage, parsed, start, null) orelse return null;
    attachPrivScope(p.arena, out.items, parsed.priv_names);

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
    var rest_param: ?[]const u8 = null;
    while (!p.check(.right_paren) and !p.check(.eof) and !p.had_error) {
        var is_rest = false;
        if (p.match(.ellipsis)) is_rest = true;
        // Destructuring parameter: `[...]` / `{...}` binding pattern (with an
        // optional `= default`). Desugared to a synthetic `__param_N` name plus
        // `let` decls prepended to the body, mirroring the arrow-param path.
        if (!is_rest and (p.check(.left_bracket) or p.check(.left_brace))) {
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
        // `yield` is a valid BindingIdentifier for a parameter in sloppy-mode
        // code outside a generator (`function m(yield){}`); the strict / generator
        // cases keep the reserved-word rejection below.
        const yield_as_param = p.check(.kw_yield) and !p.strict and !p.in_generator_function;
        const param_tok = if (yield_as_param) p.advance() else (p.expect(.identifier) orelse return null);
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
    // BoundNames of destructuring parameters live in the desugared prelude as
    // `let <name> = …` decls (with `__`-prefixed synthetic temps interspersed).
    // Harvest the user-visible names so duplicates *within* a pattern (`[x,x]`)
    // and *across* params (`x,[x]`) are detected — these are always errors, even
    // in a sloppy list, because such a list is non-simple.
    for (param_prelude.items) |st| {
        if (st.kind == .var_decl) {
            const nm = st.data.var_decl.name;
            if (!std.mem.startsWith(u8, nm, "__")) {
                // A destructuring pattern may not bind `eval`/`arguments` (nor any
                // other future reserved word) in strict-mode code.
                if (!parser_file.checkStrictBindingName(p, nm, p.current.line, p.current.column)) return null;
                bound.append(p.arena, nm) catch {
                    p.had_error = true;
                    return null;
                };
            }
        }
    }
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
            if (defaults.items[i]) |dexpr_raw| {
                // SingleNameBinding with an anonymous-function Initializer names the
                // function after the parameter (`function(p = () => {})` → "p").
                // The default expr sits in the conditional's `alternate`, so wrap
                // it in `__nameFn__(fn, "p")` to preserve that name.
                const dexpr = blk: {
                    if (!isAnonFnDef(dexpr_raw)) break :blk dexpr_raw;
                    const namer = nodeIdent(p, "__nameFn__") orelse return null;
                    const key = p.makeNode(.string_literal, 0, 0, .{ .string_literal = orig }) orelse return null;
                    var cargs = std.ArrayList(*Node){};
                    cargs.append(p.arena, dexpr_raw) catch return null;
                    cargs.append(p.arena, key) catch return null;
                    break :blk p.makeNode(.call_expr, 0, 0, .{ .call_expr = .{ .callee = namer, .args = cargs.items } }) orelse return null;
                };
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
        // IsSimpleParameterList is false when the list has a rest element, a
        // default value, or a destructuring pattern. `simple` captured that
        // above (before the default-param TDZ desugar rewrote `defaults`).
        .non_simple = !simple,
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
    var body_has_use_strict = false;
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
                    body_has_use_strict = true;
                }
            } else in_prologue = false;
        }
        p.drainExtraStmts(&body);
    }
    p.applyLiveBindings(body.items, li_start, le_start, la_start);
    // §15.2.1: a "use strict" prologue makes the *whole* function strict, which
    // retroactively outlaws a duplicate parameter name; and a body-level
    // `let`/`const` may never redeclare a parameter (LexicallyDeclaredNames of
    // the FunctionStatementList must be disjoint from BoundNames of the
    // FormalParameters). Both are only decidable once the body has been read.
    if (!p.had_error) {
        // A "use strict" prologue also retroactively outlaws a parameter bound to
        // `eval`/`arguments` or a future reserved word (§15.2.1). Only meaningful
        // when the body introduced strictness that the params weren't parsed under.
        if (body_has_use_strict and !saved_strict) {
            for (param_names) |pn| {
                if (parser_file.isStrictReservedWord(pn)) {
                    p.had_error = true;
                    p.error_info = parser_file.ParseError{
                        .message = "unexpected strict-mode reserved word as parameter name",
                        .line = p.current.line,
                        .column = p.current.column,
                    };
                    break;
                }
            }
        }
    }
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
    // Publish this body's own "use strict" prologue flag for the caller's
    // checkStrictDirectiveSimpleParams (§15.2.1: a non-simple parameter list may
    // not be combined with a "use strict" body directive). Set at the end so a
    // nested function body that already returned doesn't leave a stale value.
    p.pending_body_use_strict = body_has_use_strict;
    p.fn_nesting_depth -= 1;
    _ = p.expect(.right_brace) orelse return null;
    // Explicit resource management: wrap the user body in the `using` disposal
    // desugar (a no-op unless it contains `using`/`await using` declarations)
    // before the parameter prelude / generator marker is prepended, so disposal
    // covers exactly the FunctionBody StatementList.
    const body_items = stmt_mod.desugarUsingScope(p, body.items, p.current.start);
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
        combined.appendSlice(p.arena, body_items) catch {
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
        combined.appendSlice(p.arena, body_items) catch {
            p.had_error = true;
            return null;
        };
        return combined.items;
    }
    return body_items;
}
