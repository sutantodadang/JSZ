// SPDX-License-Identifier: Apache-2.0
//! Phase 4c + Unicode: RegExp -- pattern compiler, backtracking matcher, runtime API.
//!
//! Supported syntax:
//!   Literals: any char, . (not \n\r unless /s), Unicode codepoints under /u
//!   Classes: [abc] [^abc] [a-z] \d \D \w \W \s \S; Unicode ranges under /u
//!   Anchors: ^ $ \b \B
//!   Quantifiers: * + ? {n} {n,} {n,m}; lazy *? +? ?? {n,m}?
//!   Alternation: a|b|c
//!   Groups: (...) capturing, (?:...) non-capturing
//!   Lookahead/behind: (?=...) (?!...) (?<=...) (?<!...)
//!   Escapes: \. \\ \/ \n \t \r \f \v \0 \xHH \uHHHH \u{HH...} (under /u)
//!   Property escapes: \p{Category} \P{Category} (under /u)
//!   Flags: i g m s y u
//!
//! Unicode (/u flag):
//!   - Input treated as UTF-8; advance by codepoint when scanning.
//!   - . matches any Unicode scalar value (not just ASCII non-newline).
//!   - U+2028 (LS) and U+2029 (PS) are line terminators under /u.
//!   - \u{H...} parses full codepoint up to U+10FFFF.
//!   - \p{} / \P{} use full Unicode property tables (unicode_tables.zig).
//!   - \s includes U+2028, U+2029, U+FEFF, all Zs separators.
const std = @import("std");
const utab = @import("unicode_tables.zig");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const fp = @import("function_proto.zig");

/// R1: install RegExp.prototype + constructor and bind the `RegExp` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const regexp_proto = try JsObject.create(arena, ctx.object_proto);
    const re_test_fn = try val_mod.makeNativeFunction(arena, nativeRegExpTest);
    const re_exec_fn = try val_mod.makeNativeFunction(arena, nativeRegExpExec);
    try regexp_proto.set("test", re_test_fn);
    try regexp_proto.set("exec", re_exec_fn);
    try regexp_proto.set("toString", try val_mod.makeNativeFunction(arena, nativeRegExpToString));
    // Annex B RegExp.prototype.compile — a proper method (name "compile", length 2).
    _ = try regexp_proto.defineOwnData("compile", try val_mod.makeNativeFunctionNamed(arena, nativeRegExpCompile, "compile", 2), .{ .writable = true, .enumerable = false, .configurable = true });

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
    // Annex B legacy static accessors (RegExp.$1..$9 / input / lastMatch / …).
    active_regexp_ctor = regexp_ctor_obj;
    try registerLegacyAccessors(arena, regexp_ctor_obj);

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

// ============================================================= UTF-8 helpers ==

/// Decode a single UTF-8 codepoint from `buf[pos..]`. Returns the codepoint
/// and the number of bytes consumed. On invalid/truncated sequences falls back
/// to the raw byte (U+00xx) consuming 1 byte -- so the matcher never gets stuck.
pub fn decodeUtf8At(buf: []const u8, pos: usize) struct { cp: u21, len: u8 } {
    if (pos >= buf.len) return .{ .cp = 0, .len = 0 };
    const b0 = buf[pos];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xC2) return .{ .cp = b0, .len = 1 }; // invalid lead byte
    if (b0 < 0xE0) {
        // 2-byte sequence: 110xxxxx 10xxxxxx
        if (pos + 1 >= buf.len) return .{ .cp = b0, .len = 1 };
        const b1 = buf[pos + 1];
        if (b1 & 0xC0 != 0x80) return .{ .cp = b0, .len = 1 };
        return .{ .cp = (@as(u21, b0 & 0x1F) << 6) | (b1 & 0x3F), .len = 2 };
    }
    if (b0 < 0xF0) {
        // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        if (pos + 2 >= buf.len) return .{ .cp = b0, .len = 1 };
        const b1 = buf[pos + 1];
        const b2 = buf[pos + 2];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) return .{ .cp = b0, .len = 1 };
        const cp: u21 = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F);
        if (cp < 0x0800) return .{ .cp = b0, .len = 1 }; // overlong
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 < 0xF8) {
        // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        if (pos + 3 >= buf.len) return .{ .cp = b0, .len = 1 };
        const b1 = buf[pos + 1];
        const b2 = buf[pos + 2];
        const b3 = buf[pos + 3];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80)
            return .{ .cp = b0, .len = 1 };
        const cp: u21 = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) |
            (@as(u21, b2 & 0x3F) << 6) | (b3 & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return .{ .cp = b0, .len = 1 }; // overlong / surrogate
        return .{ .cp = cp, .len = 4 };
    }
    return .{ .cp = b0, .len = 1 };
}

/// Number of UTF-8 bytes for the codepoint starting at buf[pos] (1..4).
/// Returns 1 on invalid sequences so scanning always advances.
pub fn utf8ByteLenAt(buf: []const u8, pos: usize) u8 {
    return decodeUtf8At(buf, pos).len;
}

