// SPDX-License-Identifier: Apache-2.0
//! Class and function-body parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const ast = @import("./ast.zig");
const Node = ast.Node;

pub const ParamParse = parser_file.ParamParse;

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
    accessor: AccessorKind = .none,
    name: []const u8 = "",
    computed_key: ?*Node = null,
    params: [][]const u8 = &[_][]const u8{},
    rest_param: ?[]const u8 = null,
    body: []*Node = &[_]*Node{},
};

/// A parsed class field (`name = init;`, `#name = init;`, `[expr] = init;`,
/// or `static name = init;`). Methods are kept separately in ClassMember.
const ClassField = struct {
    is_static: bool = false,
    name: []const u8 = "",
    computed_key: ?*Node = null,
    init: ?*Node = null,
};

const ClassBodyParse = struct {
    ctor_params: [][]const u8 = &[_][]const u8{},
    ctor_rest: ?[]const u8 = null,
    ctor_body: []*Node = &[_]*Node{},
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
        } else if (p.check(.identifier) or p.check(.string) or p.check(.number)) {
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

        const mparams = p.parseFunctionParams() orelse return null;
        const mbody = p.parseFunctionBody() orelse return null;

        if (!is_static and accessor == .none and computed_key == null and std.mem.eql(u8, name, "constructor")) {
            res.ctor_params = mparams.params;
            res.ctor_rest = mparams.rest_param;
            res.ctor_body = mbody;
        } else {
            members.append(p.arena, .{
                .is_static = is_static,
                .accessor = accessor,
                .name = name,
                .computed_key = computed_key,
                .params = mparams.params,
                .rest_param = mparams.rest_param,
                .body = mbody,
            }) catch return null;
        }
    }
    _ = p.expect(.right_brace) orelse return null;
    res.members = members.items;
    res.fields = fields.items;
    return res;
}

