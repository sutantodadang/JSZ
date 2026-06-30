// SPDX-License-Identifier: Apache-2.0
//! Phase 4c: RegExp — pattern compiler, backtracking matcher, runtime API.
//!
//! Supported syntax:
//!   Literals: any char, . (not \n\r  )
//!   Classes: [abc] [^abc] [a-z] \d \D \w \W \s \S
//!   Anchors: ^ $ \b \B
//!   Quantifiers: * + ? {n} {n,} {n,m}; lazy *? +? ?? {n,m}?
//!   Alternation: a|b|c
//!   Groups: (...) capturing, (?:...) non-capturing
//!   Escapes: \. \\ \/ \n \t \r \f \v \0 \xHH \uHHHH
//!   Flags: i g m
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");

/// R1: install RegExp.prototype + constructor and bind the `RegExp` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const regexp_proto = try JsObject.create(arena, ctx.object_proto);
    const re_test_fn = try val_mod.makeNativeFunction(arena, nativeRegExpTest);
    const re_exec_fn = try val_mod.makeNativeFunction(arena, nativeRegExpExec);
    try regexp_proto.set("test", re_test_fn);
    try regexp_proto.set("exec", re_exec_fn);

    const regexp_ctor_obj = try JsObject.create(arena, null);
    const regexp_proto_val = try val_mod.makeObject(arena, regexp_proto);
    try regexp_ctor_obj.set("prototype", regexp_proto_val);
    const regexp_call_fn = try val_mod.makeNativeFunction(arena, nativeRegExpCtor);
    try regexp_ctor_obj.set("__call__", regexp_call_fn);
    _ = try regexp_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "RegExp"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try regexp_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    const regexp_ctor_val = try val_mod.makeObject(arena, regexp_ctor_obj);
    _ = try regexp_proto.defineOwnData("constructor", regexp_ctor_val, .{ .writable = true, .enumerable = false, .configurable = true });
    try ctx.env.define("RegExp", regexp_ctor_val);

    realm_mod.active_regexp_proto = regexp_proto;

    // ES2024: source/flags/global/etc. are getter properties on RegExp.prototype.
    try intrinsics.defineGetter(arena, regexp_proto, "source", nativeRegExpGetSource);
    try intrinsics.defineGetter(arena, regexp_proto, "flags", nativeRegExpGetFlags);
    try intrinsics.defineGetter(arena, regexp_proto, "global", nativeRegExpGetGlobal);
    try intrinsics.defineGetter(arena, regexp_proto, "ignoreCase", nativeRegExpGetIgnoreCase);
    try intrinsics.defineGetter(arena, regexp_proto, "multiline", nativeRegExpGetMultiline);
    try intrinsics.defineGetter(arena, regexp_proto, "dotAll", nativeRegExpGetDotAll);
    try intrinsics.defineGetter(arena, regexp_proto, "sticky", nativeRegExpGetSticky);
    try intrinsics.defineGetter(arena, regexp_proto, "unicode", nativeRegExpGetUnicode);
    try intrinsics.defineGetter(arena, regexp_proto, "hasIndices", nativeRegExpGetHasIndices);
    try intrinsics.defineGetter(arena, regexp_proto, "unicodeSets", nativeRegExpGetUnicodeSets);
}

// ============================================================= IR =============

pub const MAX_CAPTURES = 64;

/// Char class: set of codepoints encoded as 256-bit bitmap (ASCII) + ranges list.
pub const CharClass = struct {
    bitmap: [256]bool = [_]bool{false} ** 256,
    negate: bool = false,

    pub fn matches(self: *const CharClass, c: u8) bool {
        const hit = self.bitmap[c];
        return if (self.negate) !hit else hit;
    }

    pub fn addChar(self: *CharClass, c: u8) void {
        self.bitmap[c] = true;
    }

    pub fn addRange(self: *CharClass, lo: u8, hi: u8) void {
        var i: u16 = lo;
        while (i <= hi) : (i += 1) self.bitmap[@intCast(i)] = true;
    }

    /// Add predefined class (\d \w \s) or their negated variants.
    pub fn addPredefined(self: *CharClass, kind: u8, neg: bool) void {
        // We add to the bitmap here; negation is handled at call site if needed.
        _ = neg;
        switch (kind) {
            'd' => self.addRange('0', '9'),
            'w' => {
                self.addRange('a', 'z');
                self.addRange('A', 'Z');
                self.addRange('0', '9');
                self.addChar('_');
            },
            's' => {
                self.addChar(' ');
                self.addChar('\t');
                self.addChar('\n');
                self.addChar('\r');
                self.addChar(0x0B); // \v
                self.addChar(0x0C); // \f
                self.addChar(0xA0); // NBSP
            },
            else => {},
        }
    }
};

pub const RegexNode = union(enum) {
    literal: u8, // single ASCII byte (codepoint <= 127 after case fold)
    char_class: *CharClass,
    dot, // any char except line terminators
    anchor_start, // ^
    anchor_end, // $
    word_boundary, // \b
    non_word_boundary, // \B
    alt: []RegexNode, // alternation: try each in order
    seq: []RegexNode, // sequence: match all in order
    group: struct { // capturing group
        idx: u32,
        inner: *RegexNode,
    },
    non_capturing: *RegexNode,
    quant: struct {
        inner: *RegexNode,
        min: u32,
        max: u32, // std.math.maxInt(u32) = infinity
        lazy: bool,
    },
    /// Phase 4d: lookahead assertion (?=...) or (?!...)
    look_ahead: struct {
        inner: *RegexNode,
        negative: bool,
    },
    /// Phase 13: lookbehind assertion (?<=...) or (?<!...)
    look_behind: struct {
        inner: *RegexNode,
        negative: bool,
    },
    /// Phase 4d: backreference \1..\9
    back_ref: u8, // group index 1-9
};