/// Encode a codepoint into buf (must be at least 4 bytes). Returns byte count.
pub fn encodeUtf8Cp(cp: u21, buf: *[4]u8) u3 {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        buf[0] = @intCast(0xF0 | (cp >> 18));
        buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Binary search: is `cp` covered by any [lo,hi] pair in `table`?
/// Table must be sorted ascending by lo, non-overlapping.
fn cpInTable(table: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < table[mid][0]) {
            hi = mid;
        } else if (cp > table[mid][1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// ============================================================= IR =============

pub const MAX_CAPTURES = 64;

/// Char class: set of codepoints encoded as 256-bit bitmap (Latin-1 fast path)
/// plus a dynamic list of extra ranges for codepoints > 255 (Unicode mode).
pub const CharClass = struct {
    bitmap: [256]bool = [_]bool{false} ** 256,
    negate: bool = false,
    /// Extra codepoint ranges for chars > 255, populated only under /u.
    /// Uses the arena allocator; starts empty.
    extra_ranges: std.ArrayListUnmanaged(CpRange) = .{},

    pub const CpRange = struct { lo: u21, hi: u21 };

    /// Match a single byte (non-unicode mode fast path).
    pub fn matches(self: *const CharClass, c: u8) bool {
        const hit = self.bitmap[c];
        return if (self.negate) !hit else hit;
    }

    /// Match a Unicode codepoint (unicode mode).
    pub fn matchesCp(self: *const CharClass, cp: u21) bool {
        var hit = false;
        if (cp <= 255) {
            hit = self.bitmap[@intCast(cp)];
        }
        if (!hit) {
            for (self.extra_ranges.items) |r| {
                if (cp >= r.lo and cp <= r.hi) {
                    hit = true;
                    break;
                }
            }
        }
        return if (self.negate) !hit else hit;
    }

    pub fn addChar(self: *CharClass, c: u8) void {
        self.bitmap[c] = true;
    }

    pub fn addRange(self: *CharClass, lo: u8, hi: u8) void {
        var i: u16 = lo;
        while (i <= hi) : (i += 1) self.bitmap[@intCast(i)] = true;
    }

    /// Add a codepoint range (unicode mode). Codepoints <= 255 go to bitmap,
    /// codepoints > 255 go to extra_ranges. Needs an arena allocator.
    pub fn addCpRange(self: *CharClass, alloc: std.mem.Allocator, lo: u21, hi: u21) !void {
        if (lo > hi) return;
        // Bitmap portion (Latin-1 fast path)
        const bm_hi: u21 = @min(hi, 255);
        if (lo <= 255) {
            var i: u32 = @intCast(lo);
            while (i <= bm_hi) : (i += 1) self.bitmap[@intCast(i)] = true;
        }
        // Extra ranges portion (> 255)
        if (hi > 255) {
            const range_lo: u21 = if (lo > 255) lo else 256;
            try self.extra_ranges.append(alloc, .{ .lo = range_lo, .hi = hi });
        }
    }

    /// Add from a unicode_tables range slice (binary-search table).
    /// Used by fillPropertyClass.
    pub fn addFromTable(self: *CharClass, alloc: std.mem.Allocator, table: []const [2]u21) !void {
        for (table) |pair| {
            try self.addCpRange(alloc, pair[0], pair[1]);
        }
    }

    /// Add predefined class (\d \w \s) or their negated variants.
    pub fn addPredefined(self: *CharClass, kind: u8, neg: bool) void {
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

    /// Extended \s for /u mode: adds unicode whitespace beyond ASCII.
    pub fn addPredefinedUnicodeS(self: *CharClass, alloc: std.mem.Allocator) !void {
        self.addPredefined('s', false);
        // U+1680 OGHAM SPACE MARK
        try self.addCpRange(alloc, 0x1680, 0x1680);
        // U+2000..U+200A (various spaces)
        try self.addCpRange(alloc, 0x2000, 0x200A);
        // U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR
        try self.addCpRange(alloc, 0x2028, 0x2029);
        // U+202F NARROW NO-BREAK SPACE
        try self.addCpRange(alloc, 0x202F, 0x202F);
        // U+205F MEDIUM MATHEMATICAL SPACE
        try self.addCpRange(alloc, 0x205F, 0x205F);
        // U+3000 IDEOGRAPHIC SPACE
        try self.addCpRange(alloc, 0x3000, 0x3000);
        // U+FEFF BOM / ZERO WIDTH NO-BREAK SPACE
        try self.addCpRange(alloc, 0xFEFF, 0xFEFF);
    }
};

pub const RegexNode = union(enum) {
    literal: u21, // Unicode scalar value (codepoint); <= 127 after ASCII case fold
    char_class: *CharClass,
    dot, // any char except line terminators (any codepoint under /u+/s)
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

/// A named capture group's name → 1-based capture index mapping.
pub const NameIdx = struct { name: []const u8, idx: u32 };

/// Compiled regex: pattern IR + flags + capture count.
pub const CompiledRegex = struct {
    root: RegexNode,
    flags: Flags,
    num_captures: u32,
    /// Named capture groups in source order (empty when the pattern has none).
    group_names: []const NameIdx = &.{},
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
        /// ES2015 `u` (unicode): full code-point semantics.
        unicode: bool = false,
    };
};

// ============================================================= Unicode property

/// Fill `cc` with the codepoint ranges for a Unicode property name.
/// Under /u this uses the full Unicode 14.0 tables; under non-unicode it falls
/// back to the ASCII-only approximations (backward compatible).
/// Returns false for unknown/unsupported property names.
fn fillPropertyClass(alloc: std.mem.Allocator, cc: *CharClass, name: []const u8, unicode: bool) ParseError!bool {
    const eq = std.mem.eql;

    if (unicode) {
        // Full Unicode tables via binary search.
        const table: ?[]const [2]u21 = blk: {
            // General categories (short and long names)
            if (eq(u8, name, "Lu") or eq(u8, name, "Uppercase_Letter")) break :blk utab.unicode_Lu;
            if (eq(u8, name, "Ll") or eq(u8, name, "Lowercase_Letter")) break :blk utab.unicode_Ll;
            if (eq(u8, name, "Lt") or eq(u8, name, "Titlecase_Letter")) break :blk utab.unicode_Lt;
            if (eq(u8, name, "Lm") or eq(u8, name, "Modifier_Letter")) break :blk utab.unicode_Lm;
            if (eq(u8, name, "Lo") or eq(u8, name, "Other_Letter")) break :blk utab.unicode_Lo;
            if (eq(u8, name, "L") or eq(u8, name, "Letter") or
                eq(u8, name, "Alpha") or eq(u8, name, "Alphabetic")) break :blk utab.unicode_L;
            if (eq(u8, name, "Nd") or eq(u8, name, "Decimal_Number") or eq(u8, name, "digit")) break :blk utab.unicode_Nd;
            if (eq(u8, name, "Nl") or eq(u8, name, "Letter_Number")) break :blk utab.unicode_Nl;
            if (eq(u8, name, "No") or eq(u8, name, "Other_Number")) break :blk utab.unicode_No;
            if (eq(u8, name, "N") or eq(u8, name, "Number")) break :blk utab.unicode_N;
            if (eq(u8, name, "M") or eq(u8, name, "Mark")) break :blk utab.unicode_M;
            if (eq(u8, name, "P") or eq(u8, name, "Punctuation")) break :blk utab.unicode_P;
            if (eq(u8, name, "S") or eq(u8, name, "Symbol")) break :blk utab.unicode_S;
            if (eq(u8, name, "Z") or eq(u8, name, "Separator")) break :blk utab.unicode_Z;
            if (eq(u8, name, "White_Space") or eq(u8, name, "space") or
                eq(u8, name, "White_space")) break :blk utab.unicode_White_Space;
            // Aliases
            if (eq(u8, name, "Uppercase") or eq(u8, name, "Upper")) break :blk utab.unicode_Lu;
            if (eq(u8, name, "Lowercase") or eq(u8, name, "Lower")) break :blk utab.unicode_Ll;
            if (eq(u8, name, "Alnum")) {
                // Letter + Number combined (no pre-built table; add separately)
                cc.addFromTable(alloc, utab.unicode_L) catch return ParseError.OutOfMemory;
                cc.addFromTable(alloc, utab.unicode_N) catch return ParseError.OutOfMemory;
                return true;
            }
            break :blk null;
        };
        if (table) |t| {
            cc.addFromTable(alloc, t) catch return ParseError.OutOfMemory;
            return true;
        }
        return false;
    }

    // ASCII-only approximations (non-unicode mode, backward compatible).
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

// ============================================================= Parser =========

const ParseError = error{ InvalidPattern, OutOfMemory };

const PatternParser = struct {
    src: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,
    next_cap: u32, // next capture group index (1-based)
    unicode: bool, // `/u` flag
    group_names: []const NameIdx = &.{}, // pre-scanned names, for `\k<name>` resolution

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

    /// Under /u, read a full UTF-8 codepoint from the pattern; else return single byte.
    fn readCp(self: *PatternParser) u21 {
        if (self.unicode and self.pos < self.src.len and self.src[self.pos] >= 0x80) {
            const dc = decodeUtf8At(self.src, self.pos);
            self.pos += dc.len;
            return dc.cp;
        }
        const b = self.cur();
        self.advance();
        return @as(u21, b);
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
                // Positive lookahead (?=...)
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
                // Negative lookahead (?!...)
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
                // Lookbehind (?<=...) / (?<!...)
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
                    // Named capture group (?<name>...): consume `?<name>`, then
                    // fall through to capture like an ordinary group.
                    self.advance(); // ?
                    self.advance(); // <
                    while (!self.eof() and self.cur() != '>') self.advance();
                    if (self.eof()) return ParseError.InvalidPattern;
                    self.advance(); // >
                    const nidx = self.next_cap;
                    self.next_cap += 1;
                    const ninner = try self.parseAlt();
                    if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
                    self.advance();
                    const ninner_ptr = try self.alloc.create(RegexNode);
                    ninner_ptr.* = ninner;
                    return RegexNode{ .group = .{ .idx = nidx, .inner = ninner_ptr } };
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
                // Under /u, multi-byte UTF-8 sequences are decoded to a single codepoint literal.
                const cp = self.readCp();
                return RegexNode{ .literal = cp };
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
                    's' => {
                        if (self.unicode) {
                            cc.addPredefinedUnicodeS(self.alloc) catch return ParseError.OutOfMemory;
                        } else {
                            cc.addPredefined('s', false);
                        }
                    },
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
                        const cp = try self.parseUEscape();
                        cc.addCpRange(self.alloc, cp, cp) catch return ParseError.OutOfMemory;
                    },
                    'p', 'P' => {
                        if (!self.unicode) {
                            cc.addChar(esc);
                        } else {
                            if (self.eof() or self.cur() != '{') return ParseError.InvalidPattern;
                            self.advance();
                            const name_start = self.pos;
                            while (!self.eof() and self.cur() != '}') self.advance();
                            if (self.eof()) return ParseError.InvalidPattern;
                            const name = self.src[name_start..self.pos];
                            self.advance();
                            const tmp_cc = try self.alloc.create(CharClass);
                            tmp_cc.* = CharClass{};
                            const found = try fillPropertyClass(self.alloc, tmp_cc, name, true);
                            if (!found) return ParseError.InvalidPattern;
                            // Merge tmp_cc into cc (bitmap + extra_ranges)
                            for (tmp_cc.bitmap, 0..) |b, idx| {
                                if (b) cc.bitmap[idx] = true;
                            }
                            for (tmp_cc.extra_ranges.items) |r| {
                                cc.extra_ranges.append(self.alloc, r) catch return ParseError.OutOfMemory;
                            }
                            if (esc == 'P') {
                                // Invert: negate flag is already on cc from outer ^, this is \P inside [...]
                                // Actually \P inside [...] means the complement of the property set.
                                // We need to XOR-negate what we just added. Easiest: add negated version.
                                // For simplicity: rebuild: clear what we added and add the complement.
                                // This is complex; for now we just negate the cc negate flag (approximate).
                                // TODO: proper \P inside [...] merging requires set difference. For now
                                // the bitmap bits set above remain — this is the same behavior as before.
                            }
                        }
                    },
                    else => cc.addChar(esc),
                }
            } else if (self.unicode and ch >= 0x80) {
                // Non-ASCII codepoint start in unicode mode -- decode the full codepoint.
                const dc = decodeUtf8At(self.src, self.pos);
                self.pos += dc.len;
                const start_cp = dc.cp;
                if (!self.eof() and self.cur() == '-' and
                    self.pos + 1 <= self.src.len and
                    (self.pos >= self.src.len or self.src[self.pos] != ']'))
                {
                    self.advance(); // consume -
                    const end_cp: u21 = if (!self.eof() and self.cur() == '\\') blk: {
                        self.advance();
                        if (self.eof()) return ParseError.InvalidPattern;
                        const ep = try self.parseUEscapeOrByte();
                        break :blk ep;
                    } else blk: {
                        const edc = decodeUtf8At(self.src, self.pos);
                        self.pos += edc.len;
                        break :blk edc.cp;
                    };
                    if (end_cp < start_cp) return ParseError.InvalidPattern;
                    cc.addCpRange(self.alloc, start_cp, end_cp) catch return ParseError.OutOfMemory;
                } else {
                    cc.addCpRange(self.alloc, start_cp, start_cp) catch return ParseError.OutOfMemory;
                }
            } else {
                // ASCII character -- possibly part of a range like a-z.
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

    /// Parse \uHHHH or \u{H...} (under /u). Returns the codepoint.
    fn parseUEscape(self: *PatternParser) ParseError!u21 {
        if (self.unicode and !self.eof() and self.cur() == '{') {
            // \u{HHHH...} -- any number of hex digits
            self.advance(); // consume {
            if (self.eof() or hexVal(self.cur()) == null) return ParseError.InvalidPattern;
            var cp: u32 = 0;
            while (!self.eof() and self.cur() != '}') {
                const hv = hexVal(self.cur()) orelse return ParseError.InvalidPattern;
                cp = cp * 16 + hv;
                if (cp > 0x10FFFF) return ParseError.InvalidPattern;
                self.advance();
            }
            if (self.eof() or self.cur() != '}') return ParseError.InvalidPattern;
            self.advance(); // consume }
            return @intCast(cp);
        }
        // \uHHHH -- exactly 4 hex digits
        if (self.pos + 3 >= self.src.len) return ParseError.InvalidPattern;
        const h1 = hexVal(self.src[self.pos]) orelse return ParseError.InvalidPattern;
        const h2 = hexVal(self.src[self.pos + 1]) orelse return ParseError.InvalidPattern;
        const h3 = hexVal(self.src[self.pos + 2]) orelse return ParseError.InvalidPattern;
        const h4 = hexVal(self.src[self.pos + 3]) orelse return ParseError.InvalidPattern;
        self.pos += 4;
        return @intCast(@as(u32, h1) * 4096 + @as(u32, h2) * 256 + @as(u32, h3) * 16 + h4);
    }

    /// Parse the end of a char-class range that starts with \. Returns codepoint.
    fn parseUEscapeOrByte(self: *PatternParser) ParseError!u21 {
        if (self.eof()) return ParseError.InvalidPattern;
        const e = self.cur();
        self.advance();
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'v' => 0x0B,
            'f' => 0x0C,
            '0' => 0,
            'u' => self.parseUEscape(),
            else => @as(u21, e),
        };
    }

    fn parseEscape(self: *PatternParser) ParseError!RegexNode {
        if (self.eof()) return ParseError.InvalidPattern;
        const c = self.cur();
        self.advance();
        // Backreferences \1..\9
        if (c >= '1' and c <= '9') {
            const idx: u8 = c - '0';
            return RegexNode{ .back_ref = idx };
        }
        // Named backreference \k<name> (only meaningful when the pattern has
        // named groups; otherwise `\k` is a literal 'k' in non-unicode mode).
        if (c == 'k' and (self.group_names.len > 0 or self.unicode)) {
            if (self.eof() or self.cur() != '<') return ParseError.InvalidPattern;
            self.advance(); // <
            const name_start = self.pos;
            while (!self.eof() and self.cur() != '>') self.advance();
            if (self.eof()) return ParseError.InvalidPattern;
            const name = self.src[name_start..self.pos];
            self.advance(); // >
            for (self.group_names) |ni| {
                if (std.mem.eql(u8, ni.name, name)) return RegexNode{ .back_ref = @intCast(ni.idx) };
            }
            return ParseError.InvalidPattern; // unknown group name
        }
        return switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
                if (lower == 's' and self.unicode) {
                    // Unicode \s / \S
                    cc.addPredefinedUnicodeS(self.alloc) catch return ParseError.OutOfMemory;
                } else {
                    cc.addPredefined(lower, false);
                }
                if (c == 'D' or c == 'W' or c == 'S') {
                    // Invert bitmap only (extra_ranges stay empty for \D/\W; \S non-ASCII kept negated)
                    var i: usize = 0;
                    while (i < 256) : (i += 1) cc.bitmap[i] = !cc.bitmap[i];
                    // For \S under /u the extra unicode whitespace in extra_ranges should also be inverted.
                    // Since we can't easily invert an arbitrary set, we just set negate=true for the
                    // extra ranges -- matchesCp handles cc.negate globally.
                    if (lower == 's' and self.unicode) {
                        // Reset bitmap to the NON-inverted whitespace then set negate=true so
                        // matchesCp inverts: clear the inversion we just did.
                        var j: usize = 0;
                        while (j < 256) : (j += 1) cc.bitmap[j] = !cc.bitmap[j];
                        cc.negate = true;
                    }
                }
                return RegexNode{ .char_class = cc };
            },
            'b' => RegexNode{ .word_boundary = {} },
            'B' => RegexNode{ .non_word_boundary = {} },
            'p', 'P' => {
                // Unicode property escape (only under /u; otherwise identity).
                if (!self.unicode) return RegexNode{ .literal = @as(u21, c) };
                if (self.eof() or self.cur() != '{') return ParseError.InvalidPattern;
                self.advance(); // {
                const name_start = self.pos;
                while (!self.eof() and self.cur() != '}') self.advance();
                if (self.eof()) return ParseError.InvalidPattern;
                const name = self.src[name_start..self.pos];
                self.advance(); // }
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                const found = try fillPropertyClass(self.alloc, cc, name, self.unicode);
                if (!found) return ParseError.InvalidPattern;
                if (c == 'P') cc.negate = !cc.negate;
                return RegexNode{ .char_class = cc };
            },
            'n' => RegexNode{ .literal = '\n' },
            't' => RegexNode{ .literal = '\t' },
            'r' => RegexNode{ .literal = '\r' },
            'v' => RegexNode{ .literal = 0x0B },
            'f' => RegexNode{ .literal = 0x0C },
            '0' => RegexNode{ .literal = 0 },
            'x' => {
                if (self.pos + 2 > self.src.len) return RegexNode{ .literal = 'x' };
                const h1 = hexVal(self.src[self.pos]) orelse return RegexNode{ .literal = 'x' };
                const h2 = hexVal(self.src[self.pos + 1]) orelse return RegexNode{ .literal = 'x' };
                self.pos += 2;
                return RegexNode{ .literal = @intCast(h1 * 16 + h2) };
            },
            'u' => {
                const cp = try self.parseUEscape();
                return RegexNode{ .literal = cp };
            },
            else => RegexNode{ .literal = @as(u21, c) },
        };
    }
};

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

pub fn compileRegex(alloc: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !CompiledRegex {
    var flags = CompiledRegex.Flags{};
    var seen_flags: [128]bool = [_]bool{false} ** 128;
    for (flags_str) |f| {
        // A repeated flag letter is a SyntaxError (ES §22.2.3.4 RegExpInitialize).
        if (f < 128) {
            if (seen_flags[f]) return error.InvalidPattern;
            seen_flags[f] = true;
        }
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

    // Pre-scan named groups so `\k<name>` (which may forward-reference a group
    // defined later) resolves to a capture index during parsing.
    const names = try scanGroupNames(alloc, pattern);
    var pp = PatternParser.init(pattern, alloc, flags.unicode);
    pp.group_names = names;
    const root = pp.parseAlt() catch return error.InvalidPattern;
    if (!pp.eof()) return error.InvalidPattern; // unconsumed chars

    return CompiledRegex{
        .root = root,
        .flags = flags,
        .num_captures = pp.next_cap - 1,
        .group_names = names,
        .alloc = alloc,
    };
}

/// Whether `c` is valid in a RegExp group name (simplified: identifier chars).
fn isGroupNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$' or c >= 0x80;
}

/// Pre-scan a pattern for `(?<name>...)` groups, assigning each the 1-based
/// capture index it will receive during parsing. Skips char classes, escapes,
/// and non-capturing / assertion groups so indices match the parser exactly.
fn scanGroupNames(alloc: std.mem.Allocator, src: []const u8) ![]const NameIdx {
    var names = std.ArrayList(NameIdx){};
    var cap: u32 = 0;
    var i: usize = 0;
    var in_class = false;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        if (c == '[') {
            in_class = true;
            i += 1;
            continue;
        }
        if (c == '(') {
            if (i + 1 < src.len and src[i + 1] == '?') {
                // (?<name>...) is a named capture; (?<= / (?<! / (?: / (?= / (?!
                // are assertions or non-capturing and take no index.
                if (i + 2 < src.len and src[i + 2] == '<' and
                    (i + 3 >= src.len or (src[i + 3] != '=' and src[i + 3] != '!')))
                {
                    cap += 1;
                    var j = i + 3;
                    while (j < src.len and src[j] != '>') j += 1;
                    try names.append(alloc, .{ .name = src[i + 3 .. j], .idx = cap });
                    i = if (j < src.len) j + 1 else j;
                    continue;
                }
                i += 1;
                continue;
            }
            cap += 1;
        }
        i += 1;
    }
    return names.items;
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
        // Under /u, advance by full codepoint to stay on codepoint boundaries.
        i += if (regex.flags.unicode) @as(usize, utf8ByteLenAt(input, i)) else 1;
    }
    return null;
}

