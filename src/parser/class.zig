// SPDX-License-Identifier: Apache-2.0
//! Class and function-body parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const ast = @import("./ast.zig");
const Node = ast.Node;

pub const ParamParse = parser_file.ParamParse;

pub fn parseClassDeclStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // class
    const name_tok = p.expect(.identifier) orelse return null;
    const class_name = name_tok.value_str;

    var super_name: ?[]const u8 = null;
    if (p.match(.kw_extends)) {
        const s = p.expect(.identifier) orelse return null;
        super_name = s.value_str;
    }

    _ = p.expect(.left_brace) orelse return null;
    var ctor_params: [][]const u8 = &[_][]const u8{};
    var ctor_body: []*Node = &[_]*Node{};
    var methods = std.ArrayList(struct { name: []const u8, params: [][]const u8, body: []*Node }){};
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        if (!p.check(.identifier)) {
            _ = p.advance();
            continue;
        }
        const mname_tok = p.advance();
        const mname = mname_tok.value_str;
        const mparams = p.parseFunctionParams() orelse return null;
        const mbody = p.parseFunctionBody() orelse return null;
        if (std.mem.eql(u8, mname, "constructor")) {
            ctor_params = mparams.params;
            ctor_body = mbody;
        } else {
            methods.append(p.arena, .{ .name = mname, .params = mparams.params, .body = mbody }) catch return null;
        }
    }
    _ = p.expect(.right_brace) orelse return null;

    if (ctor_body.len == 0) {
        if (super_name != null) {
            // Derived class default constructor: super.call(this)
            const id_super = p.makeNode(.identifier, start, start, .{ .identifier = "super" }) orelse return null;
            const id_call = p.makeNode(.identifier, start, start, .{ .identifier = "call" }) orelse return null;
            const super_call = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_super, .property = id_call, .computed = false },
            }) orelse return null;
            const this_expr = p.makeNode(.this_expr, start, start, .{ .this_expr = {} }) orelse return null;
            var super_args = std.ArrayList(*Node){};
            super_args.append(p.arena, this_expr) catch return null;
            const super_call_expr = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = super_call, .args = super_args.items },
            }) orelse return null;
            const super_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = super_call_expr }) orelse return null;
            var body = std.ArrayList(*Node){};
            body.append(p.arena, super_stmt) catch return null;
            ctor_body = body.items;
        } else {
            ctor_body = &[_]*Node{};
        }
    }

    var out = std.ArrayList(*Node){};

    var ctor_body_effective = ctor_body;
    if (super_name) |sname| {
        // Allow `super(...)` in subclass constructors by binding local `super`.
        const id_super_ctor = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
        const super_decl = p.makeNode(.var_decl, start, start, .{
            .var_decl = .{ .kind = .var_, .name = "super", .init = id_super_ctor },
        }) orelse return null;
        var ctor_stmts = std.ArrayList(*Node){};
        ctor_stmts.append(p.arena, super_decl) catch return null;
        for (ctor_body) |st| ctor_stmts.append(p.arena, st) catch return null;
        ctor_body_effective = ctor_stmts.items;
    }

    // var ClassName = function ClassName(...) { ... }
    const ctor_fn = p.makeNode(.function_expr, start, p.current.start, .{
        .function_expr = .{
            .name = class_name,
            .params = ctor_params,
            .param_defaults = &[_]?*Node{},
            .rest_param = null,
            .body = ctor_body_effective,
            .is_arrow = false,
            .is_strict = parser_file.hasUseStrict(ctor_body_effective),
            .requires_super = super_name != null,
        },
    }) orelse return null;
    const ctor_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = .var_, .name = class_name, .init = ctor_fn },
    }) orelse return null;
    out.append(p.arena, ctor_decl) catch return null;

    if (super_name) |sname| {
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

    // prototype methods
    for (methods.items) |m| {
        const id_class = p.makeNode(.identifier, start, start, .{ .identifier = class_name }) orelse return null;
        const id_proto = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
        const class_proto = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = id_class, .property = id_proto, .computed = false },
        }) orelse return null;
        const id_method = p.makeNode(.identifier, start, start, .{ .identifier = m.name }) orelse return null;
        const lhs = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = class_proto, .property = id_method, .computed = false },
        }) orelse return null;
        var method_body = m.body;
        if (super_name) |sname| {
            // Allow `super.foo()` in subclass methods by binding `super = Super.prototype`.
            const id_super_cls = p.makeNode(.identifier, start, start, .{ .identifier = sname }) orelse return null;
            const id_proto2 = p.makeNode(.identifier, start, start, .{ .identifier = "prototype" }) orelse return null;
            const super_proto2 = p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = id_super_cls, .property = id_proto2, .computed = false },
            }) orelse return null;
            const super_decl2 = p.makeNode(.var_decl, start, start, .{
                .var_decl = .{ .kind = .var_, .name = "super", .init = super_proto2 },
            }) orelse return null;
            var body_with_super = std.ArrayList(*Node){};
            body_with_super.append(p.arena, super_decl2) catch return null;
            for (m.body) |st| body_with_super.append(p.arena, st) catch return null;
            method_body = body_with_super.items;
        }
        const fn_expr = p.makeNode(.function_expr, start, p.current.start, .{
            .function_expr = .{
                .name = null,
                .params = m.params,
                .param_defaults = &[_]?*Node{},
                .rest_param = null,
                .body = method_body,
                .is_arrow = false,
                .is_strict = parser_file.hasUseStrict(method_body),
            },
        }) orelse return null;
        const assign = p.makeNode(.assignment_expr, start, p.current.start, .{
            .assignment_expr = .{ .op = .assign, .target = lhs, .value = fn_expr },
        }) orelse return null;
        const stmt = p.makeNode(.expr_stmt, start, p.current.start, .{ .expr_stmt = assign }) orelse return null;
        out.append(p.arena, stmt) catch return null;
    }

    if (out.items.len == 1) return out.items[0];
    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = out.items },
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
    var body = std.ArrayList(*Node){};
    const li_start = p.live_imports.items.len;
    const le_start = p.live_exports.items.len;
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        const s = p.parseStatement() orelse break;
        body.append(p.arena, s) catch {
            p.had_error = true;
            break;
        };
        p.drainExtraStmts(&body);
    }
    p.applyLiveBindings(body.items, li_start, le_start);
    _ = p.expect(.right_brace) orelse return null;
    return body.items;
}