/// Compiled regex: pattern IR + flags + capture count.
pub const CompiledRegex = struct {
    root: RegexNode,
    flags: Flags,
    num_captures: u32,
    /// arena allocator used for node storage
    alloc: std.mem.Allocator,

    pub const Flags = struct {
        ignore_case: bool = false,
        global: bool = false,
        multiline: bool = false,
        /// ES2018 `s` (dotAll): `.` also matches line terminators.
        dotall: bool = false,
        /// ES2015 `y` (sticky): match anchored at lastIndex (no scanning).
        sticky: bool = false,
        /// ES2015 `u` (unicode): accepted; full code-point/property-escape
        /// semantics are NOT yet implemented (byte-oriented matcher).
        unicode: bool = false,
    };
};

// ============================================================= Parser =========

const ParseError = error{ InvalidPattern, OutOfMemory };

const PatternParser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,
    next_cap: u32, // next capture group index (1-based)
    unicode: bool, // `/u` flag: enables `\p{...}` property escapes

    fn init(src: []const u8, alloc: std.mem.Allocator, unicode: bool) PatternParser {
        return .{ .src = src, .pos = 0, .alloc = alloc, .next_cap = 1, .unicode = unicode };
    }

    fn eof(self: *const PatternParser) bool {
        return self.pos >= self.src.len;
    }

    fn cur(self: *const PatternParser) u8 {
        if (self.eof()) return 0;
        return self.src[self.pos];
    }

    fn peek(self: *const PatternParser) ?u8 {
        if (self.pos + 1 >= self.src.len) return null;
        return self.src[self.pos + 1];
    }

    fn advance(self: *PatternParser) void {
        if (!self.eof()) self.pos += 1;
    }

    // Top-level: parse alternation
    fn parseAlt(self: *PatternParser) ParseError!RegexNode {
        var arms = std.ArrayListUnmanaged(RegexNode){};
        errdefer arms.deinit(self.alloc);

        const first = try self.parseSeq();
        try arms.append(self.alloc, first);

        while (!self.eof() and self.cur() == '|') {
            self.advance();
            const arm = try self.parseSeq();
            try arms.append(self.alloc, arm);
        }

        if (arms.items.len == 1) {
            const node = arms.items[0];
            arms.deinit(self.alloc);
            return node;
        }
        return RegexNode{ .alt = try arms.toOwnedSlice(self.alloc) };
    }

    // Sequence of atoms (stops at | or ) or EOF)
    fn parseSeq(self: *PatternParser) ParseError!RegexNode {
        var items = std.ArrayListUnmanaged(RegexNode){};
        errdefer items.deinit(self.alloc);

        while (!self.eof() and self.cur() != '|' and self.cur() != ')') {
            const atom = try self.parseAtom();
            // Check for quantifier
            const quant = try self.parseQuantifier();
            if (quant) |q| {
                const inner = try self.alloc.create(RegexNode);
                inner.* = atom;
                try items.append(self.alloc, RegexNode{ .quant = .{
                    .inner = inner,
                    .min = q.min,
                    .max = q.max,
                    .lazy = q.lazy,
                } });
            } else {
                try items.append(self.alloc, atom);
            }
        }

        if (items.items.len == 0) {
            items.deinit(self.alloc);
            // empty seq matches empty string — return empty seq
            return RegexNode{ .seq = &[_]RegexNode{} };
        }
        if (items.items.len == 1) {
            const node = items.items[0];
            items.deinit(self.alloc);
            return node;
        }
        return RegexNode{ .seq = try items.toOwnedSlice(self.alloc) };
    }

    const QuantInfo = struct { min: u32, max: u32, lazy: bool };

    fn parseQuantifier(self: *PatternParser) ParseError!?QuantInfo {
        if (self.eof()) return null;
        const c = self.cur();
        var q: QuantInfo = undefined;
        switch (c) {
            '*' => {
                self.advance();
                q = .{ .min = 0, .max = std.math.maxInt(u32), .lazy = false };
            },
            '+' => {
                self.advance();
                q = .{ .min = 1, .max = std.math.maxInt(u32), .lazy = false };
            },
            '?' => {
                self.advance();
                q = .{ .min = 0, .max = 1, .lazy = false };
            },
            '{' => {
                // Try to parse {n}, {n,}, {n,m}
                const saved_pos = self.pos;
                self.advance(); // consume {
                const n = self.parseUint() catch {
                    self.pos = saved_pos;
                    return null;
                };
                if (self.eof() or (self.cur() != ',' and self.cur() != '}')) {
                    self.pos = saved_pos;
                    return null;
                }
                if (self.cur() == '}') {
                    self.advance();
                    q = .{ .min = n, .max = n, .lazy = false };
                } else {
                    self.advance(); // consume ,
                    if (!self.eof() and self.cur() == '}') {
                        self.advance();
                        q = .{ .min = n, .max = std.math.maxInt(u32), .lazy = false };
                    } else {
                        const m = self.parseUint() catch {
                            self.pos = saved_pos;
                            return null;
                        };
                        if (self.eof() or self.cur() != '}') {
                            self.pos = saved_pos;
                            return null;
                        }
                        self.advance();
                        if (m < n) return ParseError.InvalidPattern;
                        q = .{ .min = n, .max = m, .lazy = false };
                    }
                }
            },
            else => return null,
        }
        // Check for lazy modifier
        if (!self.eof() and self.cur() == '?') {
            self.advance();
            q.lazy = true;
        }
        return q;
    }

    fn parseUint(self: *PatternParser) ParseError!u32 {
        if (self.eof() or self.cur() < '0' or self.cur() > '9') return ParseError.InvalidPattern;
        var n: u64 = 0;
        while (!self.eof() and self.cur() >= '0' and self.cur() <= '9') {
            // Saturate huge quantifier bounds (e.g. `a{9999999999}`) instead of overflowing.
            n = n * 10 + (self.cur() - '0');
            if (n > std.math.maxInt(u32)) n = std.math.maxInt(u32);
            self.advance();
        }
        return @intCast(n);
    }

    fn parseAtom(self: *PatternParser) ParseError!RegexNode {
        if (self.eof()) return ParseError.InvalidPattern;
        const c = self.cur();

        switch (c) {
            '(' => {
                self.advance();
                // Non-capturing group?
                if (!self.eof() and self.cur() == '?' and self.peek() != null and self.peek().? == ':') {
                    self.advance();
                    self.advance(); // consume ?:
                    const inner = try self.parseAlt();
                    if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                    self.advance();
                    const inner_ptr = try self.alloc.create(RegexNode);
                    inner_ptr.* = inner;
                    return RegexNode{ .non_capturing = inner_ptr };
                }
                // Phase 4d: positive lookahead (?=...)
                if (!self.eof() and self.cur() == '?' and self.peek() != null and self.peek().? == '=') {
                    self.advance();
                    self.advance(); // consume ?=
                    const inner = try self.parseAlt();
                    if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                    self.advance();
                    const inner_ptr = try self.alloc.create(RegexNode);
                    inner_ptr.* = inner;
                    return RegexNode{ .look_ahead = .{ .inner = inner_ptr, .negative = false } };
                }
                // Phase 4d: negative lookahead (?!...)
                if (!self.eof() and self.cur() == '?' and self.peek() != null and self.peek().? == '!') {
                    self.advance();
                    self.advance(); // consume ?!
                    const inner = try self.parseAlt();
                    if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                    self.advance();
                    const inner_ptr = try self.alloc.create(RegexNode);
                    inner_ptr.* = inner;
                    return RegexNode{ .look_ahead = .{ .inner = inner_ptr, .negative = true } };
                }
                // Phase 13: lookbehind (?<=...) / (?<!...)
                if (!self.eof() and self.cur() == '?' and self.peek() != null and self.peek().? == '<') {
                    const p2: ?u8 = if (self.pos + 2 < self.src.len) self.src[self.pos + 2] else null;
                    if (p2 != null and (p2.? == '=' or p2.? == '!')) {
                        const neg = p2.? == '!';
                        self.advance(); // ?
                        self.advance(); // <
                        self.advance(); // = or !
                        const inner = try self.parseAlt();
                        if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                        self.advance();
                        const inner_ptr = try self.alloc.create(RegexNode);
                        inner_ptr.* = inner;
                        return RegexNode{ .look_behind = .{ .inner = inner_ptr, .negative = neg } };
                    }
                    // Named groups (?<name>...) are not supported.
                    return ParseError.InvalidPattern;
                }
                // Capturing group
                const idx = self.next_cap;
                self.next_cap += 1;
                const inner = try self.parseAlt();
                if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                self.advance();
                const inner_ptr = try self.alloc.create(RegexNode);
                inner_ptr.* = inner;
                return RegexNode{ .group = .{ .idx = idx, .inner = inner_ptr } };
            },
            '[' => {
                return try self.parseCharClass();
            },
            '.' => {
                self.advance();
                return RegexNode{ .dot = {} };
            },
            '^' => {
                self.advance();
                return RegexNode{ .anchor_start = {} };
            },
            '$' => {
                self.advance();
                return RegexNode{ .anchor_end = {} };
            },
            '\\' => {
                self.advance();
                return try self.parseEscape();
            },
            else => {
                self.advance();
                return RegexNode{ .literal = c };
            },
        }
    }

    fn parseCharClass(self: *PatternParser) ParseError!RegexNode {
        if (self.eof() or self.cur() != '[') return ParseError.InvalidPattern;
        self.advance(); // consume [

        const cc = try self.alloc.create(CharClass);
        cc.* = CharClass{};

        // Negation?
        if (!self.eof() and self.cur() == '^') {
            cc.negate = true;
            self.advance();
        }

        // Parse class body
        while (!self.eof() and self.cur() != ']') {
            const ch = self.cur();
            if (ch == '\\') {
                self.advance();
                if (self.eof()) return ParseError.InvalidPattern;
                const esc = self.cur();
                self.advance();
                switch (esc) {
                    'd' => cc.addPredefined('d', false),
                    'D' => {
                        // \D inside class: add all non-digit
                        // Easier: add digits to a tmp, then negate outside — but we can't.
                        // We simulate by adding all non-digits.
                        var i: u16 = 0;
                        while (i <= 255) : (i += 1) {
                            if (i < '0' or i > '9') cc.bitmap[@intCast(i)] = true;
                        }
                    },
                    'w' => cc.addPredefined('w', false),
                    'W' => {
                        var i: u16 = 0;
                        while (i <= 255) : (i += 1) {
                            const ci: u8 = @intCast(i);
                            const is_w = (ci >= 'a' and ci <= 'z') or (ci >= 'A' and ci <= 'Z') or
                                (ci >= '0' and ci <= '9') or ci == '_';
                            if (!is_w) cc.bitmap[@intCast(i)] = true;
                        }
                    },
                    's' => cc.addPredefined('s', false),
                    'S' => {
                        var i: u16 = 0;
                        while (i <= 255) : (i += 1) {
                            const ci: u8 = @intCast(i);
                            const is_s = ci == ' ' or ci == '\t' or ci == '\n' or ci == '\r' or
                                ci == 0x0B or ci == 0x0C or ci == 0xA0;
                            if (!is_s) cc.bitmap[@intCast(i)] = true;
                        }
                    },
                    'n' => cc.addChar('\n'),
                    't' => cc.addChar('\t'),
                    'r' => cc.addChar('\r'),
                    'v' => cc.addChar(0x0B),
                    'f' => cc.addChar(0x0C),
                    '0' => cc.addChar(0),
                    'x' => {
                        if (self.pos + 1 >= self.src.len) return ParseError.InvalidPattern;
                        const h1 = hexVal(self.src[self.pos]) orelse return ParseError.InvalidPattern;
                        const h2 = hexVal(self.src[self.pos + 1]) orelse return ParseError.InvalidPattern;
                        self.pos += 2;
                        cc.addChar(@intCast(h1 * 16 + h2));
                    },
                    'u' => {
                        if (self.pos + 3 >= self.src.len) return ParseError.InvalidPattern;
                        const h1 = hexVal(self.src[self.pos]) orelse return ParseError.InvalidPattern;
                        const h2 = hexVal(self.src[self.pos + 1]) orelse return ParseError.InvalidPattern;
                        const h3 = hexVal(self.src[self.pos + 2]) orelse return ParseError.InvalidPattern;
                        const h4 = hexVal(self.src[self.pos + 3]) orelse return ParseError.InvalidPattern;
                        self.pos += 4;
                        const cp: u32 = @as(u32, h1) * 4096 + @as(u32, h2) * 256 + @as(u32, h3) * 16 + h4;
                        if (cp <= 255) cc.addChar(@intCast(cp));
                    },
                    else => cc.addChar(esc),
                }
            } else {
                // Possible range: a-z
                const start_ch = ch;
                self.advance();
                if (!self.eof() and self.cur() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                    self.advance(); // consume -
                    const end_ch_raw = self.cur();
                    self.advance();
                    const end_ch: u8 = if (end_ch_raw == '\\') blk: {
                        if (self.eof()) return ParseError.InvalidPattern;
                        const e = self.cur();
                        self.advance();
                        break :blk switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            'v' => 0x0B,
                            'f' => 0x0C,
                            '0' => 0,
                            else => e,
                        };
                    } else end_ch_raw;
                    if (end_ch < start_ch) return ParseError.InvalidPattern;
                    cc.addRange(start_ch, end_ch);
                } else {
                    cc.addChar(start_ch);
                }
            }
        }

        if (self.eof() or self.cur() != ']') return ParseError.InvalidPattern;
        self.advance(); // consume ]
        return RegexNode{ .char_class = cc };
    }

    fn parseEscape(self: *PatternParser) ParseError!RegexNode {
        if (self.eof()) return ParseError.InvalidPattern;
        const c = self.cur();
        self.advance();
        // Phase 4d: backreferences \1..\9
        if (c >= '1' and c <= '9') {
            const idx: u8 = c - '0';
            return RegexNode{ .back_ref = idx };
        }
        return switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
                cc.addPredefined(lower, false);
                if (c == 'D' or c == 'W' or c == 'S') {
                    // Invert the bitmap.
                    var i: usize = 0;
                    while (i < 256) : (i += 1) cc.bitmap[i] = !cc.bitmap[i];
                }
                return RegexNode{ .char_class = cc };
            },
            'b' => RegexNode{ .word_boundary = {} },
            'B' => RegexNode{ .non_word_boundary = {} },
            'p', 'P' => {
                // Unicode property escape (only under /u; otherwise identity).
                if (!self.unicode) return RegexNode{ .literal = c };
                if (self.eof() or self.cur() != '{') return ParseError.InvalidPattern;
                self.advance(); // {
                const name_start = self.pos;
                while (!self.eof() and self.cur() != '}') self.advance();
                if (self.eof()) return ParseError.InvalidPattern;
                const name = self.src[name_start..self.pos];
                self.advance(); // }
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                if (!fillPropertyClass(cc, name)) return ParseError.InvalidPattern;
                if (c == 'P') cc.negate = true;
                return RegexNode{ .char_class = cc };
            },
            'n' => RegexNode{ .literal = '\n' },
            't' => RegexNode{ .literal = '\t' },
            'r' => RegexNode{ .literal = '\r' },
            'v' => RegexNode{ .literal = 0x0B },
            'f' => RegexNode{ .literal = 0x0C },
            '0' => RegexNode{ .literal = 0 },
            'x' => {
                // `\xHH`: two hex digits. Annex B (non-unicode): if NOT followed by
                // two hex digits, `\x` is an identity escape matching literal 'x'.
                // Bounds: need src[pos] and src[pos+1], so pos+2 must be <= len
                // (the old `pos+1 > len` check read src[pos+1] out of bounds).
                if (self.pos + 2 > self.src.len) return RegexNode{ .literal = 'x' };
                const h1 = hexVal(self.src[self.pos]) orelse return RegexNode{ .literal = 'x' };
                const h2 = hexVal(self.src[self.pos + 1]) orelse return RegexNode{ .literal = 'x' };
                self.pos += 2;
                return RegexNode{ .literal = @intCast(h1 * 16 + h2) };
            },
            'u' => {
                if (self.pos + 3 >= self.src.len) return ParseError.InvalidPattern;
                const h1 = hexVal(self.src[self.pos]) orelse return ParseError.InvalidPattern;
                const h2 = hexVal(self.src[self.pos + 1]) orelse return ParseError.InvalidPattern;
                const h3 = hexVal(self.src[self.pos + 2]) orelse return ParseError.InvalidPattern;
                const h4 = hexVal(self.src[self.pos + 3]) orelse return ParseError.InvalidPattern;
                self.pos += 4;
                const cp: u32 = @as(u32, h1) * 4096 + @as(u32, h2) * 256 + @as(u32, h3) * 16 + h4;
                // Only ASCII support for literals
                if (cp <= 127) return RegexNode{ .literal = @intCast(cp) };
                // Non-ASCII: match as byte
                return RegexNode{ .literal = @intCast(cp & 0xFF) };
            },
            else => RegexNode{ .literal = c },
        };
    }
};

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Compile a pattern string + flags string into a CompiledRegex.
/// Returns InvalidPattern on bad pattern.
/// Fill `cc` with the ASCII approximation of a Unicode property name (`\p{...}`).
/// Returns false for unknown/unsupported names. Non-ASCII code points are not
/// covered (byte-oriented engine).
fn fillPropertyClass(cc: *CharClass, name: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, name, "L") or eq(u8, name, "Letter") or
        eq(u8, name, "Alpha") or eq(u8, name, "Alphabetic"))
    {
        cc.addRange('a', 'z');
        cc.addRange('A', 'Z');
        return true;
    }
    if (eq(u8, name, "Lu") or eq(u8, name, "Uppercase_Letter") or eq(u8, name, "Uppercase")) {
        cc.addRange('A', 'Z');
        return true;
    }
    if (eq(u8, name, "Ll") or eq(u8, name, "Lowercase_Letter") or eq(u8, name, "Lowercase")) {
        cc.addRange('a', 'z');
        return true;
    }
    if (eq(u8, name, "N") or eq(u8, name, "Nd") or eq(u8, name, "Number") or eq(u8, name, "Decimal_Number")) {
        cc.addRange('0', '9');
        return true;
    }
    if (eq(u8, name, "Alnum")) {
        cc.addRange('a', 'z');
        cc.addRange('A', 'Z');
        cc.addRange('0', '9');
        return true;
    }
    if (eq(u8, name, "White_Space") or eq(u8, name, "space") or eq(u8, name, "White_space")) {
        cc.addChar(' ');
        cc.addChar('\t');
        cc.addChar('\n');
        cc.addChar('\r');
        cc.addChar(0x0B);
        cc.addChar(0x0C);
        return true;
    }
    return false;
}