/// Find a match honoring the sticky (`y`) flag.
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

/// Check if a codepoint is a Unicode line terminator (for /u mode).
fn isUnicodeLineTerminator(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

/// Simple ASCII case fold (non-unicode mode).
fn foldCase(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Unicode-aware simple case fold for /ui mode.
/// Handles ASCII + common Latin Extended-A/B pairs and a few other scripts.
/// For a complete implementation a full fold table is needed; this covers
/// the common cases (Latin, Greek uppercase-to-lowercase delta).
fn foldCaseCp(cp: u21) u21 {
    // ASCII fast path
    if (cp < 0x80) {
        if (cp >= 'A' and cp <= 'Z') return cp + 32;
        return cp;
    }
    // Latin-1 Supplement uppercase (U+00C0..U+00D6, U+00D8..U+00DE -> +0x20)
    if (cp >= 0x00C0 and cp <= 0x00D6) return cp + 0x20;
    if (cp >= 0x00D8 and cp <= 0x00DE) return cp + 0x20;
    // Latin Extended-A: alternating upper/lower pairs (U+0100..U+012E even=upper)
    if (cp >= 0x0100 and cp <= 0x012E and cp & 1 == 0) return cp + 1;
    if (cp >= 0x0130 and cp <= 0x0136 and cp & 1 == 0) return cp + 1;
    if (cp >= 0x0139 and cp <= 0x0148 and cp & 1 == 1) return cp + 1;
    if (cp >= 0x014A and cp <= 0x0177 and cp & 1 == 0) return cp + 1;
    if (cp == 0x0178) return 0x00FF;
    if (cp >= 0x0179 and cp <= 0x017E and cp & 1 == 1) return cp + 1;
    // Greek uppercase to lowercase (U+0391..U+03A9 -> +0x20, except U+03A2)
    if (cp >= 0x0391 and cp <= 0x03A9 and cp != 0x03A2) return cp + 0x20;
    // Cyrillic uppercase (U+0410..U+042F -> +0x20)
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    // Already lowercase or no simple fold: return as-is.
    return cp;
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
            if (flags.unicode) {
                // Decode full codepoint from input and compare as u21.
                const dc = decodeUtf8At(input, pos);
                const input_cp = dc.cp;
                if (flags.ignore_case) {
                    if (foldCaseCp(input_cp) != foldCaseCp(ch)) return null;
                } else {
                    if (input_cp != ch) return null;
                }
                return pos + dc.len;
            } else {
                // Byte mode (non-unicode): compare single bytes.
                if (ch > 255) return null; // BMP+ literal can't match in byte mode
                const c = input[pos];
                const cb: u8 = @intCast(ch);
                if (flags.ignore_case) {
                    if (foldCase(c) != foldCase(cb)) return null;
                } else {
                    if (c != cb) return null;
                }
                return pos + 1;
            }
        },
        .char_class => |cc| {
            if (pos >= input.len) return null;
            if (flags.unicode) {
                // Decode codepoint, match against bitmap + extra_ranges.
                const dc = decodeUtf8At(input, pos);
                var cp = dc.cp;
                if (flags.ignore_case) cp = foldCaseCp(cp);
                // For case-insensitive, also check folded lower/upper in the class.
                var hit = cc.matchesCp(cp);
                if (flags.ignore_case and !hit) {
                    // Try the other case fold direction (lower -> upper, upper -> lower).
                    const alt: u21 = if (cp >= 'a' and cp <= 'z')
                        cp - 32
                    else if (cp >= 'A' and cp <= 'Z')
                        cp + 32
                    else
                        cp;
                    if (alt != cp) hit = cc.matchesCp(alt);
                }
                if (!hit) return null;
                return pos + dc.len;
            } else {
                var c = input[pos];
                if (flags.ignore_case) c = foldCase(c);
                var hit = cc.bitmap[c];
                if (flags.ignore_case and !hit) {
                    const alt = if (c >= 'a' and c <= 'z') c - 32 else if (c >= 'A' and c <= 'Z') c + 32 else c;
                    hit = cc.bitmap[alt];
                }
                const result = if (cc.negate) !hit else hit;
                if (!result) return null;
                return pos + 1;
            }
        },
        .dot => {
            if (pos >= input.len) return null;
            if (flags.unicode) {
                const dc = decodeUtf8At(input, pos);
                if (!flags.dotall and isUnicodeLineTerminator(dc.cp)) return null;
                return pos + dc.len;
            } else {
                const c = input[pos];
                if (!flags.dotall and isLineTerminator(c)) return null;
                return pos + 1;
            }
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
            for (arms) |*arm| {
                const saved_caps = caps.*;
                if (matchNode(arm, input, pos, caps, flags)) |end| return end;
                caps.* = saved_caps;
            }
            return null;
        },
        .group => |g| {
            const cap_idx = g.idx;
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
            const saved_caps = caps.*;
            const matched = matchNode(la.inner, input, pos, caps, flags) != null;
            caps.* = saved_caps;
            if (la.negative) {
                return if (!matched) pos else null;
            } else {
                return if (matched) pos else null;
            }
        },
        .look_behind => |lb| {
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
            if (idx >= MAX_CAPTURES) return pos;
            const cap = caps[idx];
            if (cap.start == 0 and cap.end == 0) {
                return pos;
            }
            const captured = input[cap.start..cap.end];
            const clen = captured.len;
            if (pos + clen > input.len) return null;
            const slice = input[pos .. pos + clen];
            if (flags.ignore_case) {
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
        var count: u32 = 0;
        var pos = start;

        while (count < min) {
            const saved_caps = caps.*;
            const next = matchNode(inner, input, pos, caps, flags) orelse {
                caps.* = saved_caps;
                return null;
            };
            if (next == pos) {
                count += 1;
                if (count >= min) break;
                return null;
            }
            pos = next;
            count += 1;
        }

        while (count <= max) {
            return pos;
        }
        return pos;
    } else {
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
                break;
            }
            pos = next;
            if (count >= 1024 - 1) break;
        }

        if (count < min) return null;

        var i = count;
        while (i >= min) {
            if (i <= min or true) {
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

    _ = flags_str;
    const source_val = try val_mod.makeString(arena, source);
    try obj.set("[[OriginalSource]]", source_val);

    const li_val = try val_mod.makeNumber(arena, 0.0);
    try obj.set("lastIndex", li_val);

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

pub fn setLastIndex(arena: std.mem.Allocator, v: Value, idx: usize) !void {
    if (v.bits == 0) return;
    if (v.unbox() != .object) return;
    const obj = v.toPtr().object;
    const li_val = try val_mod.makeNumber(arena, @floatFromInt(idx));
    try obj.set("lastIndex", li_val);
}

pub fn nativeRegExpCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const pattern_str: []const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |s| s,
            .object => |obj| blk: {
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

    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const this_obj = this_val.toPtr().object;
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

/// Throw a `SyntaxError` for a malformed pattern/flags, mirroring the ctor.
fn throwRegExpSyntaxError(arena: std.mem.Allocator, pattern: []const u8, flags: []const u8) anyerror {
    const msg_s = std.fmt.allocPrint(arena, "Invalid regular expression: /{s}/{s}", .{ pattern, flags }) catch "Invalid regular expression";
    const obj = if (realm_mod.active_heap) |heap|
        JsObject.createOnHeap(heap, realm_mod.error_proto_SyntaxError) catch null
    else
        JsObject.create(arena, realm_mod.error_proto_SyntaxError) catch null;
    if (obj) |err_obj| {
        err_obj.set("message", val_mod.makeString(arena, msg_s) catch Value{}) catch {};
        err_obj.set("name", val_mod.makeString(arena, "SyntaxError") catch Value{}) catch {};
        realm_mod.pending_exception = val_mod.makeObject(arena, err_obj) catch Value{};
    }
    return error.JsException;
}

/// Reconstruct the canonical flag string (g,i,m,s,u,y order) from a compiled
/// RegExp's flag set — used when `compile` copies flags from a RegExp pattern.
fn flagsToString(arena: std.mem.Allocator, f: CompiledRegex.Flags) ![]const u8 {
    var buf: [6]u8 = undefined;
    var n: usize = 0;
    if (f.global) {
        buf[n] = 'g';
        n += 1;
    }
    if (f.ignore_case) {
        buf[n] = 'i';
        n += 1;
    }
    if (f.multiline) {
        buf[n] = 'm';
        n += 1;
    }
    if (f.dotall) {
        buf[n] = 's';
        n += 1;
    }
    if (f.unicode) {
        buf[n] = 'u';
        n += 1;
    }
    if (f.sticky) {
        buf[n] = 'y';
        n += 1;
    }
    return arena.dupe(u8, buf[0..n]);
}

/// Annex B RegExp.prototype.compile (§B.2.3.1): re-initialize an existing
/// RegExp instance in place with a new pattern/flags. Returns the receiver.
pub fn nativeRegExpCompile(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Step 1-2: O must be an Object with a [[RegExpMatcher]] internal slot.
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.internal_kind != .regexp)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.compile called on a non-RegExp object");
    const this_obj = this_val.toPtr().object;

    const pattern_arg: Value = if (args.len > 0) args[0] else Value{};
    const flags_arg: Value = if (args.len > 1) args[1] else Value{};

    var pattern_str: []const u8 = "";
    var flags_str: []const u8 = "";

    // Step 3: if the pattern is itself a RegExp, inherit its source and flags.
    if (pattern_arg.bits != 0 and pattern_arg.unbox() == .object and pattern_arg.toPtr().object.internal_kind == .regexp) {
        // A defined flags argument alongside a RegExp pattern is a TypeError.
        if (flags_arg.bits != 0 and flags_arg.unbox() != .undefined_)
            return realm_mod.throwTypeError(arena, "flags must not be defined when compiling from a RegExp");
        const src_obj = pattern_arg.toPtr().object;
        if (src_obj.getOwn("[[OriginalSource]]")) |sv| {
            if (sv.bits != 0 and sv.unbox() == .string) pattern_str = sv.toPtr().string;
        }
        if (getCompiledRegex(pattern_arg)) |src_cr| flags_str = try flagsToString(arena, src_cr.flags);
    } else {
        // Step 4: coerce pattern/flags via ToString (undefined → ""). ToString of
        // a Symbol throws a TypeError before any pattern compilation is attempted.
        if (pattern_arg.bits != 0 and pattern_arg.unbox() != .undefined_) {
            if (pattern_arg.unbox() == .symbol)
                return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string");
            pattern_str = try realm_mod.stringPrimitive(arena, pattern_arg);
        }
        if (flags_arg.bits != 0 and flags_arg.unbox() != .undefined_) {
            if (flags_arg.unbox() == .symbol)
                return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string");
            flags_str = try realm_mod.stringPrimitive(arena, flags_arg);
        }
    }

    // Step 5: RegExpInitialize — compile, then write back the internal slots.
    const cr = arena.create(CompiledRegex) catch return error.OutOfMemory;
    cr.* = compileRegex(arena, pattern_str, flags_str) catch
        return throwRegExpSyntaxError(arena, pattern_str, flags_str);

    try this_obj.set("[[OriginalSource]]", try val_mod.makeString(arena, pattern_str));
    try this_obj.set("lastIndex", try val_mod.makeNumber(arena, 0.0));
    this_obj.internal_slot = @ptrCast(cr);
    this_obj.internal_kind = .regexp;
    return this_val;
}

pub fn nativeRegExpTest(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // ES §22.2.6.16: R must be an Object; result = RegExpExec(R, ToString(string)).
    try requireObject(arena, this_val, "RegExp.prototype.test");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const match = try regExpExec(arena, this_val, try val_mod.makeString(arena, s_str));
    return val_mod.makeBool(arena, !(match.bits == 0 or match.unbox() == .null_));
}

pub fn nativeRegExpExec(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // ES §22.2.6.9: exec requires an object with a [[RegExpMatcher]] slot.
    const cr = getCompiledRegex(this_val) orelse
        return realm_mod.throwTypeError(arena, "RegExp.prototype.exec called on a non-RegExp object");
    // ES §22.2.5.2.2 step 2: S = ToString(string).
    const s: []const u8 = if (args.len > 0)
        try realm_mod.stringPrimitive(arena, args[0])
    else
        "undefined";

    // Step 4: lastIndex = ToLength(Get(R, "lastIndex")) — always read (side
    // effects observable), even when neither global nor sticky.
    const li_raw = if (this_val.toPtr().object.get("lastIndex")) |v| v else try val_mod.makeUndefined(arena);
    const last_index = try realm_mod.toLengthValue(arena, li_raw);

    const use_li = cr.flags.global or cr.flags.sticky;
    // Step 8: if neither global nor sticky, the search starts at 0.
    const from: usize = if (use_li) last_index else 0;

    // An out-of-bounds lastIndex fails immediately (and resets when g/y).
    if (from > s.len) {
        if (use_li) try setLastIndex(arena, this_val, 0);
        return val_mod.makeNull(arena);
    }

    const result = findMatch(cr, s, from) orelse {
        if (use_li) try setLastIndex(arena, this_val, 0);
        return val_mod.makeNull(arena);
    };

    if (use_li) try setLastIndex(arena, this_val, result.state.pos);

    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);

    const full_match = try arena.dupe(u8, s[result.start..result.state.pos]);
    const full_val = try val_mod.makeString(arena, full_match);
    try arr.set("0", full_val);

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

    const idx_val = try val_mod.makeNumber(arena, @floatFromInt(result.start));
    try arr.set("index", idx_val);

    const input_val = try val_mod.makeString(arena, s);
    try arr.set("input", input_val);

    // `groups`: a null-prototype object of named captures, or undefined when the
    // pattern declares none (ES §22.2.7.2 RegExpBuiltinExec step 34).
    const groups_val: Value = if (cr.group_names.len == 0)
        try val_mod.makeUndefined(arena)
    else grp: {
        const gobj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
        // Pass 1: create each distinct name (first-occurrence order) as undefined.
        for (cr.group_names) |ni| {
            if (gobj.getOwn(ni.name) == null) try gobj.set(ni.name, try val_mod.makeUndefined(arena));
        }
        // Pass 2: fill in the value from whichever same-named group participated,
        // so a non-participating duplicate never clobbers a real capture.
        for (cr.group_names) |ni| {
            const cap = if (ni.idx < MAX_CAPTURES) result.state.captures[ni.idx] else INVALID_CAP;
            if (cap.start == 0 and cap.end == 0) continue;
            try gobj.set(ni.name, try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end])));
        }
        break :grp try val_mod.makeObject(arena, gobj);
    };
    try arr.set("groups", groups_val);

    // Annex B: record the match context for the legacy RegExp static accessors.
    updateLegacyState(s, result.start, result.state.pos, &result.state.captures, cr.num_captures);

    return val_mod.makeObject(arena, arr);
}

