// SPDX-License-Identifier: Apache-2.0
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
    /// Annex B.1.1 HTML-like comments (`<!--` and a line-leading `-->`) are part
    /// of the Script grammar only. Cleared by `Parser.parseModule`, where the
    /// same character sequences must stay punctuators (and so a SyntaxError).
    allow_html_comments: bool = true,
    /// One-shot override for `slashIsRegex`. `/` after `}` is lexed as division
    /// because a `}` far more often closes an object literal used as an operand,
    /// but the parser knows when it is at statement position (`{}/re/`,
    /// `class A{}/re/`) and re-lexes the token with this set. Cleared by the
    /// next `next()` call.
    force_regex_once: bool = false,

    /// Rewind to `pos` and pull one token, forcing a leading `/` to lex as a
    /// RegularExpressionLiteral. `line`/`column` are restored by the caller's
    /// saved token, so only the scan position matters here.
    pub fn relexAsRegexAt(self: *Lexer, pos: usize, line: u32, column: u32) LexError!Token {
        self.pos = pos;
        self.line = line;
        self.column = column;
        self.force_regex_once = true;
        defer self.force_regex_once = false;
        return self.next();
    }

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Lexer {
        return Lexer{
            .source = source,
            // HashbangComment (§12.5): `#!` is a comment only at the very start
            // of the source text — for a Script, a Module, and eval code alike.
            // One byte in and it is a SyntaxError, so match position 0 exactly.
            .pos = hashbangLen(source),
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

    /// Byte length of a leading HashbangComment (`#!` through, but not
    /// including, the first LineTerminator), or 0 when the source has none.
    /// U+2028/U+2029 end the comment too, so they are matched explicitly.
    fn hashbangLen(source: []const u8) usize {
        if (source.len < 2 or source[0] != '#' or source[1] != '!') return 0;
        var i: usize = 2;
        while (i < source.len) : (i += 1) {
            if (isLineTerminator(source[i])) break;
            if (i + 2 < source.len and source[i] == 0xE2 and source[i + 1] == 0x80 and
                (source[i + 2] == 0xA8 or source[i + 2] == 0xA9)) break;
        }
        return i;
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

    /// Byte length of a non-line-terminator Unicode whitespace code point at the
    /// current position (UTF-8), or 0 if none. Covers the ES `WhiteSpace`
    /// production beyond the ASCII set: NBSP, the U+2000-block spaces, BOM, etc.
    /// (U+2028/U+2029 are line terminators, handled separately.)
    fn unicodeWsLen(self: *const Lexer) usize {
        const rem = self.source.len - self.pos;
        if (rem < 2) return 0;
        const p = self.source[self.pos..];
        if (p[0] == 0xC2 and p[1] == 0xA0) return 2; // U+00A0 NBSP
        if (rem < 3) return 0;
        if (p[0] == 0xE1 and p[1] == 0x9A and p[2] == 0x80) return 3; // U+1680
        if (p[0] == 0xE2 and p[1] == 0x80) {
            if (p[2] >= 0x80 and p[2] <= 0x8A) return 3; // U+2000..U+200A
            if (p[2] == 0xAF) return 3; // U+202F
        }
        if (p[0] == 0xE2 and p[1] == 0x81 and p[2] == 0x9F) return 3; // U+205F
        if (p[0] == 0xE3 and p[1] == 0x80 and p[2] == 0x80) return 3; // U+3000
        if (p[0] == 0xEF and p[1] == 0xBB and p[2] == 0xBF) return 3; // U+FEFF ZWNBSP/BOM
        return 0;
    }

    /// Skip whitespace and comments. Returns true if any line terminator was consumed.
    fn skipTrivia(self: *Lexer) bool {
        var lt_before = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            // Whitespace (ASCII)
            if (c == ' ' or c == '\t' or c == '\x0B' or c == '\x0C') {
                self.pos += 1;
                self.column += 1;
                continue;
            }
            // Whitespace (multi-byte Unicode: NBSP, U+2000-block, BOM, …)
            const uws = self.unicodeWsLen();
            if (uws > 0) {
                self.pos += uws;
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
            // Annex B.1.1 SingleLineHTMLOpenComment: `<!--` runs to end of line.
            if (self.allow_html_comments and c == '<' and
                std.mem.startsWith(u8, self.source[self.pos..], "<!--"))
            {
                self.skipToLineEnd();
                continue;
            }
            // Annex B.1.1 SingleLineHTMLCloseComment: `-->` runs to end of line,
            // but only where the rest of the line before it is whitespace and
            // delimited comments — which is exactly "a line terminator (or the
            // start of input) has been passed without producing a token".
            if (self.allow_html_comments and c == '-' and
                (lt_before or self.pos == 0) and
                std.mem.startsWith(u8, self.source[self.pos..], "-->"))
            {
                self.skipToLineEnd();
                continue;
            }
            // Line comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                self.column += 2;
                self.skipToLineEnd();
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

    /// Advance past every character up to (but not including) the next line
    /// terminator. Shared by `//`, `<!--` and `-->` comment forms.
    fn skipToLineEnd(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const d = self.source[self.pos];
            if (d == '\n' or d == '\r') break;
            if (self.isUnicodeLineTerm()) break;
            self.pos += 1;
            self.column += 1;
        }
    }

    /// Determine if '/' starts a regex based on the previous token kind.
    /// ES5 spec: regex is allowed when the previous token is one of the listed kinds
    /// or there is no previous token.
    fn slashIsRegex(self: *const Lexer) bool {
        if (self.force_regex_once) return true;
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
            // NOTE: `.right_brace` is intentionally NOT regex-allowed. A `}` far
            // more commonly closes an object literal used as an operand
            // (`{valueOf(){}} / 1`) than a block followed by a regex, so treat
            // `/` after `}` as division.
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
            // `yield /re/` — yield is an operator-position keyword, so a following
            // `/` starts a regex (`received = yield/abc/i`), not division.
            .kw_yield,
            // `=> /re/` — a concise arrow body begins in expression position, so a
            // following `/` starts a regex (`x => /a/.test(x)`), not division.
            .arrow,
            => true,
            else => false,
        };
    }

    /// Advance over a run of digits accepted by `isDigit`, permitting single
    /// `_` numeric separators that sit strictly between two such digits (per
    /// the NumericLiteralSeparator grammar). Misplaced separators (leading,
    /// trailing, doubled, or abutting a non-digit) are a syntax error.
    fn scanDigits(self: *Lexer, comptime isDigit: fn (u8) bool) LexError!void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isDigit(c)) {
                self.pos += 1;
                self.column += 1;
            } else if (c == '_') {
                if (self.pos == 0 or !isDigit(self.source[self.pos - 1])) return LexError.InvalidNumericLiteral;
                if (self.pos + 1 >= self.source.len or !isDigit(self.source[self.pos + 1])) return LexError.InvalidNumericLiteral;
                self.pos += 1;
                self.column += 1;
            } else break;
        }
    }

    fn lexNumber(self: *Lexer, start: usize, start_col: u32, lt_before: bool) LexError!Token {
        // Hex literal: 0x... — caller has self.pos == start, so peek the char AFTER the '0'.
        if (self.source[start] == '0' and start + 1 < self.source.len) {
            const next_c = self.source[start + 1];
            if (next_c == 'x' or next_c == 'X') {
                self.pos = start + 2;
                self.column += 2;
                const hex_start = self.pos;
                try self.scanDigits(isHexDigit);
                if (self.pos == hex_start) return LexError.InvalidNumericLiteral;
                // BigInt hex literal: 0x..n
                if (self.pos < self.source.len and self.source[self.pos] == 'n') {
                    const digits = self.source[start..self.pos]; // "0x123"
                    self.pos += 1;
                    self.column += 1;
                    var t = Token.initSimple(.bigint, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                    t.value_str = try self.stripSeparators(digits);
                    self.prev_kind = .number;
                    return t;
                }
                const slice = self.source[start..self.pos];
                const clean = try self.stripSeparators(slice[2..]);
                const hex_val_int = std.fmt.parseUnsigned(u64, clean, 16) catch return LexError.InvalidNumericLiteral;
                var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_num = @floatFromInt(hex_val_int);
                t.value_str = slice;
                self.prev_kind = .number;
                return t;
            } else if (next_c == 'b' or next_c == 'B') {
                // Binary literal: 0b...
                self.pos = start + 2;
                self.column += 2;
                const bin_start = self.pos;
                try self.scanDigits(isBinDigit);
                if (self.pos == bin_start) return LexError.InvalidNumericLiteral;
                if (self.pos < self.source.len and self.source[self.pos] == 'n') {
                    const digits = self.source[start..self.pos];
                    self.pos += 1;
                    self.column += 1;
                    var t = Token.initSimple(.bigint, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                    t.value_str = try self.stripSeparators(digits);
                    self.prev_kind = .number;
                    return t;
                }
                const clean = try self.stripSeparators(self.source[start + 2..self.pos]);
                const bin_val = std.fmt.parseUnsigned(u64, clean, 2) catch return LexError.InvalidNumericLiteral;
                var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_num = @floatFromInt(bin_val);
                t.value_str = self.source[start..self.pos];
                self.prev_kind = .number;
                return t;
            } else if (next_c == 'o' or next_c == 'O') {
                // Octal literal: 0o...
                self.pos = start + 2;
                self.column += 2;
                const oct_start = self.pos;
                try self.scanDigits(isOctDigit);
                if (self.pos == oct_start) return LexError.InvalidNumericLiteral;
                if (self.pos < self.source.len and self.source[self.pos] == 'n') {
                    const digits = self.source[start..self.pos];
                    self.pos += 1;
                    self.column += 1;
                    var t = Token.initSimple(.bigint, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                    t.value_str = try self.stripSeparators(digits);
                    self.prev_kind = .number;
                    return t;
                }
                const clean = try self.stripSeparators(self.source[start + 2..self.pos]);
                const oct_val = std.fmt.parseUnsigned(u64, clean, 8) catch return LexError.InvalidNumericLiteral;
                var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_num = @floatFromInt(oct_val);
                t.value_str = self.source[start..self.pos];
                self.prev_kind = .number;
                return t;
            }
        }

        // Decimal/octal
        try self.scanDigits(isDecDigit);
        // Annex B.1.1 LegacyOctalIntegerLiteral: in non-strict code an integer
        // with a leading `0` followed only by octal digits (no 8/9, no `.`, `e`,
        // or `n`) is valued in base 8 — `070` === 56. A leading `0` followed by
        // an 8/9 (`08`) is instead a NonOctalDecimalIntegerLiteral and keeps its
        // decimal value (handled by the fall-through below). Strict-mode rejection
        // of the leading-0 form is an early error raised by the parser.
        if (self.source[start] == '0' and self.pos - start >= 2) {
            const digits = self.source[start..self.pos];
            var all_octal = true;
            for (digits) |d| {
                if (d < '0' or d > '7') {
                    all_octal = false;
                    break;
                }
            }
            const after: u8 = if (self.pos < self.source.len) self.source[self.pos] else 0;
            if (all_octal and after != '.' and after != 'e' and after != 'E' and after != 'n') {
                const oct_val = std.fmt.parseUnsigned(u64, digits, 8) catch return LexError.InvalidNumericLiteral;
                var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
                t.value_num = @floatFromInt(oct_val);
                t.value_str = digits;
                self.prev_kind = .number;
                return t;
            }
        }
        // BigInt decimal literal: 123n (integer only, no fraction/exponent).
        // A leading-dot number (e.g. `.5n`) already consumed its `.` in the
        // dispatcher, so `source[start] == '.'` means it is a fraction and the
        // `n` must NOT be folded into a (malformed) BigInt literal.
        if (self.source[start] != '.' and self.pos < self.source.len and self.source[self.pos] == 'n') {
            const digits = self.source[start..self.pos];
            self.pos += 1;
            self.column += 1;
            var t = Token.initSimple(.bigint, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
            t.value_str = try self.stripSeparators(digits);
            self.prev_kind = .number;
            return t;
        }
        // Fractional part
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            self.column += 1;
            try self.scanDigits(isDecDigit);
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
            try self.scanDigits(isDecDigit);
            if (self.pos == exp_start) return LexError.InvalidNumericLiteral;
        }
        const slice = self.source[start..self.pos];
        const clean = try self.stripSeparators(slice);
        const val = std.fmt.parseFloat(f64, clean) catch return LexError.InvalidNumericLiteral;
        var t = Token.initSimple(.number, @intCast(start), @intCast(self.pos), self.line, start_col, lt_before);
        t.value_num = val;
        t.value_str = slice;
        self.prev_kind = .number;
        return t;
    }

    /// Return `s` with any `_` numeric separators removed. When `s` has none
    /// (the common case) the original slice is returned without allocating;
    /// otherwise a separator-free copy is allocated from the lexer arena.
    fn stripSeparators(self: *Lexer, s: []const u8) LexError![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '_') == null) return s;
        var buf = self.allocator.alloc(u8, s.len) catch return LexError.OutOfMemory;
        var n: usize = 0;
        for (s) |c| {
            if (c == '_') continue;
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
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
            // LineContinuation :: \ LineTerminatorSequence, where the sequence
            // may be U+2028/U+2029. Those are three UTF-8 bytes, so the u8
            // switch below cannot match them; drop the whole sequence here.
            if (self.isUnicodeLineTerm()) {
                self.pos += 3;
                self.line += 1;
                self.column = 1;
                continue;
            }
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
                '0', '1', '2', '3', '4', '5', '6', '7' => {
                    // Legacy octal escape (Annex B.1.2 LegacyOctalEscapeSequence),
                    // valid only in non-strict code. The first digit bounds the
                    // total length so the value never exceeds 255: a leading digit
                    // in 0–3 permits up to three octal digits, a leading 4–7 only
                    // two (`\400` is `\40` followed by a literal '0'). `\0` not
                    // followed by an octal digit is the NUL escape (also legal in
                    // strict code; strict rejection of the octal forms is a
                    // separate early error not enforced here).
                    var val: u32 = esc - '0';
                    const max_more: usize = if (esc <= '3') 2 else 1;
                    var consumed: usize = 0;
                    while (consumed < max_more and self.pos < self.source.len) {
                        const d = self.source[self.pos];
                        if (d < '0' or d > '7') break;
                        val = val * 8 + (d - '0');
                        self.pos += 1;
                        self.column += 1;
                        consumed += 1;
                    }
                    try appendWtf8(&buf, self.allocator, val);
                },
                '\'' => try buf.append(self.allocator, '\''),
                '"' => try buf.append(self.allocator, '"'),
                '\\' => try buf.append(self.allocator, '\\'),
                '\n' => {}, // LineContinuation: LF removed from the value
                '\r' => {
                    // CRLF line continuation: consume the paired LF too, so it
                    // isn't seen as a raw (string-terminating) line terminator
                    // on the next iteration. The whole LineTerminatorSequence is
                    // removed from the string value.
                    if (self.pos < self.source.len and self.source[self.pos] == '\n') {
                        self.pos += 1;
                        self.column += 1;
                    }
                },
                'x' => {
                    if (self.pos + 1 >= self.source.len) return LexError.InvalidEscape;
                    const h1 = hexVal(self.source[self.pos]) orelse return LexError.InvalidEscape;
                    const h2 = hexVal(self.source[self.pos + 1]) orelse return LexError.InvalidEscape;
                    // \xHH is a code unit (0..255); WTF-8 encode so bytes ≥ 0x80
                    // round-trip as U+00xx rather than a raw Latin-1 octet.
                    try appendWtf8(&buf, self.allocator, h1 * 16 + h2);
                    self.pos += 2;
                    self.column += 2;
                },
                'u' => {
                    // ES6 code-point escape: \u{H+}
                    if (self.pos < self.source.len and self.source[self.pos] == '{') {
                        self.pos += 1;
                        self.column += 1;
                        var cp: u32 = 0;
                        var ndigits: usize = 0;
                        while (self.pos < self.source.len and self.source[self.pos] != '}') {
                            const hv = hexVal(self.source[self.pos]) orelse return LexError.InvalidEscape;
                            cp = cp * 16 + hv;
                            if (cp > 0x10FFFF) return LexError.InvalidEscape;
                            ndigits += 1;
                            self.pos += 1;
                            self.column += 1;
                        }
                        if (ndigits == 0 or self.pos >= self.source.len) return LexError.InvalidEscape;
                        self.pos += 1; // consume '}'
                        self.column += 1;
                        try appendWtf8(&buf, self.allocator, cp);
                    } else {
                        if (self.pos + 3 >= self.source.len) return LexError.InvalidEscape;
                        const h1 = hexVal(self.source[self.pos]) orelse return LexError.InvalidEscape;
                        const h2 = hexVal(self.source[self.pos + 1]) orelse return LexError.InvalidEscape;
                        const h3 = hexVal(self.source[self.pos + 2]) orelse return LexError.InvalidEscape;
                        const h4 = hexVal(self.source[self.pos + 3]) orelse return LexError.InvalidEscape;
                        const codepoint: u32 = @as(u32, h1) * 4096 + @as(u32, h2) * 256 + @as(u32, h3) * 16 + @as(u32, h4);
                        try appendWtf8(&buf, self.allocator, codepoint);
                        self.pos += 4;
                        self.column += 4;
                    }
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
            // LineContinuation :: \ LineTerminatorSequence, where the sequence
            // may be U+2028/U+2029. Those are three UTF-8 bytes, so the u8
            // switch below cannot match them; drop the whole sequence here.
            if (self.isUnicodeLineTerm()) {
                self.pos += 3;
                self.line += 1;
                self.column = 1;
                continue;
            }
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
            // A RegularExpressionLiteral may not span a LineTerminator — U+2028
            // and U+2029 included (§12.9.5), which the u8 test above misses.
            if (isLineTerminator(c) or self.isUnicodeLineTerm()) return LexError.UnterminatedString;
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
                    // `\` + U+2028/U+2029 is not a valid RegularExpressionBackslashSequence.
                    if (self.isUnicodeLineTerm()) return LexError.UnterminatedString;
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
        // Consume flags. isIdentChar accepts any byte >= 0x80, but Unicode
        // WhiteSpace (NBSP, U+2000-block, BOM, …) and line terminators
        // (U+2028/U+2029) are NOT identifier parts — stop so `/x/g<NBSP>;`
        // treats the space as trivia rather than a bogus flag byte.
        while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
            if (self.source[self.pos] >= 0x80 and (self.unicodeWsLen() > 0 or self.isUnicodeLineTerm())) break;
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
                // isIdentStart accepts any byte >= 0x80, but Unicode WhiteSpace
                // (NBSP, U+2000-block, BOM, …) and line terminators (U+2028/U+2029)
                // are NOT identifier parts — stop here so `x y` is two tokens.
                if (self.source[self.pos] >= 0x80 and (self.unicodeWsLen() > 0 or self.isUnicodeLineTerm())) break;
                self.pos += 1;
                self.column += 1;
            }
            // A `\u` escape in continuation position (e.g. `await`) — switch to
            // buffer mode, seeding it with the raw prefix already scanned, and decode
            // the rest like the escape-leading identifier path below.
            if (self.pos < self.source.len and self.source[self.pos] == '\\' and
                self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u')
            {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(self.allocator);
                try buf.appendSlice(self.allocator, self.source[start..self.pos]);
                while (self.pos < self.source.len) {
                    const nc = self.source[self.pos];
                    if (isIdentChar(nc)) {
                        try buf.append(self.allocator, nc);
                        self.pos += 1;
                        self.column += 1;
                    } else if (nc == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                        if (parseUnicodeEscape(self.source, self.pos + 2)) |r2| {
                            try appendIdentCp(&buf, self.allocator, r2.cp);
                            self.column += @intCast(r2.end - self.pos);
                            self.pos = r2.end;
                        } else break;
                    } else break;
                }
                const owned = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                const kind = lookupKeyword(owned) orelse .identifier;
                var t = Token.initSimple(kind, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
                t.value_str = owned;
                self.prev_kind = kind;
                return t;
            }
            const slice = self.source[start..self.pos];
            const kind = lookupKeyword(slice) orelse .identifier;
            var t = Token.initSimple(kind, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
            t.value_str = slice;
            self.prev_kind = kind;
            return t;
        }

        // Unicode-escape identifier: \uXXXX or \u{XXXX}
        // e.g. `export { x as μ }` — the escape must be decoded into UTF-8
        // so the exported name string equals the actual Unicode character.
        if (c == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
            if (parseUnicodeEscape(self.source, self.pos + 2)) |r| {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(self.allocator);
                try appendIdentCp(&buf, self.allocator, r.cp);
                self.column += @intCast(r.end - self.pos);
                self.pos = r.end;
                // Consume any following raw ident chars or additional \uXXXX escapes.
                while (self.pos < self.source.len) {
                    const nc = self.source[self.pos];
                    if (isIdentChar(nc)) {
                        try buf.append(self.allocator, nc);
                        self.pos += 1;
                        self.column += 1;
                    } else if (nc == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                        if (parseUnicodeEscape(self.source, self.pos + 2)) |r2| {
                            try appendIdentCp(&buf, self.allocator, r2.cp);
                            self.column += @intCast(r2.end - self.pos);
                            self.pos = r2.end;
                        } else break;
                    } else break;
                }
                const owned = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                const kind = lookupKeyword(owned) orelse .identifier;
                var t = Token.initSimple(kind, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
                t.value_str = owned;
                self.prev_kind = kind;
                return t;
            }
        }

        // Private name (`#x`): a class private field/method name or a private
        // member access `obj.#x`. Tokenize `#` + identifier as a single
        // `.identifier` token whose value INCLUDES the leading `#`, so member
        // access and field declarations resolve it as the property key "#x".
        // (We do not implement private brand checks; `#x` is a plain key.)
        if (c == '#' and self.pos + 1 < self.source.len and
            (isIdentStart(self.source[self.pos + 1]) or
                (self.source[self.pos + 1] == '\\' and self.pos + 2 < self.source.len and self.source[self.pos + 2] == 'u')))
        {
            self.pos += 1; // consume '#'
            self.column += 1;
            const name_start = self.pos;
            while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
                if (self.source[self.pos] >= 0x80 and (self.unicodeWsLen() > 0 or self.isUnicodeLineTerm())) break;
                self.pos += 1;
                self.column += 1;
            }
            // A `\u` escape in the private name (`#\u{6F}_`, `#a‌`) — switch
            // to buffer mode, seeding it with `#` + the raw prefix already scanned,
            // then decode the rest like the escape-identifier path above.
            if (self.pos < self.source.len and self.source[self.pos] == '\\' and
                self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u')
            {
                var buf = std.ArrayList(u8){};
                defer buf.deinit(self.allocator);
                try buf.append(self.allocator, '#');
                try buf.appendSlice(self.allocator, self.source[name_start..self.pos]);
                while (self.pos < self.source.len) {
                    const nc = self.source[self.pos];
                    if (isIdentChar(nc)) {
                        try buf.append(self.allocator, nc);
                        self.pos += 1;
                        self.column += 1;
                    } else if (nc == '\\' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                        if (parseUnicodeEscape(self.source, self.pos + 2)) |r2| {
                            try appendIdentCp(&buf, self.allocator, r2.cp);
                            self.column += @intCast(r2.end - self.pos);
                            self.pos = r2.end;
                        } else break;
                    } else break;
                }
                const owned = self.allocator.dupe(u8, buf.items) catch return LexError.OutOfMemory;
                var t = Token.initSimple(.identifier, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
                t.value_str = owned;
                self.prev_kind = .identifier;
                return t;
            }
            const slice = self.source[start..self.pos];
            var t = Token.initSimple(.identifier, @intCast(start), @intCast(self.pos), start_line, start_col, lt_before);
            t.value_str = slice;
            self.prev_kind = .identifier;
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

/// Append a Unicode code point to `buf` as WTF-8 / CESU-8: lone surrogates
/// (U+D800..U+DFFF) are encoded raw (3 bytes), and astral code points are
/// encoded as a UTF-16 surrogate pair (two 3-byte sequences). This makes UTF-8
/// byte-order comparison agree with ECMAScript's UTF-16 code-unit ordering for
/// `<`/`>` on strings built from `\u` escapes.
fn appendWtf8(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u32) error{OutOfMemory}!void {
    if (cp <= 0x7F) {
        try buf.append(alloc, @intCast(cp));
    } else if (cp <= 0x7FF) {
        try buf.append(alloc, @intCast(0xC0 | (cp >> 6)));
        try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
        try buf.append(alloc, @intCast(0xE0 | (cp >> 12)));
        try buf.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
    } else {
        const v = cp - 0x10000;
        const hi: u32 = 0xD800 + (v >> 10);
        const lo: u32 = 0xDC00 + (v & 0x3FF);
        try appendWtf8(buf, alloc, hi);
        try appendWtf8(buf, alloc, lo);
    }
}

/// Append a code point as *real* UTF-8, used for identifier names built from
/// `\u` escapes. Unlike `appendWtf8`, an astral code point is encoded as a
/// single 4-byte sequence (not a surrogate pair) so that `\u{1D4D1}` produces
/// the same bytes as the literal character `𝓑` in source — identifiers are keys
/// compared for equality, and regex named-group keys use real UTF-8 too, so both
/// must agree. Lone surrogates (which real UTF-8 cannot represent) fall back to
/// the WTF-8 3-byte encoding.
fn appendIdentCp(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u32) error{OutOfMemory}!void {
    if (cp >= 0x10000 and cp <= 0x10FFFF) {
        try buf.append(alloc, @intCast(0xF0 | (cp >> 18)));
        try buf.append(alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try buf.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(alloc, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try appendWtf8(buf, alloc, cp);
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDecDigit(c);
}

fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isBinDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
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

/// Parse `\uXXXX` or `\u{XXXX}` where `i` is the index in `src` right after
/// the `\u` (i.e. the first hex digit or `{`). Returns `{.cp, .end}` on
/// success (`.end` is the source index past the last consumed char); returns
/// null on malformed input without consuming anything.
fn parseUnicodeEscape(src: []const u8, i: usize) ?struct { cp: u32, end: usize } {
    if (i >= src.len) return null;
    if (src[i] == '{') {
        var j = i + 1;
        var cp: u32 = 0;
        var any: bool = false;
        while (j < src.len and src[j] != '}') : (j += 1) {
            const h = hexVal(src[j]) orelse return null;
            cp = (cp << 4) | @as(u32, h);
            if (cp > 0x10FFFF) return null;
            any = true;
        }
        if (j >= src.len or !any) return null;
        return .{ .cp = cp, .end = j + 1 };
    } else {
        if (i + 4 > src.len) return null;
        var cp: u32 = 0;
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            const h = hexVal(src[i + j]) orelse return null;
            cp = (cp << 4) | @as(u32, h);
        }
        return .{ .cp = cp, .end = i + 4 };
    }
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
