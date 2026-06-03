// SPDX-License-Identifier: MIT
//! ES5 lexer: regex/division disambiguation, ASI tracking, full token set.
//! Single public method: next() !Token. EOF returns .eof sentinel.
const std = @import("std");
const tok = @import("./token.zig");
pub const Token = tok.Token;
pub const TokenKind = tok.TokenKind;
const lookupKeyword = tok.lookupKeyword;

pub const LexError = error{
    UnterminatedString,
    UnterminatedComment,
    InvalidEscape,
    InvalidNumericLiteral,
    OutOfMemory,
    TemplateLiteralNotSupported,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    /// The last non-whitespace token kind, for regex/division disambiguation.
    prev_kind: ?TokenKind,
    /// Allocator used for string escape processing only.
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .prev_kind = null,
            .allocator = allocator,
        };
    }

    fn cur(self: *const Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peek1(self: *const Lexer) ?u8 {
        if (self.pos + 1 >= self.source.len) return null;
        return self.source[self.pos + 1];
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn skipLineTerminator(self: *Lexer) void {
        const c = self.source[self.pos];
        if (c == '\r') {
            self.pos += 1;
            self.line += 1;
            self.column = 1;
            if (self.pos < self.source.len and self.source[self.pos] == '\n') {
                self.pos += 1;
            }
        } else {
            // \n or unicode line sep (    handled as bytes)
            self.pos += 1;
            self.line += 1;
            self.column = 1;
        }
    }

    fn isLineTerminator(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    /// Returns true if the next 3 bytes are the UTF-8 encoding of U+2028 or U+2029.
    fn isUnicodeLineTerm(self: *const Lexer) bool {
        if (self.pos + 2 >= self.source.len) return false;
        const a = self.source[self.pos];
        const b = self.source[self.pos + 1];
        const c2 = self.source[self.pos + 2];
        // U+2028 = 0xE2 0x80 0xA8; U+2029 = 0xE2 0x80 0xA9
        return a == 0xE2 and b == 0x80 and (c2 == 0xA8 or c2 == 0xA9);
    }

    /// Skip whitespace and comments. Returns true if any line terminator was consumed.
    fn skipTrivia(self: *Lexer) bool {
        var lt_before = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            // Whitespace
            if (c == ' ' or c == '\t' or c == '\x0B' or c == '\x0C' or c == 0xA0) {
                self.pos += 1;
                self.column += 1;
                continue;
            }
            // Line terminators
            if (c == '\n' or c == '\r') {
                lt_before = true;
                self.skipLineTerminator();
                continue;
            }
            // Unicode line terminators (U+2028, U+2029) in UTF-8
            if (self.isUnicodeLineTerm()) {
                lt_before = true;
                self.pos += 3;
                self.line += 1;
                self.column = 1;
                continue;
            }
            // Line comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                self.column += 2;
                while (self.pos < self.source.len) {
                    const d = self.source[self.pos];
                    if (d == '\n' or d == '\r') break;
                    if (self.isUnicodeLineTerm()) break;
                    self.pos += 1;
                    self.column += 1;
                }
                // The line terminator itself will be consumed on the next iteration.
                continue;
            }
            // Block comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                self.pos += 2;
                self.column += 2;
                while (self.pos + 1 < self.source.len) {
                    const d = self.source[self.pos];
                    if (d == '\n' or d == '\r') {
                        lt_before = true;
                        self.skipLineTerminator();
                        continue;
                    }
                    if (self.isUnicodeLineTerm()) {
                        lt_before = true;
                        self.pos += 3;
                        self.line += 1;
                        self.column = 1;
                        continue;
                    }
                    if (d == '*' and self.source[self.pos + 1] == '/') {
                        self.pos += 2;
                        self.column += 2;
                        break;
                    }
                    self.pos += 1;
                    self.column += 1;
                }
                continue;
            }
            break;
        }
        return lt_before;
    }

    /// Determine if '/' starts a regex based on the previous token kind.
    /// ES5 spec: regex is allowed when the previous token is one of the listed kinds
    /// or there is no previous token.
    fn slashIsRegex(self: *const Lexer) bool {
        const p = self.prev_kind orelse return true;
        return switch (p) {
            .left_paren,
            .comma,
            .eq,
            .plus_eq,
            .minus_eq,
            .star_eq,
            .star_star_eq,
            .slash_eq,
            .percent_eq,
            .amp_eq,
            .pipe_eq,
            .caret_eq,
            .lt_lt_eq,
            .gt_gt_eq,
            .gt_gt_gt_eq,
            .plus,
            .minus,
            .star,
            .star_star,
            .slash,
            .percent,
            .bang,
            .tilde,
            .lt,
            .gt,
            .lt_eq,
            .gt_eq,
            .eq_eq,
            .bang_eq,
            .eq_eq_eq,
            .bang_eq_eq,
            .amp_amp,
            .pipe_pipe,
            .question_question,
            .amp_amp_eq,
            .pipe_pipe_eq,
            .question_question_eq,
            .question,
            .colon,
            .semicolon,
            .left_brace,
            .right_brace,
            .left_bracket,
            .kw_return,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_new,
            .kw_instanceof,
            .kw_in,
            .kw_if,
            .kw_while,
            .kw_for,
            .kw_do,
            .kw_else,
            .kw_case,
            .kw_throw,
            => true,
            else => false,
        };
    }

    fn lexNumber(self: *Lexer, start: usize, start_col: u32, lt_before: bool) LexError!Token {
        // Hex literal: 0x... — caller has self.pos == start, so peek the char AFTER the '0'.
        if (self.source[start] == '0' and start + 1 < self.source.len) {
            const next_c = self.source[start + 1];
            if (next_c == 'x' or next_c == 'X') {
                self.pos = start + 2;
                self.column += 2;
                const hex_start = self.pos;
                while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                    self.pos += 1;
                    self.column += 1;
                }
                if (self.pos == hex_start) return LexError.InvalidNumericLiteral;
                const slice = self.source[start..self.pos];
                const hex_val_int = std.fmt.parseUnsigned(u64, slice[2..], 16) catch return LexError.InvalidNumericLiteral;
                var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_num = @floatFromInt(hex_val_int);
                t.value_str = slice;
                self.prev_kind = .number;
                return t;
            }
        }

        // Decimal/octal
        while (self.pos < self.source.len and isDecDigit(self.source[self.pos])) {
            self.pos += 1;
            self.column += 1;
        }
        // Fractional part
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            self.column += 1;
            while (self.pos < self.source.len and isDecDigit(self.source[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
        }
        // Exponent
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            self.column += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
                self.column += 1;
            }
            const exp_start = self.pos;
            while (self.pos < self.source.len and isDecDigit(self.source[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
            if (self.pos == exp_start) return LexError.InvalidNumericLiteral;
        }
        const slice = self.source[start..self.pos];
        const val = std.fmt.parseFloat(f64, slice) catch return LexError.InvalidNumericLiteral;
        var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
        t.value_num = val;
        t.value_str = slice;
        self.prev_kind = .number;
        return t;
    }

    /// Lex a string literal (single or double quoted).
    /// Processes escape sequences, storing result in arena-allocated buffer.
    fn lexString(self: *Lexer, quote: u8, start: usize, start_col: u32, lt_before: bool) LexError!Token {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == quote) {
                self.pos += 1;
                self.column += 1;
                // Copy to arena
                const owned = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                var t = Token.initSimple(.string, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_str = owned;
                self.prev_kind = .string;
                return t;
            }
            if (isLineTerminator(c)) return LexError.UnterminatedString;
            if (c != '\\') {
                buf.append(self.allocator, c) catch return LexError.OutOfMemory;
                self.pos += 1;
                self.column += 1;
                continue;
            }
            // Escape sequence
            self.pos += 1;
            self.column += 1;
            if (self.pos >= self.source.len) return LexError.UnterminatedString;
            const esc = self.source[self.pos];
            self.pos += 1;
            self.column += 1;
            switch (esc) {
                'n' => try buf.append(self.allocator, '\n'),
                't' => try buf.append(self.allocator, '\t'),
                'r' => try buf.append(self.allocator, '\r'),
                'v' => try buf.append(self.allocator, 0x0B),
                'b' => try buf.append(self.allocator, 0x08),
                'f' => try buf.append(self.allocator, 0x0C),
                '0' => try buf.append(self.allocator, 0),
                '\'' => try buf.append(self.allocator, '\''),
                '"' => try buf.append(self.allocator, '"'),
                '\\' => try buf.append(self.allocator, '\\'),
                '\n', '\r' => {}, // line continuation
                'x' => {
                    if (self.pos + 1 >= self.source.len) return LexError.InvalidEscape;
                    const h1 = hexVal(self.source[self.pos]) orelse return LexError.InvalidEscape;
                    const h2 = hexVal(self.source[self.pos + 1]) orelse return LexError.InvalidEscape;
                    try buf.append(self.allocator, @intCast(h1 * 16 + h2));
                    self.pos += 2;
                    self.column += 2;
                },
                'u' => {
                    if (self.pos + 3 >= self.source.len) return LexError.InvalidEscape;
                    const h1 = hexVal(self.source[self.pos]) orelse return LexError.InvalidEscape;
                    const h2 = hexVal(self.source[self.pos + 1]) orelse return LexError.InvalidEscape;
                    const h3 = hexVal(self.source[self.pos + 2]) orelse return LexError.InvalidEscape;
                    const h4 = hexVal(self.source[self.pos + 3]) orelse return LexError.InvalidEscape;
                    const codepoint: u21 = @as(u21, h1) * 4096 + @as(u21, h2) * 256 + @as(u21, h3) * 16 + @as(u21, h4);
                    var ubuf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &ubuf) catch return LexError.InvalidEscape;
                    try buf.appendSlice(self.allocator, ubuf[0..len]);
                    self.pos += 4;
                    self.column += 4;
                },
                else => {
                    // Non-special escape: just emit the character
                    try buf.append(self.allocator, esc);
                },
            }
        }
        return LexError.UnterminatedString;
    }

    /// Lex a simple template literal as a string token.
    /// Phase 7 baseline: supports plain templates and escape sequences, but does not
    /// support `${...}` interpolation yet.
    fn lexTemplateString(self: *Lexer, start: usize, start_col: u32, lt_before: bool) LexError!Token {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '`') {
                self.pos += 1;
                self.column += 1;
                const owned = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                var t = Token.initSimple(.string, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_str = owned;
                self.prev_kind = .string;
                return t;
            }
            if (c == '$' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                return LexError.TemplateLiteralNotSupported;
            }
            if (c != '\\') {
                buf.append(self.allocator, c) catch return LexError.OutOfMemory;
                self.advance();
                continue;
            }
            self.pos += 1;
            self.column += 1;
            if (self.pos >= self.source.len) return LexError.UnterminatedString;
            const esc = self.source[self.pos];
            self.pos += 1;
            self.column += 1;
            switch (esc) {
                'n' => try buf.append(self.allocator, '\n'),
                't' => try buf.append(self.allocator, '\t'),
                'r' => try buf.append(self.allocator, '\r'),
                '`' => try buf.append(self.allocator, '`'),
                '\\' => try buf.append(self.allocator, '\\'),
                else => try buf.append(self.allocator, esc),
            }
        }
        return LexError.UnterminatedString;
    }

    /// Lex a regex literal. We do minimal parsing: find the end.
    /// Pattern: /body/flags — body cannot contain unescaped / or line terminator.
    fn lexRegex(self: *Lexer, start: usize, start_col: u32, lt_before: bool) LexError!Token {
        // Consume body
        var in_class = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isLineTerminator(c)) return LexError.UnterminatedString;
            if (c == '[') {
                in_class = true;
                self.pos += 1;
                self.column += 1;
                continue;
            }
            if (c == ']') {
                in_class = false;
                self.pos += 1;
                self.column += 1;
                continue;
            }
            if (c == '\\') {
                self.pos += 1;
                self.column += 1;
                if (self.pos < self.source.len and !isLineTerminator(self.source[self.pos])) {
                    self.pos += 1;
                    self.column += 1;
                }
                continue;
            }
            if (c == '/' and !in_class) {
                self.pos += 1;
                self.column += 1;
                break;
            }
            self.pos += 1;
            self.column += 1;
        }
        // Consume flags
        while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
            self.pos += 1;
            self.column += 1;
        }
        const slice = self.source[start..self.pos];
        var t = Token.initSimple(.regex, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
        t.value_str = slice;
        self.prev_kind = .regex;
        return t;
    }

    /// Produce the next token. Caller is responsible for handling LexError.
    pub fn next(self: *Lexer) LexError!Token {
        const lt_before = self.skipTrivia();

        if (self.pos >= self.source.len) {
            const t = Token.initSimple(.eof, @intCast(self.pos), @intCast(self.pos), self.line, self.column, lt_before);
            return t;
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const c = self.source[self.pos];

        // Identifier or keyword
        if (isIdentStart(c)) {
            self.pos += 1;
            self.column += 1;
            while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
            const slice = self.source[start..self.pos];
            const kind = lookupKeyword(slice) orelse .identifier;
            var t = Token.initSimple(kind, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
            t.value_str = slice;
            self.prev_kind = kind;
            return t;
        }

        // Number
        if (isDecDigit(c) or (c == '.' and self.pos + 1 < self.source.len and isDecDigit(self.source[self.pos + 1]))) {
            if (c == '.') {
                // starts with dot: e.g. .5
                self.pos += 1;
                self.column += 1;
            }
            return self.lexNumber(start, start_col, lt_before);
        }

        // String
        if (c == '"' or c == '\'') {
            self.pos += 1;
            self.column += 1;
            return self.lexString(c, start, start_col, lt_before);
        }

        // Template literal
        if (c == '`') {
            self.pos += 1;
            self.column += 1;
            return self.lexTemplateString(start, start_col, lt_before);
        }

        // Single-char and multi-char punctuators
        self.pos += 1;
        self.column += 1;

        const kind: TokenKind = switch (c) {
            '(' => .left_paren,
            ')' => .right_paren,
            '{' => .left_brace,
            '}' => .right_brace,
            '[' => .left_bracket,
            ']' => .right_bracket,
            ';' => .semicolon,
            ':' => .colon,
            ',' => .comma,
            '~' => .tilde,
            '?' => blk: {
                if (self.pos < self.source.len) {
                    const n = self.source[self.pos];
                    if (n == '?') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .question_question_eq;
                        }
                        break :blk .question_question;
                    }
                    // `?.` is optional chaining, but NOT when followed by a digit
                    // (e.g. `x?.3:y` is the ternary `x ? .3 : y`).
                    if (n == '.') {
                        const after: u8 = if (self.pos + 1 < self.source.len) self.source[self.pos + 1] else 0;
                        if (!(after >= '0' and after <= '9')) {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .question_dot;
                        }
                    }
                }
                break :blk .question;
            },
            '.' => blk: {
                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
                    self.pos += 2;
                    self.column += 2;
                    break :blk .ellipsis;
                }
                break :blk .dot;
            },
            '+' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '+') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .plus_plus;
                    }
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .plus_eq;
                    }
                }
                break :blk .plus;
            },
            '-' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '-') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .minus_minus;
                    }
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .minus_eq;
                    }
                }
                break :blk .minus;
            },
            '*' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '*') {
                    self.pos += 1;
                    self.column += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .star_star_eq;
                    }
                    break :blk .star_star;
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    break :blk .star_eq;
                }
                break :blk .star;
            },
            '%' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    break :blk .percent_eq;
                }
                break :blk .percent;
            },
            '&' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '&') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .amp_amp_eq;
                        }
                        break :blk .amp_amp;
                    }
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .amp_eq;
                    }
                }
                break :blk .amp;
            },
            '|' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '|') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .pipe_pipe_eq;
                        }
                        break :blk .pipe_pipe;
                    }
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .pipe_eq;
                    }
                }
                break :blk .pipe;
            },
            '^' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    break :blk .caret_eq;
                }
                break :blk .caret;
            },
            '!' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .bang_eq_eq;
                    }
                    break :blk .bang_eq;
                }
                break :blk .bang;
            },
            '=' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .eq_eq_eq;
                        }
                        break :blk .eq_eq;
                    }
                    if (self.source[self.pos] == '>') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .arrow;
                    }
                }
                break :blk .eq;
            },
            '<' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .lt_eq;
                    }
                    if (self.source[self.pos] == '<') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .lt_lt_eq;
                        }
                        break :blk .lt_lt;
                    }
                }
                break :blk .lt;
            },
            '>' => blk: {
                if (self.pos < self.source.len) {
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        self.column += 1;
                        break :blk .gt_eq;
                    }
                    if (self.source[self.pos] == '>') {
                        self.pos += 1;
                        self.column += 1;
                        if (self.pos < self.source.len and self.source[self.pos] == '>') {
                            self.pos += 1;
                            self.column += 1;
                            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                                self.pos += 1;
                                self.column += 1;
                                break :blk .gt_gt_gt_eq;
                            }
                            break :blk .gt_gt_gt;
                        }
                        if (self.pos < self.source.len and self.source[self.pos] == '=') {
                            self.pos += 1;
                            self.column += 1;
                            break :blk .gt_gt_eq;
                        }
                        break :blk .gt_gt;
                    }
                }
                break :blk .gt;
            },
            '/' => blk: {
                if (self.slashIsRegex()) {
                    // Regex literal — self.pos is already past '/'
                    return self.lexRegex(start, start_col, lt_before);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    self.column += 1;
                    break :blk .slash_eq;
                }
                break :blk .slash;
            },
            else => .illegal,
        };

        var t = Token.initSimple(kind, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
        t.value_str = self.source[start..self.pos];
        self.prev_kind = kind;
        return t;
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDecDigit(c);
}

fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDecDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ------------------------------------------------------------------ tests ---

test "Lexer: basic tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("1 + 2", arena.allocator());
    const t1 = try lex.next();
    try std.testing.expectEqual(TokenKind.number, t1.kind);
    try std.testing.expectEqual(@as(f64, 1), t1.value_num);
    const t2 = try lex.next();
    try std.testing.expectEqual(TokenKind.plus, t2.kind);
    const t3 = try lex.next();
    try std.testing.expectEqual(TokenKind.number, t3.kind);
    try std.testing.expectEqual(@as(f64, 2), t3.value_num);
    const t4 = try lex.next();
    try std.testing.expectEqual(TokenKind.eof, t4.kind);
}

test "Lexer: string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("\"hello\"", arena.allocator());
    const t = try lex.next();
    try std.testing.expectEqual(TokenKind.string, t.kind);
    try std.testing.expectEqualStrings("hello", t.value_str);
}

test "Lexer: string escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("\"a\\nb\"", arena.allocator());
    const t = try lex.next();
    try std.testing.expectEqualStrings("a\nb", t.value_str);
}

test "Lexer: keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("var function return", arena.allocator());
    const t1 = try lex.next();
    try std.testing.expectEqual(TokenKind.kw_var, t1.kind);
    const t2 = try lex.next();
    try std.testing.expectEqual(TokenKind.kw_function, t2.kind);
    const t3 = try lex.next();
    try std.testing.expectEqual(TokenKind.kw_return, t3.kind);
}