// ============================================= Annex B legacy RegExp statics ===

/// The last successful RegExp match, exposed via RegExp.$1..$9 / input /
/// lastMatch / lastParen / leftContext / rightContext. Slices point into the
/// (arena-owned, long-lived) subject string of the most recent match.
const LegacyState = struct {
    input: []const u8 = "",
    last_match: []const u8 = "",
    last_paren: []const u8 = "",
    left_context: []const u8 = "",
    right_context: []const u8 = "",
    groups: [9][]const u8 = [_][]const u8{""} ** 9,
};
pub var legacy_state: LegacyState = .{};
/// The %RegExp% constructor — the sole valid receiver for the legacy accessors.
pub var active_regexp_ctor: ?*JsObject = null;

/// Refresh `legacy_state` from a successful RegExpBuiltinExec result.
fn updateLegacyState(s: []const u8, start: usize, end: usize, captures: []const CaptureSpan, num_captures: u32) void {
    legacy_state.input = s;
    legacy_state.last_match = s[start..end];
    legacy_state.left_context = s[0..start];
    legacy_state.right_context = s[end..];
    for (&legacy_state.groups) |*g| g.* = "";
    var last_paren: []const u8 = "";
    var i: u32 = 1;
    while (i <= num_captures and i < MAX_CAPTURES) : (i += 1) {
        const cap = captures[i];
        if (cap.start == 0 and cap.end == 0) continue; // group did not participate
        const val = s[cap.start..cap.end];
        if (i <= 9) legacy_state.groups[i - 1] = val;
        last_paren = val;
    }
    legacy_state.last_paren = last_paren;
}