/// Build an instance-field initializer statement: `this.<name> = <init>` (or
/// `this[<computed>] = <init>`), with `undefined` when there is no initializer.
/// A private name (`#x`) is emitted as a non-computed member, so it resolves to
/// the property key "#x" — matching how `obj.#x` reads are parsed.
fn makeInstanceFieldInit(p: *Parser, f: ClassField) ?*Node {
    const s = p.current.start;
    const this_node = p.makeNode(.this_expr, s, s, .{ .this_expr = {} }) orelse return null;
    const lhs = if (f.computed_key) |k|
        (p.makeNode(.member_expr, s, s, .{ .member_expr = .{ .object = this_node, .property = k, .computed = true } }) orelse return null)
    else
        (nodeMember(p, this_node, f.name) orelse return null);
    const val = f.init orelse (p.makeNode(.undefined_literal, s, s, .{ .undefined_literal = {} }) orelse return null);
    const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = val } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
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
    const s = p.current.start;
    const superthis = nodeIdent(p, "__superthis") orelse return null;
    const val = f.init orelse (p.makeNode(.undefined_literal, s, s, .{ .undefined_literal = {} }) orelse return null);

    // Private fields: `__superthis.#name = init` (member assignment → PrivateFieldAdd).
    if (f.computed_key == null and f.name.len > 0 and f.name[0] == '#') {
        const lhs = nodeMember(p, superthis, f.name) orelse return null;
        const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = val } }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
    }

    // Public fields: Object.defineProperty(__superthis, key,
    //   { value: init, writable: true, enumerable: true, configurable: true }).
    const key_val = if (f.computed_key) |k| k else (p.makeNode(.string_literal, s, s, .{ .string_literal = f.name }) orelse return null);
    const t1 = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null;
    const t2 = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null;
    const t3 = p.makeNode(.bool_literal, s, s, .{ .bool_literal = true }) orelse return null;
    var props = std.ArrayList(ast.ObjectProp){};
    props.append(p.arena, .{ .key = "value", .value = val }) catch return null;
    props.append(p.arena, .{ .key = "writable", .value = t1 }) catch return null;
    props.append(p.arena, .{ .key = "enumerable", .value = t2 }) catch return null;
    props.append(p.arena, .{ .key = "configurable", .value = t3 }) catch return null;
    const desc = p.makeNode(.object_literal, s, s, .{ .object_literal = .{ .properties = props.items } }) orelse return null;

    const id_obj = nodeIdent(p, "Object") orelse return null;
    const callee = nodeMember(p, id_obj, "defineProperty") orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, superthis) catch return null;
    args.append(p.arena, key_val) catch return null;
    args.append(p.arena, desc) catch return null;
    const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
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
    const cls = nodeIdent(p, class_name) orelse return null;
    const lhs = if (f.computed_key) |k|
        (p.makeNode(.member_expr, s, s, .{ .member_expr = .{ .object = cls, .property = k, .computed = true } }) orelse return null)
    else
        (nodeMember(p, cls, f.name) orelse return null);
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
    const val = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = call_member, .args = call_args } }) orelse return null;

    const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = val } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
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
            const sup_proto = nodeMember(p, sup_cls, "prototype") orelse return null;
            const sup_decl = p.makeNode(.var_decl, s, s, .{ .var_decl = .{ .kind = .var_, .name = "super", .init = sup_proto } }) orelse return null;
            // Bindings used by `super.PROP = V` desugar (rewriteSuperPropAssign):
            // `__sproto__` is the parent prototype (Set base) and `__superthis`
            // the Receiver — here `this`, the method's receiver.
            const sup_cls2 = nodeIdent(p, sname) orelse return null;
            const sup_proto2 = nodeMember(p, sup_cls2, "prototype") orelse return null;
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

    const fn_expr = p.makeNode(.function_expr, s, s, .{ .function_expr = .{
        .name = null,
        .params = m.params,
        .rest_param = m.rest_param,
        .body = body,
        .is_arrow = false,
    } }) orelse return null;

    const target = if (m.is_static)
        (nodeIdent(p, class_name) orelse return null)
    else
        (nodeMember(p, nodeIdent(p, class_name) orelse return null, "prototype") orelse return null);

    if (m.accessor == .none) {
        const lhs = if (m.computed_key) |k|
            (p.makeNode(.member_expr, s, s, .{ .member_expr = .{ .object = target, .property = k, .computed = true } }) orelse return null)
        else
            (nodeMember(p, target, m.name) orelse return null);
        const assign = p.makeNode(.assignment_expr, s, s, .{ .assignment_expr = .{ .op = .assign, .target = lhs, .value = fn_expr } }) orelse return null;
        return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = assign });
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

    const id_obj = nodeIdent(p, "Object") orelse return null;
    const callee = nodeMember(p, id_obj, "defineProperty") orelse return null;
    var args = std.ArrayList(*Node){};
    args.append(p.arena, target) catch return null;
    args.append(p.arena, key_val) catch return null;
    args.append(p.arena, desc) catch return null;
    const call = p.makeNode(.call_expr, s, s, .{ .call_expr = .{ .callee = callee, .args = args.items } }) orelse return null;
    return p.makeNode(.expr_stmt, s, s, .{ .expr_stmt = call });
}

