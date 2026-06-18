// SPDX-License-Identifier: Apache-2.0
//! Expression-parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const ast = @import("./ast.zig");
const Node = ast.Node;
const prec_mod = @import("./precedence.zig");
const Prec = prec_mod.Prec;
const infixPrec = prec_mod.infixPrec;
const isAssignOp = prec_mod.isAssignOp;

// ---------------------------------------------------------------- expressions ---

/// Continue parsing an expression that started with an identifier node already parsed.
pub fn parseExprFromIdent(p: *Parser, ident: *Node) ?*Node {
    // We have the identifier node. Check for assignment or other binary/postfix ops.
    var base: *Node = ident;
    var saw_optional = false;
    // Handle postfix member access / calls.
    while (true) {
        if (p.match(.question_dot)) {
            // ES2020 optional chaining: `obj?.prop`, `obj?.[expr]`, `obj?.(args)`.
            saw_optional = true;
            if (p.check(.left_paren)) {
                const args = p.parseArgs() orelse return null;
                base = p.makeNode(.call_expr, base.start, p.current.start, .{
                    .call_expr = .{ .callee = base, .args = args, .optional = true },
                }) orelse return null;
            } else if (p.match(.left_bracket)) {
                const prop = p.parseExpression() orelse return null;
                _ = p.expect(.right_bracket) orelse return null;
                base = p.makeNode(.member_expr, base.start, p.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = true, .optional = true },
                }) orelse return null;
            } else {
                const prop_tok = p.expectIdentifierName() orelse return null;
                const prop = p.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                    .identifier = prop_tok.value_str,
                }) orelse return null;
                base = p.makeNode(.member_expr, base.start, p.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = false, .optional = true },
                }) orelse return null;
            }
        } else if (p.check(.left_paren)) {
            const args = p.parseArgs() orelse return null;
            const raw_call = p.makeNode(.call_expr, base.start, p.current.start, .{
                .call_expr = .{ .callee = base, .args = args },
            }) orelse return null;
            base = p.rewriteSuperCall(raw_call) orelse return null;
        } else if (p.match(.dot)) {
            const prop_tok = p.expectIdentifierName() orelse return null;
            const prop = p.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                .identifier = prop_tok.value_str,
            }) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = false },
            }) orelse return null;
        } else if (p.match(.left_bracket)) {
            const prop = p.parseExpression() orelse return null;
            _ = p.expect(.right_bracket) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = true },
            }) orelse return null;
        } else {
            break;
        }
    }
    if (saw_optional) {
        base = p.makeNode(.optional_chain, base.start, base.end, .{
            .optional_chain = base,
        }) orelse return null;
    }
    // Now let the assignment/binary parser take over.
    return finishBinaryFromBase(p, base);
}

/// Continue parsing a binary/assignment expression given a left-hand base node.
fn finishBinaryFromBase(p: *Parser, base: *Node) ?*Node {
    var left = base;
    // Handle postfix ++ / -- that may follow the base.
    if (!p.current.line_terminator_before) {
        if (p.current.kind == .plus_plus) {
            _ = p.advance();
            left = p.makeNode(.update_expr, left.start, p.current.start, .{
                .update_expr = .{ .op = .inc, .operand = left, .prefix = false },
            }) orelse return null;
        } else if (p.current.kind == .minus_minus) {
            _ = p.advance();
            left = p.makeNode(.update_expr, left.start, p.current.start, .{
                .update_expr = .{ .op = .dec, .operand = left, .prefix = false },
            }) orelse return null;
        }
    }
    // Binary expression climbing (Pratt).
    while (true) {
        const p2 = infixPrec(p.current.kind);
        if (p2 == 0 or p2 <= Prec.comma) break;
        if (p.current.kind == .left_paren or p.current.kind == .left_bracket or p.current.kind == .dot) break;
        const op_kind = p.current.kind;
        if (op_kind == .star_star and left.kind == .unary_expr and !left.paren) {
            if (!p.had_error) {
                p.had_error = true;
                p.error_info = parser_file.ParseError{
                    .message = "unary operator not allowed as left operand of **",
                    .line = p.current.line,
                    .column = p.current.column,
                };
            }
            return null;
        }
        if (op_kind == .question_question) {
            if (isUnparenthesizedAndOr(left)) {
                p.coalesceMixError();
                return null;
            }
        } else if (op_kind == .amp_amp or op_kind == .pipe_pipe) {
            if (isUnparenthesizedNullish(left)) {
                p.coalesceMixError();
                return null;
            }
        }
        _ = p.advance();
        const right = p.parseBinaryExpr(if (op_kind == .star_star) p2 - 1 else p2) orelse return null;
        if (op_kind == .question_question) {
            if (isUnparenthesizedAndOr(right)) {
                p.coalesceMixError();
                return null;
            }
        } else if (op_kind == .amp_amp or op_kind == .pipe_pipe) {
            if (isUnparenthesizedNullish(right)) {
                p.coalesceMixError();
                return null;
            }
        }
        const start = left.start;
        left = switch (op_kind) {
            .amp_amp, .pipe_pipe, .question_question => p.makeNode(.logical_expr, start, p.current.start, .{
                .logical_expr = .{
                    .op = switch (op_kind) {
                        .amp_amp => .and_,
                        .pipe_pipe => .or_,
                        else => .nullish,
                    },
                    .left = left,
                    .right = right,
                },
            }) orelse return null,
            else => p.makeNode(.binary_expr, start, p.current.start, .{
                .binary_expr = .{
                    .op = tokenToBinaryOp(op_kind),
                    .left = left,
                    .right = right,
                },
            }) orelse return null,
        };
    }
    // Conditional ?:
    if (p.match(.question)) {
        const consequent = p.parseAssignmentExpr() orelse return null;
        _ = p.expect(.colon) orelse return null;
        const alternate = p.parseAssignmentExpr() orelse return null;
        left = p.makeNode(.conditional_expr, left.start, p.current.start, .{
            .conditional_expr = .{ .test_ = left, .consequent = consequent, .alternate = alternate },
        }) orelse return null;
    }
    // Arrow function? (base must be a parenthesized sequence — handled via the normal parseAssignmentExprCore path).
    if (p.match(.arrow)) {
        const params = p.extractArrowParams(left) orelse return null;
        var body_nodes: []*Node = undefined;
        if (p.check(.left_brace)) {
            const blk = p.parseBlock() orelse return null;
            body_nodes = blk.data.block_stmt.body;
        } else {
            const expr_body = p.parseAssignmentExpr() orelse return null;
            const ret = p.makeNode(.return_stmt, expr_body.start, expr_body.end, .{
                .return_stmt = expr_body,
            }) orelse return null;
            var one = std.ArrayList(*Node){};
            one.append(p.arena, ret) catch {
                p.had_error = true;
                return null;
            };
            body_nodes = one.items;
        }
        const is_strict = parser_file.hasUseStrict(body_nodes);
        return p.makeNode(.function_expr, left.start, p.current.start, .{
            .function_expr = .{
                .name = null,
                .params = params,
                .param_defaults = &[_]?*Node{},
                .rest_param = null,
                .body = body_nodes,
                .is_arrow = true,
                .is_async = false,
                .is_strict = is_strict,
            },
        });
    }
    // Assignment?
    if (isAssignOp(p.current.kind)) {
        const op = tokenToAssignOp(p.current.kind);
        _ = p.advance();
        const right = p.parseAssignmentExpr() orelse return null;
        left = p.makeNode(.assignment_expr, left.start, p.current.start, .{
            .assignment_expr = .{ .op = op, .target = left, .value = right },
        }) orelse return null;
    }
    // Comma sequence: `expr, expr2, ...` at statement level (parseExprStmt goes through
    // parseExpression which handles comma, but parseExprFromIdent does not — fix here).
    if (p.check(.comma)) {
        var exprs = std.ArrayList(*Node){};
        exprs.append(p.arena, left) catch {
            p.had_error = true;
            return null;
        };
        while (p.match(.comma)) {
            const e = p.parseAssignmentExpr() orelse return null;
            exprs.append(p.arena, e) catch {
                p.had_error = true;
                return null;
            };
        }
        return p.makeNode(.sequence_expr, exprs.items[0].start, p.current.start, .{
            .sequence_expr = .{ .exprs = exprs.items },
        });
    }
    return left;
}