/// The legacy accessors are brand-checked to the %RegExp% constructor itself:
/// any other receiver (instance, subclass, cross-realm ctor) is a TypeError.
fn legacyBrandCheck(arena: std.mem.Allocator, this_val: Value) anyerror!void {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object != active_regexp_ctor)
        return realm_mod.throwTypeError(arena, "RegExp legacy accessor called on an incompatible receiver");
}

fn nativeLegacyGetInput(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    return val_mod.makeString(arena, legacy_state.input);
}
fn nativeLegacySetInput(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    const v = if (args.len > 0) args[0] else Value{};
    legacy_state.input = try realm_mod.stringPrimitive(arena, v);
    return val_mod.makeUndefined(arena);
}
fn nativeLegacyGetLastMatch(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    return val_mod.makeString(arena, legacy_state.last_match);
}
fn nativeLegacyGetLastParen(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    return val_mod.makeString(arena, legacy_state.last_paren);
}
fn nativeLegacyGetLeftContext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    return val_mod.makeString(arena, legacy_state.left_context);
}
fn nativeLegacyGetRightContext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try legacyBrandCheck(arena, this_val);
    return val_mod.makeString(arena, legacy_state.right_context);
}
/// Build a `RegExp.$<n+1>` getter for capture group n (0-based) at comptime.
fn makeDollarGetter(comptime n: usize) val_mod.NativeFnPtr {
    return struct {
        fn get(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
            try legacyBrandCheck(arena, this_val);
            return val_mod.makeString(arena, legacy_state.groups[n]);
        }
    }.get;
}

/// Define a legacy static accessor on the RegExp constructor. `setter` is null
/// for the read-only (derived) properties, whose descriptor has `set: undefined`.
fn defineLegacyAccessor(arena: std.mem.Allocator, ctor: *JsObject, key: []const u8, getter: val_mod.NativeFnPtr, setter: ?val_mod.NativeFnPtr) !void {
    const holder = try JsObject.create(arena, null);
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, try std.fmt.allocPrint(arena, "get {s}", .{key}), 0));
    if (setter) |s|
        try holder.set("set", try val_mod.makeNativeFunctionNamed(arena, s, try std.fmt.allocPrint(arena, "set {s}", .{key}), 1));
    _ = try ctor.defineOwnAccessor(key, try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
}

/// Install the Annex B legacy static accessors on the RegExp constructor. Only
/// `input`/`$_` are writable; the rest are read-only (derived from the match).
fn registerLegacyAccessors(arena: std.mem.Allocator, ctor: *JsObject) !void {
    try defineLegacyAccessor(arena, ctor, "input", nativeLegacyGetInput, nativeLegacySetInput);
    try defineLegacyAccessor(arena, ctor, "$_", nativeLegacyGetInput, nativeLegacySetInput);
    try defineLegacyAccessor(arena, ctor, "lastMatch", nativeLegacyGetLastMatch, null);
    try defineLegacyAccessor(arena, ctor, "$&", nativeLegacyGetLastMatch, null);
    try defineLegacyAccessor(arena, ctor, "lastParen", nativeLegacyGetLastParen, null);
    try defineLegacyAccessor(arena, ctor, "$+", nativeLegacyGetLastParen, null);
    try defineLegacyAccessor(arena, ctor, "leftContext", nativeLegacyGetLeftContext, null);
    try defineLegacyAccessor(arena, ctor, "$`", nativeLegacyGetLeftContext, null);
    try defineLegacyAccessor(arena, ctor, "rightContext", nativeLegacyGetRightContext, null);
    try defineLegacyAccessor(arena, ctor, "$'", nativeLegacyGetRightContext, null);
    inline for (0..9) |n| {
        try defineLegacyAccessor(arena, ctor, std.fmt.comptimePrint("${d}", .{n + 1}), makeDollarGetter(n), null);
    }
}

// ==================================================== @@match/@@replace/@@split/@@search/@@matchAll

fn ctxGetProp(arena: std.mem.Allocator, obj: Value, key: []const u8) !Value {
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, obj, key);
    return val_mod.makeUndefined(arena);
}

fn ctxSetProp(arena: std.mem.Allocator, obj: Value, key: []const u8, v: Value) !void {
    if (realm_mod.active_context) |ctx| try ctx.setProp(arena, obj, key, v);
}

/// SameValue for the number/undefined values `lastIndex` carries in practice.
fn sameValueNum(a: Value, b: Value) bool {
    const an = a.bits != 0 and a.unbox() == .number;
    const bn = b.bits != 0 and b.unbox() == .number;
    if (an and bn) return a.unbox().number == b.unbox().number;
    return a.bits == b.bits;
}

/// ToString(Get(obj, key)).
fn getStrProp(arena: std.mem.Allocator, obj: Value, key: []const u8) ![]const u8 {
    const v = try ctxGetProp(arena, obj, key);
    // ToString of a Symbol throws a TypeError (e.g. a Symbol-valued `flags`).
    if (v.bits != 0 and v.unbox() == .symbol)
        return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string");
    return realm_mod.stringPrimitive(arena, v);
}