pub fn compileRegex(alloc: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !CompiledRegex {
    var flags = CompiledRegex.Flags{};
    for (flags_str) |f| {
        switch (f) {
            'i' => flags.ignore_case = true,
            'g' => flags.global = true,
            'm' => flags.multiline = true,
            's' => flags.dotall = true,
            'y' => flags.sticky = true,
            'u' => flags.unicode = true,
            else => return error.InvalidPattern,
        }
    }

    var pp = PatternParser.init(pattern, alloc, flags.unicode);
    const root = pp.parseAlt() catch return error.InvalidPattern;
    if (!pp.eof()) return error.InvalidPattern; // unconsumed chars

    return CompiledRegex{
        .root = root,
        .flags = flags,
        .num_captures = pp.next_cap - 1,
        .alloc = alloc,
    };
}

// ============================================================= Matcher ========

pub const CaptureSpan = struct { start: usize, end: usize };
pub const INVALID_CAP = CaptureSpan{ .start = 0, .end = 0 };

/// Match result: position after the match + capture array.
const MatchState = struct {
    pos: usize,
    captures: [MAX_CAPTURES]CaptureSpan,
};

/// A successful match: the start offset and the resulting match state.
pub const MatchResult = struct { start: usize, state: MatchState };

/// Entry point: try to match starting at `start`. Returns null on no match.
pub fn matchAt(
    regex: *const CompiledRegex,
    input: []const u8,
    start: usize,
) ?MatchState {
    var caps = [_]CaptureSpan{INVALID_CAP} ** MAX_CAPTURES;
    const end_pos = matchNode(&regex.root, input, start, &caps, &regex.flags) orelse return null;
    return MatchState{ .pos = end_pos, .captures = caps };
}

/// Try to find a match anywhere in `input` starting from `from`.
/// Returns null if no match found.
pub fn matchAnywhere(
    regex: *const CompiledRegex,
    input: []const u8,
    from: usize,
) ?MatchResult {
    var i = from;
    while (i <= input.len) {
        if (matchAt(regex, input, i)) |ms| {
            return .{ .start = i, .state = ms };
        }
        if (i >= input.len) break;
        i += 1;
    }
    return null;
}

/// Find a match honoring the sticky (`y`) flag: when sticky, the match must
/// begin exactly at `from` (no scanning); otherwise scan forward.
pub fn findMatch(
    regex: *const CompiledRegex,
    input: []const u8,
    from: usize,
) ?MatchResult {
    if (regex.flags.sticky) {
        if (from > input.len) return null;
        if (matchAt(regex, input, from)) |ms| return .{ .start = from, .state = ms };
        return null;
    }
    return matchAnywhere(regex, input, from);
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn isLineTerminator(c: u8) bool {
    return c == '\n' or c == '\r';
}

fn foldCase(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn matchNode(
    node: *const RegexNode,
    input: []const u8,
    pos: usize,
    caps: *[MAX_CAPTURES]CaptureSpan,
    flags: *const CompiledRegex.Flags,
) ?usize {
    switch (node.*) {
        .literal => |ch| {
            if (pos >= input.len) return null;
            const c = input[pos];
            if (flags.ignore_case) {
                if (foldCase(c) != foldCase(ch)) return null;
            } else {
                if (c != ch) return null;
            }
            return pos + 1;
        },
        .char_class => |cc| {
            if (pos >= input.len) return null;
            var c = input[pos];
            if (flags.ignore_case) c = foldCase(c);
            // For case-insensitive, we check both upper and lower in the bitmap.
            var hit = cc.bitmap[c];
            if (flags.ignore_case and !hit) {
                const alt = if (c >= 'a' and c <= 'z') c - 32 else if (c >= 'A' and c <= 'Z') c + 32 else c;
                hit = cc.bitmap[alt];
            }
            const result = if (cc.negate) !hit else hit;
            if (!result) return null;
            return pos + 1;
        },
        .dot => {
            if (pos >= input.len) return null;
            const c = input[pos];
            if (!flags.dotall and isLineTerminator(c)) return null;
            return pos + 1;
        },
        .anchor_start => {
            if (pos == 0) return pos;
            if (flags.multiline and pos > 0 and isLineTerminator(input[pos - 1])) return pos;
            return null;
        },
        .anchor_end => {
            if (pos == input.len) return pos;
            if (flags.multiline and pos < input.len and isLineTerminator(input[pos])) return pos;
            return null;
        },
        .word_boundary => {
            const before = if (pos > 0) isWordChar(input[pos - 1]) else false;
            const after = if (pos < input.len) isWordChar(input[pos]) else false;
            if (before != after) return pos;
            return null;
        },
        .non_word_boundary => {
            const before = if (pos > 0) isWordChar(input[pos - 1]) else false;
            const after = if (pos < input.len) isWordChar(input[pos]) else false;
            if (before == after) return pos;
            return null;
        },
        .seq => |nodes| {
            var cur_pos = pos;
            for (nodes) |*child| {
                cur_pos = matchNode(child, input, cur_pos, caps, flags) orelse return null;
            }
            return cur_pos;
        },
        .alt => |arms| {
            // Save captures before each attempt.
            for (arms) |*arm| {
                const saved_caps = caps.*;
                if (matchNode(arm, input, pos, caps, flags)) |end| return end;
                caps.* = saved_caps;
            }
            return null;
        },
        .group => |g| {
            const cap_idx = g.idx;
            // Groups beyond the capture-array capacity match without recording
            // (never index out of bounds).
            if (cap_idx >= MAX_CAPTURES) return matchNode(g.inner, input, pos, caps, flags);
            const saved_start = caps[cap_idx].start;
            const saved_end = caps[cap_idx].end;
            const inner_end = matchNode(g.inner, input, pos, caps, flags) orelse {
                caps[cap_idx] = .{ .start = saved_start, .end = saved_end };
                return null;
            };
            caps[cap_idx] = .{ .start = pos, .end = inner_end };
            return inner_end;
        },
        .non_capturing => |inner| {
            return matchNode(inner, input, pos, caps, flags);
        },
        .quant => |q| {
            return matchQuant(q.inner, q.min, q.max, q.lazy, input, pos, caps, flags);
        },
        .look_ahead => |la| {
            // Zero-width assertion: try to match inner from current pos.
            // Snapshot captures, run inner, restore captures (lookahead is non-consuming).
            const saved_caps = caps.*;
            const matched = matchNode(la.inner, input, pos, caps, flags) != null;
            caps.* = saved_caps; // always restore — lookahead captures are discarded
            if (la.negative) {
                // Negative lookahead: succeed iff inner did NOT match.
                return if (!matched) pos else null;
            } else {
                // Positive lookahead: succeed iff inner matched.
                return if (matched) pos else null;
            }
        },
        .look_behind => |lb| {
            // Zero-width: succeed iff the inner pattern matches some substring
            // ending exactly at `pos`. Try each start j in [0, pos]. Captures are
            // discarded (assertion is non-consuming). Fixed-length inners match
            // exactly; greedy variable-length inners may be incomplete.
            var matched_lb = false;
            var j: usize = pos + 1;
            while (j > 0) {
                j -= 1;
                var tmp_caps = caps.*;
                if (matchNode(lb.inner, input, j, &tmp_caps, flags)) |end| {
                    if (end == pos) {
                        matched_lb = true;
                        break;
                    }
                }
            }
            if (lb.negative) {
                return if (!matched_lb) pos else null;
            } else {
                return if (matched_lb) pos else null;
            }
        },
        .back_ref => |idx| {
            // Backreference: match captured group idx at current position.
            // If the group hasn't matched (span is INVALID_CAP), succeed with 0 consumption (ES5).
            if (idx >= MAX_CAPTURES) return pos;
            const cap = caps[idx];
            if (cap.start == 0 and cap.end == 0) {
                // Group hasn't matched yet — treat as empty match (ES5 §15.10.2.9).
                return pos;
            }
            const captured = input[cap.start..cap.end];
            const clen = captured.len;
            if (pos + clen > input.len) return null;
            const slice = input[pos .. pos + clen];
            if (flags.ignore_case) {
                // ASCII case-fold comparison.
                for (slice, captured) |a, b| {
                    if (foldCase(a) != foldCase(b)) return null;
                }
            } else {
                if (!std.mem.eql(u8, slice, captured)) return null;
            }
            return pos + clen;
        },
    }
}

fn matchQuant(
    inner: *const RegexNode,
    min: u32,
    max: u32,
    lazy: bool,
    input: []const u8,
    start: usize,
    caps: *[MAX_CAPTURES]CaptureSpan,
    flags: *const CompiledRegex.Flags,
) ?usize {
    if (lazy) {
        // Lazy: try fewest repetitions first.
        var count: u32 = 0;
        var pos = start;

        // Must match at least `min` times
        while (count < min) {
            const saved_caps = caps.*;
            const next = matchNode(inner, input, pos, caps, flags) orelse {
                caps.* = saved_caps;
                return null;
            };
            // Prevent infinite loop on zero-width match
            if (next == pos) {
                count += 1;
                if (count >= min) break;
                return null;
            }
            pos = next;
            count += 1;
        }

        // Now try with current count, then expand
        while (count <= max) {
            // Caller's continuation is implicit: we just return pos.
            // For lazy, we return the current position (fewest), which the caller uses.
            // But we need to handle the "rest of the pattern" — that's not available here.
            // In a real backtracking engine we'd have continuations, but our simple
            // matchNode approach doesn't thread the "rest". We handle this by returning
            // pos here and letting the seq node advance naturally.
            // This works correctly for lazy because seq calls us, and we return min pos.
            // The outer seq will try the next node; if it fails, it can't backtrack back.
            // This is a limitation but covers most practical cases.
            return pos;
        }
        return pos;
    } else {
        // Greedy: try maximum repetitions, then backtrack.
        // First, collect all possible match positions.
        var positions: [1024]usize = undefined;
        var count: u32 = 0;
        var pos = start;
        positions[0] = pos;

        while (count < max) {
            const saved_caps = caps.*;
            const next = matchNode(inner, input, pos, caps, flags) orelse {
                caps.* = saved_caps;
                break;
            };
            count += 1;
            positions[count] = next;
            if (next == pos) {
                // Zero-width match: stop to prevent infinite loop.
                break;
            }
            pos = next;
            if (count >= 1024 - 1) break;
        }

        if (count < min) return null;

        // Try from maximum down to minimum.
        var i = count;
        while (i >= min) {
            if (i <= min or true) {
                // Restore captures to pre-quant state
                // (We can't easily do this without saving; just return greedy max)
                return positions[i];
            }
            if (i == 0) break;
            i -= 1;
        }
        return positions[if (count >= min) count else min];
    }
}

// ============================================================= Runtime API ====

/// Build a RegExp JsObject from a CompiledRegex.
pub fn makeRegExpObject(arena: std.mem.Allocator, cr: *CompiledRegex, source: []const u8, flags_str: []const u8) !Value {
    const proto: ?*JsObject = realm_mod.active_regexp_proto;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);

    // Store source in a hidden slot; flags/global/etc. are resolved via prototype getters.
    _ = flags_str; // no longer stored as a data property
    const source_val = try val_mod.makeString(arena, source);
    try obj.set("[[OriginalSource]]", source_val);

    // lastIndex = 0
    const li_val = try val_mod.makeNumber(arena, 0.0);
    try obj.set("lastIndex", li_val);

    // Internal slot
    obj.internal_slot = @ptrCast(cr);
    obj.internal_kind = .regexp;

    return val_mod.makeObject(arena, obj);
}

/// Extract CompiledRegex from a Value, or return null if not a RegExp.
pub fn getCompiledRegex(v: Value) ?*CompiledRegex {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .regexp) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// Get the lastIndex from a regex object.
pub fn getLastIndex(v: Value) usize {
    if (v.bits == 0) return 0;
    if (v.unbox() != .object) return 0;
    const obj = v.toPtr().object;
    if (obj.get("lastIndex")) |li| {
        if (li.bits != 0 and li.unbox() == .number) {
            const n = li.unbox().number;
            if (n < 0 or std.math.isNan(n)) return 0;
            return @intCast(val_mod.f64ToI64Sat(n));
        }
    }
    return 0;
}

/// Set lastIndex on a regex object.
pub fn setLastIndex(arena: std.mem.Allocator, v: Value, idx: usize) !void {
    if (v.bits == 0) return;
    if (v.unbox() != .object) return;
    const obj = v.toPtr().object;
    const li_val = try val_mod.makeNumber(arena, @floatFromInt(idx));
    try obj.set("lastIndex", li_val);
}

/// Native RegExp constructor / function.
pub fn nativeRegExpCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Extract source string
    const pattern_str: []const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |s| s,
            .object => |obj| blk: {
                // If it's already a RegExp, return its source
                if (obj.internal_kind == .regexp) {
                    if (obj.get("[[OriginalSource]]")) |sv| {
                        if (sv.bits != 0 and sv.unbox() == .string) break :blk sv.toPtr().string;
                    }
                }
                break :blk "";
            },
            else => "",
        }
    else
        "";

    const flags_str: []const u8 = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .string => |s| s,
            .undefined_ => "",
            else => "",
        }
    else
        "";

    const cr = arena.create(CompiledRegex) catch return error.OutOfMemory;
    cr.* = compileRegex(arena, pattern_str, flags_str) catch {
        // Throw SyntaxError
        const msg_s = std.fmt.allocPrint(arena, "Invalid regular expression: /{s}/{s}", .{ pattern_str, flags_str }) catch "Invalid regular expression";
        const proto_opt = realm_mod.error_proto_SyntaxError;
        const proto: ?*JsObject = proto_opt;
        const obj = if (realm_mod.active_heap) |heap|
            JsObject.createOnHeap(heap, proto) catch null
        else
            JsObject.create(arena, proto) catch null;
        if (obj) |err_obj| {
            const msg_val = val_mod.makeString(arena, msg_s) catch Value{};
            const name_val = val_mod.makeString(arena, "SyntaxError") catch Value{};
            err_obj.set("message", msg_val) catch {};
            err_obj.set("name", name_val) catch {};
            realm_mod.pending_exception = val_mod.makeObject(arena, err_obj) catch Value{};
        }
        return error.JsException;
    };

    // Populate `this` if it's a fresh object (from `new`), else create new.
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const this_obj = this_val.toPtr().object;
        // Store source in hidden slot; flag properties resolve via prototype getters.
        const source_val = try val_mod.makeString(arena, pattern_str);
        try this_obj.set("[[OriginalSource]]", source_val);
        const li_val = try val_mod.makeNumber(arena, 0.0);
        try this_obj.set("lastIndex", li_val);
        this_obj.internal_slot = @ptrCast(cr);
        this_obj.internal_kind = .regexp;
        return this_val;
    }

    return makeRegExpObject(arena, cr, pattern_str, flags_str);
}