/// Parse a full expression (includes comma operator).
pub fn parseExpression(p: *Parser) ?*Node {
    const start = p.current.start;
    var left = p.parseAssignmentExpr() orelse return null;
    if (p.check(.comma)) {
        var exprs = std.ArrayList(*Node){};
        exprs.append(p.arena, left) catch {
            p.had_error = true;
            return null;
        };
        while (p.match(.comma)) {
            const e = p.parseAssignmentExpr() orelse return null;
            exprs.append(p.arena, e) catch {
                p.had_error = true;
                return null;
            };
        }
        left = p.makeNode(.sequence_expr, start, p.current.start, .{
            .sequence_expr = .{ .exprs = exprs.items },
        }) orelse return null;
    }
    return left;
}

pub fn parseAssignmentExpr(p: *Parser) ?*Node {
    // W2-async: speculative async-arrow detection. `async` is contextual, so
    // only treat it as an async-arrow marker when an arrow form looks likely
    // (`async (` or `async ident`, same line). If the speculative parse is
    // not an arrow, backtrack and parse `async` as an ordinary identifier.
    if (p.currentIsAsyncKw() and !p.peekNext().line_terminator_before and
        (p.peekNext().kind == .left_paren or p.peekNext().kind == .identifier))
    {
        const save_lexer = p.lexer;
        const save_cur = p.current;
        _ = p.advance(); // consume `async`
        const candidate = p.parseAssignmentExprCore(true);
        if (candidate) |c| {
            if (c.kind == .function_expr and c.data.function_expr.is_arrow) return c;
        }
        if (p.had_error) return candidate;
        // Not an arrow — rewind so `async` parses as a normal identifier.
        p.lexer = save_lexer;
        p.current = save_cur;
    }
    return p.parseAssignmentExprCore(false);
}

pub fn parseAssignmentExprCore(p: *Parser, is_async_arrow: bool) ?*Node {
    const start = p.current.start;
    // Conditional has higher precedence than assignment.
    const left = p.parseConditionalExpr() orelse return null;
    // ES2015 arrow function: params => body
    if (p.match(.arrow)) {
        const params = p.extractArrowParams(left) orelse return null;
        var body_nodes: []*Node = undefined;
        if (p.check(.left_brace)) {
            const blk = p.parseBlock() orelse return null;
            body_nodes = blk.data.block_stmt.body;
        } else {
            const expr_body = p.parseAssignmentExpr() orelse return null;
            const ret = p.makeNode(.return_stmt, expr_body.start, expr_body.end, .{
                .return_stmt = expr_body,
            }) orelse return null;
            var one = std.ArrayList(*Node){};
            one.append(p.arena, ret) catch {
                p.had_error = true;
                return null;
            };
            body_nodes = one.items;
        }
        const is_strict = parser_file.hasUseStrict(body_nodes);
        return p.makeNode(.function_expr, start, p.current.start, .{
            .function_expr = .{
                .name = null,
                .params = params,
                .param_defaults = &[_]?*Node{},
                .rest_param = null,
                .body = body_nodes,
                .is_arrow = true,
                .is_async = is_async_arrow,
                .is_strict = is_strict,
            },
        });
    }
    // Check for assignment operator.
    if (isAssignOp(p.current.kind)) {
        const op = tokenToAssignOp(p.current.kind);
        _ = p.advance();
        const right = p.parseAssignmentExpr() orelse return null; // right-assoc
        return p.makeNode(.assignment_expr, start, p.current.start, .{
            .assignment_expr = .{ .op = op, .target = left, .value = right },
        });
    }
    return left;
}

