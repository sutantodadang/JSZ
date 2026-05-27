// SPDX-License-Identifier: MIT
//! ES5 token enum and Token struct. Borrowed slices into source, zero-copy.
const std = @import("std");

pub const TokenKind = enum {
    // Literals
    number,
    string,
    identifier,
    regex,
    // Punctuators
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    semicolon,
    colon,
    comma,
    dot,
    question,
    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    tilde,
    amp,
    pipe,
    caret,
    // Compound operators
    plus_plus,
    minus_minus,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    lt_lt,
    gt_gt,
    gt_gt_gt,
    lt_lt_eq,
    gt_gt_eq,
    gt_gt_gt_eq,
    // Comparison
    bang_eq,
    bang_eq_eq,
    eq,
    eq_eq,
    eq_eq_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    // Logical
    amp_amp,
    pipe_pipe,
    // Arrow (Phase 7, lex but reject)
    arrow,
    // Keywords
    kw_break,
    kw_case,
    kw_catch,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_return,
    kw_switch,
    kw_this,
    kw_throw,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    // Future reserved (ES5 strict)
    kw_class,
    kw_const,
    kw_enum,
    kw_export,
    kw_extends,
    kw_import,
    kw_super,
    // Literal keywords
    kw_true,
    kw_false,
    kw_null,
    // Meta
    eof,
    illegal,
};

pub const Token = struct {
    kind: TokenKind,
    /// Byte offset into source (start).
    start: u32,
    /// Byte offset into source (end, exclusive).
    end: u32,
    line: u32,
    column: u32,
    /// True if at least one line terminator appeared before this token.
    line_terminator_before: bool,
    // For numeric literals.
    value_num: f64,
    // For string/identifier/regex literals — points into source or owned buffer.
    value_str: []const u8,

    pub fn initSimple(kind: TokenKind, start: u32, end: u32, line: u32, col: u32, lt_before: bool) Token {
        return Token{
            .kind = kind,
            .start = start,
            .end = end,
            .line = line,
            .column = col,
            .line_terminator_before = lt_before,
            .value_num = 0,
            .value_str = "",
        };
    }
};

/// Map an identifier string to its keyword TokenKind, or null.
pub fn lookupKeyword(s: []const u8) ?TokenKind {
    if (s.len < 2 or s.len > 10) return null;
    const map = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "break", .kw_break },
        .{ "case", .kw_case },
        .{ "catch", .kw_catch },
        .{ "continue", .kw_continue },
        .{ "debugger", .kw_debugger },
        .{ "default", .kw_default },
        .{ "delete", .kw_delete },
        .{ "do", .kw_do },
        .{ "else", .kw_else },
        .{ "finally", .kw_finally },
        .{ "for", .kw_for },
        .{ "function", .kw_function },
        .{ "if", .kw_if },
        .{ "in", .kw_in },
        .{ "instanceof", .kw_instanceof },
        .{ "new", .kw_new },
        .{ "return", .kw_return },
        .{ "switch", .kw_switch },
        .{ "this", .kw_this },
        .{ "throw", .kw_throw },
        .{ "try", .kw_try },
        .{ "typeof", .kw_typeof },
        .{ "var", .kw_var },
        .{ "void", .kw_void },
        .{ "while", .kw_while },
        .{ "with", .kw_with },
        .{ "class", .kw_class },
        .{ "const", .kw_const },
        .{ "enum", .kw_enum },
        .{ "export", .kw_export },
        .{ "extends", .kw_extends },
        .{ "import", .kw_import },
        .{ "super", .kw_super },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "null", .kw_null },
    });
    return map.get(s);
}

test "Token fields" {
    const t = Token.initSimple(.eof, 0, 0, 1, 1, false);
    try std.testing.expectEqual(TokenKind.eof, t.kind);
}

test "lookupKeyword" {
    try std.testing.expectEqual(TokenKind.kw_var, lookupKeyword("var").?);
    try std.testing.expectEqual(TokenKind.kw_function, lookupKeyword("function").?);
    try std.testing.expect(lookupKeyword("foo") == null);
}