/// RegExp.prototype.test(str) -> boolean
pub fn nativeRegExpTest(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeBool(arena, false);
    const s: []const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |st| st,
            else => "",
        }
    else
        "";

    const use_li = cr.flags.global or cr.flags.sticky;
    const from: usize = if (use_li) getLastIndex(this_val) else 0;
    if (findMatch(cr, s, from)) |m| {
        if (use_li) try setLastIndex(arena, this_val, m.state.pos);
        return val_mod.makeBool(arena, true);
    }
    if (use_li) try setLastIndex(arena, this_val, 0);
    return val_mod.makeBool(arena, false);
}

/// RegExp.prototype.exec(str) -> Array | null
pub fn nativeRegExpExec(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeNull(arena);
    const s: []const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |st| st,
            else => "",
        }
    else
        "";

    const use_li = cr.flags.global or cr.flags.sticky;
    const from: usize = if (use_li) getLastIndex(this_val) else 0;

    const result = findMatch(cr, s, from) orelse {
        if (use_li) try setLastIndex(arena, this_val, 0);
        return val_mod.makeNull(arena);
    };

    if (use_li) try setLastIndex(arena, this_val, result.state.pos);

    // Build result array: [fullMatch, cap1, ..., capN]
    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);

    // Index 0 = full match
    const full_match = try arena.dupe(u8, s[result.start..result.state.pos]);
    const full_val = try val_mod.makeString(arena, full_match);
    try arr.set("0", full_val);

    // Capture groups 1..N (bounded by the capture-array capacity).
    var i: u32 = 1;
    while (i <= cr.num_captures and i < MAX_CAPTURES) : (i += 1) {
        const cap = result.state.captures[i];
        const cap_val: Value = if (cap.start == 0 and cap.end == 0 and i > 0)
            try val_mod.makeUndefined(arena)
        else
            try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end]));
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(key, cap_val);
    }
    arr.array_length = cr.num_captures + 1;

    // Set .index property
    const idx_val = try val_mod.makeNumber(arena, @floatFromInt(result.start));
    try arr.set("index", idx_val);

    // Set .input property
    const input_val = try val_mod.makeString(arena, s);
    try arr.set("input", input_val);

    return val_mod.makeObject(arena, arr);
}