pub fn extractArrowParams(p: *Parser, lhs: *Node) ?[][]const u8 {
    var params = std.ArrayList([]const u8){};
    switch (lhs.kind) {
        .identifier => {
            params.append(p.arena, lhs.data.identifier) catch {
                p.had_error = true;
                return null;
            };
        },
        .sequence_expr => {
            for (lhs.data.sequence_expr.exprs) |e| {
                if (e.kind != .identifier) {
                    if (!p.had_error) {
                        p.had_error = true;
                        p.error_info = parser_file.ParseError{
                            .message = "invalid arrow parameter list",
                            .line = p.current.line,
                            .column = p.current.column,
                        };
                    }
                    return null;
                }
                params.append(p.arena, e.data.identifier) catch {
                    p.had_error = true;
                    return null;
                };
            }
        },
        else => {
            if (!p.had_error) {
                p.had_error = true;
                p.error_info = parser_file.ParseError{
                    .message = "invalid arrow parameter list",
                    .line = p.current.line,
                    .column = p.current.column,
                };
            }
            return null;
        },
    }
    return params.items;
}

pub fn parseConditionalExpr(p: *Parser) ?*Node {
    const start = p.current.start;
    const test_ = p.parseBinaryExpr(Prec.comma) orelse return null;
    if (p.match(.question)) {
        const consequent = p.parseAssignmentExpr() orelse return null;
        _ = p.expect(.colon) orelse return null;
        const alternate = p.parseAssignmentExpr() orelse return null;
        return p.makeNode(.conditional_expr, start, p.current.start, .{
            .conditional_expr = .{ .test_ = test_, .consequent = consequent, .alternate = alternate },
        });
    }
    return test_;
}

/// Emit the "cannot mix ?? with && or ||" SyntaxError.
pub fn coalesceMixError(p: *Parser) void {
    if (!p.had_error) {
        p.had_error = true;
        p.error_info = parser_file.ParseError{
            .message = "cannot mix '??' with '||' or '&&' without parentheses",
            .line = p.current.line,
            .column = p.current.column,
        };
    }
}

