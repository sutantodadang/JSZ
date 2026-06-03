// SPDX-License-Identifier: MIT
//! Operator precedence table — 16 ES5 levels (lowest = 1, highest = 16).
const std = @import("std");
const TokenKind = @import("../lexer/token.zig").TokenKind;

/// Numeric precedence values (higher = tighter binding).
pub const Prec = struct {
    pub const comma: u8 = 1;
    pub const assignment: u8 = 2;
    pub const conditional: u8 = 3;
    // ES2020 nullish coalescing: same tier as `||`/`&&` but cannot be mixed
    // with them without parentheses (enforced in the parser).
    pub const nullish_coalescing: u8 = 4;
    pub const logical_or: u8 = 5;
    pub const logical_and: u8 = 6;
    pub const bitwise_or: u8 = 7;
    pub const bitwise_xor: u8 = 8;
    pub const bitwise_and: u8 = 9;
    pub const equality: u8 = 10;
    pub const relational: u8 = 11;
    pub const shift: u8 = 12;
    pub const additive: u8 = 13;
    pub const multiplicative: u8 = 14;
    pub const exponentiation: u8 = 15;
    pub const unary: u8 = 16;
    pub const postfix: u8 = 17;
    pub const call_member: u8 = 18;
};

/// Return the infix precedence for binary/logical/relational operators.
/// Returns 0 if the token is not an infix operator.
pub fn infixPrec(kind: TokenKind) u8 {
    return switch (kind) {
        .comma => Prec.comma,
        // Assignment operators are handled separately (right-assoc), not via infixPrec
        .question_question => Prec.nullish_coalescing,
        .pipe_pipe => Prec.logical_or,
        .amp_amp => Prec.logical_and,
        .pipe => Prec.bitwise_or,
        .caret => Prec.bitwise_xor,
        .amp => Prec.bitwise_and,
        .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => Prec.equality,
        .lt, .lt_eq, .gt, .gt_eq, .kw_instanceof, .kw_in => Prec.relational,
        .lt_lt, .gt_gt, .gt_gt_gt => Prec.shift,
        .plus, .minus => Prec.additive,
        .star, .slash, .percent => Prec.multiplicative,
        .star_star => Prec.exponentiation,
        .left_paren, .left_bracket, .dot => Prec.call_member,
        else => 0,
    };
}

/// Returns true if kind is a compound assignment operator.
pub fn isAssignOp(kind: TokenKind) bool {
    return switch (kind) {
        .eq, .plus_eq, .minus_eq, .star_eq, .star_star_eq, .slash_eq, .percent_eq,
        .amp_eq, .pipe_eq, .caret_eq, .lt_lt_eq, .gt_gt_eq, .gt_gt_gt_eq,
        .amp_amp_eq, .pipe_pipe_eq, .question_question_eq => true,
        else => false,
    };
}

test "precedence: additive > relational" {
    try std.testing.expect(infixPrec(.plus) > infixPrec(.lt));
}

test "precedence: multiplicative > additive" {
    try std.testing.expect(infixPrec(.star) > infixPrec(.plus));
}

test "precedence: logical_and > logical_or" {
    try std.testing.expect(infixPrec(.amp_amp) > infixPrec(.pipe_pipe));
}