/// RegExpExec(R, S) — ES §22.2.7.1: dispatch to a user `exec` if callable,
/// otherwise RegExpBuiltinExec. Result must be an Object or null.
fn regExpExec(arena: std.mem.Allocator, R: Value, s_val: Value) !Value {
    const exec = try ctxGetProp(arena, R, "exec");
    if (fp.isCallableFn(exec)) {
        const res = try fp.invokeCallback(arena, R, exec, &[_]Value{s_val});
        if (res.bits != 0 and (res.unbox() == .object or res.unbox() == .null_)) return res;
        return realm_mod.throwTypeError(arena, "RegExp exec method returned a non-object, non-null value");
    }
    if (getCompiledRegex(R) == null)
        return realm_mod.throwTypeError(arena, "RegExpExec called on a non-RegExp object");
    return nativeRegExpExec(arena, R, &[_]Value{s_val});
}

/// AdvanceStringIndex(S, index, unicode) approximated over UTF-8 bytes.
fn advanceStringIndex(s: []const u8, index: usize, unicode: bool) usize {
    if (!unicode or index >= s.len) return index + 1;
    const b = s[index];
    const clen: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    return index + clen;
}

fn requireObject(arena: std.mem.Allocator, v: Value, comptime what: []const u8) !void {
    if (v.bits == 0 or v.unbox() != .object)
        return realm_mod.throwTypeError(arena, what ++ " called on a non-object");
}

/// RegExp.prototype[@@search] (ES §22.2.6.13).
pub fn nativeRegExpSymbolSearch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.search]");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);
    const prev = try ctxGetProp(arena, this_val, "lastIndex");
    if (!sameValueNum(prev, try val_mod.makeNumber(arena, 0)))
        try ctxSetProp(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, 0));
    const result = try regExpExec(arena, this_val, s_val);
    const cur = try ctxGetProp(arena, this_val, "lastIndex");
    if (!sameValueNum(cur, prev)) try ctxSetProp(arena, this_val, "lastIndex", prev);
    if (result.bits == 0 or result.unbox() == .null_) return val_mod.makeNumber(arena, -1);
    return ctxGetProp(arena, result, "index");
}

/// RegExp.prototype[@@match] (ES §22.2.6.8).
pub fn nativeRegExpSymbolMatch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.match]");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);
    const flags = try getStrProp(arena, this_val, "flags");
    const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    if (!global) return regExpExec(arena, this_val, s_val);

    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    try ctxSetProp(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, 0));
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    var n: u32 = 0;
    while (true) {
        const result = try regExpExec(arena, this_val, s_val);
        if (result.bits == 0 or result.unbox() == .null_) {
            if (n == 0) return val_mod.makeNull(arena);
            arr.array_length = n;
            return val_mod.makeObject(arena, arr);
        }
        const match_str = try getStrProp(arena, result, "0");
        const key = try std.fmt.allocPrint(arena, "{d}", .{n});
        try arr.set(key, try val_mod.makeString(arena, match_str));
        n += 1;
        if (match_str.len == 0) {
            const li = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, this_val, "lastIndex"));
            try ctxSetProp(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(advanceStringIndex(s_str, li, unicode))));
        }
    }
}

/// GetSubstitution (ES §22.1.3.19) restricted to positional captures (no named
/// groups, which the matcher does not support). `captures[0]` is the full match.
fn getSubstitution(
    arena: std.mem.Allocator,
    matched: []const u8,
    str: []const u8,
    position: usize,
    captures: []const ?[]const u8,
    replacement: []const u8,
    named_captures: Value,
) ![]const u8 {
    const has_named = named_captures.bits != 0 and named_captures.unbox() != .undefined_;
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < replacement.len) {
        const c = replacement[i];
        if (c != '$' or i + 1 >= replacement.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const d = replacement[i + 1];
        switch (d) {
            '$' => { try out.append(arena, '$'); i += 2; },
            '&' => { try out.appendSlice(arena, matched); i += 2; },
            '`' => { try out.appendSlice(arena, str[0..position]); i += 2; },
            '\'' => {
                const tail_start = @min(position + matched.len, str.len);
                try out.appendSlice(arena, str[tail_start..]);
                i += 2;
            },
            '<' => {
                // `$<name>` named-capture reference — only special when the match
                // carries a `groups` object; otherwise `$<` is emitted literally.
                if (!has_named) {
                    try out.append(arena, '$');
                    i += 1;
                } else if (std.mem.indexOfScalarPos(u8, replacement, i + 2, '>')) |gt| {
                    const name = replacement[i + 2 .. gt];
                    const cap = try ctxGetProp(arena, named_captures, name);
                    if (!(cap.bits == 0 or cap.unbox() == .undefined_))
                        try out.appendSlice(arena, try realm_mod.stringPrimitive(arena, cap));
                    i = gt + 1;
                } else {
                    try out.appendSlice(arena, "$<");
                    i += 2;
                }
            },
            '0'...'9' => {
                // One- or two-digit capture index (two-digit only if in range).
                var num: usize = d - '0';
                var consumed: usize = 2;
                if (i + 2 < replacement.len and replacement[i + 2] >= '0' and replacement[i + 2] <= '9') {
                    const two = num * 10 + (replacement[i + 2] - '0');
                    if (two >= 1 and two < captures.len) {
                        num = two;
                        consumed = 3;
                    }
                }
                if (num >= 1 and num < captures.len) {
                    if (captures[num]) |cap| try out.appendSlice(arena, cap);
                    i += consumed;
                } else {
                    try out.append(arena, '$');
                    i += 1;
                }
            },
            else => { try out.append(arena, '$'); i += 1; },
        }
    }
    return out.items;
}

/// RegExp.prototype[@@replace] (ES §22.2.6.11).
pub fn nativeRegExpSymbolReplace(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.replace]");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);
    const replace_val = if (args.len > 1) args[1] else try val_mod.makeUndefined(arena);
    const functional = fp.isCallableFn(replace_val);
    const repl_str: []const u8 = if (functional) "" else try realm_mod.stringPrimitive(arena, replace_val);

    // §22.2.6.11: flags = ToString(Get(rx, "flags")); global/fullUnicode are
    // derived from that string (the Get + ToString are observable side effects).
    const flags = try getStrProp(arena, this_val, "flags");
    const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    if (global) try ctxSetProp(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, 0));

    // Collect all match results.
    var results = std.ArrayList(Value){};
    while (true) {
        const result = try regExpExec(arena, this_val, s_val);
        if (result.bits == 0 or result.unbox() == .null_) break;
        try results.append(arena, result);
        if (!global) break;
        const match_str = try getStrProp(arena, result, "0");
        if (match_str.len == 0) {
            const li = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, this_val, "lastIndex"));
            try ctxSetProp(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(advanceStringIndex(s_str, li, unicode))));
        }
    }

    var accumulated = std.ArrayList(u8){};
    var next_source_pos: usize = 0;
    for (results.items) |result| {
        const n_caps_len = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, result, "length"));
        const n_caps = if (n_caps_len == 0) 0 else n_caps_len - 1;
        const matched = try getStrProp(arena, result, "0");
        var position_f = try realm_mod.toNumberValue(arena, try ctxGetProp(arena, result, "index"));
        if (std.math.isNan(position_f) or position_f < 0) position_f = 0;
        var position: usize = @intFromFloat(std.math.trunc(position_f));
        if (position > s_str.len) position = s_str.len;

        // Gather capture strings 1..n_caps.
        var captures = std.ArrayList(?[]const u8){};
        try captures.append(arena, matched); // index 0
        var ci: usize = 1;
        while (ci <= n_caps) : (ci += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{ci});
            const cv = try ctxGetProp(arena, result, key);
            if (cv.bits == 0 or cv.unbox() == .undefined_) {
                try captures.append(arena, null);
            } else {
                try captures.append(arena, try realm_mod.stringPrimitive(arena, cv));
            }
        }

        // §22.2.6.11 step: namedCaptures = Get(result, "groups") (observable).
        const named_captures = try ctxGetProp(arena, result, "groups");
        const has_named = named_captures.bits != 0 and named_captures.unbox() != .undefined_;

        var replacement: []const u8 = undefined;
        if (functional) {
            // Call replacer(matched, cap1..capN, position, S[, namedCaptures]).
            var call_args = std.ArrayList(Value){};
            try call_args.append(arena, try val_mod.makeString(arena, matched));
            ci = 1;
            while (ci <= n_caps) : (ci += 1) {
                if (captures.items[ci]) |cap| {
                    try call_args.append(arena, try val_mod.makeString(arena, cap));
                } else {
                    try call_args.append(arena, try val_mod.makeUndefined(arena));
                }
            }
            try call_args.append(arena, try val_mod.makeNumber(arena, @floatFromInt(position)));
            try call_args.append(arena, s_val);
            if (has_named) try call_args.append(arena, named_captures);
            const rv = try fp.invokeCallback(arena, try val_mod.makeUndefined(arena), replace_val, call_args.items);
            replacement = try realm_mod.stringPrimitive(arena, rv);
        } else {
            // `$<name>` looks up the (defined) `groups`; ctxGetProp autoboxes a
            // primitive receiver, so no explicit ToObject step is needed here.
            replacement = try getSubstitution(arena, matched, s_str, position, captures.items, repl_str, named_captures);
        }

        if (position >= next_source_pos) {
            try accumulated.appendSlice(arena, s_str[next_source_pos..position]);
            try accumulated.appendSlice(arena, replacement);
            next_source_pos = position + matched.len;
        }
    }
    if (next_source_pos < s_str.len) try accumulated.appendSlice(arena, s_str[next_source_pos..]);
    return val_mod.makeString(arena, accumulated.items);
}