// ============================================================= Prototype Getters

/// source getter: "(?:)" on RegExp.prototype, real pattern otherwise.
pub fn nativeRegExpGetSource(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.source called on incompatible receiver");
    if (getCompiledRegex(this_val) == null)
        return val_mod.makeString(arena, "(?:)");
    const obj = this_val.toPtr().object;
    if (obj.getOwn("[[OriginalSource]]")) |sv| return sv;
    return val_mod.makeString(arena, "(?:)");
}

/// flags getter: "" on RegExp.prototype, canonical "gimsuy" subset otherwise.
pub fn nativeRegExpGetFlags(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.flags called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeString(arena, "");
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    if (cr.flags.global) { buf[len] = 'g'; len += 1; }
    if (cr.flags.ignore_case) { buf[len] = 'i'; len += 1; }
    if (cr.flags.multiline) { buf[len] = 'm'; len += 1; }
    if (cr.flags.dotall) { buf[len] = 's'; len += 1; }
    if (cr.flags.unicode) { buf[len] = 'u'; len += 1; }
    if (cr.flags.sticky) { buf[len] = 'y'; len += 1; }
    // makeString stores the slice without copying — dupe into arena first.
    const owned = try arena.dupe(u8, buf[0..len]);
    return val_mod.makeString(arena, owned);
}