pub fn parseClassDeclStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // class
    const name_tok = p.expect(.identifier) orelse return null;
    const class_name = name_tok.value_str;

    var super_name: ?[]const u8 = null;
    // When the heritage is a non-identifier expression (e.g. `extends fn(await x)`),
    // store it here and emit `var __super__ = <expr>;` before the class body.
    var heritage_expr: ?*Node = null;
    if (p.match(.kw_extends)) {
        const heritage = p.parseCallMemberExpr() orelse return null;
        if (heritage.kind == .identifier) {
            super_name = heritage.data.identifier;
        } else {
            super_name = "__super__";
            heritage_expr = heritage;
        }
    }

    _ = p.expect(.left_brace) orelse return null;
    const parsed = parseClassMembers(p) orelse return null;
    const ctor_params: [][]const u8 = parsed.ctor_params;
    const ctor_rest: ?[]const u8 = parsed.ctor_rest;
    var ctor_body: []*Node = parsed.ctor_body;
    const members = parsed.members;
    const fields = parsed.fields;

    if (ctor_body.len == 0) {
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
            .var_decl = .{ .kind = .var_, .name = "__super__", .init = he },
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
            const sp_proto = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = sp_cls, .property = (p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null), .computed = false },
            }) orelse return null;
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
        for (ctor_body) |st| ctor_stmts.append(p.arena, st) catch return null;
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
            .name = class_name,
            .params = ctor_params,
            .param_defaults = &[_]?*Node{},
            .rest_param = ctor_rest,
            .body = ctor_body_effective,
            .is_arrow = false,
            .is_strict = parser_file.hasUseStrict(ctor_body_effective),
            .requires_super = super_name != null,
        },
    }) orelse return null;
    const ctor_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = .let, .name = class_name, .init = ctor_fn },
    }) orelse return null;
    out.append(p.arena, ctor_decl) catch return null;

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
            const a_sup = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
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

        var args_create = std.ArrayList(*Node){};
        args_create.append(p.arena, super_proto) catch return null;
        const rhs_create = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = callee_create, .args = args_create.items },
        }) orelse return null;

        const assign_proto = p.makeNode(.assignment_expr, start, start, .{
            .assignment_expr = .{ .op = .assign, .target = lhs_proto, .value = rhs_create },
        }) orelse return null;
        const stmt_proto = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_proto }) orelse return null;
        out.append(p.arena, stmt_proto) catch return null;
    }

    // ClassName.prototype.constructor = ClassName
    const id_class_ctor = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    const id_proto_ctor = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
    const class_proto_ctor = p.makeNode(.member_expr, start, start, .{
        .member_expr = .{ .object = id_class_ctor, .property = id_proto_ctor, .computed = false },
    }) orelse return null;
    const id_ctor_name = p.makeNode(.identifier, start, start, .{ .identifier = "constructor" }) orelse return null;
    const ctor_slot = p.makeNode(.member_expr, start, start, .{
        .member_expr = .{ .object = class_proto_ctor, .property = id_ctor_name, .computed = false },
    }) orelse return null;
    const id_class_value = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
    const assign_ctor = p.makeNode(.assignment_expr, start, start, .{
        .assignment_expr = .{ .op = .assign, .target = ctor_slot, .value = id_class_value },
    }) orelse return null;
    const stmt_ctor = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_ctor }) orelse return null;
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

    if (out.items.len == 1) return out.items[0];
    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = out.items },
    });
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

    var super_name: ?[]const u8 = null;
    var heritage_expr: ?*Node = null;
    if (p.match(.kw_extends)) {
        const heritage = p.parseCallMemberExpr() orelse return null;
        if (heritage.kind == .identifier) {
            super_name = heritage.data.identifier;
        } else {
            super_name = "__super__";
            heritage_expr = heritage;
        }
    }

    _ = p.expect(.left_brace) orelse return null;
        const parsed = parseClassMembers(p) orelse return null;
        const ctor_params: [][]const u8 = parsed.ctor_params;
        var ctor_body: []*Node = parsed.ctor_body;
        const members = parsed.members;
        const fields = parsed.fields;

        // If no constructor and derives from something, generate default
        if (ctor_body.len == 0 and super_name != null) {
            const sname = super_name.?;
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
            const ret_stmt = p.makeNode(.return_stmt, start, start, .{ .return_stmt = rc_call }) orelse return null;
            var body = std.ArrayList(*Node){};
            body.append(p.arena, ret_stmt) catch return null;
            ctor_body = body.items;
        }

        // Build constructor body with super() handler for derived classes
        var ctor_body_effective = ctor_body;
        if (super_name) |sname| {
            var out = std.ArrayList(*Node){};
            var ctor_stmts = std.ArrayList(*Node){};
            const st_decl = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "__superthis", .init = null },
            }) orelse return null;
            ctor_stmts.append(p.arena, st_decl) catch return null;
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
            const target = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
            const rc_assign = p.makeNode(.assignment_expr, start, start, .{
                .assignment_expr = .{ .op = .assign, .target = target, .value = rc_call },
            }) orelse return null;
            const rc_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = rc_assign }) orelse return null;
            ctor_stmts.append(p.arena, rc_stmt) catch return null;

            const super_fn_params = p.arena.dupe([]const u8, ctor_params) catch return null;
            const super_fn_body = ctor_stmts.items;
            const super_fn = p.makeNode(.function_expr, start, start, .{
                .function_expr = .{ .name = null, .params = super_fn_params, .body = super_fn_body, .is_arrow = false },
            }) orelse return null;

            const super_binding = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "super", .init = super_fn },
            }) orelse return null;
            out.append(p.arena, super_binding) catch return null;

            for (ctor_body) |stmt| {
                out.append(p.arena, stmt) catch return null;
            }

            const ret_id = p.makeNode(.identifier, start, start, .{ .identifier = "__superthis" }) orelse return null;
            const ret_stmt2 = p.makeNode(.return_stmt, start, start, .{ .return_stmt = ret_id }) orelse return null;
            out.append(p.arena, ret_stmt2) catch return null;
            ctor_body_effective = out.items;
        } else {
            // Base class: instance fields initialize at the start of the ctor.
            ctor_body_effective = prependInstanceFields(p, ctor_body_effective, fields) orelse return null;
        }

        // Emit IIFE wrapper
        const ret_id = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const ret_stmt = p.makeNode(.return_stmt, start, start, .{ .return_stmt = ret_id }) orelse return null;
        var fn_body = std.ArrayList(*Node){};
        if (heritage_expr) |he| {
            const hv = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "__super__", .init = he },
            }) orelse return null;
            fn_body.append(p.arena, hv) catch return null;
        }

        // Named class → ctor name = class_name; anonymous with export-default hint → "default"; else null.
        const ctor_fn_name: ?[]const u8 = if (has_name) class_name else blk: {
            const hint = p.export_default_name_hint;
            p.export_default_name_hint = null;
            break :blk hint;
        };
        const ctor_fn = p.makeNode(.function_expr, start, start, .{
            .function_expr = .{ .name = ctor_fn_name, .params = ctor_params, .body = ctor_body_effective, .is_arrow = false },
        }) orelse return null;
        const ctor_var = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = class_name, .init = ctor_fn },
        }) orelse return null;
        fn_body.append(p.arena, ctor_var) catch return null;

        // Static inheritance: Object.setPrototypeOf(ClassName, Super)
        if (super_name) |sname| {
            const id_o = p.makeNode(.identifier, start, start, .{ .identifier = "Object" }) orelse return null;
            const id_sp = p.makeNode(.identifier, start, start, .{ .identifier = "setPrototypeOf" }) orelse return null;
            const callee_sp = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_o, .property = id_sp, .computed = false },
            }) orelse return null;
            const a_cls = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const a_sup = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            var sp_args = std.ArrayList(*Node){};
            sp_args.append(p.arena, a_cls) catch return null;
            sp_args.append(p.arena, a_sup) catch return null;
            const sp_call = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee_sp, .args = sp_args.items },
            }) orelse return null;
            const sp_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = sp_call }) orelse return null;
            fn_body.append(p.arena, sp_stmt) catch return null;
        }

        // Prototype chain: ClassName.prototype = Object.create(Super.prototype)
        if (super_name) |sname| {
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

            var args_create = std.ArrayList(*Node){};
            args_create.append(p.arena, super_proto) catch return null;
            const rhs_create = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee_create, .args = args_create.items },
            }) orelse return null;

            const assign_proto = p.makeNode(.assignment_expr, start, start, .{
                .assignment_expr = .{ .op = .assign, .target = lhs_proto, .value = rhs_create },
            }) orelse return null;
            const stmt_proto = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_proto }) orelse return null;
            fn_body.append(p.arena, stmt_proto) catch return null;
        }

        // Constructor back-link: ClassName.prototype.constructor = ClassName
        {
            const id_class_ctor = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const id_proto_ctor = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const class_proto_ctor = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_class_ctor, .property = id_proto_ctor, .computed = false },
            }) orelse return null;
            const id_ctor_name = p.makeNode(.identifier, start, start, .{ .identifier = "constructor" }) orelse return null;
            const ctor_slot = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = class_proto_ctor, .property = id_ctor_name, .computed = false },
            }) orelse return null;
            const id_class_value = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
            const assign_ctor = p.makeNode(.assignment_expr, start, start, .{
                .assignment_expr = .{ .op = .assign, .target = ctor_slot, .value = id_class_value },
            }) orelse return null;
            const stmt_ctor = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = assign_ctor }) orelse return null;
            fn_body.append(p.arena, stmt_ctor) catch return null;
        }

        for (members) |m| {
            const stmt = emitClassMember(p, class_name, super_name, m) orelse return null;
            fn_body.append(p.arena, stmt) catch return null;
        }

        // static fields: `ClassName.<name> = <init>` after the class is defined.
        for (fields) |f| {
            if (!f.is_static) continue;
            const stmt = makeStaticFieldInit(p, class_name, f) orelse return null;
            fn_body.append(p.arena, stmt) catch return null;
        }

        fn_body.append(p.arena, ret_stmt) catch return null;

        const fn_expr = p.makeNode(.function_expr, start, p.current.start, .{
            .function_expr = .{ .name = null, .params = &[_][]const u8{}, .body = fn_body.items, .is_arrow = false },
        }) orelse return null;
        return p.makeNode(.call_expr, start, p.current.start, .{
            .call_expr = .{ .callee = fn_expr, .args = &[_]*Node{} },
        });
}