test "Lexer: line terminator tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("a\nb", arena.allocator());
    const t1 = try lex.next();
    try std.testing.expect(!t1.line_terminator_before);
    const t2 = try lex.next();
    try std.testing.expect(t2.line_terminator_before);
}

test "Lexer: hex literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("0xFF", arena.allocator());
    const t = try lex.next();
    try std.testing.expectEqual(TokenKind.number, t.kind);
    try std.testing.expectEqual(@as(f64, 255), t.value_num);
}

test "Lexer: compound operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("=== !== && ||", arena.allocator());
    const t1 = try lex.next();
    try std.testing.expectEqual(TokenKind.eq_eq_eq, t1.kind);
    const t2 = try lex.next();
    try std.testing.expectEqual(TokenKind.bang_eq_eq, t2.kind);
    const t3 = try lex.next();
    try std.testing.expectEqual(TokenKind.amp_amp, t3.kind);
    const t4 = try lex.next();
    try std.testing.expectEqual(TokenKind.pipe_pipe, t4.kind);
}

test "Lexer: ES2020/2021 operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("?? ?. &&= ||= ??=", arena.allocator());
    try std.testing.expectEqual(TokenKind.question_question, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.question_dot, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.amp_amp_eq, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.pipe_pipe_eq, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.question_question_eq, (try lex.next()).kind);
}

test "Lexer: ?. before digit is ternary, not optional chaining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("x?.3:y", arena.allocator());
    try std.testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.question, (try lex.next()).kind);
    const num = try lex.next();
    try std.testing.expectEqual(TokenKind.number, num.kind);
    try std.testing.expectEqual(@as(f64, 0.3), num.value_num);
    try std.testing.expectEqual(TokenKind.colon, (try lex.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
}

test "Lexer: line comment skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lex = Lexer.init("1 // comment\n2", arena.allocator());
    _ = try lex.next(); // 1
    const t = try lex.next();
    try std.testing.expectEqual(TokenKind.number, t.kind);
    try std.testing.expect(t.line_terminator_before);
}