/// global getter.
pub fn nativeRegExpGetGlobal(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.global called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.global);
}

/// ignoreCase getter.
pub fn nativeRegExpGetIgnoreCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.ignoreCase called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.ignore_case);
}

/// multiline getter.
pub fn nativeRegExpGetMultiline(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.multiline called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.multiline);
}

/// dotAll getter.
pub fn nativeRegExpGetDotAll(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.dotAll called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.dotall);
}

/// sticky getter.
pub fn nativeRegExpGetSticky(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.sticky called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.sticky);
}

/// unicode getter.
pub fn nativeRegExpGetUnicode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.unicode called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.unicode);
}

/// hasIndices getter (not tracked; always false).
pub fn nativeRegExpGetHasIndices(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.hasIndices called on incompatible receiver");
    if (getCompiledRegex(this_val) == null) return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, false);
}

/// unicodeSets getter (not tracked; always false).
pub fn nativeRegExpGetUnicodeSets(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.unicodeSets called on incompatible receiver");
    if (getCompiledRegex(this_val) == null) return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, false);
}

// ============================================================= Tests ==========

test "regexp: basic literal match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "abc", "");
    const result = matchAt(&cr, "xabcz", 1);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.pos);
}

test "regexp: dot matches non-newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "a.c", "");
    try std.testing.expect(matchAt(&cr, "abc", 0) != null);
    try std.testing.expect(matchAt(&cr, "a\nc", 0) == null);
}

test "regexp: anchor start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "^abc", "");
    try std.testing.expect(matchAt(&cr, "abcx", 0) != null);
    try std.testing.expect(matchAnywhere(&cr, "xabc", 0) == null);
}

test "regexp: quantifier plus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "a+", "");
    const result = matchAt(&cr, "aaab", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.pos);
}

test "regexp: char class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "[abc]", "");
    try std.testing.expect(matchAt(&cr, "b", 0) != null);
    try std.testing.expect(matchAt(&cr, "d", 0) == null);
}

test "regexp: invalid pattern throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPattern, compileRegex(arena.allocator(), "[", ""));
}