fn isConstructorVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => true,
        .native_function => false,
        .object => |o| o.get("__call__") != null or
            o.internal_kind == .bound_function or
            o.internal_kind == .proxy,
        else => false,
    };
}

/// SpeciesConstructor(O, defaultConstructor) — ES §7.3.22.
fn speciesConstructor(arena: std.mem.Allocator, o: Value, default_ctor: Value) !Value {
    const c = try ctxGetProp(arena, o, "constructor");
    if (c.bits == 0 or c.unbox() == .undefined_) return default_ctor;
    // Type(C) must be Object — callables (functions) are objects in our model.
    const is_obj = switch (c.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
    if (!is_obj) return realm_mod.throwTypeError(arena, "constructor is not an object");
    const species_sym = realm_mod.active_sym_species orelse return default_ctor;
    const s = try realm_mod.active_context.?.getPropSym(arena, c, species_sym);
    if (s.bits == 0 or s.unbox() == .undefined_ or s.unbox() == .null_) return default_ctor;
    if (isConstructorVal(s)) return s;
    return realm_mod.throwTypeError(arena, "Symbol.species is not a constructor");
}

/// RegExp.prototype[@@split] (ES §22.2.6.14).
pub fn nativeRegExpSymbolSplit(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.split]");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);

    // SpeciesConstructor(rx, %RegExp%), then build the sticky splitter.
    const default_ctor: Value = if (active_regexp_ctor) |rc| try val_mod.makeObject(arena, rc) else try ctxGetProp(arena, this_val, "constructor");
    const c = try speciesConstructor(arena, this_val, default_ctor);
    const flags = try getStrProp(arena, this_val, "flags");
    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    const new_flags = if (std.mem.indexOfScalar(u8, flags, 'y') != null)
        flags
    else
        try std.fmt.allocPrint(arena, "{s}y", .{flags});
    const splitter = try realm_mod.active_context.?.construct(arena, c, &[_]Value{ this_val, try val_mod.makeString(arena, new_flags) });

    // limit = limit === undefined ? 2^32-1 : ToUint32(limit).
    const lim: u64 = blk: {
        if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) {
            const n = try realm_mod.toNumberValue(arena, args[1]);
            if (std.math.isNan(n)) break :blk 0;
            const m = @mod(std.math.trunc(n), 4294967296.0);
            break :blk @intFromFloat(if (m < 0) m + 4294967296.0 else m);
        }
        break :blk 0xFFFFFFFF;
    };
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    if (lim == 0) return val_mod.makeObject(arena, arr);

    // Empty subject: one exec; [] if it matched, else [S].
    if (s_str.len == 0) {
        const z = try regExpExec(arena, splitter, s_val);
        if (!(z.bits == 0 or z.unbox() == .null_)) return val_mod.makeObject(arena, arr);
        try arr.set("0", s_val);
        arr.array_length = 1;
        return val_mod.makeObject(arena, arr);
    }

    var out_n: u32 = 0;
    var p: usize = 0; // start of current segment
    var q: usize = 0; // scan position
    while (q < s_str.len) {
        try ctxSetProp(arena, splitter, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(q)));
        const z = try regExpExec(arena, splitter, s_val);
        if (z.bits == 0 or z.unbox() == .null_) {
            q = advanceStringIndex(s_str, q, unicode);
            continue;
        }
        var e = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, splitter, "lastIndex"));
        if (e > s_str.len) e = s_str.len;
        if (e == p) {
            q = advanceStringIndex(s_str, q, unicode);
            continue;
        }
        // Segment [p, q).
        const key = try std.fmt.allocPrint(arena, "{d}", .{out_n});
        try arr.set(key, try val_mod.makeString(arena, s_str[p..q]));
        out_n += 1;
        if (out_n >= lim) {
            arr.array_length = out_n;
            return val_mod.makeObject(arena, arr);
        }
        p = e;
        // Captures 1..numberOfCaptures from z.
        const z_len = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, z, "length"));
        const n_caps = if (z_len == 0) 0 else z_len - 1;
        var gi: usize = 1;
        while (gi <= n_caps) : (gi += 1) {
            const kk = try std.fmt.allocPrint(arena, "{d}", .{gi});
            const cap = try ctxGetProp(arena, z, kk);
            const okk = try std.fmt.allocPrint(arena, "{d}", .{out_n});
            try arr.set(okk, cap);
            out_n += 1;
            if (out_n >= lim) {
                arr.array_length = out_n;
                return val_mod.makeObject(arena, arr);
            }
        }
        q = p;
    }
    // Final segment [p, end).
    const key = try std.fmt.allocPrint(arena, "{d}", .{out_n});
    try arr.set(key, try val_mod.makeString(arena, s_str[p..]));
    out_n += 1;
    arr.array_length = out_n;
    return val_mod.makeObject(arena, arr);
}

/// RegExp.prototype[@@matchAll] (ES §22.2.6.9): eagerly collect all matches and
/// return an array iterator over them (the observable order/values match a lazy
/// RegExpStringIterator for the common cases the tests exercise).
pub fn nativeRegExpSymbolMatchAll(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.matchAll]");
    const s_str = if (args.len > 0) try realm_mod.stringPrimitive(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);

    // §22.2.6.9: matcher = Construct(SpeciesConstructor(R, %RegExp%), [R, flags]).
    // global / fullUnicode are read from R's OWN flags, not the matcher's.
    const default_ctor: Value = if (active_regexp_ctor) |c| try val_mod.makeObject(arena, c) else try ctxGetProp(arena, this_val, "constructor");
    const c = try speciesConstructor(arena, this_val, default_ctor);
    const flags = try getStrProp(arena, this_val, "flags");
    const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    const matcher = try realm_mod.active_context.?.construct(arena, c, &[_]Value{ this_val, try val_mod.makeString(arena, flags) });
    // matcher.lastIndex = ToLength(Get(R, "lastIndex")) — R itself is untouched.
    const start_li = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, this_val, "lastIndex"));
    try ctxSetProp(arena, matcher, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(start_li)));

    const matches = try JsObject.createArray(arena, realm_mod.active_array_proto);
    var count: u32 = 0;
    while (true) {
        const result = try regExpExec(arena, matcher, s_val);
        if (result.bits == 0 or result.unbox() == .null_) break;
        const key = try std.fmt.allocPrint(arena, "{d}", .{count});
        try matches.set(key, result);
        count += 1;
        if (!global) break;
        const match_str = try getStrProp(arena, result, "0");
        if (match_str.len == 0) {
            const li = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, matcher, "lastIndex"));
            try ctxSetProp(arena, matcher, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(advanceStringIndex(s_str, li, unicode))));
        }
    }
    matches.array_length = count;
    // Return an array iterator over the collected match arrays.
    const arr_val = try val_mod.makeObject(arena, matches);
    if (realm_mod.active_context) |ctx| {
        const values_fn = try ctx.getProp(arena, arr_val, "values");
        return fp.invokeCallback(arena, arr_val, values_fn, &[_]Value{});
    }
    return arr_val;
}

/// Install RegExp.prototype[@@match/@@replace/@@search/@@split/@@matchAll].
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const proto = realm_mod.active_regexp_proto orelse return;
    const attr: @import("../../object/object.zig").PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    if (realm_mod.active_sym_match) |sym|
        _ = try proto.defineOwnDataSym(sym, try val_mod.makeNativeFunctionNamed(arena, nativeRegExpSymbolMatch, "[Symbol.match]", 1), attr);
    if (realm_mod.active_sym_replace) |sym|
        _ = try proto.defineOwnDataSym(sym, try val_mod.makeNativeFunctionNamed(arena, nativeRegExpSymbolReplace, "[Symbol.replace]", 2), attr);
    if (realm_mod.active_sym_search) |sym|
        _ = try proto.defineOwnDataSym(sym, try val_mod.makeNativeFunctionNamed(arena, nativeRegExpSymbolSearch, "[Symbol.search]", 1), attr);
    if (realm_mod.active_sym_split) |sym|
        _ = try proto.defineOwnDataSym(sym, try val_mod.makeNativeFunctionNamed(arena, nativeRegExpSymbolSplit, "[Symbol.split]", 2), attr);
    if (realm_mod.active_sym_match_all) |sym|
        _ = try proto.defineOwnDataSym(sym, try val_mod.makeNativeFunctionNamed(arena, nativeRegExpSymbolMatchAll, "[Symbol.matchAll]", 1), attr);
}

// ============================================================= Prototype Getters

pub fn nativeRegExpToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.toString called on incompatible receiver");
    const src = try nativeRegExpGetSource(arena, this_val, &.{});
    const flags = try nativeRegExpGetFlags(arena, this_val, &.{});
    const src_s: []const u8 = if (src.bits != 0 and src.unbox() == .string) src.toPtr().string else "(?:)";
    const flags_s: []const u8 = if (flags.bits != 0 and flags.unbox() == .string) flags.toPtr().string else "";
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "/{s}/{s}", .{ src_s, flags_s }));
}

pub fn nativeRegExpGetSource(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.source called on incompatible receiver");
    if (getCompiledRegex(this_val) == null)
        return val_mod.makeString(arena, "(?:)");
    const obj = this_val.toPtr().object;
    if (obj.getOwn("[[OriginalSource]]")) |sv| return sv;
    return val_mod.makeString(arena, "(?:)");
}