/// Pratt-style binary expression parser.
pub fn parseBinaryExpr(p: *Parser, min_prec: u8) ?*Node {
    var left = p.parseUnaryExpr() orelse return null;
    while (true) {
        const prec = infixPrec(p.current.kind);
        if (prec == 0 or prec <= min_prec) break;
        if (p.current.kind == .left_paren or p.current.kind == .left_bracket or p.current.kind == .dot) {
            // Call/member — handled in parseUnaryExpr's postfix loop, not here.
            break;
        }
        const op_kind = p.current.kind;
        // ES2016: a UnaryExpression may not be the left operand of `**` (e.g. `-2 ** 2`).
        if (op_kind == .star_star and left.kind == .unary_expr and !left.paren) {
            if (!p.had_error) {
                p.had_error = true;
                p.error_info = parser_file.ParseError{
                    .message = "unary operator not allowed as left operand of **",
                    .line = p.current.line,
                    .column = p.current.column,
                };
            }
            return null;
        }
        // ES2020: `??` may not be mixed with `&&`/`||` without parentheses.
        if (op_kind == .question_question) {
            if (isUnparenthesizedAndOr(left)) {
                p.coalesceMixError();
                return null;
            }
        } else if (op_kind == .amp_amp or op_kind == .pipe_pipe) {
            if (isUnparenthesizedNullish(left)) {
                p.coalesceMixError();
                return null;
            }
        }
        _ = p.advance();
        // Exponentiation is right-associative: recurse at p-1 so same-prec ** binds rightward.
        const right = p.parseBinaryExpr(if (op_kind == .star_star) prec - 1 else prec) orelse return null;
        // Reject the right-operand mixing direction too (e.g. `a ?? b || c`).
        if (op_kind == .question_question) {
            if (isUnparenthesizedAndOr(right)) {
                p.coalesceMixError();
                return null;
            }
        } else if (op_kind == .amp_amp or op_kind == .pipe_pipe) {
            if (isUnparenthesizedNullish(right)) {
                p.coalesceMixError();
                return null;
            }
        }
        const start = left.start;
        left = switch (op_kind) {
            .amp_amp, .pipe_pipe, .question_question => p.makeNode(.logical_expr, start, p.current.start, .{
                .logical_expr = .{
                    .op = switch (op_kind) {
                        .amp_amp => .and_,
                        .pipe_pipe => .or_,
                        else => .nullish,
                    },
                    .left = left,
                    .right = right,
                },
            }) orelse return null,
            else => p.makeNode(.binary_expr, start, p.current.start, .{
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

pub fn parseUnaryExpr(p: *Parser) ?*Node {
    const start = p.current.start;
    // Phase 8: `await X` desugars to a call __await__(X) (synchronous-drain await).
    // Works at module top level and inside any function; no VM changes needed.
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "await")) {
        _ = p.advance();
        const operand = p.parseUnaryExpr() orelse return null;
        const callee = p.makeNode(.identifier, start, start, .{ .identifier = "__await__" }) orelse return null;
        var args = std.ArrayList(*Node){};
        args.append(p.arena, operand) catch return null;
        return p.makeNode(.call_expr, start, p.current.start, .{
            .call_expr = .{ .callee = callee, .args = args.items },
        });
    }
    // Prefix unary
    switch (p.current.kind) {
        .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
            const op_kind = p.current.kind;
            _ = p.advance();
            const operand = p.parseUnaryExpr() orelse return null;
            return p.makeNode(.unary_expr, start, p.current.start, .{
                .unary_expr = .{ .op = tokenToUnaryOp(op_kind), .operand = operand },
            });
        },
        .plus_plus => {
            _ = p.advance();
            const operand = p.parseUnaryExpr() orelse return null;
            return p.makeNode(.update_expr, start, p.current.start, .{
                .update_expr = .{ .op = .inc, .operand = operand, .prefix = true },
            });
        },
        .minus_minus => {
            _ = p.advance();
            const operand = p.parseUnaryExpr() orelse return null;
            return p.makeNode(.update_expr, start, p.current.start, .{
                .update_expr = .{ .op = .dec, .operand = operand, .prefix = true },
            });
        },
        .kw_new => {
            _ = p.advance();
            // M16 Phase 4: `await` is reserved in module code; `new await …` is
            // a SyntaxError per spec (await is not a valid NewExpression callee).
            if (p.is_module and p.current.kind == .identifier and
                std.mem.eql(u8, p.current.value_str, "await"))
            {
                return p.fail("SyntaxError: 'await' expression cannot follow 'new'");
            }
            // For `new`, parse only member expressions (no call) as the callee,
            // then optionally consume argument list.
            const callee = p.parseNewCallee() orelse return null;
            var args: []*Node = &[_]*Node{};
            if (p.check(.left_paren)) {
                args = p.parseArgs() orelse return null;
            }
            var new_node: *Node = p.makeNode(.new_expr, start, p.current.start, .{
                .new_expr = .{ .callee = callee, .args = args },
            }) orelse return null;
            // Allow member access and calls on the result of `new`: e.g. new Foo().bar()
            while (true) {
                if (p.check(.left_paren)) {
                    const call_args = p.parseArgs() orelse return null;
                    new_node = p.makeNode(.call_expr, new_node.start, p.current.start, .{
                        .call_expr = .{ .callee = new_node, .args = call_args },
                    }) orelse return null;
                } else if (p.match(.dot)) {
                    const prop_tok2 = p.expectIdentifierName() orelse return null;
                    const prop2 = p.makeNode(.identifier, prop_tok2.start, prop_tok2.end, .{
                        .identifier = prop_tok2.value_str,
                    }) orelse return null;
                    new_node = p.makeNode(.member_expr, new_node.start, p.current.start, .{
                        .member_expr = .{ .object = new_node, .property = prop2, .computed = false },
                    }) orelse return null;
                } else if (p.match(.left_bracket)) {
                    const prop2 = p.parseExpression() orelse return null;
                    _ = p.expect(.right_bracket) orelse return null;
                    new_node = p.makeNode(.member_expr, new_node.start, p.current.start, .{
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
    var expr = p.parseCallMemberExpr() orelse return null;
    if (!p.current.line_terminator_before) {
        if (p.current.kind == .plus_plus) {
            _ = p.advance();
            expr = p.makeNode(.update_expr, start, p.current.start, .{
                .update_expr = .{ .op = .inc, .operand = expr, .prefix = false },
            }) orelse return null;
        } else if (p.current.kind == .minus_minus) {
            _ = p.advance();
            expr = p.makeNode(.update_expr, start, p.current.start, .{
                .update_expr = .{ .op = .dec, .operand = expr, .prefix = false },
            }) orelse return null;
        }
    }
    return expr;
}

/// Parse call, member access, subscript. Handles ES2020 optional chaining
/// (`?.`); if any link in the chain is optional, the whole chain is wrapped
/// in an `optional_chain` node which establishes the short-circuit boundary.
pub fn parseCallMemberExpr(p: *Parser) ?*Node {
    var base = p.parsePrimaryExpr() orelse return null;
    var saw_optional = false;
    while (true) {
        if (p.match(.question_dot)) {
            // `obj?.[expr]`, `obj?.(args)`, or `obj?.prop`
            saw_optional = true;
            if (p.check(.left_paren)) {
                const args = p.parseArgs() orelse return null;
                base = p.makeNode(.call_expr, base.start, p.current.start, .{
                    .call_expr = .{ .callee = base, .args = args, .optional = true },
                }) orelse return null;
            } else if (p.match(.left_bracket)) {
                const prop = p.parseExpression() orelse return null;
                _ = p.expect(.right_bracket) orelse return null;
                base = p.makeNode(.member_expr, base.start, p.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = true, .optional = true },
                }) orelse return null;
            } else {
                const prop_tok = p.expectIdentifierName() orelse return null;
                const prop = p.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                    .identifier = prop_tok.value_str,
                }) orelse return null;
                base = p.makeNode(.member_expr, base.start, p.current.start, .{
                    .member_expr = .{ .object = base, .property = prop, .computed = false, .optional = true },
                }) orelse return null;
            }
        } else if (p.check(.left_paren)) {
            const args = p.parseArgs() orelse return null;
            const raw_call = p.makeNode(.call_expr, base.start, p.current.start, .{
                .call_expr = .{ .callee = base, .args = args },
            }) orelse return null;
            base = p.rewriteSuperCall(raw_call) orelse return null;
        } else if (p.match(.dot)) {
            const prop_tok = p.expectIdentifierName() orelse return null;
            const prop = p.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                .identifier = prop_tok.value_str,
            }) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = false },
            }) orelse return null;
        } else if (p.match(.left_bracket)) {
            const prop = p.parseExpression() orelse return null;
            _ = p.expect(.right_bracket) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = true },
            }) orelse return null;
        } else {
            break;
        }
    }
    if (saw_optional) {
        base = p.makeNode(.optional_chain, base.start, base.end, .{
            .optional_chain = base,
        }) orelse return null;
    }
    return base;
}