pub fn parseFunctionParams(p: *Parser) ?parser_file.ParamParse {
    _ = p.expect(.left_paren) orelse return null;
    var params = std.ArrayList([]const u8){};
    var defaults = std.ArrayList(?*Node){};
    var saw_rest = false;
    var rest_param: ?[]const u8 = null;
    while (!p.check(.right_paren) and !p.check(.eof) and !p.had_error) {
        var is_rest = false;
        if (p.match(.ellipsis)) is_rest = true;
        const param_tok = p.expect(.identifier) orelse return null;
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
            default_expr = p.parseAssignmentExpr() orelse return null;
        }
        defaults.append(p.arena, default_expr) catch return null;
        if (saw_rest) break;
        if (!p.match(.comma)) break;
    }
    _ = p.expect(.right_paren) orelse return null;
    return parser_file.ParamParse{
        .params = params.items,
        .param_defaults = defaults.items,
        .rest_param = rest_param,
    };
}

pub fn parseFunctionBody(p: *Parser) ?[]*Node {
    _ = p.expect(.left_brace) orelse return null;
    p.fn_nesting_depth += 1;
    // A function body is strict if it inherits strictness from the enclosing
    // code or carries its own "use strict" directive prologue. Restored on exit
    // so a strict function nested in sloppy code doesn't leak strictness back.
    const saved_strict = p.strict;
    var body = std.ArrayList(*Node){};
    const li_start = p.live_imports.items.len;
    const le_start = p.live_exports.items.len;
    const la_start = p.live_export_aliases.items.len;
    var in_prologue = true;
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        const s = p.parseStatement() orelse break;
        body.append(p.arena, s) catch {
            p.had_error = true;
            break;
        };
        if (in_prologue) {
            if (parser_file.directiveOf(s)) |dir| {
                if (std.mem.eql(u8, dir, "use strict")) p.strict = true;
            } else in_prologue = false;
        }
        p.drainExtraStmts(&body);
    }
    p.applyLiveBindings(body.items, li_start, le_start, la_start);
    p.strict = saved_strict;
    p.fn_nesting_depth -= 1;
    _ = p.expect(.right_brace) orelse return null;
    return body.items;
}