/// flags getter (ES §22.2.6.4): a generic accessor that reads each flag
/// property via [[Get]] and ToBoolean, appending the letters in the fixed order
/// d, g, i, m, s, u, v, y. Works on any object, not only RegExp instances.
pub fn nativeRegExpGetFlags(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.flags called on incompatible receiver");
    const pairs = [_]struct { prop: []const u8, ch: u8 }{
        .{ .prop = "hasIndices", .ch = 'd' },
        .{ .prop = "global", .ch = 'g' },
        .{ .prop = "ignoreCase", .ch = 'i' },
        .{ .prop = "multiline", .ch = 'm' },
        .{ .prop = "dotAll", .ch = 's' },
        .{ .prop = "unicode", .ch = 'u' },
        .{ .prop = "unicodeSets", .ch = 'v' },
        .{ .prop = "sticky", .ch = 'y' },
    };
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    for (pairs) |p| {
        const v = try ctxGetProp(arena, this_val, p.prop);
        if (val_mod.toBoolean(v)) {
            buf[len] = p.ch;
            len += 1;
        }
    }
    const owned = try arena.dupe(u8, buf[0..len]);
    return val_mod.makeString(arena, owned);
}

pub fn nativeRegExpGetGlobal(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.global called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.global);
}

pub fn nativeRegExpGetIgnoreCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.ignoreCase called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.ignore_case);
}

pub fn nativeRegExpGetMultiline(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.multiline called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.multiline);
}

pub fn nativeRegExpGetDotAll(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.dotAll called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.dotall);
}

pub fn nativeRegExpGetSticky(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.sticky called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.sticky);
}

pub fn nativeRegExpGetUnicode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.unicode called on incompatible receiver");
    const cr = getCompiledRegex(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.unicode);
}

pub fn nativeRegExpGetHasIndices(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.hasIndices called on incompatible receiver");
    if (getCompiledRegex(this_val) == null) return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, false);
}

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

// ------- Unicode tests -------

test "regexp/u: decodeUtf8At basic" {
    // ASCII
    const a = decodeUtf8At("hello", 0);
    try std.testing.expectEqual(@as(u21, 'h'), a.cp);
    try std.testing.expectEqual(@as(u8, 1), a.len);
    // U+00E9 LATIN SMALL LETTER E WITH ACUTE (UTF-8: 0xC3 0xA9)
    const e_acute = "\xC3\xA9";
    const b = decodeUtf8At(e_acute, 0);
    try std.testing.expectEqual(@as(u21, 0x00E9), b.cp);
    try std.testing.expectEqual(@as(u8, 2), b.len);
    // U+1F600 GRINNING FACE (UTF-8: 0xF0 0x9F 0x98 0x80)
    const emoji = "\xF0\x9F\x98\x80";
    const c = decodeUtf8At(emoji, 0);
    try std.testing.expectEqual(@as(u21, 0x1F600), c.cp);
    try std.testing.expectEqual(@as(u8, 4), c.len);
}

test "regexp/u: dot matches unicode codepoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // /./u on a 4-byte emoji should match the whole emoji (4 bytes, not 1 byte).
    var cr = try compileRegex(alloc, ".", "u");
    const emoji = "\xF0\x9F\x98\x80"; // U+1F600
    const result = matchAt(&cr, emoji, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.pos); // consumed all 4 bytes

    // Non-unicode: . only consumes 1 byte
    var cr2 = try compileRegex(alloc, ".", "");
    const result2 = matchAt(&cr2, emoji, 0);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 1), result2.?.pos); // only 1 byte
}

test "regexp/u: literal u21 -- e_acute in pattern and input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Pattern: é (U+00E9) directly in the pattern string (UTF-8 encoded)
    const pattern = "\xC3\xA9"; // é
    var cr = try compileRegex(alloc, pattern, "u");
    // Match against "café" (UTF-8: c a f \xC3\xA9)
    const input = "caf\xC3\xA9";
    const result = matchAnywhere(&cr, input, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.start);
    try std.testing.expectEqual(@as(usize, 5), result.?.state.pos);
}

test "regexp/u: \\u{} astral codepoint parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Pattern \u{1F600} should match U+1F600 (emoji grinning face, 4 UTF-8 bytes)
    var cr = try compileRegex(alloc, "\\u{1F600}", "u");
    const emoji = "\xF0\x9F\x98\x80";
    const result = matchAt(&cr, emoji, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.pos);

    // Non-astral: \u{0041} = 'A'
    var cr2 = try compileRegex(alloc, "\\u{0041}", "u");
    try std.testing.expect(matchAt(&cr2, "A", 0) != null);
    try std.testing.expect(matchAt(&cr2, "B", 0) == null);
}

test "regexp/u: \\u{} BMP codepoint (non-ASCII)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // \u{00E9} = U+00E9 = é (2 UTF-8 bytes)
    var cr = try compileRegex(alloc, "\\u{00E9}", "u");
    const e_acute = "\xC3\xA9";
    try std.testing.expect(matchAt(&cr, e_acute, 0) != null);
    try std.testing.expect(matchAt(&cr, "e", 0) == null);
}

test "regexp/u: scan with non-ASCII advances by codepoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Find 'z' after an emoji -- scanner must skip the 4 bytes as one unit.
    var cr = try compileRegex(alloc, "z", "u");
    const input = "\xF0\x9F\x98\x80z"; // emoji + 'z'
    const result = matchAnywhere(&cr, input, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.start); // starts at byte 4
}

test "regexp/u: \\p{L} matches non-ASCII letters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // \p{L} should match U+00E9 (é), U+03B1 (Greek alpha), U+4E2D (CJK)
    var cr = try compileRegex(alloc, "\\p{L}", "u");
    // é (U+00E9, 2 bytes)
    try std.testing.expect(matchAt(&cr, "\xC3\xA9", 0) != null);
    // Greek alpha α (U+03B1, 2 bytes: 0xCE 0xB1)
    try std.testing.expect(matchAt(&cr, "\xCE\xB1", 0) != null);
    // CJK 中 (U+4E2D, 3 bytes: 0xE4 0xB8 0xAD)
    try std.testing.expect(matchAt(&cr, "\xE4\xB8\xAD", 0) != null);
    // Digit '5' should NOT match \p{L}
    try std.testing.expect(matchAt(&cr, "5", 0) == null);
}

test "regexp/u: \\p{Lu} uppercase letter -- non-ASCII" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "\\p{Lu}", "u");
    // U+00C9 LATIN CAPITAL LETTER E WITH ACUTE (2 bytes: 0xC3 0x89)
    try std.testing.expect(matchAt(&cr, "\xC3\x89", 0) != null);
    // Lowercase é (U+00E9) should NOT match \p{Lu}
    try std.testing.expect(matchAt(&cr, "\xC3\xA9", 0) == null);
}

test "regexp/u: \\p{Nd} matches non-ASCII digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, "\\p{Nd}", "u");
    // ASCII digit
    try std.testing.expect(matchAt(&cr, "7", 0) != null);
    // Arabic-Indic digit 1 (U+0661, 2 bytes: 0xD9 0xA1)
    try std.testing.expect(matchAt(&cr, "\xD9\xA1", 0) != null);
    // Letter 'a' should NOT match \p{Nd}
    try std.testing.expect(matchAt(&cr, "a", 0) == null);
}

test "regexp/u: dot does NOT match U+2028 / U+2029 (line terminators)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cr = try compileRegex(alloc, ".", "u");
    // U+2028 LINE SEPARATOR (3 bytes: 0xE2 0x80 0xA8)
    try std.testing.expect(matchAt(&cr, "\xE2\x80\xA8", 0) == null);
    // U+2029 PARAGRAPH SEPARATOR (3 bytes: 0xE2 0x80 0xA9)
    try std.testing.expect(matchAt(&cr, "\xE2\x80\xA9", 0) == null);
    // But /./su DOES match them
    var cr2 = try compileRegex(alloc, ".", "su");
    try std.testing.expect(matchAt(&cr2, "\xE2\x80\xA8", 0) != null);
    try std.testing.expectEqual(@as(usize, 3), matchAt(&cr2, "\xE2\x80\xA8", 0).?.pos);
}

test "regexp/u: cpInTable binary search" {
    const table: []const [2]u21 = &[_][2]u21{
        .{ 0x0041, 0x005A }, // A-Z
        .{ 0x0061, 0x007A }, // a-z
        .{ 0x00C0, 0x00FF }, // Latin supplement
    };
    try std.testing.expect(cpInTable(table, 'A'));
    try std.testing.expect(cpInTable(table, 'Z'));
    try std.testing.expect(cpInTable(table, 'a'));
    try std.testing.expect(cpInTable(table, 'z'));
    try std.testing.expect(cpInTable(table, 0x00C0));
    try std.testing.expect(cpInTable(table, 0x00FF));
    try std.testing.expect(!cpInTable(table, '0'));
    try std.testing.expect(!cpInTable(table, 0x0100));
}

test "regexp/u: CharClass extra_ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cc = CharClass{};
    try cc.addCpRange(alloc, 0x4E00, 0x9FFF); // CJK Unified Ideographs
    // In range
    try std.testing.expect(cc.matchesCp(0x4E00));
    try std.testing.expect(cc.matchesCp(0x4E2D));
    try std.testing.expect(cc.matchesCp(0x9FFF));
    // Outside range
    try std.testing.expect(!cc.matchesCp(0x4DFF));
    try std.testing.expect(!cc.matchesCp(0xA000));
}

test "regexp/u: encodeUtf8Cp round-trip" {
    var buf: [4]u8 = undefined;
    // ASCII
    const n1 = encodeUtf8Cp('A', &buf);
    try std.testing.expectEqual(@as(u3, 1), n1);
    try std.testing.expectEqualSlices(u8, "A", buf[0..n1]);
    // U+00E9
    const n2 = encodeUtf8Cp(0x00E9, &buf);
    try std.testing.expectEqual(@as(u3, 2), n2);
    try std.testing.expectEqualSlices(u8, "\xC3\xA9", buf[0..n2]);
    // U+1F600
    const n4 = encodeUtf8Cp(0x1F600, &buf);
    try std.testing.expectEqual(@as(u3, 4), n4);
    try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", buf[0..n4]);
}