/// Rewrite super call sites into explicit .call(this, ...) form.
/// - super(a, b) -> super.call(this, a, b)
/// - super.m(a)  -> super.m.call(this, a)
pub fn rewriteSuperCall(p: *Parser, call_node: *Node) ?*Node {
    if (call_node.kind != .call_expr) return call_node;
    const call = call_node.data.call_expr;
    const start = call_node.start;
    const end = call_node.end;

    // Case 1: direct super(...)
    if (call.callee.kind == .identifier and std.mem.eql(u8, call.callee.data.identifier, "super")) {
        const id_call = p.makeNode(.identifier, start, end, .{ .identifier = "call" }) orelse return null;
        const super_call = p.makeNode(.member_expr, start, end, .{
            .member_expr = .{ .object = call.callee, .property = id_call, .computed = false },
        }) orelse return null;
        const this_expr = p.makeNode(.this_expr, start, end, .{ .this_expr = {} }) orelse return null;
        var new_args = std.ArrayList(*Node){};
        new_args.append(p.arena, this_expr) catch return null;
        for (call.args) |a| new_args.append(p.arena, a) catch return null;
        return p.makeNode(.call_expr, start, end, .{
            .call_expr = .{ .callee = super_call, .args = new_args.items },
        });
    }

    // Case 2: super.method(...)
    if (call.callee.kind == .member_expr) {
        const me = call.callee.data.member_expr;
        const is_super_obj = me.object.kind == .identifier and std.mem.eql(u8, me.object.data.identifier, "super");
        const is_explicit_call = (!me.computed and me.property.kind == .identifier and std.mem.eql(u8, me.property.data.identifier, "call"));
        if (is_super_obj and !is_explicit_call) {
            const id_call = p.makeNode(.identifier, start, end, .{ .identifier = "call" }) orelse return null;
            const method_call = p.makeNode(.member_expr, start, end, .{
                .member_expr = .{ .object = call.callee, .property = id_call, .computed = false },
            }) orelse return null;
            const this_expr = p.makeNode(.this_expr, start, end, .{ .this_expr = {} }) orelse return null;
            var new_args = std.ArrayList(*Node){};
            new_args.append(p.arena, this_expr) catch return null;
            for (call.args) |a| new_args.append(p.arena, a) catch return null;
            return p.makeNode(.call_expr, start, end, .{
                .call_expr = .{ .callee = method_call, .args = new_args.items },
            });
        }
    }
    return call_node;
}

/// Parse a member expression without call expressions (for `new` callee).
/// Handles dot and bracket access but NOT `(` argument lists.
pub fn parseNewCallee(p: *Parser) ?*Node {
    var base = p.parsePrimaryExpr() orelse return null;
    while (true) {
        if (p.match(.dot)) {
            const prop_tok = p.expectIdentifierName() orelse return null;
            const prop = p.makeNode(.identifier, prop_tok.start, prop_tok.end, .{
                .identifier = prop_tok.value_str,
            }) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = false },
            }) orelse return null;
        } else if (p.match(.left_bracket)) {
            const prop = p.parseExpression() orelse return null;
            _ = p.expect(.right_bracket) orelse return null;
            base = p.makeNode(.member_expr, base.start, p.current.start, .{
                .member_expr = .{ .object = base, .property = prop, .computed = true },
            }) orelse return null;
        } else {
            break;
        }
    }
    return base;
}

pub fn parseArgs(p: *Parser) ?[]*Node {
    _ = p.expect(.left_paren) orelse return null;
    var args = std.ArrayList(*Node){};
    while (!p.check(.right_paren) and !p.check(.eof) and !p.had_error) {
        const has_spread = p.match(.ellipsis);
        const parsed = p.parseAssignmentExpr() orelse return null;
        const a = if (has_spread)
            (p.makeNode(.spread_expr, parsed.start, parsed.end, .{ .spread_expr = parsed }) orelse return null)
        else
            parsed;
        args.append(p.arena, a) catch {
            p.had_error = true;
            return null;
        };
        if (!p.match(.comma)) break;
    }
    _ = p.expect(.right_paren) orelse return null;
    return args.items;
}

pub fn parsePrimaryExpr(p: *Parser) ?*Node {
    const start = p.current.start;
    const end = p.current.end;
    switch (p.current.kind) {
        .number => {
            const v = p.current.value_num;
            _ = p.advance();
            return p.makeNode(.number_literal, start, end, .{ .number_literal = v });
        },
        .bigint => {
            const s = p.current.value_str;
            _ = p.advance();
            return p.makeNode(.bigint_literal, start, end, .{ .bigint_literal = s });
        },
        .string => {
            const s = p.current.value_str;
            _ = p.advance();
            return p.makeNode(.string_literal, start, end, .{ .string_literal = s });
        },
        .kw_true => {
            _ = p.advance();
            return p.makeNode(.bool_literal, start, end, .{ .bool_literal = true });
        },
        .kw_false => {
            _ = p.advance();
            return p.makeNode(.bool_literal, start, end, .{ .bool_literal = false });
        },
        .kw_null => {
            _ = p.advance();
            return p.makeNode(.null_literal, start, end, .{ .null_literal = {} });
        },
        .kw_this => {
            _ = p.advance();
            return p.makeNode(.this_expr, start, end, .{ .this_expr = {} });
        },
        .kw_super => {
            _ = p.advance();
            return p.makeNode(.identifier, start, end, .{ .identifier = "super" });
        },
        .kw_import => {
            // M16 Phase 3: `import` in expression position is either a dynamic
            // `import(specifier)` call or the `import.meta` meta-property — never
            // an import declaration (that path is handled in parseImportDecl).
            _ = p.advance();
            if (p.match(.dot)) {
                const meta = p.expectIdentifierName() orelse return null;
                if (!std.mem.eql(u8, meta.value_str, "meta")) return p.fail("expected 'meta' after 'import.'");
                // `import.meta` → the hidden, module-scoped meta object binding.
                return p.makeNode(.identifier, start, p.current.start, .{ .identifier = "__import_meta__" });
            }
            if (p.check(.left_paren)) {
                // `import(spec)` → `__import__(spec)`: return the native callee and
                // let parseCallMemberExpr consume the argument list. The argument
                // is evaluated by the VM before the call, so an abrupt specifier
                // (throwing getter / bad reference) propagates synchronously.
                return p.makeNode(.identifier, start, p.current.start, .{ .identifier = "__import__" });
            }
            return p.fail("expected '(' or '.' after 'import'");
        },
        .kw_yield => {
            if (!p.in_generator_function) {
                if (!p.had_error) {
                    p.had_error = true;
                    p.error_info = parser_file.ParseError{
                        .message = "yield is only valid inside generator functions",
                        .line = p.current.line,
                        .column = p.current.column,
                    };
                }
                return null;
            }
            _ = p.advance();
            if (p.match(.star)) {
                const delegated = p.parseAssignmentExpr() orelse {
                    if (!p.had_error) {
                        p.had_error = true;
                        p.error_info = parser_file.ParseError{
                            .message = "expected expression after yield*",
                            .line = p.current.line,
                            .column = p.current.column,
                        };
                    }
                    return null;
                };
                const helper = p.makeNode(.identifier, start, p.current.start, .{ .identifier = "__yield_star__" }) orelse return null;
                var args = std.ArrayList(*Node){};
                args.append(p.arena, delegated) catch return null;
                return p.makeNode(.call_expr, start, p.current.start, .{
                    .call_expr = .{ .callee = helper, .args = args.items },
                });
            }
            const can_have_arg = !(p.current.line_terminator_before or p.check(.semicolon) or p.check(.right_brace) or p.check(.eof));
            const yielded = if (can_have_arg) p.parseAssignmentExpr() orelse return null else null;
            return p.makeNode(.yield_expr, start, p.current.start, .{ .yield_expr = yielded });
        },
        .kw_of => {
            // `of` is a contextual keyword (only special in `for…of`); it is a
            // valid IdentifierReference everywhere else (e.g. `var of = x; of()`).
            _ = p.advance();
            return p.makeNode(.identifier, start, end, .{ .identifier = "of" });
        },
        .kw_class => return p.parseClassExpr(),
        .identifier => {
            // W2-async: `async function(){}` / `async function name(){}`
            // expression. Contextual: only when `function` follows on the
            // same line.
            if (p.currentIsAsyncKw() and p.peekNext().kind == .kw_function and !p.peekNext().line_terminator_before) {
                _ = p.advance(); // consume `async`
                return p.parseFunctionExpr(true);
            }
            const name = p.current.value_str;
            _ = p.advance();
            // Special: 'undefined' identifier -> undefined literal
            if (std.mem.eql(u8, name, "undefined")) {
                return p.makeNode(.undefined_literal, start, end, .{ .undefined_literal = {} });
            }
            return p.makeNode(.identifier, start, end, .{ .identifier = name });
        },
        .left_paren => {
            _ = p.advance();
            // Empty parens `()` are only valid as an arrow's parameter list.
            // Emit an empty sequence_expr marker so the enclosing
            // parseAssignmentExprCore sees `=>` and extractArrowParams yields
            // zero parameters.
            if (p.check(.right_paren)) {
                _ = p.advance(); // consume ')'
                if (!p.check(.arrow)) {
                    if (!p.had_error) {
                        p.had_error = true;
                        p.error_info = parser_file.ParseError{
                            .message = "unexpected empty parentheses",
                            .line = p.current.line,
                            .column = p.current.column,
                        };
                    }
                    return null;
                }
                return p.makeNode(.sequence_expr, start, p.current.start, .{
                    .sequence_expr = .{ .exprs = &[_]*Node{} },
                });
            }
            const expr = p.parseExpression() orelse return null;
            _ = p.expect(.right_paren) orelse return null;
            expr.paren = true;
            return expr;
        },
        .kw_function => {
            return p.parseFunctionExpr(false);
        },
        .left_brace => {
            return p.parseObjectLiteral();
        },
        .left_bracket => {
            return p.parseArrayLiteral();
        },
        .regex => {
            // Phase 4c: regex literal /pattern/flags
            const raw = p.current.value_str;
            _ = p.advance();
            // raw format: /pattern/flags — parse it
            const parsed = parseRegexRaw(raw);
            const owned_pat = p.arena.dupe(u8, parsed.pattern) catch return null;
            const owned_flags = p.arena.dupe(u8, parsed.flags) catch return null;
            return p.makeNode(.regex_literal, start, end, .{
                .regex_literal = .{ .pattern = owned_pat, .flags = owned_flags },
            });
        },
        else => {
            if (!p.had_error) {
                p.had_error = true;
                var buf: [128]u8 = undefined;
                const msg_s = std.fmt.bufPrint(&buf, "unexpected token '{s}' at line {d}", .{
                    @tagName(p.current.kind), p.current.line,
                }) catch "unexpected token";
                const owned = p.arena.dupe(u8, msg_s) catch "unexpected token";
                p.error_info = parser_file.ParseError{
                    .message = owned,
                    .line = p.current.line,
                    .column = p.current.column,
                };
            }
            return null;
        },
    }
}

pub fn parseObjectLiteral(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.expect(.left_brace) orelse return null;
    var props = std.ArrayList(ast.ObjectProp){};
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        const prop_start = p.current.start;
        // ES6 computed key: `{ [expr]: value }`. The key expression is
        // evaluated at runtime (may produce a symbol).
        if (p.check(.left_bracket)) {
            _ = p.advance(); // consume '['
            const key_expr = p.parseAssignmentExpr() orelse return null;
            _ = p.expect(.right_bracket) orelse return null;
            // ES6 computed method `{ [expr](params) { body } }` ≡ a function-valued
            // property with a runtime-evaluated key.
            if (p.check(.left_paren)) {
                const cm_params = p.parseFunctionParams() orelse return null;
                const cm_body = p.parseFunctionBody() orelse return null;
                const cm_fn = p.makeNode(.function_expr, prop_start, p.current.start, .{
                    .function_expr = .{
                        .name = null,
                        .params = cm_params.params,
                        .param_defaults = cm_params.param_defaults,
                        .rest_param = cm_params.rest_param,
                        .body = cm_body,
                        .is_arrow = false,
                        .is_generator = false,
                        .is_async = false,
                        .is_strict = parser_file.hasUseStrict(cm_body),
                    },
                }) orelse return null;
                props.append(p.arena, ast.ObjectProp{ .key = "", .value = cm_fn, .kind = .init, .computed_key = key_expr }) catch {
                    p.had_error = true;
                    return null;
                };
                if (!p.match(.comma)) break;
                continue;
            }
            _ = p.expect(.colon) orelse return null;
            const cval = p.parseAssignmentExpr() orelse return null;
            props.append(p.arena, ast.ObjectProp{ .key = "", .value = cval, .kind = .init, .computed_key = key_expr }) catch {
                p.had_error = true;
                return null;
            };
            if (!p.match(.comma)) break;
            continue;
        }
        // Key: identifier, string literal, or number literal.
        var key: []const u8 = undefined;
        if (p.check(.identifier)) {
            key = p.current.value_str;
            _ = p.advance();
        } else if (p.check(.string)) {
            key = p.current.value_str;
            _ = p.advance();
        } else if (p.check(.number)) {
            // Number key: convert to string.
            const n = p.current.value_num;
            _ = p.advance();
            // Simple integer check.
            if (n == @trunc(n) and n >= 0 and n < 1e15) {
                const s = std.fmt.allocPrint(p.arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch {
                    p.had_error = true;
                    return null;
                };
                key = s;
            } else {
                const s = std.fmt.allocPrint(p.arena, "{d}", .{n}) catch {
                    p.had_error = true;
                    return null;
                };
                key = s;
            }
        } else {
            if (!p.had_error) {
                p.had_error = true;
                p.error_info = parser_file.ParseError{
                    .message = "expected property key",
                    .line = p.current.line,
                    .column = p.current.column,
                };
            }
            return null;
        }
        // Accessor: `get name(...) { ... }` / `set name(v) { ... }`.
        // `key` holds "get"/"set"; an accessor only if a property name follows
        // (not ':' for a data prop named get/set, not '(' for a method, not end).
        if ((std.mem.eql(u8, key, "get") or std.mem.eql(u8, key, "set")) and
            !p.check(.colon) and !p.check(.comma) and
            !p.check(.right_brace) and !p.check(.left_paren))
        {
            const acc_kind: ast.PropKind = if (key[0] == 'g') .get else .set;
            var aname: []const u8 = undefined;
            if (p.check(.identifier) or p.check(.string)) {
                aname = p.current.value_str;
                _ = p.advance();
            } else if (p.check(.number)) {
                const n = p.current.value_num;
                _ = p.advance();
                aname = if (n == @trunc(n) and n >= 0 and n < 1e15)
                    std.fmt.allocPrint(p.arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch { p.had_error = true; return null; }
                else
                    std.fmt.allocPrint(p.arena, "{d}", .{n}) catch { p.had_error = true; return null; };
            } else {
                p.had_error = true;
                p.error_info = parser_file.ParseError{ .message = "expected accessor name", .line = p.current.line, .column = p.current.column };
                return null;
            }
            const acc_params = p.parseFunctionParams() orelse return null;
            const acc_body = p.parseFunctionBody() orelse return null;
            const acc_fn = p.makeNode(.function_expr, prop_start, p.current.start, .{
                .function_expr = .{
                    .name = null,
                    .params = acc_params.params,
                    .param_defaults = acc_params.param_defaults,
                    .rest_param = acc_params.rest_param,
                    .body = acc_body,
                    .is_arrow = false,
                    .is_generator = false,
                    .is_async = false,
                    .is_strict = parser_file.hasUseStrict(acc_body),
                },
            }) orelse return null;
            props.append(p.arena, ast.ObjectProp{ .key = aname, .value = acc_fn, .kind = acc_kind }) catch {
                p.had_error = true;
                return null;
            };
            if (!p.match(.comma)) break;
            continue;
        }
        // ES6 method shorthand: `name(params) { body }` ≡ `name: function(params){body}`.
        if (p.check(.left_paren)) {
            const m_params = p.parseFunctionParams() orelse return null;
            const m_body = p.parseFunctionBody() orelse return null;
            const m_fn = p.makeNode(.function_expr, prop_start, p.current.start, .{
                .function_expr = .{
                    .name = key,
                    .params = m_params.params,
                    .param_defaults = m_params.param_defaults,
                    .rest_param = m_params.rest_param,
                    .body = m_body,
                    .is_arrow = false,
                    .is_generator = false,
                    .is_async = false,
                    .is_strict = parser_file.hasUseStrict(m_body),
                },
            }) orelse return null;
            props.append(p.arena, ast.ObjectProp{ .key = key, .value = m_fn, .kind = .init }) catch {
                p.had_error = true;
                return null;
            };
            if (!p.match(.comma)) break;
            continue;
        }
        // ES6 shorthand property: `{ x }` ≡ `{ x: x }`.
        if (p.check(.comma) or p.check(.right_brace)) {
            const id_node = p.makeNode(.identifier, prop_start, p.current.start, .{
                .identifier = key,
            }) orelse return null;
            props.append(p.arena, ast.ObjectProp{ .key = key, .value = id_node, .kind = .init }) catch {
                p.had_error = true;
                return null;
            };
            if (!p.match(.comma)) break;
            continue;
        }
        _ = p.expect(.colon) orelse return null;
        const val_node = p.parseAssignmentExpr() orelse return null;
        props.append(p.arena, ast.ObjectProp{ .key = key, .value = val_node, .kind = .init }) catch {
            p.had_error = true;
            return null;
        };
        if (!p.match(.comma)) break;
    }
    _ = p.expect(.right_brace) orelse return null;
    const obj_end = p.current.start;
    return p.makeNode(.object_literal, start, obj_end, .{
        .object_literal = .{ .properties = props.items },
    });
}

pub fn parseArrayLiteral(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.expect(.left_bracket) orelse return null;
    var elements = std.ArrayList(*Node){};
    while (!p.check(.right_bracket) and !p.check(.eof) and !p.had_error) {
        // Elision: a hole reads as `undefined` (ToNumber → NaN), matching the
        // observable value of a sparse-array hole. (We don't model true absence,
        // so `index in arr` is true for a hole — but the value is spec-correct.)
        if (p.check(.comma)) {
            const hole_node = p.makeNode(.undefined_literal, p.current.start, p.current.start, .{ .undefined_literal = {} }) orelse return null;
            elements.append(p.arena, hole_node) catch {
                p.had_error = true;
                return null;
            };
            _ = p.advance(); // consume comma
            continue;
        }
        const has_spread = p.match(.ellipsis);
        const parsed = p.parseAssignmentExpr() orelse return null;
        const elem = if (has_spread)
            (p.makeNode(.spread_expr, parsed.start, parsed.end, .{ .spread_expr = parsed }) orelse return null)
        else
            parsed;
        elements.append(p.arena, elem) catch {
            p.had_error = true;
            return null;
        };
        if (!p.match(.comma)) break;
    }
    _ = p.expect(.right_bracket) orelse return null;
    const arr_end = p.current.start;
    return p.makeNode(.array_literal, start, arr_end, .{
        .array_literal = .{ .elements = elements.items },
    });
}

pub fn parseFunctionExpr(p: *Parser, is_async: bool) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'function'
    const is_generator = p.match(.star);
    var name: ?[]const u8 = null;
    if (p.check(.identifier)) {
        name = p.current.value_str;
        _ = p.advance();
    }
    const parsed_params = p.parseFunctionParams() orelse return null;
    const prev_gen = p.in_generator_function;
    p.in_generator_function = is_generator;
    const body = p.parseFunctionBody() orelse {
        p.in_generator_function = prev_gen;
        return null;
    };
    p.in_generator_function = prev_gen;
    const is_strict = parser_file.hasUseStrict(body);
    return p.makeNode(.function_expr, start, p.current.start, .{
        .function_expr = .{
            .name = name,
            .params = parsed_params.params,
            .param_defaults = parsed_params.param_defaults,
            .rest_param = parsed_params.rest_param,
            .body = body,
            .is_arrow = false,
            .is_generator = is_generator,
            .is_async = is_async,
            .is_strict = is_strict,
        },
    });
}

// ------------------------------------------------------------------- helpers ---

/// True if `n` is a non-parenthesized `&&` / `||` logical expression.
fn isUnparenthesizedAndOr(n: *Node) bool {
    return n.kind == .logical_expr and !n.paren and
        (n.data.logical_expr.op == .and_ or n.data.logical_expr.op == .or_);
}

/// True if `n` is a non-parenthesized `??` logical expression.
fn isUnparenthesizedNullish(n: *Node) bool {
    return n.kind == .logical_expr and !n.paren and n.data.logical_expr.op == .nullish;
}

fn tokenToBinaryOp(kind: @import("../lexer/token.zig").TokenKind) ast.BinaryOp {
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

fn tokenToUnaryOp(kind: @import("../lexer/token.zig").TokenKind) ast.UnaryOp {
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

fn tokenToAssignOp(kind: @import("../lexer/token.zig").TokenKind) ast.AssignOp {
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
        .amp_amp_eq => .logical_and,
        .pipe_pipe_eq => .logical_or,
        .question_question_eq => .logical_nullish,
        else => .assign,
    };
}
