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
const uprop = @import("unicode_prop_tables.zig");
const casefold = @import("unicode_casefold.zig");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const fp = @import("function_proto.zig");
const string_proto = @import("string_proto.zig");

/// R1: install RegExp.prototype + constructor and bind the `RegExp` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const regexp_proto = try JsObject.create(arena, ctx.object_proto);
    const re_test_fn = try val_mod.makeNativeFunctionNamed(arena, nativeRegExpTest, "test", 1);
    const re_exec_fn = try val_mod.makeNativeFunctionNamed(arena, nativeRegExpExec, "exec", 1);
    try regexp_proto.set("test", re_test_fn);
    try regexp_proto.set("exec", re_exec_fn);
    try regexp_proto.set("toString", try val_mod.makeNativeFunctionNamed(arena, nativeRegExpToString, "toString", 0));
    // Annex B RegExp.prototype.compile — a proper method (name "compile", length 2).
    _ = try regexp_proto.defineOwnData("compile", try val_mod.makeNativeFunctionNamed(arena, nativeRegExpCompile, "compile", 2), .{ .writable = true, .enumerable = false, .configurable = true });

    const regexp_ctor_obj = try JsObject.create(arena, null);
    const regexp_proto_val = try val_mod.makeObject(arena, regexp_proto);
    try regexp_ctor_obj.defineOwnDataForced("prototype", regexp_proto_val, .{ .writable = false, .enumerable = false, .configurable = false });
    const regexp_call_fn = try val_mod.makeNativeFunction(arena, nativeRegExpCtor);
    try regexp_ctor_obj.set("__call__", regexp_call_fn);
    _ = try regexp_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try regexp_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "RegExp"), .{ .writable = false, .enumerable = false, .configurable = true });
    const regexp_ctor_val = try val_mod.makeObject(arena, regexp_ctor_obj);
    _ = try regexp_proto.defineOwnData("constructor", regexp_ctor_val, .{ .writable = true, .enumerable = false, .configurable = true });
    try ctx.env.define("RegExp", regexp_ctor_val);

    realm_mod.active_regexp_proto = regexp_proto;
    // ES2025 RegExp.escape static — writable, non-enumerable, configurable.
    _ = try regexp_ctor_obj.defineOwnData("escape", try val_mod.makeNativeFunctionNamed(arena, nativeRegExpEscape, "escape", 1), .{ .writable = true, .enumerable = false, .configurable = true });
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

// ================================================================ RegExp.escape ==

/// SyntaxCharacter :: one of ^ $ \ . * + ? ( ) [ ] { } |
fn isSyntaxChar(c: u21) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

/// ControlLetter (§22.2.1): the ASCII letters accepted after `\c`.
fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// otherPunctuators (§EncodeForRegExpEscape): , - = < > # & ! % : ; @ ~ ' ` "
fn isOtherPunctuator(c: u21) bool {
    return switch (c) {
        ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => true,
        else => false,
    };
}

/// WhiteSpace ∪ LineTerminator, minus the ControlEscape members (\t\v\f handled
/// earlier). Covers the Unicode Space_Separator (Zs) set plus BOM/LS/PS.
fn isEscapeWhiteSpace(c: u21) bool {
    return switch (c) {
        0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

/// Append the lowercase hex escape `\xHH` (2 digits) for a code point ≤ 0xFF.
fn appendHex2(arena: std.mem.Allocator, out: *std.ArrayList(u8), c: u21) !void {
    try out.appendSlice(arena, "\\x");
    var buf: [2]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>2}", .{@as(u8, @intCast(c))}) catch unreachable;
    try out.appendSlice(arena, &buf);
}

/// Append the lowercase Unicode escape `\uHHHH` for a single UTF-16 code unit.
fn appendUnicodeEscape(arena: std.mem.Allocator, out: *std.ArrayList(u8), cu: u16) !void {
    try out.appendSlice(arena, "\\u");
    var buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>4}", .{cu}) catch unreachable;
    try out.appendSlice(arena, &buf);
}

/// EncodeForRegExpEscape(c) — append the escaped form of a single code point.
/// `raw` is the source's raw bytes for `c` (used for the identity case so astral
/// / multibyte code points round-trip without re-encoding).
fn encodeForRegExpEscape(arena: std.mem.Allocator, out: *std.ArrayList(u8), c: u21, raw: []const u8) !void {
    if (isSyntaxChar(c) or c == '/') {
        try out.append(arena, '\\');
        try out.append(arena, @intCast(c)); // all ASCII single bytes
        return;
    }
    switch (c) {
        0x09 => return out.appendSlice(arena, "\\t"),
        0x0A => return out.appendSlice(arena, "\\n"),
        0x0B => return out.appendSlice(arena, "\\v"),
        0x0C => return out.appendSlice(arena, "\\f"),
        0x0D => return out.appendSlice(arena, "\\r"),
        else => {},
    }
    const is_surrogate = c >= 0xD800 and c <= 0xDFFF;
    if (isOtherPunctuator(c) or isEscapeWhiteSpace(c) or is_surrogate) {
        if (c <= 0xFF) {
            try appendHex2(arena, out, c);
        } else if (c <= 0xFFFF) {
            try appendUnicodeEscape(arena, out, @intCast(c));
        } else {
            // Astral: emit the surrogate pair (UTF16EncodeCodePoint).
            const v = c - 0x10000;
            try appendUnicodeEscape(arena, out, @intCast(0xD800 + (v >> 10)));
            try appendUnicodeEscape(arena, out, @intCast(0xDC00 + (v & 0x3FF)));
        }
        return;
    }
    // Identity: copy the source's raw bytes verbatim.
    try out.appendSlice(arena, raw);
}

/// RegExp.escape ( S ) — ES2025. Escapes `S` so it matches literally in a pattern.
pub fn nativeRegExpEscape(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = this_val;
    const s: []const u8 = switch (if (args.len > 0) args[0].unbox() else .undefined_) {
        .string => |str| str,
        else => return realm_mod.throwTypeError(arena, "RegExp.escape requires a string argument"),
    };
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        // decodeCpAt folds a high+low WTF-8 surrogate pair into one astral code
        // point so it round-trips as an identity char (StringToCodePoints).
        const dec = decodeCpAt(s, i);
        const len = if (dec.len == 0) 1 else dec.len;
        const c = dec.cp;
        if (i == 0 and ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) {
            // Leading digit/ASCII-letter: force `\xHH` so it can't extend a prior escape.
            try appendHex2(arena, &out, c);
        } else {
            try encodeForRegExpEscape(arena, &out, c, s[i .. i + len]);
        }
        i += len;
    }
    return val_mod.makeString(arena, out.items);
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

/// Width of the code point at `pos` AS `/u` MODE SEES IT — a WTF-8 surrogate
/// pair (how `\u{...}` escapes and String.fromCodePoint store astral
/// characters) counts as the single 6-byte unit `decodeCpAt` folds it into.
/// Scanning with `utf8ByteLenAt` instead would land in the middle of the pair
/// and desynchronize from what the matcher just consumed.
pub fn cpByteLenAt(buf: []const u8, pos: usize) u8 {
    return decodeCpAt(buf, pos).len;
}

/// Decode one code point at `pos` the way `/u` and `/v` mode see the input.
///
/// JSZ stores an astral character either as a single 4-byte UTF-8 sequence
/// (source literals) or as a WTF-8 surrogate pair of two 3-byte sequences
/// (`\u{...}` escapes, `String.fromCodePoint`). Both denote the same
/// ECMAScript string, so codepoint mode must fold the pair back into one
/// code point -- otherwise `\p{...}`, astral literals and `.` silently fail
/// to match anything built through the escape/`fromCodePoint` path.
///
/// Only for `cpMode()`: without `/u`, a surrogate pair really is two separate
/// UTF-16 code units and must stay split.
fn decodeCpAt(buf: []const u8, pos: usize) struct { cp: u21, len: u8 } {
    const dec = decodeUtf8At(buf, pos);
    if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF and pos + dec.len < buf.len) {
        const nxt = decodeUtf8At(buf, pos + dec.len);
        if (nxt.len != 0 and nxt.cp >= 0xDC00 and nxt.cp <= 0xDFFF) {
            return .{
                .cp = 0x10000 + ((dec.cp - 0xD800) << 10) + (nxt.cp - 0xDC00),
                .len = dec.len + nxt.len,
            };
        }
    }
    return .{ .cp = dec.cp, .len = dec.len };
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
    /// Unicode property-escape tables (\p{...}/\P{...}) under /u. Each entry is a
    /// sorted, disjoint range table plus a per-property negation flag so that
    /// `\P{X}` inside a character class means "the complement of X".
    prop_refs: std.ArrayListUnmanaged(PropRef) = .{},

    pub const CpRange = struct { lo: u21, hi: u21 };
    pub const PropRef = struct { table: []const [2]u21, negated: bool };

    /// Add a Unicode property-escape table (binary-searched at match time).
    pub fn addPropTable(self: *CharClass, alloc: std.mem.Allocator, table: []const [2]u21, negated: bool) !void {
        try self.prop_refs.append(alloc, .{ .table = table, .negated = negated });
    }

    /// Match a single byte (non-unicode mode fast path).
    pub fn matches(self: *const CharClass, c: u8) bool {
        const hit = self.bitmap[c];
        return if (self.negate) !hit else hit;
    }

    /// Match a Unicode codepoint (unicode mode).
    pub fn matchesCp(self: *const CharClass, cp: u21) bool {
        const hit = self.containsCp(cp);
        return if (self.negate) !hit else hit;
    }

    /// Membership BEFORE the leading `^` is applied. Case-insensitive matching
    /// needs this: it has to test several case variants and negate the combined
    /// result once, not once per variant.
    pub fn containsCp(self: *const CharClass, cp: u21) bool {
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
        if (!hit) {
            for (self.prop_refs.items) |pr| {
                const in_table = tableContains(pr.table, cp);
                if (if (pr.negated) !in_table else in_table) {
                    hit = true;
                    break;
                }
            }
        }
        return hit;
    }

    /// Binary search a sorted, disjoint [lo,hi] range table for `cp`.
    fn tableContains(table: []const [2]u21, cp: u21) bool {
        var lo: usize = 0;
        var hi: usize = table.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = table[mid];
            if (cp < r[0]) {
                hi = mid;
            } else if (cp > r[1]) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
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
    /// ES2025 duplicate named capture groups: `\k<x>` when several groups share
    /// the name `x`. The grammar guarantees they live in different alternatives,
    /// so at most one has participated; the reference uses whichever is set and
    /// matches the empty string when none is.
    back_ref_multi: []const u32,
    /// ES2025 RegExp modifiers `(?ims-ims: ... )`: rebinds the i/m/s flags for
    /// the enclosed disjunction only. `add` and `remove` can never overlap --
    /// the parser rejects a modifier listed on both sides.
    modifier: struct {
        inner: *RegexNode,
        add: ModifierSet,
        remove: ModifierSet,
    },
};

/// The three flags a `(?ims-ims:...)` group may rebind.
pub const ModifierSet = struct {
    ignore_case: bool = false,
    multiline: bool = false,
    dotall: bool = false,

    fn empty(self: ModifierSet) bool {
        return !self.ignore_case and !self.multiline and !self.dotall;
    }

    fn overlaps(self: ModifierSet, other: ModifierSet) bool {
        return (self.ignore_case and other.ignore_case) or
            (self.multiline and other.multiline) or
            (self.dotall and other.dotall);
    }
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
    /// Wave 23: compiled Pike-VM program (non-backtracking, linear-time).
    /// Non-null when the pattern is Pike-eligible (no top-level backreference).
    /// When null, execution falls back to the recursive backtracking matcher.
    program: ?*Program = null,
    /// Lazily-initialized PikeVM execution state (reused across matches).
    pike_vm: ?PikeVM = null,
    /// Whether the pattern contains a backreference outside any lookaround.
    /// Such patterns are NP-hard in general, so they keep the backtracker.
    has_backref: bool = false,
    /// Whether the pattern requires ES §22.2.2.5.1 step-2b processing:
    /// zero-width optional iterations must discard their captures and, for
    /// patterns with lazy inner quantifiers, trigger a forced non-empty retry.
    /// Patterns with this flag always use the backtracking engine.
    needs_step2b: bool = false,

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
        /// ES2024 `v` (unicodeSets): extended character classes plus set
        /// operations. Implies full code-point matching semantics like `u`.
        unicode_sets: bool = false,
        /// ES2022 `d` (hasIndices): exec results carry an `indices` array.
        has_indices: bool = false,

        /// Whether the matcher should advance by whole code points (true under
        /// either `u` or `v`) rather than by single bytes.
        pub fn cpMode(self: Flags) bool {
            return self.unicode or self.unicode_sets;
        }
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
    unicode: bool, // codepoint mode (`/u` or `/v`)
    unicode_sets: bool = false, // `/v` flag: enables ClassSetExpression grammar
    group_names: []const NameIdx = &.{}, // pre-scanned names, for `\k<name>` resolution
    total_caps: u32 = 0, // pre-scanned capture-group count, for `\N` validation

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
            // `decodeCpAt` folds a WTF-8 surrogate pair (an astral character read
            // from a string-form pattern, `new RegExp("𝌆","u")`) into the
            // single astral code point `/u` mode must see.
            const dc = decodeCpAt(self.src, self.pos);
            self.pos += dc.len;
            return dc.cp;
        }
        const b = self.cur();
        self.advance();
        return @as(u21, b);
    }

    /// A literal node for code point `cp`. In byte-based (non-/u) mode a value
    /// ≥ 0x80 is expanded to a sequence of byte-literals holding its WTF-8 bytes,
    /// so it matches the same way a bare multi-byte character does. Under /u the
    /// matcher decodes code points directly, so a single literal node is emitted.
    fn cpLiteralNode(self: *PatternParser, cp: u21) ParseError!RegexNode {
        if (self.unicode or cp < 0x80) return RegexNode{ .literal = cp };
        var buf: [4]u8 = undefined;
        const n = encodeUtf8Cp(cp, &buf);
        var items = std.ArrayListUnmanaged(RegexNode){};
        for (buf[0..n]) |b| {
            items.append(self.alloc, .{ .literal = @as(u21, b) }) catch return ParseError.OutOfMemory;
        }
        return RegexNode{ .seq = items.items };
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
                // Only an Atom is quantifiable. Assertions are not, with the one
                // Annex B exception of `(?=...)`/`(?!...)` outside unicode mode
                // (QuantifiableAssertion); lookbehind is never quantifiable.
                switch (atom) {
                    .look_ahead => if (self.unicode) return ParseError.InvalidPattern,
                    .look_behind,
                    .anchor_start,
                    .anchor_end,
                    .word_boundary,
                    .non_word_boundary,
                    => return ParseError.InvalidPattern,
                    else => {},
                }
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

    /// Parse `(?ims:...)` / `(?ims-ims:...)` after `(` has been consumed and the
    /// non-capturing / lookaround forms have been ruled out. Every other `(?`
    /// spelling is a modifier group, so anything malformed here is a genuine
    /// Syntax Error rather than a fallthrough to some other production.
    fn parseModifierGroup(self: *PatternParser) ParseError!RegexNode {
        self.advance(); // '?'
        var add: ModifierSet = .{};
        var remove: ModifierSet = .{};
        try self.parseModifierList(&add);
        if (!self.eof() and self.cur() == '-') {
            self.advance();
            try self.parseModifierList(&remove);
        }
        // `(?-:a)` names no flags at all; `(?i-i:a)` both adds and removes one.
        if (add.empty() and remove.empty()) return ParseError.InvalidPattern;
        if (add.overlaps(remove)) return ParseError.InvalidPattern;
        if (self.eof() or self.cur() != ':') return ParseError.InvalidPattern;
        self.advance(); // ':'
        const inner = try self.parseAlt();
        if (self.eof() or self.cur() != ')') return ParseError.InvalidPattern;
        self.advance();
        const inner_ptr = try self.alloc.create(RegexNode);
        inner_ptr.* = inner;
        return RegexNode{ .modifier = .{ .inner = inner_ptr, .add = add, .remove = remove } };
    }

    /// Consume a run of distinct `i`/`m`/`s` modifier letters. Stops at the
    /// first character that is not one; a repeat (`(?ii:a)`) is a Syntax Error.
    fn parseModifierList(self: *PatternParser, set: *ModifierSet) ParseError!void {
        while (!self.eof()) {
            switch (self.cur()) {
                'i' => {
                    if (set.ignore_case) return ParseError.InvalidPattern;
                    set.ignore_case = true;
                },
                'm' => {
                    if (set.multiline) return ParseError.InvalidPattern;
                    set.multiline = true;
                },
                's' => {
                    if (set.dotall) return ParseError.InvalidPattern;
                    set.dotall = true;
                },
                else => return,
            }
            self.advance();
        }
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
                // ES2025 modifier group `(?ims:...)` / `(?ims-ims:...)`. Every
                // other `(?` form was handled above, so this is the last one.
                if (!self.eof() and self.cur() == '?') {
                    return try self.parseModifierGroup();
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
                if (self.unicode_sets) return try self.parseClassSetExpr();
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
            // A quantifier here has no Atom to repeat (`*a`, `a**`, `(+)`).
            '*', '+', '?' => return ParseError.InvalidPattern,
            '{' => {
                // `{` is a SyntaxCharacter: under /u it must be escaped. Annex B
                // lets it stand for itself, but only when it cannot begin a
                // quantifier -- `{1}` here would be a quantifier with no Atom.
                if (self.unicode) return ParseError.InvalidPattern;
                const saved = self.pos;
                const q = self.parseQuantifier() catch return ParseError.InvalidPattern;
                if (q != null) return ParseError.InvalidPattern;
                self.pos = saved;
                self.advance();
                return RegexNode{ .literal = '{' };
            },
            '}', ']' => {
                // Likewise reserved under /u; a bare literal under Annex B.
                if (self.unicode) return ParseError.InvalidPattern;
                self.advance();
                return RegexNode{ .literal = @as(u21, c) };
            },
            else => {
                // Under /u, multi-byte UTF-8 sequences are decoded to a single codepoint literal.
                const cp = self.readCp();
                return RegexNode{ .literal = cp };
            },
        }
    }

    /// Parse the ClassAtom that follows a `-` inside a character class and
    /// return its code point. Ranges may be spelled with escapes on either side
    /// (`[\x41-\x5A]`, `[\u{10401}-\u{10404}]`), which the per-escape cases
    /// below cannot express on their own. A CharacterClassEscape stands for a
    /// whole set and may never end a range.
    /// Read the remaining digits of a LegacyOctalEscapeSequence (Annex B), given
    /// the value of the first octal digit (already consumed). A leading 0-3 allows
    /// up to three octal digits total; 4-7 allows two. Returns the code unit value.
    fn readLegacyOctalRest(self: *PatternParser, first: u21) u21 {
        var val: u21 = first;
        const max_digits: u8 = if (first <= 3) 3 else 2;
        var digits: u8 = 1;
        while (digits < max_digits and !self.eof() and self.cur() >= '0' and self.cur() <= '7') {
            val = val * 8 + (self.cur() - '0');
            self.advance();
            digits += 1;
        }
        return val;
    }

    /// Add a predefined set escape (`\d \D \w \W \s \S`) to `cc`. Shared by the
    /// class body and the Annex B CharacterRangeOrUnion path.
    fn addSetEscapeToClass(_: *PatternParser, cc: *CharClass, esc: u8) void {
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
            else => {},
        }
    }

    /// Annex B CharacterRangeOrUnion: after a range dash has been consumed at
    /// `lo-<here>`, if the endpoint is a CharacterClassEscape (`\d` etc.) then the
    /// range is not a range at all — the `-` is literal and the result is the
    /// union of {lo}, {'-'}, and the escape's set. Consumes the escape and returns
    /// true; otherwise consumes nothing and returns false.
    fn tryClassRangeOrUnion(self: *PatternParser, cc: *CharClass, lo: u21) ParseError!bool {
        if (self.unicode) return false;
        if (self.eof() or self.cur() != '\\' or self.pos + 1 >= self.src.len) return false;
        const e = self.src[self.pos + 1];
        const is_set = switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => true,
            else => false,
        };
        if (!is_set) return false;
        self.advance(); // backslash
        self.advance(); // set letter
        cc.addCpRange(self.alloc, lo, lo) catch return ParseError.OutOfMemory;
        cc.addChar('-');
        self.addSetEscapeToClass(cc, e);
        return true;
    }

    fn parseClassRangeEnd(self: *PatternParser) ParseError!u21 {
        if (self.eof()) return ParseError.InvalidPattern;
        if (self.cur() != '\\') {
            if (!self.unicode) {
                const b = self.cur();
                self.advance();
                return b;
            }
            const dc = decodeCpAt(self.src, self.pos);
            self.pos += dc.len;
            return dc.cp;
        }
        self.advance(); // backslash
        if (self.eof()) return ParseError.InvalidPattern;
        const e = self.cur();
        self.advance();
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'v' => 0x0B,
            'f' => 0x0C,
            'b' => 0x08,
            '0' => blk: {
                if (!self.unicode and !self.eof() and self.cur() >= '0' and self.cur() <= '7') {
                    break :blk self.readLegacyOctalRest(0);
                }
                break :blk 0;
            },
            // Annex B legacy octal at a range endpoint (e.g. `[\12-\14]`).
            '1', '2', '3', '4', '5', '6', '7' => blk: {
                if (self.unicode) return ParseError.InvalidPattern;
                break :blk self.readLegacyOctalRest(e - '0');
            },
            'x' => blk: {
                if (self.pos + 1 >= self.src.len or
                    hexVal(self.src[self.pos]) == null or
                    hexVal(self.src[self.pos + 1]) == null)
                {
                    if (self.unicode) return ParseError.InvalidPattern;
                    break :blk 'x';
                }
                const h1 = hexVal(self.src[self.pos]).?;
                const h2 = hexVal(self.src[self.pos + 1]).?;
                self.pos += 2;
                break :blk @as(u21, h1) * 16 + h2;
            },
            'u' => try self.parseUEscape(),
            'c' => blk: {
                if (!self.eof() and isAsciiAlpha(self.cur())) {
                    const v: u21 = self.cur() & 0x1F;
                    self.advance();
                    break :blk v;
                }
                if (self.unicode) return ParseError.InvalidPattern;
                break :blk 'c';
            },
            'd', 'D', 'w', 'W', 's', 'S', 'p', 'P' => ParseError.InvalidPattern,
            else => blk: {
                if (self.unicode and !isSyntaxChar(e) and e != '/' and e != '-')
                    return ParseError.InvalidPattern;
                break :blk e;
            },
        };
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
                // A CharacterClassEscape stands for a whole set, so it can never
                // be an endpoint of a range: `[\d-a]` / `[a-\d]` are early errors
                // under /u (Annex B tolerates them as three separate atoms).
                const is_set_escape = switch (esc) {
                    'd', 'D', 'w', 'W', 's', 'S', 'p', 'P' => true,
                    else => false,
                };
                // The code point this escape denotes, when it denotes exactly
                // one — set below by the single-character cases so the range
                // check after the switch can use it as a lower bound.
                var single_cp: ?u21 = null;
                if (self.unicode and is_set_escape and !self.eof() and self.cur() == '-' and
                    self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']')
                {
                    // `\p{..}`/`\P{..}` have not consumed their braces yet, so only
                    // the single-letter escapes can be checked here; the property
                    // forms are re-checked after their name is read.
                    if (esc != 'p' and esc != 'P') return ParseError.InvalidPattern;
                }
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
                    'n' => single_cp = '\n',
                    't' => single_cp = '\t',
                    'r' => single_cp = '\r',
                    'v' => single_cp = 0x0B,
                    'f' => single_cp = 0x0C,
                    // Inside a class `\b` is BACKSPACE, not a word boundary.
                    'b' => single_cp = 0x08,
                    '0' => {
                        if (self.unicode and !self.eof() and self.cur() >= '0' and self.cur() <= '9') {
                            return ParseError.InvalidPattern; // legacy octal
                        }
                        if (!self.unicode and !self.eof() and self.cur() >= '0' and self.cur() <= '7') {
                            single_cp = self.readLegacyOctalRest(0);
                        } else {
                            single_cp = 0;
                        }
                    },
                    // Annex B: inside a class, \1-\7 are LegacyOctalEscapes (there
                    // are no backreferences in a class); \8/\9 are IdentityEscapes.
                    '1', '2', '3', '4', '5', '6', '7' => {
                        if (self.unicode) return ParseError.InvalidPattern;
                        single_cp = self.readLegacyOctalRest(esc - '0');
                    },
                    'c' => {
                        // ClassControlLetter is a letter always; Annex B also admits
                        // a DecimalDigit or `_` (character value mod 32).
                        const is_ctrl = !self.eof() and (isAsciiAlpha(self.cur()) or
                            (!self.unicode and (std.ascii.isDigit(self.cur()) or self.cur() == '_')));
                        if (is_ctrl) {
                            single_cp = self.cur() & 0x1F;
                            self.advance();
                        } else if (self.unicode) {
                            return ParseError.InvalidPattern;
                        } else {
                            // Annex B ClassAtom :: `\` -- the backslash itself,
                            // with the `c` left to be read as an ordinary member.
                            cc.addChar('\\');
                            self.pos -= 1;
                        }
                    },
                    'x' => {
                        if (self.pos + 1 >= self.src.len or
                            hexVal(self.src[self.pos]) == null or
                            hexVal(self.src[self.pos + 1]) == null)
                        {
                            if (self.unicode) return ParseError.InvalidPattern;
                            single_cp = 'x';
                        } else {
                            const h1 = hexVal(self.src[self.pos]).?;
                            const h2 = hexVal(self.src[self.pos + 1]).?;
                            self.pos += 2;
                            single_cp = @as(u21, h1) * 16 + h2;
                        }
                    },
                    'u' => single_cp = try self.parseUEscape(),
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
                            const table = uprop.lookup(name) orelse return ParseError.InvalidPattern;
                            // `\P{X}` inside [...] means "the complement of X"; the
                            // per-property negation flag handles this correctly when
                            // OR-combined with the rest of the class.
                            cc.addPropTable(self.alloc, table, esc == 'P') catch return ParseError.OutOfMemory;
                            // Now that `{Name}` is consumed, apply the same
                            // "set escape cannot be a range endpoint" rule.
                            if (!self.eof() and self.cur() == '-' and
                                self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']')
                            {
                                return ParseError.InvalidPattern;
                            }
                        }
                    },
                    else => {
                        // ClassEscape :: IdentityEscape. Under /u only
                        // SyntaxCharacter, `/` and `-` may be escaped this way.
                        if (self.unicode and !isSyntaxChar(esc) and esc != '/' and esc != '-') {
                            return ParseError.InvalidPattern;
                        }
                        single_cp = esc;
                    },
                }
                if (single_cp) |lo| {
                    if (!self.eof() and self.cur() == '-' and
                        self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']')
                    {
                        self.advance(); // consume -
                        if (!try self.tryClassRangeOrUnion(cc, lo)) {
                            const hi = try self.parseClassRangeEnd();
                            if (hi < lo) return ParseError.InvalidPattern;
                            cc.addCpRange(self.alloc, lo, hi) catch return ParseError.OutOfMemory;
                        }
                    } else {
                        cc.addCpRange(self.alloc, lo, lo) catch return ParseError.OutOfMemory;
                    }
                }
            } else if (ch >= 0x80) {
                // Non-ASCII codepoint start -- decode the full codepoint and store
                // it as a code point, mirroring how `consumeClass` decodes the
                // subject in *both* modes. Under /u, `decodeCpAt` folds a WTF-8
                // surrogate *pair* — how `new RegExp("[𝌆]","u")` stores an astral
                // character read from a string argument — into the single astral
                // code point `/u` mode must see. In non-/u (code-unit) mode a
                // multibyte member such as an Arabic-Indic digit (`[٠-٩]`) must be
                // added as its code point too, else `[٠١…]` — with each member
                // formerly split into raw bytes — would never match the decoded
                // code point the matcher tests.
                const start_cp: u21 = if (self.unicode) blk: {
                    const d = decodeCpAt(self.src, self.pos);
                    self.pos += d.len;
                    break :blk d.cp;
                } else blk: {
                    const d = decodeUtf8At(self.src, self.pos);
                    self.pos += d.len;
                    break :blk d.cp;
                };
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
                    } else if (self.unicode) blk: {
                        const edc = decodeCpAt(self.src, self.pos);
                        self.pos += edc.len;
                        break :blk edc.cp;
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
                    if (!try self.tryClassRangeOrUnion(cc, start_ch)) {
                        // The endpoint may be an escape denoting any code point
                        // (`[a-\u{10404}]`), so it is not limited to a byte.
                        const end_cp = try self.parseClassRangeEnd();
                        if (end_cp < start_ch) return ParseError.InvalidPattern;
                        cc.addCpRange(self.alloc, start_ch, end_cp) catch return ParseError.OutOfMemory;
                    }
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
        const lead: u21 = @intCast(@as(u32, h1) * 4096 + @as(u32, h2) * 256 + @as(u32, h3) * 16 + h4);
        // Under /u a \uHHHH high surrogate immediately followed by a \uHHHH low
        // surrogate combines into a single astral code point (RegExpUnicode
        // EscapeSequence trailing-surrogate rule).
        if (self.unicode and lead >= 0xD800 and lead <= 0xDBFF and
            self.pos + 5 < self.src.len and self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u')
        {
            const t1 = hexVal(self.src[self.pos + 2]);
            const t2 = hexVal(self.src[self.pos + 3]);
            const t3 = hexVal(self.src[self.pos + 4]);
            const t4 = hexVal(self.src[self.pos + 5]);
            if (t1 != null and t2 != null and t3 != null and t4 != null) {
                const trail: u21 = @intCast(@as(u32, t1.?) * 4096 + @as(u32, t2.?) * 256 + @as(u32, t3.?) * 16 + t4.?);
                if (trail >= 0xDC00 and trail <= 0xDFFF) {
                    self.pos += 6;
                    return @intCast(0x10000 + ((@as(u32, lead) - 0xD800) << 10) + (@as(u32, trail) - 0xDC00));
                }
            }
        }
        return lead;
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
            // Under /u a DecimalEscape is always a backreference, so naming a
            // group that does not exist is an early error.
            if (self.unicode) {
                if (idx > self.total_caps) return ParseError.InvalidPattern;
                return RegexNode{ .back_ref = idx };
            }
            // Annex B: a DecimalEscape referring to an existing capture group is a
            // backreference; otherwise \1-\7 are LegacyOctalEscapeSequences and
            // \8/\9 are IdentityEscapes (the literal digit).
            if (idx <= self.total_caps) return RegexNode{ .back_ref = idx };
            if (c == '8' or c == '9') return RegexNode{ .literal = @as(u21, c) };
            return self.cpLiteralNode(self.readLegacyOctalRest(idx));
        }
        // Named backreference \k<name> (only meaningful when the pattern has
        // named groups; otherwise `\k` is a literal 'k' in non-unicode mode).
        if (c == 'k' and (self.group_names.len > 0 or self.unicode)) {
            if (self.eof() or self.cur() != '<') return ParseError.InvalidPattern;
            self.advance(); // <
            const name_start = self.pos;
            while (!self.eof() and self.cur() != '>') self.advance();
            if (self.eof()) return ParseError.InvalidPattern;
            const name = decodeGroupNameId(self.alloc, self.src[name_start..self.pos]) catch
                return ParseError.OutOfMemory;
            self.advance(); // >
            var hits = std.ArrayList(u32){};
            for (self.group_names) |ni| {
                if (std.mem.eql(u8, ni.name, name))
                    hits.append(self.alloc, ni.idx) catch return ParseError.OutOfMemory;
            }
            if (hits.items.len == 1) return RegexNode{ .back_ref = @intCast(hits.items[0]) };
            if (hits.items.len > 1) return RegexNode{ .back_ref_multi = hits.items };
            return ParseError.InvalidPattern; // unknown group name
        }
        return switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
                // `\s` matches the full Unicode WhiteSpace + LineTerminator set in
                // BOTH /u and non-/u modes -- CharacterClassEscape :: s is defined
                // over code points, not affected by the /u flag. consumeClass
                // decodes a whole code unit in either mode, so the extra_ranges
                // (Unicode spaces beyond Latin-1) apply regardless of /u.
                if (lower == 's') {
                    cc.addPredefinedUnicodeS(self.alloc) catch return ParseError.OutOfMemory;
                } else {
                    cc.addPredefined(lower, false);
                }
                // `\D`/`\W`/`\S` are the complements of `\d`/`\w`/`\s`. Use the
                // global negate flag (rather than bitmap inversion) so the
                // complement covers code points > 255 too -- e.g. `\S` must match
                // U+180E (a non-whitespace astral-ish BMP char) and `\D` must
                // match any non-ASCII-digit code point.
                if (c == 'D' or c == 'W' or c == 'S') {
                    cc.negate = true;
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
                const table = uprop.lookup(name) orelse return ParseError.InvalidPattern;
                const cc = try self.alloc.create(CharClass);
                cc.* = CharClass{};
                cc.addPropTable(self.alloc, table, c == 'P') catch return ParseError.OutOfMemory;
                return RegexNode{ .char_class = cc };
            },
            'n' => RegexNode{ .literal = '\n' },
            't' => RegexNode{ .literal = '\t' },
            'r' => RegexNode{ .literal = '\r' },
            'v' => RegexNode{ .literal = 0x0B },
            'f' => RegexNode{ .literal = 0x0C },
            '0' => {
                // `\0` is NUL; `\0` followed by a digit is a legacy octal escape,
                // which /u forbids outright.
                if (self.unicode and !self.eof() and self.cur() >= '0' and self.cur() <= '9') {
                    return ParseError.InvalidPattern;
                }
                // Annex B: `\0` followed by octal digits is a LegacyOctalEscape.
                if (!self.unicode and !self.eof() and self.cur() >= '0' and self.cur() <= '7') {
                    return self.cpLiteralNode(self.readLegacyOctalRest(0));
                }
                return RegexNode{ .literal = 0 };
            },
            'c' => {
                // \cX -- the control character for ControlLetter X. Under /u a
                // missing/invalid ControlLetter is an early error; Annex B instead
                // rereads the whole thing as a literal `\` followed by `c`.
                if (!self.eof() and isAsciiAlpha(self.cur())) {
                    const letter = self.cur();
                    self.advance();
                    return RegexNode{ .literal = @as(u21, letter & 0x1F) };
                }
                if (self.unicode) return ParseError.InvalidPattern;
                self.pos -= 1; // re-emit the 'c' as an ordinary literal next round
                return RegexNode{ .literal = '\\' };
            },
            'x' => {
                if (self.pos + 2 > self.src.len or
                    hexVal(self.src[self.pos]) == null or
                    hexVal(self.src[self.pos + 1]) == null)
                {
                    // Incomplete \xHH: an identity escape under Annex B only.
                    if (self.unicode) return ParseError.InvalidPattern;
                    return RegexNode{ .literal = 'x' };
                }
                const h1 = hexVal(self.src[self.pos]).?;
                const h2 = hexVal(self.src[self.pos + 1]).?;
                self.pos += 2;
                return self.cpLiteralNode(@intCast(@as(u16, h1) * 16 + h2));
            },
            'u' => {
                const save = self.pos;
                if (self.parseUEscape()) |cp| {
                    return self.cpLiteralNode(cp);
                } else |_| {
                    // Incomplete `\u`: /u forbids it; Annex B rereads it as an
                    // IdentityEscape, i.e. a literal `u`.
                    if (self.unicode) return ParseError.InvalidPattern;
                    self.pos = save;
                    return RegexNode{ .literal = 'u' };
                }
            },
            else => {
                // IdentityEscape: /u admits only SyntaxCharacter and `/`; Annex B
                // admits (almost) anything.
                if (self.unicode and !isSyntaxChar(c) and c != '/') return ParseError.InvalidPattern;
                return RegexNode{ .literal = @as(u21, c) };
            },
        };
    }

    // ================================================= v-flag ClassSetExpression

    /// One parsed operand of a ClassSetExpression, plus (for union ranges) the
    /// single codepoint it represents when it was a bare ClassSetCharacter.
    const SetOperand = struct { set: ClassSet, single_cp: ?u21 };

    /// Entry point for `[...]` under the `v` flag. Parses the whole class,
    /// then lowers the resulting code-point set + string alternatives to an AST
    /// node (a plain char_class when there are no strings, else an alternation).
    fn parseClassSetExpr(self: *PatternParser) ParseError!RegexNode {
        var negate = false;
        var set = try self.parseNestedClassBody(&negate);
        defer set.deinit(self.alloc);
        return self.lowerClassSet(negate, &set);
    }

    /// Parse `[` [`^`] ClassSetInner `]` and return the resulting set, reporting
    /// negation via `neg_out`. Used both at the top level and for nested `[...]`.
    fn parseNestedClassBody(self: *PatternParser, neg_out: *bool) ParseError!ClassSet {
        if (self.eof() or self.cur() != '[') return ParseError.InvalidPattern;
        self.advance(); // [
        if (!self.eof() and self.cur() == '^') {
            neg_out.* = true;
            self.advance();
        }
        var set = try self.parseClassSetInner();
        errdefer set.deinit(self.alloc);
        if (self.eof() or self.cur() != ']') return ParseError.InvalidPattern;
        self.advance(); // ]
        return set;
    }

    /// Parse the body of a class (up to but not consuming `]`): a union, an
    /// intersection chain (`&&`), or a subtraction chain (`--`).
    fn parseClassSetInner(self: *PatternParser) ParseError!ClassSet {
        var first = try self.parseSetOperand();
        errdefer first.set.deinit(self.alloc);

        // Intersection: A && B && ...
        if (self.cur() == '&' and self.peek() == @as(?u8, '&')) {
            var acc = first.set;
            while (self.cur() == '&' and self.peek() == @as(?u8, '&')) {
                self.advance();
                self.advance();
                var rhs = try self.parseSetOperand();
                defer rhs.set.deinit(self.alloc);
                const next = try acc.intersect(self.alloc, &rhs.set);
                acc.deinit(self.alloc);
                acc = next;
            }
            return acc;
        }
        // Subtraction: A -- B -- ...
        if (self.cur() == '-' and self.peek() == @as(?u8, '-')) {
            var acc = first.set;
            while (self.cur() == '-' and self.peek() == @as(?u8, '-')) {
                self.advance();
                self.advance();
                var rhs = try self.parseSetOperand();
                defer rhs.set.deinit(self.alloc);
                const next = try acc.subtract(self.alloc, &rhs.set);
                acc.deinit(self.alloc);
                acc = next;
            }
            return acc;
        }
        // Union: operands (and ClassSetRanges) juxtaposed until `]`.
        var acc = first.set;
        var pending_lo: ?u21 = first.single_cp;
        while (!self.eof() and self.cur() != ']') {
            // ClassSetRange: `a-b` where the previous operand was a single char.
            if (pending_lo != null and self.cur() == '-' and self.peek() != @as(?u8, '-') and
                !(self.pos + 1 < self.src.len and self.src[self.pos + 1] == ']'))
            {
                self.advance(); // consume `-`
                var hi_op = try self.parseSetOperand();
                defer hi_op.set.deinit(self.alloc);
                const hi = hi_op.single_cp orelse return ParseError.InvalidPattern;
                if (hi < pending_lo.?) return ParseError.InvalidPattern;
                try acc.addRange(self.alloc, pending_lo.?, hi);
                pending_lo = null;
                continue;
            }
            var op = try self.parseSetOperand();
            const nlo = op.single_cp;
            const merged = try acc.unionWith(self.alloc, &op.set);
            acc.deinit(self.alloc);
            op.set.deinit(self.alloc);
            acc = merged;
            pending_lo = nlo;
        }
        return acc;
    }

    /// Parse one ClassSetOperand: a nested `[...]`, `\q{...}`, `\p{}`/`\P{}`, a
    /// class-escape (`\d` etc.), or a single ClassSetCharacter (possibly escaped).
    fn parseSetOperand(self: *PatternParser) ParseError!SetOperand {
        if (self.eof()) return ParseError.InvalidPattern;
        const c = self.cur();
        if (c == '[') {
            var neg = false;
            var set = try self.parseNestedClassBody(&neg);
            if (neg) {
                const comp = try set.complement(self.alloc);
                set.deinit(self.alloc);
                return .{ .set = comp, .single_cp = null };
            }
            return .{ .set = set, .single_cp = null };
        }
        if (c == '\\') {
            self.advance();
            if (self.eof()) return ParseError.InvalidPattern;
            const esc = self.cur();
            switch (esc) {
                'q' => {
                    self.advance();
                    return .{ .set = try self.parseQStrings(), .single_cp = null };
                },
                'd', 'D', 'w', 'W', 's', 'S' => {
                    self.advance();
                    var set = ClassSet{};
                    try set.addClassEscape(self.alloc, esc, self.unicode);
                    return .{ .set = set, .single_cp = null };
                },
                'p', 'P' => {
                    self.advance();
                    return .{ .set = try self.parsePropSet(esc == 'P'), .single_cp = null };
                },
                else => {
                    const cp = try self.parseUEscapeOrByte();
                    var set = ClassSet{};
                    try set.addRange(self.alloc, cp, cp);
                    return .{ .set = set, .single_cp = cp };
                },
            }
        }
        // Bare ClassSetCharacter.
        const cp = self.readCp();
        var set = ClassSet{};
        try set.addRange(self.alloc, cp, cp);
        return .{ .set = set, .single_cp = cp };
    }

    /// Parse `\q{ alt | alt | ... }` string-literal alternatives into a ClassSet:
    /// length-1 alternatives join the code-point set, others become string members.
    fn parseQStrings(self: *PatternParser) ParseError!ClassSet {
        if (self.eof() or self.cur() != '{') return ParseError.InvalidPattern;
        self.advance(); // {
        var set = ClassSet{};
        errdefer set.deinit(self.alloc);
        var cur_str = std.ArrayListUnmanaged(u21){};
        defer cur_str.deinit(self.alloc);
        while (true) {
            if (self.eof()) return ParseError.InvalidPattern;
            const ch = self.cur();
            if (ch == '}' or ch == '|') {
                // Flush the current alternative.
                if (cur_str.items.len == 1) {
                    const cp = cur_str.items[0];
                    try set.addRange(self.alloc, cp, cp);
                } else {
                    const owned = try self.alloc.dupe(u21, cur_str.items);
                    try set.strings.append(self.alloc, owned);
                }
                cur_str.clearRetainingCapacity();
                self.advance();
                if (ch == '}') break;
                continue;
            }
            if (ch == '\\') {
                self.advance();
                const cp = try self.parseUEscapeOrByte();
                try cur_str.append(self.alloc, cp);
            } else {
                try cur_str.append(self.alloc, self.readCp());
            }
        }
        return set;
    }

    /// Parse the `{Name}` of a `\p`/`\P` escape in a class set. Handles both
    /// code-point properties (via the shared tables) and properties of strings
    /// (e.g. Emoji_Keycap_Sequence). `\P` of a string property is a Syntax error.
    fn parsePropSet(self: *PatternParser, negated: bool) ParseError!ClassSet {
        if (self.eof() or self.cur() != '{') return ParseError.InvalidPattern;
        self.advance(); // {
        const name_start = self.pos;
        while (!self.eof() and self.cur() != '}') self.advance();
        if (self.eof()) return ParseError.InvalidPattern;
        const name = self.src[name_start..self.pos];
        self.advance(); // }
        var set = ClassSet{};
        errdefer set.deinit(self.alloc);
        if (uprop.lookup(name)) |table| {
            for (table) |pair| try set.addRange(self.alloc, pair[0], pair[1]);
            if (negated) {
                const comp = try set.complement(self.alloc);
                set.deinit(self.alloc);
                return comp;
            }
            return set;
        }
        if (propertyOfStrings(name)) |seqs| {
            if (negated) return ParseError.InvalidPattern; // \P of a string property
            for (seqs) |s| {
                if (s.len == 1) {
                    try set.addRange(self.alloc, s[0], s[0]);
                } else {
                    try set.strings.append(self.alloc, s);
                }
            }
            return set;
        }
        return ParseError.InvalidPattern;
    }

    /// Lower a finished ClassSet to an AST node. With no string members this is a
    /// plain char_class; otherwise an alternation of each string (as a literal
    /// sequence) plus the remaining code-point class. A negated class that
    /// contains strings is a Syntax error (ES: MayContainStrings).
    fn lowerClassSet(self: *PatternParser, negate: bool, set: *ClassSet) ParseError!RegexNode {
        if (negate and set.strings.items.len > 0) return ParseError.InvalidPattern;

        const cc = try self.alloc.create(CharClass);
        cc.* = CharClass{};
        cc.negate = negate;
        for (set.ranges.items) |r| try cc.addCpRange(self.alloc, r.lo, r.hi);

        if (set.strings.items.len == 0) return RegexNode{ .char_class = cc };

        var arms = std.ArrayListUnmanaged(RegexNode){};
        // Longest strings first so an alternation prefers the maximal munch.
        const strs = try self.alloc.dupe([]const u21, set.strings.items);
        std.sort.pdq([]const u21, strs, {}, cmpStrLenDesc);
        for (strs) |s| {
            if (s.len == 0) {
                try arms.append(self.alloc, RegexNode{ .seq = &[_]RegexNode{} });
                continue;
            }
            var seq = try self.alloc.alloc(RegexNode, s.len);
            for (s, 0..) |cp, i| seq[i] = RegexNode{ .literal = cp };
            if (s.len == 1) {
                try arms.append(self.alloc, seq[0]);
            } else {
                try arms.append(self.alloc, RegexNode{ .seq = seq });
            }
        }
        if (set.ranges.items.len > 0) try arms.append(self.alloc, RegexNode{ .char_class = cc });
        if (arms.items.len == 1) return arms.items[0];
        return RegexNode{ .alt = try arms.toOwnedSlice(self.alloc) };
    }
};

fn cmpStrLenDesc(_: void, a: []const u21, b: []const u21) bool {
    return a.len > b.len;
}

/// A code-point set plus string members, used while evaluating a v-mode
/// ClassSetExpression. Ranges are kept sorted and disjoint after each op.
const ClassSet = struct {
    ranges: std.ArrayListUnmanaged(CharClass.CpRange) = .{},
    strings: std.ArrayListUnmanaged([]const u21) = .{},

    fn deinit(self: *ClassSet, alloc: std.mem.Allocator) void {
        self.ranges.deinit(alloc);
        self.strings.deinit(alloc);
    }

    fn addRange(self: *ClassSet, alloc: std.mem.Allocator, lo: u21, hi: u21) !void {
        if (lo > hi) return;
        try self.ranges.append(alloc, .{ .lo = lo, .hi = hi });
        try normalizeRanges(alloc, &self.ranges);
    }

    fn addClassEscape(self: *ClassSet, alloc: std.mem.Allocator, esc: u8, unicode: bool) !void {
        var cc = CharClass{};
        const lower = if (esc >= 'A' and esc <= 'Z') esc + 32 else esc;
        if (lower == 's' and unicode) {
            try cc.addPredefinedUnicodeS(alloc);
        } else {
            cc.addPredefined(lower, false);
        }
        // Collect the code points the bitmap/extra ranges cover, then negate if uppercase.
        var tmp = std.ArrayListUnmanaged(CharClass.CpRange){};
        defer tmp.deinit(alloc);
        var i: u21 = 0;
        while (i <= 255) : (i += 1) {
            if (cc.bitmap[i]) try tmp.append(alloc, .{ .lo = i, .hi = i });
        }
        for (cc.extra_ranges.items) |r| try tmp.append(alloc, r);
        try normalizeRanges(alloc, &tmp);
        if (esc == 'D' or esc == 'W' or esc == 'S') {
            const comp = try complementRanges(alloc, tmp.items);
            defer alloc.free(comp);
            for (comp) |r| try self.addRange(alloc, r.lo, r.hi);
        } else {
            for (tmp.items) |r| try self.addRange(alloc, r.lo, r.hi);
        }
    }

    fn hasString(self: *const ClassSet, s: []const u21) bool {
        for (self.strings.items) |t| {
            if (std.mem.eql(u21, t, s)) return true;
        }
        return false;
    }

    fn unionWith(self: *const ClassSet, alloc: std.mem.Allocator, other: *const ClassSet) !ClassSet {
        var out = ClassSet{};
        for (self.ranges.items) |r| try out.ranges.append(alloc, r);
        for (other.ranges.items) |r| try out.ranges.append(alloc, r);
        try normalizeRanges(alloc, &out.ranges);
        for (self.strings.items) |s| try out.strings.append(alloc, s);
        for (other.strings.items) |s| {
            if (!out.hasString(s)) try out.strings.append(alloc, s);
        }
        return out;
    }

    fn intersect(self: *const ClassSet, alloc: std.mem.Allocator, other: *const ClassSet) !ClassSet {
        var out = ClassSet{};
        const inter = try intersectRanges(alloc, self.ranges.items, other.ranges.items);
        defer alloc.free(inter);
        for (inter) |r| try out.ranges.append(alloc, r);
        for (self.strings.items) |s| {
            if (other.hasString(s)) try out.strings.append(alloc, s);
        }
        return out;
    }

    fn subtract(self: *const ClassSet, alloc: std.mem.Allocator, other: *const ClassSet) !ClassSet {
        var out = ClassSet{};
        const diff = try subtractRanges(alloc, self.ranges.items, other.ranges.items);
        defer alloc.free(diff);
        for (diff) |r| try out.ranges.append(alloc, r);
        for (self.strings.items) |s| {
            if (!other.hasString(s)) try out.strings.append(alloc, s);
        }
        return out;
    }

    fn complement(self: *const ClassSet, alloc: std.mem.Allocator) !ClassSet {
        var out = ClassSet{};
        const comp = try complementRanges(alloc, self.ranges.items);
        defer alloc.free(comp);
        for (comp) |r| try out.ranges.append(alloc, r);
        return out;
    }
};

/// Sort and merge a range list in place so it is sorted and disjoint.
fn normalizeRanges(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(CharClass.CpRange)) !void {
    if (list.items.len <= 1) return;
    std.sort.pdq(CharClass.CpRange, list.items, {}, cmpRangeLo);
    var out = std.ArrayListUnmanaged(CharClass.CpRange){};
    defer out.deinit(alloc);
    var cur = list.items[0];
    for (list.items[1..]) |r| {
        if (r.lo <= cur.hi + 1 and cur.hi != std.math.maxInt(u21)) {
            if (r.hi > cur.hi) cur.hi = r.hi;
        } else if (r.lo <= cur.hi) {
            if (r.hi > cur.hi) cur.hi = r.hi;
        } else {
            try out.append(alloc, cur);
            cur = r;
        }
    }
    try out.append(alloc, cur);
    list.clearRetainingCapacity();
    try list.appendSlice(alloc, out.items);
}

fn cmpRangeLo(_: void, a: CharClass.CpRange, b: CharClass.CpRange) bool {
    return a.lo < b.lo;
}

const MAX_CP: u21 = 0x10FFFF;

/// Complement of a sorted, disjoint range set over [0, 0x10FFFF].
fn complementRanges(alloc: std.mem.Allocator, ranges: []const CharClass.CpRange) ![]CharClass.CpRange {
    var out = std.ArrayListUnmanaged(CharClass.CpRange){};
    var next: u32 = 0;
    for (ranges) |r| {
        if (r.lo > next) try out.append(alloc, .{ .lo = @intCast(next), .hi = @intCast(r.lo - 1) });
        next = @as(u32, r.hi) + 1;
    }
    if (next <= MAX_CP) try out.append(alloc, .{ .lo = @intCast(next), .hi = MAX_CP });
    return out.toOwnedSlice(alloc);
}

/// Intersection of two sorted, disjoint range sets.
fn intersectRanges(alloc: std.mem.Allocator, a: []const CharClass.CpRange, b: []const CharClass.CpRange) ![]CharClass.CpRange {
    var out = std.ArrayListUnmanaged(CharClass.CpRange){};
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const lo = @max(a[i].lo, b[j].lo);
        const hi = @min(a[i].hi, b[j].hi);
        if (lo <= hi) try out.append(alloc, .{ .lo = lo, .hi = hi });
        if (a[i].hi < b[j].hi) i += 1 else j += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// `a` minus `b`, both sorted and disjoint.
fn subtractRanges(alloc: std.mem.Allocator, a: []const CharClass.CpRange, b: []const CharClass.CpRange) ![]CharClass.CpRange {
    var out = std.ArrayListUnmanaged(CharClass.CpRange){};
    for (a) |ra| {
        var lo: u32 = ra.lo;
        const hi: u32 = ra.hi;
        for (b) |rb| {
            if (rb.hi < lo or rb.lo > hi) continue;
            if (rb.lo > lo) try out.append(alloc, .{ .lo = @intCast(lo), .hi = @intCast(rb.lo - 1) });
            if (@as(u32, rb.hi) + 1 > lo) lo = @as(u32, rb.hi) + 1;
            if (lo > hi) break;
        }
        if (lo <= hi) try out.append(alloc, .{ .lo = @intCast(lo), .hi = @intCast(hi) });
    }
    return out.toOwnedSlice(alloc);
}

/// Properties of strings (ES2024). Returns the member sequences for the few
/// tractable properties we support; null for unknown/unsupported names.
fn propertyOfStrings(name: []const u8) ?[]const []const u21 {
    if (std.mem.eql(u8, name, "Emoji_Keycap_Sequence")) return &emoji_keycap_sequences;
    return null;
}

/// The 12 Emoji_Keycap_Sequence members: `#`, `*`, `0`-`9`, each followed by
/// U+FE0F U+20E3.
const emoji_keycap_sequences = [_][]const u21{
    &.{ '#', 0xFE0F, 0x20E3 },
    &.{ '*', 0xFE0F, 0x20E3 },
    &.{ '0', 0xFE0F, 0x20E3 },
    &.{ '1', 0xFE0F, 0x20E3 },
    &.{ '2', 0xFE0F, 0x20E3 },
    &.{ '3', 0xFE0F, 0x20E3 },
    &.{ '4', 0xFE0F, 0x20E3 },
    &.{ '5', 0xFE0F, 0x20E3 },
    &.{ '6', 0xFE0F, 0x20E3 },
    &.{ '7', 0xFE0F, 0x20E3 },
    &.{ '8', 0xFE0F, 0x20E3 },
    &.{ '9', 0xFE0F, 0x20E3 },
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
            'v' => flags.unicode_sets = true,
            'd' => flags.has_indices = true,
            else => return error.InvalidPattern,
        }
    }
    // `u` and `v` are mutually exclusive (ES §22.2.3.4 RegExpInitialize step 4).
    if (flags.unicode and flags.unicode_sets) return error.InvalidPattern;

    // Pre-scan named groups so `\k<name>` (which may forward-reference a group
    // defined later) resolves to a capture index during parsing.
    var total_caps: u32 = 0;
    const names = try scanGroupNames(alloc, pattern, &total_caps);
    // `v` mode implies full code-point semantics like `u`, so the parser runs in
    // codepoint mode; `unicode_sets` separately gates the ClassSetExpression grammar.
    var pp = PatternParser.init(pattern, alloc, flags.unicode or flags.unicode_sets);
    pp.unicode_sets = flags.unicode_sets;
    pp.group_names = names;
    pp.total_caps = total_caps;
    const root = try pp.parseAlt();
    if (!pp.eof()) return error.InvalidPattern; // unconsumed chars

    const br = hasBackref(&root);
    // Patterns requiring ES §22.2.2.5.1 step-2b processing must use the
    // backtracking engine; the Pike VM cannot correctly discard captures from
    // zero-width optional iterations or implement the forced non-empty retry.
    const ns2b = hasNullableLazy(&root) or hasNullableWithLookAhead(&root);
    // The Pike VM's `look` instruction keeps a pointer to its assertion node, so
    // the root must outlive this frame: a pattern that IS an assertion (`/(?=a)/`)
    // would otherwise bake in a pointer to this function's stack slot.
    const root_ptr = try alloc.create(RegexNode);
    root_ptr.* = root;
    const prog = if (!br and !hasModifier(&root) and !ns2b) buildProgram(alloc, root_ptr, pp.next_cap - 1) else null;

    return CompiledRegex{
        .root = root,
        .flags = flags,
        .num_captures = pp.next_cap - 1,
        .group_names = names,
        .alloc = alloc,
        .has_backref = br,
        .program = prog,
        .needs_step2b = ns2b,
    };
}

/// Whether `c` is valid in a RegExp group name (simplified: identifier chars).
fn isGroupNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$' or c >= 0x80;
}

/// Decode a group-name source slice (the bytes between `(?<` and `>`) into a
/// normalized UTF-8 identifier by expanding `\uXXXX` and `\u{…}` escape
/// sequences. Consecutive `\uHigh\uLow` surrogate pairs are folded into a
/// single astral code point so that `/(?<𝑓>a)/` and `/(?<𝑓>a)/`
/// produce the same property key on the groups object. Literal UTF-8 bytes
/// (including multi-byte sequences already in the source) are copied unchanged.
fn decodeGroupNameId(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len and src[i + 1] == 'u') {
            i += 2; // skip \u
            var cp: u21 = 0;
            if (i < src.len and src[i] == '{') {
                // \u{HEX…}
                i += 1; // skip {
                while (i < src.len and src[i] != '}') {
                    cp = cp * 16 + (hexVal(src[i]) orelse 0);
                    i += 1;
                }
                if (i < src.len) i += 1; // skip }
            } else {
                // \uXXXX — exactly 4 hex digits
                var k: usize = 0;
                while (k < 4 and i < src.len) : (k += 1) {
                    cp = cp * 16 + (hexVal(src[i]) orelse 0);
                    i += 1;
                }
                // Surrogate pair: \uD800-\uDBFF followed immediately by \uDC00-\uDFFF
                if (cp >= 0xD800 and cp <= 0xDBFF and
                    i + 5 < src.len and src[i] == '\\' and src[i + 1] == 'u' and src[i + 2] != '{')
                {
                    var low: u21 = 0;
                    var m: usize = 0;
                    while (m < 4) : (m += 1) {
                        low = low * 16 + (hexVal(src[i + 2 + m]) orelse 0);
                    }
                    if (low >= 0xDC00 and low <= 0xDFFF) {
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00);
                        i += 6; // skip \uLow (backslash+u+4digits)
                    }
                }
            }
            var buf: [4]u8 = undefined;
            const n = encodeUtf8Cp(@intCast(cp), &buf);
            try out.appendSlice(alloc, buf[0..n]);
        } else {
            try out.append(alloc, src[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Validate a decoded group name against the RegExpIdentifierName grammar
/// (§22.2.1): the first code point must be an IdentifierStart (ID_Start, `$` or
/// `_`), and every subsequent one an IdentifierPart (ID_Continue, `$`, `_`, ZWNJ
/// or ZWJ). Names failing this are early SyntaxErrors — e.g. an emoji group
/// name. Astral code points are folded from any WTF-8 surrogate pair first.
fn validGroupName(name: []const u8) bool {
    if (name.len == 0) return false;
    const id_start = uprop.lookup("ID_Start") orelse return true;
    const id_cont = uprop.lookup("ID_Continue") orelse return true;
    var i: usize = 0;
    var first = true;
    while (i < name.len) {
        const dc = decodeCpAt(name, i);
        if (dc.len == 0) return false;
        i += dc.len;
        const cp = dc.cp;
        if (first) {
            first = false;
            if (cp == '$' or cp == '_') continue;
            if (!cpInTable(id_start, cp)) return false;
        } else {
            if (cp == '$' or cp == '_' or cp == 0x200C or cp == 0x200D) continue;
            if (!cpInTable(id_cont, cp)) return false;
        }
    }
    return true;
}

/// Pre-scan a pattern for `(?<name>...)` groups, assigning each the 1-based
/// capture index it will receive during parsing. Skips char classes, escapes,
/// and non-capturing / assertion groups so indices match the parser exactly.
fn scanGroupNames(alloc: std.mem.Allocator, src: []const u8, total_caps: *u32) ![]const NameIdx {
    var names = std.ArrayList(NameIdx){};
    // Position of each named group within the Disjunction tree, as the chain of
    // (disjunction id, alternative index) pairs from the root. Two same-named
    // groups are legal exactly when some shared disjunction puts them in
    // *different* alternatives (ES2025 duplicate named capture groups).
    const PathEntry = struct { disj: u32, alt: u32 };
    var stack = std.ArrayList(PathEntry){};
    defer stack.deinit(alloc);
    var paths = std.ArrayList([]const PathEntry){};
    defer paths.deinit(alloc);
    var next_disj: u32 = 1;
    try stack.append(alloc, .{ .disj = 0, .alt = 0 });

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
        if (c == '|') {
            if (stack.items.len > 0) stack.items[stack.items.len - 1].alt += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            if (stack.items.len > 1) _ = stack.pop();
            i += 1;
            continue;
        }
        if (c == '(') {
            // Every group — capturing or not — introduces a nested Disjunction.
            const opened = PathEntry{ .disj = next_disj, .alt = 0 };
            next_disj += 1;
            if (i + 1 < src.len and src[i + 1] == '?') {
                // (?<name>...) is a named capture; (?<= / (?<! / (?: / (?= / (?!
                // are assertions or non-capturing and take no index.
                if (i + 2 < src.len and src[i + 2] == '<' and
                    (i + 3 >= src.len or (src[i + 3] != '=' and src[i + 3] != '!')))
                {
                    cap += 1;
                    var j = i + 3;
                    while (j < src.len and src[j] != '>') j += 1;
                    const raw_name = src[i + 3 .. j];
                    const decoded_name = try decodeGroupNameId(alloc, raw_name);
                    if (!validGroupName(decoded_name)) return error.InvalidPattern;
                    try names.append(alloc, .{ .name = decoded_name, .idx = cap });
                    try paths.append(alloc, try alloc.dupe(PathEntry, stack.items));
                    try stack.append(alloc, opened);
                    i = if (j < src.len) j + 1 else j;
                    continue;
                }
                try stack.append(alloc, opened);
                i += 1;
                continue;
            }
            cap += 1;
            try stack.append(alloc, opened);
        }
        i += 1;
    }
    total_caps.* = cap;

    // Early error: same name, and no enclosing disjunction separates them.
    for (names.items, 0..) |a, ai| {
        for (names.items[ai + 1 ..], ai + 1..) |b, bi| {
            if (!std.mem.eql(u8, a.name, b.name)) continue;
            const pa = paths.items[ai];
            const pb = paths.items[bi];
            var separated = false;
            var k: usize = 0;
            while (k < pa.len and k < pb.len) : (k += 1) {
                if (pa[k].disj != pb[k].disj) break;
                if (pa[k].alt != pb[k].alt) {
                    separated = true;
                    break;
                }
            }
            if (!separated) return error.InvalidPattern;
        }
    }
    return names.items;
}

// ============================================================= Matcher ========

pub const CaptureSpan = struct {
    start: usize,
    end: usize,

    /// True when the group did not participate in the match. The sentinel must
    /// not be `{0, 0}`: that is a *real* empty capture at the start of the
    /// subject (`/(a*)b/.exec("b")` captures `""`, not `undefined`).
    pub fn unset(self: CaptureSpan) bool {
        return self.start == std.math.maxInt(usize);
    }
};
pub const INVALID_CAP = CaptureSpan{ .start = std.math.maxInt(usize), .end = std.math.maxInt(usize) };

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
    // Use the Pike VM when a compiled program is available (non-backtracking).
    if (regex.program) |prog| {
        // Lazily initialize the PikeVM state (reused across matchAt calls).
        const cr = @constCast(regex);
        if (cr.pike_vm == null) {
            cr.pike_vm = PikeVM.init(regex.alloc, prog) catch return null;
        }
        return cr.pike_vm.?.runAnchored(input, start, &regex.flags);
    }
    var caps = [_]CaptureSpan{INVALID_CAP} ** MAX_CAPTURES;
    match_step2b = regex.needs_step2b;
    const end_pos = matchNode(&regex.root, input, start, &caps, &regex.flags) orelse {
        match_step2b = false;
        return null;
    };
    match_step2b = false;
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
        // Advance to the next code-unit boundary so a match never starts in the
        // middle of a multi-byte sequence. Under /u that is a full code point
        // (folding a WTF-8 surrogate pair); in non-/u it is one UTF-16 code unit
        // — a BMP char spans 1–3 WTF-8 bytes, a WTF-8-encoded surrogate is 3
        // bytes, and a raw 4-byte astral (two units the byte model can't split)
        // advances a single byte, mirroring consumeDot.
        if (regex.flags.cpMode()) {
            i += @as(usize, cpByteLenAt(input, i));
        } else {
            const w = utf8ByteLenAt(input, i);
            i += if (w >= 1 and w <= 3) @as(usize, w) else 1;
        }
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
/// Canonicalize under `/u` (§22.2.2.9.3): the *simple* case folding from
/// CaseFolding.txt, so `/ſ/iu` matches "s" and `/K/iu` matches "k".
fn foldCaseCp(cp: u21) u21 {
    // ASCII fast path — the table would give the same answer.
    if (cp < 0x80) {
        if (cp >= 'A' and cp <= 'Z') return cp + 32;
        return cp;
    }
    return casefold.simpleFold(cp);
}
// --- Shared single-position primitives (used by both matchNode and the Pike VM)
// so the two execution engines agree on every character-level semantic.

/// Try to consume a single literal codepoint `ch` at `pos`. Returns the new
/// position on success, or null. Honors `/u` (codepoint vs byte) and `/i`.
fn consumeLiteral(input: []const u8, pos: usize, ch: u21, flags: *const CompiledRegex.Flags) ?usize {
    if (pos >= input.len) return null;
    if (flags.cpMode()) {
        const dc = decodeCpAt(input, pos);
        const input_cp = dc.cp;
        if (flags.ignore_case) {
            if (foldCaseCp(input_cp) != foldCaseCp(ch)) return null;
        } else {
            if (input_cp != ch) return null;
        }
        return pos + dc.len;
    } else {
        // Byte-based (non-/u): a multi-byte code unit in the pattern is stored as
        // one byte-literal per WTF-8 byte, matched byte-for-byte here. (Escapes
        // that denote a value ≥ 0x80 are expanded to their WTF-8 bytes at parse
        // time, so this path only ever sees single bytes.)
        if (ch > 255) return null;
        const c = input[pos];
        const cb: u8 = @intCast(ch);
        if (flags.ignore_case) {
            if (foldCase(c) != foldCase(cb)) return null;
        } else {
            if (c != cb) return null;
        }
        return pos + 1;
    }
}

/// Try to consume one character matching char class `cc` at `pos`.
fn consumeClass(input: []const u8, pos: usize, cc: *const CharClass, flags: *const CompiledRegex.Flags) ?usize {
    if (pos >= input.len) return null;
    if (flags.cpMode()) {
        const dc = decodeCpAt(input, pos);
        const cp = dc.cp;
        var raw = cc.containsCp(cp);
        if (flags.ignore_case and !raw) {
            // Canonicalize applies to the class members too, and the class stores
            // them uncanonicalized — so try the subject's folding and every code
            // point sharing it (`/[ſ]/iu` must match "s", and vice versa). The
            // negation is applied once, after all variants have been tried.
            const f = foldCaseCp(cp);
            if (f != cp) raw = cc.containsCp(f);
            if (!raw) for (casefold.unfold(f)) |u| {
                if (u.cp != cp and cc.containsCp(u.cp)) {
                    raw = true;
                    break;
                }
            };
        }
        if (!(if (cc.negate) !raw else raw)) return null;
        return pos + dc.len;
    } else {
        // Non-/u mode iterates UTF-16 code units, not raw bytes: a BMP code point
        // is one unit spanning 1–3 WTF-8 bytes (mirroring consumeDot). Class
        // members are stored as code points (addCpRange puts <=255 in the bitmap,
        // >255 in extra_ranges), so membership is tested against the decoded code
        // point — letting `\s`/`\S` and Latin-1 members match multi-byte input.
        const dc = decodeUtf8At(input, pos);
        const len: usize = if (dc.len >= 1 and dc.len <= 3) dc.len else 1;
        const cp: u21 = if (dc.len >= 1 and dc.len <= 3) dc.cp else input[pos];
        var hit = cc.containsCp(cp);
        if (flags.ignore_case and !hit and cp < 0x80) {
            const c: u8 = @intCast(cp);
            const alt = if (c >= 'a' and c <= 'z') c - 32 else if (c >= 'A' and c <= 'Z') c + 32 else c;
            hit = cc.bitmap[alt];
        }
        const result = if (cc.negate) !hit else hit;
        if (!result) return null;
        return pos + len;
    }
}

/// Try to consume one character for `.` (dot) at `pos`.
fn consumeDot(input: []const u8, pos: usize, flags: *const CompiledRegex.Flags) ?usize {
    if (pos >= input.len) return null;
    if (flags.cpMode()) {
        const dc = decodeCpAt(input, pos);
        if (!flags.dotall and isUnicodeLineTerminator(dc.cp)) return null;
        return pos + dc.len;
    } else {
        // Non-/u mode iterates UTF-16 code units, not raw bytes: a BMP code point
        // is one unit spanning 1–3 WTF-8 bytes, so `.` must consume the whole
        // sequence (else `/^.$/` fails on "π"). A WTF-8-encoded lone surrogate
        // (astral escape / fromCodePoint) is also 3 bytes = one code unit. A
        // 4-byte UTF-8 astral is TWO code units, which the byte model cannot
        // split, so advance a single byte there (one unit's worth).
        const dc = decodeUtf8At(input, pos);
        if (!flags.dotall and isUnicodeLineTerminator(dc.cp)) return null;
        const len: usize = if (dc.len >= 1 and dc.len <= 3) dc.len else 1;
        return pos + len;
    }
}

/// Zero-width `^` assertion test.
fn testBol(input: []const u8, pos: usize, flags: *const CompiledRegex.Flags) bool {
    if (pos == 0) return true;
    if (flags.multiline and pos > 0 and isLineTerminator(input[pos - 1])) return true;
    return false;
}

/// Zero-width `$` assertion test.
fn testEol(input: []const u8, pos: usize, flags: *const CompiledRegex.Flags) bool {
    if (pos == input.len) return true;
    if (flags.multiline and pos < input.len and isLineTerminator(input[pos])) return true;
    return false;
}

/// True at a word boundary (\b); its negation is \B.
fn atWordBoundary(input: []const u8, pos: usize) bool {
    const before = if (pos > 0) isWordChar(input[pos - 1]) else false;
    const after = if (pos < input.len) isWordChar(input[pos]) else false;
    return before != after;
}

/// Return the slice of alternatives if `node` is an `alt` (possibly wrapped in
/// a non-capturing group or a capturing group). Used in the lookbehind loop to
/// try each alternative independently when the standard matchNode ends at the
/// wrong position — preventing a high-priority arm (e.g. `^`) from shadowing a
/// lower-priority arm (e.g. `[ab]`) that would have ended at the target position.
fn lbAltArms(node: *const RegexNode) ?[]const RegexNode {
    return switch (node.*) {
        .alt => |arms| arms,
        .group => |g| lbAltArms(g.inner),
        .non_capturing => |inner| lbAltArms(inner),
        else => null,
    };
}

/// Try to match `inner` starting at `j` such that the match ends exactly at
/// `target`. On success, writes the resulting captures to `out_caps` and returns
/// true. Extends matchNode by also trying each arm of a top-level alt node
/// individually (handles priority-shadowing in lookbehind alternations).
fn lbMatchAt(
    inner: *const RegexNode,
    input: []const u8,
    j: usize,
    target: usize,
    out_caps: *[MAX_CAPTURES]CaptureSpan,
    base_caps: *const [MAX_CAPTURES]CaptureSpan,
    flags: *const CompiledRegex.Flags,
) bool {
    var tmp = base_caps.*;
    if (matchNode(inner, input, j, &tmp, flags)) |end| {
        if (end == target) { out_caps.* = tmp; return true; }
    }
    // The standard match ended at the wrong position. Try each arm of a top-level
    // alt independently — a higher-priority arm may have succeeded at the wrong end.
    const arms = lbAltArms(inner) orelse return false;
    for (arms) |*arm| {
        tmp = base_caps.*;
        if (matchNode(arm, input, j, &tmp, flags)) |end| {
            if (end == target) { out_caps.* = tmp; return true; }
        }
    }
    return false;
}

/// Set while a lookbehind body is being matched: the body may not consume input
/// beyond the position the lookbehind sits at. The assertion matcher below does
/// not backtrack, so without this bound a greedy quantifier in `(?<=^\w+)def`
/// runs to end-of-input and the "must finish exactly here" test never holds.
/// Cleared while a nested lookahead runs -- that one legitimately reads ahead.
var lookbehind_limit: ?usize = null;

/// Set before calling matchNode for patterns with `needs_step2b = true`.
/// When true, matchQuant applies ES §22.2.2.5.1 step 2b: optional (min=0)
/// iterations that are zero-width discard their captures and try a forced
/// non-empty retry under `g_force_greedy`.
var match_step2b: bool = false;

/// Set transiently inside matchQuant's step-2b forced retry so that lazy
/// quantifiers inside the body act greedily, enabling a non-empty match.
var g_force_greedy: bool = false;

inline fn withinLookbehind(end: ?usize) ?usize {
    const e = end orelse return null;
    if (lookbehind_limit) |lim| if (e > lim) return null;
    return e;
}

fn matchNode(
    node: *const RegexNode,
    input: []const u8,
    pos: usize,
    caps: *[MAX_CAPTURES]CaptureSpan,
    flags: *const CompiledRegex.Flags,
) ?usize {
    switch (node.*) {
        .literal => |ch| return withinLookbehind(consumeLiteral(input, pos, ch, flags)),
        .char_class => |cc| return withinLookbehind(consumeClass(input, pos, cc, flags)),
        .dot => return withinLookbehind(consumeDot(input, pos, flags)),
        .anchor_start => return if (testBol(input, pos, flags)) pos else null,
        .anchor_end => return if (testEol(input, pos, flags)) pos else null,
        .word_boundary => return if (atWordBoundary(input, pos)) pos else null,
        .non_word_boundary => return if (!atWordBoundary(input, pos)) pos else null,
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
        .modifier => |m| {
            // Rebind i/m/s for the enclosed disjunction only. The copy lives on
            // this frame, so the original flags are restored on return.
            var scoped = flags.*;
            if (m.add.ignore_case) scoped.ignore_case = true;
            if (m.add.multiline) scoped.multiline = true;
            if (m.add.dotall) scoped.dotall = true;
            if (m.remove.ignore_case) scoped.ignore_case = false;
            if (m.remove.multiline) scoped.multiline = false;
            if (m.remove.dotall) scoped.dotall = false;
            return matchNode(m.inner, input, pos, caps, &scoped);
        },
        .quant => |q| {
            return matchQuant(q.inner, q.min, q.max, q.lazy, input, pos, caps, flags);
        },
        .look_ahead => |la| {
            const saved_caps = caps.*;
            // A lookahead nested inside a lookbehind reads *forward* past the
            // lookbehind's position, so the consume bound does not apply to it.
            const saved_limit = lookbehind_limit;
            lookbehind_limit = null;
            const matched = matchNode(la.inner, input, pos, caps, flags) != null;
            lookbehind_limit = saved_limit;
            // §22.2.2.5: a *positive* assertion's captures survive into the rest
            // of the pattern (`/(?=(a+))/.exec("baa")` reports "aa"); a negative
            // one's are discarded, as are those of a failed positive one.
            if (la.negative or !matched) caps.* = saved_caps;
            if (la.negative) return if (!matched) pos else null;
            return if (matched) pos else null;
        },
        .look_behind => |lb| {
            var matched_lb = false;
            const saved_limit = lookbehind_limit;
            lookbehind_limit = pos;
            defer lookbehind_limit = saved_limit;
            // Phase 1: scan j from 0 upward (leftmost = greedy/longest match).
            // Standard matchNode respects alternation priority correctly.
            {
                var j: usize = 0;
                while (j <= pos) : (j += 1) {
                    var tmp_caps = caps.*;
                    if (matchNode(lb.inner, input, j, &tmp_caps, flags)) |end| {
                        if (end == pos) {
                            matched_lb = true;
                            // A positive lookbehind contributes its captures.
                            if (!lb.negative) caps.* = tmp_caps;
                            break;
                        }
                    }
                }
            }
            // Phase 2: if still unmatched and inner is a top-level alternation,
            // try each arm independently across all j values. This handles
            // priority-shadowing where a higher-priority arm (e.g. `^`, always
            // zero-width) succeeds at j but ends at the wrong position, masking a
            // lower-priority arm (e.g. `[ab]`) that ends exactly at pos.
            if (!matched_lb) {
                if (lbAltArms(lb.inner)) |arms| {
                    phase2: for (arms) |*arm| {
                        var j: usize = 0;
                        while (j <= pos) : (j += 1) {
                            var tmp_caps = caps.*;
                            if (matchNode(arm, input, j, &tmp_caps, flags)) |end| {
                                if (end == pos) {
                                    matched_lb = true;
                                    if (!lb.negative) caps.* = tmp_caps;
                                    break :phase2;
                                }
                            }
                        }
                    }
                }
            }
            if (lb.negative) {
                return if (!matched_lb) pos else null;
            } else {
                return if (matched_lb) pos else null;
            }
        },
        .back_ref_multi => |idxs| {
            var chosen: ?CaptureSpan = null;
            for (idxs) |i| {
                if (i >= MAX_CAPTURES) continue;
                if (!caps[i].unset()) {
                    chosen = caps[i];
                    break;
                }
            }
            const cap = chosen orelse return pos;
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
        .back_ref => |idx| {
            if (idx >= MAX_CAPTURES) return pos;
            const cap = caps[idx];
            if (cap.unset()) {
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

fn clearCaptures(caps: *[MAX_CAPTURES]CaptureSpan, range: ?CaptureRange) void {
    const r = range orelse return;
    var i: u32 = r.lo;
    while (i <= r.hi and i < MAX_CAPTURES) : (i += 1) caps[i] = INVALID_CAP;
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
    // RepeatMatcher resets the quantified atom's own captures before every
    // repetition, so an earlier iteration's groups cannot leak into a later one.
    const clear_range = captureRange(inner);
    // Under g_force_greedy (step-2b retry), lazy quantifiers act greedy so that
    // the retry can produce a non-empty match.
    if (lazy and !g_force_greedy) {
        var count: u32 = 0;
        var pos = start;

        while (count < min) {
            const saved_caps = caps.*;
            clearCaptures(caps, clear_range);
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
            clearCaptures(caps, clear_range);
            const next = matchNode(inner, input, pos, caps, flags) orelse {
                caps.* = saved_caps;
                break;
            };
            count += 1;
            positions[count] = next;
            if (next == pos) {
                if (count >= min and match_step2b) {
                    // ES §22.2.2.5.1 step 2b: optional iteration is zero-width.
                    // Discard its captures and try a forced non-empty retry with
                    // lazy quants acting greedily.
                    caps.* = saved_caps;
                    clearCaptures(caps, clear_range);
                    const old_force = g_force_greedy;
                    g_force_greedy = true;
                    const forced = matchNode(inner, input, pos, caps, flags);
                    g_force_greedy = old_force;
                    if (forced != null and forced.? > pos) {
                        positions[count] = forced.?;
                        pos = forced.?;
                        if (count >= 1024 - 1) break;
                        continue;
                    }
                    caps.* = saved_caps; // forced also zero-width or failed
                }
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

// ==================================================== Pike VM (non-backtracking)
//
// Wave 23: a Thompson-NFA / Pike-VM execution engine. The regex AST is compiled
// once to a flat instruction array; matching is a BFS over NFA states with an
// epsilon-closure at each input position. This guarantees O(program × input)
// time per anchored match — no exponential blowup from overlapping alternations.
//
// Submatch (capture) priority is encoded by split ordering (greedy = body-first,
// lazy = exit-first) plus first-writer-wins deduplication, reproducing JS
// leftmost-first semantics. Lookarounds are zero-width assertions evaluated by
// the recursive backtracking matcher (matchNode) — their inner captures are not
// propagated, matching the pre-existing engine behaviour. Backreferences are
// NP-hard, so any pattern containing one keeps the backtracking engine entirely.

/// A single Pike-VM instruction. Consuming ops (char/class/any_char) advance the
/// input; the rest are zero-width (epsilon) and are resolved during closure.
const Inst = union(enum) {
    char: u21, // consume one codepoint equal to this literal
    class: *const CharClass, // consume one char in this class
    any_char, // consume one char for `.`
    match, // accept
    jmp: usize, // epsilon: continue at target
    split: struct { a: usize, b: usize }, // epsilon: fork; `a` is higher priority
    save: usize, // epsilon: record current pos into capture slot
    assert_bol, // ^
    assert_eol, // $
    assert_wb, // \b
    assert_nwb, // \B
    look: *const RegexNode, // (?=)/(?!)/(?<=)/(?<!) — a look_ahead/look_behind node
    /// Reset capture groups `lo..hi` (inclusive, 1-based) to unset. Emitted at
    /// the head of every repetition of a quantified atom — RepeatMatcher clears
    /// the atom's own captures before each iteration (ES §22.2.2.5.1).
    clear: CaptureRange,
};

/// An inclusive 1-based range of capture-group indices.
const CaptureRange = struct { lo: u32, hi: u32 };

/// The span of capture-group indices contained in `node`, or null when it has
/// none. Groups are numbered by opening paren, so any subtree's groups form a
/// contiguous range.
fn captureRange(node: *const RegexNode) ?CaptureRange {
    return switch (node.*) {
        .group => |g| blk: {
            const inner = captureRange(g.inner);
            break :blk .{ .lo = g.idx, .hi = if (inner) |r| @max(g.idx, r.hi) else g.idx };
        },
        .seq, .alt => |kids| blk: {
            var acc: ?CaptureRange = null;
            for (kids) |*k| acc = mergeRange(acc, captureRange(k));
            break :blk acc;
        },
        .non_capturing => |inner| captureRange(inner),
        .quant => |q| captureRange(q.inner),
        .look_ahead => |la| captureRange(la.inner),
        .look_behind => |lb| captureRange(lb.inner),
        .modifier => |m| captureRange(m.inner),
        else => null,
    };
}

fn mergeRange(a: ?CaptureRange, b: ?CaptureRange) ?CaptureRange {
    const x = a orelse return b;
    const y = b orelse return a;
    return .{ .lo = @min(x.lo, y.lo), .hi = @max(x.hi, y.hi) };
}

/// A compiled Pike-VM program: a flat instruction array plus the number of
/// capture slots (2 per group, +2 for the whole match).
pub const Program = struct {
    insts: []const Inst,
    num_slots: usize,
};

/// Upper bound on emitted instructions. Patterns whose bounded quantifiers would
/// expand past this (e.g. `a{500000}`) fall back to the backtracking engine
/// instead of blowing up compilation memory / addThread recursion depth.
const MAX_PROG_LEN: usize = 1 << 15;

/// Incremental builder for a Program's instruction stream, with split/jmp target
/// back-patching and a hard size cap.
const ProgBuilder = struct {
    insts: std.ArrayListUnmanaged(Inst) = .{},
    alloc: std.mem.Allocator,
    failed: bool = false,

    fn here(self: *const ProgBuilder) usize {
        return self.insts.items.len;
    }

    fn emit(self: *ProgBuilder, inst: Inst) usize {
        if (self.failed or self.insts.items.len >= MAX_PROG_LEN) {
            self.failed = true;
            return 0;
        }
        const idx = self.insts.items.len;
        self.insts.append(self.alloc, inst) catch {
            self.failed = true;
            return 0;
        };
        return idx;
    }

    fn patch(self: *ProgBuilder, at: usize, inst: Inst) void {
        if (self.failed or at >= self.insts.items.len) return;
        self.insts.items[at] = inst;
    }

    /// Emit the head of one repetition: the atom's own captures are reset first.
    fn compileRepBody(self: *ProgBuilder, inner: *const RegexNode, range: ?CaptureRange) void {
        if (range) |r| _ = self.emit(.{ .clear = r });
        self.compileNode(inner);
    }

    /// Emit `inner`, then a greedy/lazy `?` (optional) around it.
    fn compileQuest(self: *ProgBuilder, inner: *const RegexNode, lazy: bool, range: ?CaptureRange) void {
        const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
        const body = self.here();
        self.compileRepBody(inner, range);
        const exit = self.here();
        if (lazy) {
            self.patch(split_at, .{ .split = .{ .a = exit, .b = body } });
        } else {
            self.patch(split_at, .{ .split = .{ .a = body, .b = exit } });
        }
    }

    /// Emit a greedy/lazy `*` (Kleene star) around `inner`.
    fn compileStar(self: *ProgBuilder, inner: *const RegexNode, lazy: bool, range: ?CaptureRange) void {
        const l1 = self.here();
        const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
        const body = self.here();
        self.compileRepBody(inner, range);
        _ = self.emit(.{ .jmp = l1 });
        const exit = self.here();
        if (lazy) {
            self.patch(split_at, .{ .split = .{ .a = exit, .b = body } });
        } else {
            self.patch(split_at, .{ .split = .{ .a = body, .b = exit } });
        }
    }

    fn compileQuant(self: *ProgBuilder, inner: *const RegexNode, min: u32, max: u32, lazy: bool) void {
        // Reject expansions that would exceed the size cap before emitting them.
        const inf = std.math.maxInt(u32);
        if (min > MAX_PROG_LEN or (max != inf and (max - min) > MAX_PROG_LEN)) {
            self.failed = true;
            return;
        }
        const range = captureRange(inner);
        var i: u32 = 0;
        while (i < min) : (i += 1) {
            self.compileRepBody(inner, range);
            if (self.failed) return;
        }
        if (max == inf) {
            // `{min,}` — the mandatory copies are done; a star covers the rest.
            self.compileStar(inner, lazy, range);
        } else {
            // `{min,max}` — (max-min) greedy/lazy optional copies. Contiguous
            // matching means flat optionals need no nesting to avoid gaps.
            var k: u32 = min;
            while (k < max) : (k += 1) {
                self.compileQuest(inner, lazy, range);
                if (self.failed) return;
            }
        }
    }

    fn compileAlt(self: *ProgBuilder, arms: []const RegexNode) void {
        // e0 | e1 | ... : each non-last arm is `split armStart, next; arm; jmp END`.
        var jmp_ends = std.ArrayListUnmanaged(usize){};
        defer jmp_ends.deinit(self.alloc);
        for (arms, 0..) |*arm, idx| {
            if (idx + 1 < arms.len) {
                const split_at = self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const arm_start = self.here();
                self.compileNode(arm);
                const jmp_at = self.emit(.{ .jmp = 0 });
                jmp_ends.append(self.alloc, jmp_at) catch {
                    self.failed = true;
                    return;
                };
                const next = self.here();
                self.patch(split_at, .{ .split = .{ .a = arm_start, .b = next } });
            } else {
                self.compileNode(arm);
            }
            if (self.failed) return;
        }
        const end = self.here();
        for (jmp_ends.items) |at| self.patch(at, .{ .jmp = end });
    }

    fn compileNode(self: *ProgBuilder, node: *const RegexNode) void {
        if (self.failed) return;
        switch (node.*) {
            .literal => |ch| _ = self.emit(.{ .char = ch }),
            .char_class => |cc| _ = self.emit(.{ .class = cc }),
            .dot => _ = self.emit(.any_char),
            .anchor_start => _ = self.emit(.assert_bol),
            .anchor_end => _ = self.emit(.assert_eol),
            .word_boundary => _ = self.emit(.assert_wb),
            .non_word_boundary => _ = self.emit(.assert_nwb),
            .seq => |nodes| for (nodes) |*child| self.compileNode(child),
            .alt => |arms| self.compileAlt(arms),
            .group => |g| {
                _ = self.emit(.{ .save = 2 * @as(usize, g.idx) });
                self.compileNode(g.inner);
                _ = self.emit(.{ .save = 2 * @as(usize, g.idx) + 1 });
            },
            .non_capturing => |inner| self.compileNode(inner),
            .quant => |q| self.compileQuant(q.inner, q.min, q.max, q.lazy),
            .look_ahead, .look_behind => _ = self.emit(.{ .look = node }),
            // Backreference patterns never reach the Pike VM (has_backref gate).
            .back_ref, .back_ref_multi => self.failed = true,
            // Flag decisions are baked into the emitted instructions, so a
            // mid-pattern rebind cannot be expressed; fall back to the
            // backtracker (compileRegex also gates on hasModifier).
            .modifier => self.failed = true,
        }
    }
};

/// True if the pattern contains any backreference (anywhere, including inside a
/// lookaround). Such patterns are NP-hard and use the backtracking engine.
fn hasBackref(node: *const RegexNode) bool {
    return switch (node.*) {
        .back_ref, .back_ref_multi => true,
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasBackref(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasBackref(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasBackref(g.inner),
        .non_capturing => |inner| hasBackref(inner),
        .quant => |q| hasBackref(q.inner),
        .look_ahead => |la| hasBackref(la.inner),
        .look_behind => |lb| hasBackref(lb.inner),
        .modifier => |m| hasBackref(m.inner),
        else => false,
    };
}

/// Whether the pattern contains a `(?ims-ims:...)` modifier group. The Pike VM
/// compiles flag decisions into its instructions, so it cannot express a
/// mid-pattern flag rebind; such patterns stay on the backtracking engine.
fn hasModifier(node: *const RegexNode) bool {
    return switch (node.*) {
        .modifier => true,
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasModifier(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasModifier(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasModifier(g.inner),
        .non_capturing => |inner| hasModifier(inner),
        .quant => |q| hasModifier(q.inner),
        .look_ahead => |la| hasModifier(la.inner),
        .look_behind => |lb| hasModifier(lb.inner),
        else => false,
    };
}

/// True if `node` contains a look_ahead (positive or negative).
fn hasLookAhead(node: *const RegexNode) bool {
    return switch (node.*) {
        .look_ahead => true,
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasLookAhead(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasLookAhead(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasLookAhead(g.inner),
        .non_capturing => |inner| hasLookAhead(inner),
        .quant => |q| hasLookAhead(q.inner),
        .look_behind => |lb| hasLookAhead(lb.inner),
        .modifier => |m| hasLookAhead(m.inner),
        else => false,
    };
}

/// True if there is a nullable quantifier (min=0) whose body contains a
/// look_ahead. The Pike VM cannot correctly discard zero-width captures from
/// such an optional body (step 2b), so these patterns use the backtracking engine.
fn hasNullableWithLookAhead(node: *const RegexNode) bool {
    return switch (node.*) {
        .quant => |q| (q.min == 0 and hasLookAhead(q.inner)) or hasNullableWithLookAhead(q.inner),
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasNullableWithLookAhead(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasNullableWithLookAhead(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasNullableWithLookAhead(g.inner),
        .non_capturing => |inner| hasNullableWithLookAhead(inner),
        .look_ahead => |la| hasNullableWithLookAhead(la.inner),
        .look_behind => |lb| hasNullableWithLookAhead(lb.inner),
        .modifier => |m| hasNullableWithLookAhead(m.inner),
        else => false,
    };
}

/// True if `node` contains a lazy quantifier anywhere in its subtree.
fn hasLazyQuant(node: *const RegexNode) bool {
    return switch (node.*) {
        .quant => |q| q.lazy or hasLazyQuant(q.inner),
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasLazyQuant(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasLazyQuant(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasLazyQuant(g.inner),
        .non_capturing => |inner| hasLazyQuant(inner),
        .look_ahead => |la| hasLazyQuant(la.inner),
        .look_behind => |lb| hasLazyQuant(lb.inner),
        .modifier => |m| hasLazyQuant(m.inner),
        else => false,
    };
}

/// True if there is a quantifier with optional iterations (min < max) whose
/// body contains a lazy quantifier. Such patterns need the backtracking engine
/// with step-2b mode: a zero-width optional iteration forces a non-empty retry
/// with the lazy quants temporarily acting greedy.
fn hasNullableLazy(node: *const RegexNode) bool {
    return switch (node.*) {
        .quant => |q| (q.min < q.max and hasLazyQuant(q.inner)) or hasNullableLazy(q.inner),
        .seq => |nodes| blk: {
            for (nodes) |*c| if (hasNullableLazy(c)) break :blk true;
            break :blk false;
        },
        .alt => |arms| blk: {
            for (arms) |*c| if (hasNullableLazy(c)) break :blk true;
            break :blk false;
        },
        .group => |g| hasNullableLazy(g.inner),
        .non_capturing => |inner| hasNullableLazy(inner),
        .look_ahead => |la| hasNullableLazy(la.inner),
        .look_behind => |lb| hasNullableLazy(lb.inner),
        .modifier => |m| hasNullableLazy(m.inner),
        else => false,
    };
}

/// Compile a parsed AST root into a Pike-VM Program. Returns null if the pattern
/// is not Pike-eligible (size cap exceeded or a backref slipped through), in
/// which case the caller keeps the backtracking engine.
fn buildProgram(alloc: std.mem.Allocator, root: *const RegexNode, num_captures: u32) ?*Program {
    var b = ProgBuilder{ .alloc = alloc };
    _ = b.emit(.{ .save = 0 }); // whole-match start
    b.compileNode(root);
    _ = b.emit(.{ .save = 1 }); // whole-match end
    _ = b.emit(.match);
    if (b.failed) {
        b.insts.deinit(alloc);
        return null;
    }
    const prog = alloc.create(Program) catch {
        b.insts.deinit(alloc);
        return null;
    };
    const ns = @min(2 * (@as(usize, num_captures) + 1), 2 * MAX_CAPTURES);
    prog.* = .{
        .insts = b.insts.toOwnedSlice(alloc) catch {
            return null;
        },
        .num_slots = ns,
    };
    return prog;
}

/// Reusable Pike-VM execution state. Buffers are sized once per program and
/// reused across every anchored run of a whole-string scan.
const PikeVM = struct {
    prog: *const Program,
    ns: usize, // slots per thread
    // Two thread lists (current / next), each a flat SoA of (pc, caps).
    a_pcs: []usize,
    a_caps: []isize,
    a_pos: []usize, // per-thread consume position (for variable-width consumes)
    a_n: usize = 0,
    b_pcs: []usize,
    b_caps: []isize,
    b_pos: []usize,
    b_n: usize = 0,
    seen: []u64, // per-pc generation stamp for closure dedup
    gen: u64 = 0,
    work: []isize, // scratch capture vector during closure
    matched: []isize, // captures of the best match so far
    matched_valid: bool = false,

    fn init(alloc: std.mem.Allocator, prog: *const Program) !PikeVM {
        const plen = prog.insts.len;
        const ns = prog.num_slots;
        // Consuming ops can advance a variable number of bytes (a multi-byte
        // class/dot, up to 6 for a WTF-8 surrogate pair), so threads waiting at
        // several byte offsets ahead of `sp` coexist in one list. Each distinct
        // in-flight offset holds up to `plen` de-duplicated threads, so size the
        // lists for the widest window rather than a single position's `plen`.
        const cap = plen * 8;
        return .{
            .prog = prog,
            .ns = ns,
            .a_pcs = try alloc.alloc(usize, cap),
            .a_caps = try alloc.alloc(isize, cap * ns),
            .a_pos = try alloc.alloc(usize, cap),
            .b_pcs = try alloc.alloc(usize, cap),
            .b_caps = try alloc.alloc(isize, cap * ns),
            .b_pos = try alloc.alloc(usize, cap),
            .seen = try alloc.alloc(u64, plen),
            .work = try alloc.alloc(isize, ns),
            .matched = try alloc.alloc(isize, ns),
        };
    }

    /// Add a thread (and its epsilon closure) to a thread list. `list_pcs`/
    /// `list_caps`/`n_ptr` select current or next; `caps` is the shared working
    /// capture vector (mutated then restored across save/split recursion).
    fn addThread(
        self: *PikeVM,
        list_pcs: []usize,
        list_caps: []isize,
        list_pos: []usize,
        n_ptr: *usize,
        pc: usize,
        sp: usize,
        caps: []isize,
        input: []const u8,
        flags: *const CompiledRegex.Flags,
    ) void {
        if (self.seen[pc] == self.gen) return;
        self.seen[pc] = self.gen;
        switch (self.prog.insts[pc]) {
            .jmp => |t| self.addThread(list_pcs, list_caps, list_pos, n_ptr, t, sp, caps, input, flags),
            .split => |s| {
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, s.a, sp, caps, input, flags);
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, s.b, sp, caps, input, flags);
            },
            .save => |slot| {
                if (slot < self.ns) {
                    const old = caps[slot];
                    caps[slot] = @intCast(sp);
                    self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags);
                    caps[slot] = old;
                } else {
                    self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags);
                }
            },
            .clear => |r| {
                const lo = 2 * @as(usize, r.lo);
                const hi = @min(2 * @as(usize, r.hi) + 2, self.ns);
                if (lo >= hi) {
                    self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags);
                } else {
                    var saved: [2 * MAX_CAPTURES]isize = undefined;
                    @memcpy(saved[0 .. hi - lo], caps[lo..hi]);
                    @memset(caps[lo..hi], -1);
                    self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags);
                    @memcpy(caps[lo..hi], saved[0 .. hi - lo]);
                }
            },
            .assert_bol => if (testBol(input, sp, flags))
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags),
            .assert_eol => if (testEol(input, sp, flags))
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags),
            .assert_wb => if (atWordBoundary(input, sp))
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags),
            .assert_nwb => if (!atWordBoundary(input, sp))
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, caps, input, flags),
            .look => |lnode| {
                var tmp = [_]CaptureSpan{INVALID_CAP} ** MAX_CAPTURES;
                if (matchNode(lnode, input, sp, &tmp, flags) == null) return;
                // matchNode already discarded a negative assertion's captures, so
                // whatever `tmp` holds belongs in the thread's capture set. Merge
                // into a local copy: `caps` is the caller's shared work buffer.
                var merged: [2 * MAX_CAPTURES]isize = undefined;
                @memcpy(merged[0..self.ns], caps[0..self.ns]);
                var gi: usize = 1;
                var touched = false;
                while (gi < MAX_CAPTURES and 2 * gi + 1 < self.ns) : (gi += 1) {
                    if (tmp[gi].unset()) continue;
                    merged[2 * gi] = @intCast(tmp[gi].start);
                    merged[2 * gi + 1] = @intCast(tmp[gi].end);
                    touched = true;
                }
                const next_caps = if (touched) merged[0..self.ns] else caps;
                self.addThread(list_pcs, list_caps, list_pos, n_ptr, pc + 1, sp, next_caps, input, flags);
            },
            // Leaf: a consuming op or `match`. Snapshot caps + the position at
            // which this thread will consume (needed because consuming ops can
            // advance a variable number of bytes — a multi-byte class/dot — so
            // threads are no longer guaranteed to sit at a single shared `sp`).
            .char, .class, .any_char, .match => {
                const idx = n_ptr.*;
                @memcpy(list_caps[idx * self.ns .. idx * self.ns + self.ns], caps);
                list_pcs[idx] = pc;
                list_pos[idx] = sp;
                n_ptr.* = idx + 1;
            },
        }
    }

    /// Run the program anchored at `start`. Returns the whole-match end position
    /// and captures, or null if no match begins exactly at `start`.
    fn runAnchored(
        self: *PikeVM,
        input: []const u8,
        start: usize,
        flags: *const CompiledRegex.Flags,
    ) ?MatchState {
        @memset(self.seen, 0);
        self.gen = 0;
        self.matched_valid = false;

        var cur_pcs = self.a_pcs;
        var cur_caps = self.a_caps;
        var cur_pos = self.a_pos;
        var cur_n: usize = 0;
        var nxt_pcs = self.b_pcs;
        var nxt_caps = self.b_caps;
        var nxt_pos = self.b_pos;
        var nxt_n: usize = 0;

        // Seed the current list at `start`.
        @memset(self.work, -1);
        self.gen += 1;
        self.addThread(cur_pcs, cur_caps, cur_pos, &cur_n, 0, start, self.work, input, flags);

        var sp = start;
        while (true) {
            self.gen += 1;
            nxt_n = 0;
            var ti: usize = 0;
            while (ti < cur_n) : (ti += 1) {
                const pc = cur_pcs[ti];
                const tpos = cur_pos[ti];
                const tcaps = cur_caps[ti * self.ns .. ti * self.ns + self.ns];
                // A consuming op may have advanced past `sp` (multi-byte class or
                // dot). Threads waiting at a later byte are carried forward
                // unchanged until `sp` reaches them, preserving priority order.
                if (tpos > sp) {
                    const idx = nxt_n;
                    @memcpy(nxt_caps[idx * self.ns .. idx * self.ns + self.ns], tcaps);
                    nxt_pcs[idx] = pc;
                    nxt_pos[idx] = tpos;
                    nxt_n = idx + 1;
                    continue;
                }
                switch (self.prog.insts[pc]) {
                    .char => |ch| {
                        if (consumeLiteral(input, sp, ch, flags)) |np| {
                            @memcpy(self.work, tcaps);
                            self.addThread(nxt_pcs, nxt_caps, nxt_pos, &nxt_n, pc + 1, np, self.work, input, flags);
                        }
                    },
                    .class => |cc| {
                        if (consumeClass(input, sp, cc, flags)) |np| {
                            @memcpy(self.work, tcaps);
                            self.addThread(nxt_pcs, nxt_caps, nxt_pos, &nxt_n, pc + 1, np, self.work, input, flags);
                        }
                    },
                    .any_char => {
                        if (consumeDot(input, sp, flags)) |np| {
                            @memcpy(self.work, tcaps);
                            self.addThread(nxt_pcs, nxt_caps, nxt_pos, &nxt_n, pc + 1, np, self.work, input, flags);
                        }
                    },
                    .match => {
                        @memcpy(self.matched, tcaps);
                        self.matched_valid = true;
                        // Threads after a match in priority order are lower
                        // priority; discard them for leftmost-first semantics.
                        break;
                    },
                    else => unreachable, // epsilon ops never enter a thread list
                }
            }
            // Swap current <-> next.
            const t_pcs = cur_pcs;
            const t_caps = cur_caps;
            const t_pos = cur_pos;
            cur_pcs = nxt_pcs;
            cur_caps = nxt_caps;
            cur_pos = nxt_pos;
            cur_n = nxt_n;
            nxt_pcs = t_pcs;
            nxt_caps = t_caps;
            nxt_pos = t_pos;
            if (cur_n == 0) break;
            // Step one byte at a time. Threads whose consume position is still
            // ahead of `sp` (a multi-byte code unit was consumed) wait in the list
            // and fire once `sp` reaches them — see the carry above.
            sp += 1;
        }

        if (!self.matched_valid) return null;
        var out = MatchState{ .pos = 0, .captures = [_]CaptureSpan{INVALID_CAP} ** MAX_CAPTURES };
        out.pos = @intCast(self.matched[1]);
        var g: usize = 1;
        const max_g = @min(self.ns / 2, MAX_CAPTURES);
        while (g < max_g) : (g += 1) {
            const s = self.matched[2 * g];
            const e = self.matched[2 * g + 1];
            if (s >= 0 and e >= 0) {
                out.captures[g] = .{ .start = @intCast(s), .end = @intCast(e) };
            }
        }
        return out;
    }
};

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
    // lastIndex is { writable, non-enumerable, non-configurable } (§22.2.7.2).
    _ = try obj.defineOwnData("lastIndex", li_val, .{ .writable = true, .enumerable = false, .configurable = false });

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

/// Set(R, "lastIndex", idx, true) — the throwing form RegExpBuiltinExec uses; a
/// non-writable lastIndex must raise TypeError rather than being silently ignored.
fn setLastIndexThrow(arena: std.mem.Allocator, v: Value, idx: usize) !void {
    const li_val = try val_mod.makeNumber(arena, @floatFromInt(idx));
    if (realm_mod.active_context) |ctx| {
        try ctx.setPropThrow(arena, v, "lastIndex", li_val);
    } else if (v.bits != 0 and v.unbox() == .object) {
        try v.toPtr().object.set("lastIndex", li_val);
    }
}

/// IsRegExp (§7.2.8): an own/inherited `Symbol.match` wins over the
/// [[RegExpMatcher]] slot, so `re[Symbol.match] = false` makes `re` stop
/// counting as a RegExp for the constructor's short-circuit.
pub fn isRegExpValue(arena: std.mem.Allocator, v: Value) anyerror!bool {
    if (v.bits == 0 or v.unbox() != .object) return false;
    if (realm_mod.active_sym_match) |match_sym| {
        if (realm_mod.active_context) |ctx| {
            const mv = try ctx.getPropSym(arena, v, match_sym);
            if (!(mv.bits == 0 or mv.unbox() == .undefined_)) return truthyValue(mv);
        }
    }
    return getCompiledRegex(v) != null;
}

fn truthyValue(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_, .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
}

pub fn nativeRegExpCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // A plain call and a `new` both arrive with a synthesized object `this`, so
    // only this flag distinguishes them (see realm.active_constructing).
    const is_construct = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    const pattern_arg = if (args.len > 0) args[0] else Value{};
    const flags_arg = if (args.len > 1) args[1] else Value{};
    const flags_undefined = flags_arg.bits == 0 or flags_arg.unbox() == .undefined_;

    // Step 1: IsRegExp(pattern) is observed once, up front — an @@match getter
    // must not run again for the source/flags reads below.
    const pattern_is_regexp = try isRegExpValue(arena, pattern_arg);
    const pattern_cr: ?*CompiledRegex = if (pattern_arg.bits != 0 and pattern_arg.unbox() == .object)
        getCompiledRegex(pattern_arg)
    else
        null;

    // Step 2.b: `RegExp(re)` (no `new`, no flags) whose .constructor is %RegExp%
    // returns that very object — including a merely RegExp-*like* one (§22.2.4.1).
    if (!is_construct and flags_undefined and pattern_is_regexp) {
        const cv = try ctxGetProp(arena, pattern_arg, "constructor");
        if (cv.bits != 0 and cv.unbox() == .object and
            active_regexp_ctor == cv.toPtr().object) return pattern_arg;
    }

    // Steps 4-6 + RegExpInitialize: P is the [[OriginalSource]] of a real RegExp,
    // the `source` property of a RegExp-like object, else ToString(pattern)
    // (undefined → ""); F likewise falls back to the pattern's own flags.
    const pattern_str: []const u8 = if (pattern_cr) |pcr| blk: {
        if (pattern_arg.toPtr().object.get("[[OriginalSource]]")) |sv| {
            if (sv.bits != 0 and sv.unbox() == .string) break :blk sv.toPtr().string;
        }
        _ = pcr;
        break :blk "";
    } else if (pattern_is_regexp) blk: {
        const sv = try ctxGetProp(arena, pattern_arg, "source");
        if (sv.bits == 0 or sv.unbox() == .undefined_) break :blk "";
        break :blk try realm_mod.stringPrimitive(arena, sv);
    } else if (pattern_arg.bits == 0 or pattern_arg.unbox() == .undefined_)
        ""
    else
        try realm_mod.stringPrimitive(arena, pattern_arg);

    const flags_str: []const u8 = if (!flags_undefined)
        try realm_mod.stringPrimitive(arena, flags_arg)
    else if (pattern_cr) |pcr|
        try flagsToString(arena, pcr.flags)
    else if (pattern_is_regexp) blk: {
        const fv = try ctxGetProp(arena, pattern_arg, "flags");
        if (fv.bits == 0 or fv.unbox() == .undefined_) break :blk "";
        break :blk try realm_mod.stringPrimitive(arena, fv);
    } else "";

    const cr = arena.create(CompiledRegex) catch return error.OutOfMemory;
    cr.* = compileRegex(arena, pattern_str, flags_str) catch {
        const msg_s = std.fmt.allocPrint(arena, "Invalid regular expression: /{s}/{s}", .{ pattern_str, flags_str }) catch "Invalid regular expression";
        const proto_opt = realm_mod.syntaxErrorProto();
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
        // lastIndex is { writable, non-enumerable, non-configurable } (§22.2.7.2).
        _ = try this_obj.defineOwnData("lastIndex", li_val, .{ .writable = true, .enumerable = false, .configurable = false });
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
        JsObject.createOnHeap(heap, realm_mod.syntaxErrorProto()) catch null
    else
        JsObject.create(arena, realm_mod.syntaxErrorProto()) catch null;
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
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    if (f.has_indices) {
        buf[n] = 'd';
        n += 1;
    }
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
    if (f.unicode_sets) {
        buf[n] = 'v';
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
    // Step 3 (legacy-regexp): [[LegacyFeaturesEnabled]] is set only for an
    // instance %RegExp% itself constructed, which a subclass instance (whose
    // prototype came from its own newTarget) and a foreign realm's instance are
    // not.
    if (this_obj.proto != realm_mod.active_regexp_proto)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.compile is disabled for this RegExp");

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
    this_obj.internal_slot = @ptrCast(cr);
    this_obj.internal_kind = .regexp;
    // RegExpInitialize's last step is Set(obj, "lastIndex", 0, true) — a throwing
    // Set, and it runs *after* the source and matcher are already in place.
    if (this_obj.ownAttr("lastIndex")) |attr| {
        if (!attr.writable) return realm_mod.throwTypeError(arena, "cannot reset the lastIndex of this RegExp");
    }
    _ = try this_obj.defineOwnData("lastIndex", try val_mod.makeNumber(arena, 0.0), .{ .writable = true, .enumerable = false, .configurable = false });
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
    // `lastIndex` lives in UTF-16 code-unit space (observable to JS), while the
    // matcher scans WTF-8 `s` in byte space. Convert on the way in and back out;
    // for an all-ASCII subject the two spaces coincide, so skip the O(n) walks.
    const s_ascii = isByteAscii(s);
    // Step 8: if neither global nor sticky, the search starts at 0.
    const from: usize = if (!use_li) 0 else if (s_ascii) last_index else string_proto.cuByteOf(s, last_index);

    // An out-of-bounds lastIndex fails immediately (and resets when g/y). The
    // bound is the code-unit length; cuByteOf clamps into range, so guard here.
    const cu_len = if (s_ascii) s.len else string_proto.cuLen(s);
    if (use_li and last_index > cu_len) {
        try setLastIndexThrow(arena, this_val, 0);
        return val_mod.makeNull(arena);
    }

    const result = findMatch(cr, s, from) orelse {
        if (use_li) try setLastIndexThrow(arena, this_val, 0);
        return val_mod.makeNull(arena);
    };

    if (use_li) try setLastIndexThrow(arena, this_val, if (s_ascii) result.state.pos else string_proto.cuIndexOfByte(s, result.state.pos));

    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);

    const full_match = try arena.dupe(u8, s[result.start..result.state.pos]);
    const full_val = try val_mod.makeString(arena, full_match);
    try arr.set("0", full_val);

    var i: u32 = 1;
    while (i <= cr.num_captures and i < MAX_CAPTURES) : (i += 1) {
        const cap = result.state.captures[i];
        const cap_val: Value = if (cap.unset() and i > 0)
            try val_mod.makeUndefined(arena)
        else
            try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end]));
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(key, cap_val);
    }
    arr.array_length = cr.num_captures + 1;

    // `index` is a UTF-16 code-unit offset (JS strings are UTF-16); the matcher
    // works in WTF-8 byte space, so convert the byte start to a code-unit index.
    const idx_val = try val_mod.makeNumber(arena, @floatFromInt(string_proto.cuIndexOfByte(s, result.start)));
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
            if (cap.unset()) continue;
            try gobj.set(ni.name, try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end])));
        }
        break :grp try val_mod.makeObject(arena, gobj);
    };
    try arr.set("groups", groups_val);

    // ES2022 `d`: MakeMatchIndicesIndexPairArray — one [start, end] pair per
    // capture (undefined when the group did not participate), plus a `groups`
    // object mirroring the named captures.
    if (cr.flags.has_indices) {
        const ind = try JsObject.createArray(arena, arr_proto);
        var k: u32 = 0;
        while (k <= cr.num_captures and k < MAX_CAPTURES) : (k += 1) {
            const span: CaptureSpan = if (k == 0)
                .{ .start = result.start, .end = result.state.pos }
            else
                result.state.captures[k];
            const key = try std.fmt.allocPrint(arena, "{d}", .{k});
            if (k > 0 and span.unset()) {
                try ind.set(key, try val_mod.makeUndefined(arena));
                continue;
            }
            const pair = try JsObject.createArray(arena, arr_proto);
            try pair.set("0", try val_mod.makeNumber(arena, @floatFromInt(string_proto.cuIndexOfByte(s, span.start))));
            try pair.set("1", try val_mod.makeNumber(arena, @floatFromInt(string_proto.cuIndexOfByte(s, span.end))));
            pair.array_length = 2;
            try ind.set(key, try val_mod.makeObject(arena, pair));
        }
        ind.array_length = cr.num_captures + 1;

        const ind_groups: Value = if (cr.group_names.len == 0)
            try val_mod.makeUndefined(arena)
        else grp: {
            const gobj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
            for (cr.group_names) |ni| {
                if (gobj.getOwn(ni.name) == null) try gobj.set(ni.name, try val_mod.makeUndefined(arena));
            }
            for (cr.group_names) |ni| {
                const cap = if (ni.idx < MAX_CAPTURES) result.state.captures[ni.idx] else INVALID_CAP;
                if (cap.unset()) continue;
                const pair = try JsObject.createArray(arena, arr_proto);
                try pair.set("0", try val_mod.makeNumber(arena, @floatFromInt(string_proto.cuIndexOfByte(s, cap.start))));
                try pair.set("1", try val_mod.makeNumber(arena, @floatFromInt(string_proto.cuIndexOfByte(s, cap.end))));
                pair.array_length = 2;
                try gobj.set(ni.name, try val_mod.makeObject(arena, pair));
            }
            break :grp try val_mod.makeObject(arena, gobj);
        };
        try ind.set("groups", ind_groups);
        try arr.set("indices", try val_mod.makeObject(arena, ind));
    }

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
        if (cap.unset()) continue; // group did not participate
        const val = s[cap.start..cap.end];
        if (i <= 9) legacy_state.groups[i - 1] = val;
        last_paren = val;
    }
    legacy_state.last_paren = last_paren;
}

/// The legacy accessors are brand-checked to the %RegExp% constructor itself:
/// any other receiver (instance, subclass, cross-realm ctor) is a TypeError.
fn legacyBrandCheck(arena: std.mem.Allocator, this_val: Value) anyerror!void {
    // Cross-realm: the receiver must be the %RegExp% of the realm this getter was
    // created in, not whichever realm's constructor happens to be active.
    const expected = if (realm_mod.activeNativeRealm()) |r| r.regexp_ctor else active_regexp_ctor;
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object != expected)
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

/// Set(obj, key, val, true) — throwing form (Symbol.search/replace/split etc.).
fn ctxSetPropThrow(arena: std.mem.Allocator, obj: Value, key: []const u8, v: Value) !void {
    if (realm_mod.active_context) |ctx| try ctx.setPropThrow(arena, obj, key, v);
}

/// SameValue for the values `lastIndex` carries: numbers compare with NaN==NaN
/// and +0≠-0; everything else by identity.
fn sameValueStrict(a: Value, b: Value) bool {
    const an = a.bits != 0 and a.unbox() == .number;
    const bn = b.bits != 0 and b.unbox() == .number;
    if (an and bn) {
        const x = a.unbox().number;
        const y = b.unbox().number;
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
        return x == y;
    }
    return a.bits == b.bits;
}

/// ToString(v) with the Symbol → TypeError guard (spec ToString).
fn toStringArg(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits != 0 and v.unbox() == .symbol)
        return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string");
    return realm_mod.stringPrimitive(arena, v);
}

/// ToNumber(v) with the Symbol/BigInt → TypeError guards the shared helper omits
/// (object valueOf/toString throws already propagate through toNumberValue).
fn toNumberArg(arena: std.mem.Allocator, v: Value) !f64 {
    if (v.bits != 0) switch (v.unbox()) {
        .symbol => return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .bigint => return realm_mod.throwTypeError(arena, "Cannot convert a BigInt value to a number"),
        else => {},
    };
    return realm_mod.toNumberValue(arena, v);
}

/// ToLength(v) via the checked ToNumber (Symbol/BigInt throw).
fn toLengthArg(arena: std.mem.Allocator, v: Value) !usize {
    const n = try toNumberArg(arena, v);
    if (std.math.isNan(n) or n <= 0) return 0;
    return @intFromFloat(@min(std.math.trunc(n), 9007199254740991.0));
}

/// ToString(Get(obj, key)).
fn getStrProp(arena: std.mem.Allocator, obj: Value, key: []const u8) ![]const u8 {
    const v = try ctxGetProp(arena, obj, key);
    // ToString of a Symbol throws a TypeError (e.g. a Symbol-valued `flags`).
    if (v.bits != 0 and v.unbox() == .symbol)
        return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string");
    return realm_mod.stringPrimitive(arena, v);
}

/// Type(v) is Object — callables (functions) are objects in our model.
fn isObjectVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
}

/// RegExpExec(R, S) — ES §22.2.7.1: dispatch to a user `exec` if callable,
/// otherwise RegExpBuiltinExec. Result must be an Object or null.
fn regExpExec(arena: std.mem.Allocator, R: Value, s_val: Value) !Value {
    const exec = try ctxGetProp(arena, R, "exec");
    if (fp.isCallableFn(exec)) {
        const res = try fp.invokeCallback(arena, R, exec, &[_]Value{s_val});
        if (res.bits != 0 and (isObjectVal(res) or res.unbox() == .null_)) return res;
        return realm_mod.throwTypeError(arena, "RegExp exec method returned a non-object, non-null value");
    }
    if (getCompiledRegex(R) == null)
        return realm_mod.throwTypeError(arena, "RegExpExec called on a non-RegExp object");
    return nativeRegExpExec(arena, R, &[_]Value{s_val});
}

/// True when every byte is < 0x80, i.e. UTF-16 code-unit indices and WTF-8 byte
/// offsets coincide — the hot path for `lastIndex` bookkeeping in exec.
fn isByteAscii(s: []const u8) bool {
    for (s) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// AdvanceStringIndex(S, index, unicode) (§22.2.7.3) over UTF-16 code units.
/// `index` and the result are code-unit offsets (the same space `lastIndex`
/// lives in); S is stored as WTF-8. Only a lead+trail surrogate pair advances
/// by two — a lone surrogate or a non-astral unit advances by one.
fn advanceStringIndex(s: []const u8, index: usize, unicode: bool) usize {
    if (!unicode) return index + 1;
    const len = string_proto.cuLen(s);
    if (index + 1 >= len) return index + 1;
    const first = string_proto.cuUnitAt(s, index) orelse return index + 1;
    if (first < 0xD800 or first > 0xDBFF) return index + 1;
    const second = string_proto.cuUnitAt(s, index + 1) orelse return index + 1;
    if (second < 0xDC00 or second > 0xDFFF) return index + 1;
    return index + 2;
}

fn requireObject(arena: std.mem.Allocator, v: Value, comptime what: []const u8) !void {
    if (v.bits == 0 or v.unbox() != .object)
        return realm_mod.throwTypeError(arena, what ++ " called on a non-object");
}

/// RegExp.prototype[@@search] (ES §22.2.6.13).
pub fn nativeRegExpSymbolSearch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.search]");
    const s_str = if (args.len > 0) try toStringArg(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);
    const prev = try ctxGetProp(arena, this_val, "lastIndex");
    if (!sameValueStrict(prev, try val_mod.makeNumber(arena, 0)))
        try ctxSetPropThrow(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, 0));
    const result = try regExpExec(arena, this_val, s_val);
    const cur = try ctxGetProp(arena, this_val, "lastIndex");
    if (!sameValueStrict(cur, prev)) try ctxSetPropThrow(arena, this_val, "lastIndex", prev);
    if (result.bits == 0 or result.unbox() == .null_) return val_mod.makeNumber(arena, -1);
    return ctxGetProp(arena, result, "index");
}

/// RegExp.prototype[@@match] (ES §22.2.6.8).
pub fn nativeRegExpSymbolMatch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObject(arena, this_val, "RegExp.prototype[Symbol.match]");
    const s_str = if (args.len > 0) try toStringArg(arena, args[0]) else "undefined";
    const s_val = try val_mod.makeString(arena, s_str);
    const flags = try getStrProp(arena, this_val, "flags");
    const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
    if (!global) return regExpExec(arena, this_val, s_val);

    const unicode = std.mem.indexOfScalar(u8, flags, 'u') != null;
    try ctxSetPropThrow(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, 0));
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
            const li = try toLengthArg(arena, try ctxGetProp(arena, this_val, "lastIndex"));
            try ctxSetPropThrow(arena, this_val, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(advanceStringIndex(s_str, li, unicode))));
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
            '$' => {
                try out.append(arena, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(arena, matched);
                i += 2;
            },
            '`' => {
                try out.appendSlice(arena, str[0..position]);
                i += 2;
            },
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
            else => {
                try out.append(arena, '$');
                i += 1;
            },
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
        // `index` is a code-unit offset (spec, and RegExpBuiltinExec now reports
        // it as such); the replacer callback receives that code-unit value, while
        // all slicing of the WTF-8 `s_str` needs the corresponding byte offset.
        var position: usize = @intFromFloat(std.math.trunc(position_f));
        const s_cu_len = string_proto.cuLen(s_str);
        if (position > s_cu_len) position = s_cu_len;
        const position_byte = string_proto.cuByteOf(s_str, position);

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
            // Non-functional branch performs ToObject(namedCaptures) when present
            // (§22.2.6.11), so a non-undefined null `groups` throws a TypeError.
            if (has_named and named_captures.unbox() == .null_)
                return realm_mod.throwTypeError(arena, "Cannot convert null groups to object");
            // `$<name>` looks up the (defined) `groups`; ctxGetProp autoboxes a
            // primitive receiver, so no explicit ToObject step is needed here.
            replacement = try getSubstitution(arena, matched, s_str, position_byte, captures.items, repl_str, named_captures);
        }

        if (position_byte >= next_source_pos) {
            try accumulated.appendSlice(arena, s_str[next_source_pos..position_byte]);
            try accumulated.appendSlice(arena, replacement);
            next_source_pos = position_byte + matched.len;
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
    const s_str = if (args.len > 0) try toStringArg(arena, args[0]) else "undefined";
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
            const n = try toNumberArg(arena, args[1]);
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

    // p, q and e are all UTF-16 code-unit offsets (§22.2.6.14); s_str is WTF-8,
    // so slicing converts code-unit bounds to byte offsets via cuByteOf.
    const s_size = string_proto.cuLen(s_str);
    var out_n: u32 = 0;
    var p: usize = 0; // start of current segment
    var q: usize = 0; // scan position
    while (q < s_size) {
        try ctxSetPropThrow(arena, splitter, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(q)));
        const z = try regExpExec(arena, splitter, s_val);
        if (z.bits == 0 or z.unbox() == .null_) {
            q = advanceStringIndex(s_str, q, unicode);
            continue;
        }
        var e = try toLengthArg(arena, try ctxGetProp(arena, splitter, "lastIndex"));
        if (e > s_size) e = s_size;
        if (e == p) {
            q = advanceStringIndex(s_str, q, unicode);
            continue;
        }
        // Segment [p, q).
        const key = try std.fmt.allocPrint(arena, "{d}", .{out_n});
        try arr.set(key, try val_mod.makeString(arena, s_str[string_proto.cuByteOf(s_str, p)..string_proto.cuByteOf(s_str, q)]));
        out_n += 1;
        if (out_n >= lim) {
            arr.array_length = out_n;
            return val_mod.makeObject(arena, arr);
        }
        p = e;
        // Captures 1..numberOfCaptures from z.
        const z_len = try toLengthArg(arena, try ctxGetProp(arena, z, "length"));
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
    try arr.set(key, try val_mod.makeString(arena, s_str[string_proto.cuByteOf(s_str, p)..]));
    out_n += 1;
    arr.array_length = out_n;
    return val_mod.makeObject(arena, arr);
}

/// %RegExpStringIteratorPrototype% (ES §22.2.9.1). Lazy iterator returned by
/// RegExp.prototype[@@matchAll]; parent = %IteratorPrototype%.
pub var active_regexp_string_iter_proto: ?*JsObject = null;

/// [[IteratingRegExp]] / [[IteratedString]] / [[Global]] / [[Unicode]] / [[Done]]
/// internal slots of a RegExp String Iterator (ES §22.2.9.1).
pub const MatchAllIterData = struct {
    regexp: Value,
    string: Value,
    string_bytes: []const u8,
    global: bool,
    unicode: bool,
    done: bool,
};

/// GC hook: keep the iterating RegExp and iterated String alive.
pub fn gcTraceStringIterator(heap: anytype, obj: *JsObject) void {
    const d: *MatchAllIterData = @ptrCast(@alignCast(obj.internal_slot orelse return));
    heap.markValueLive(d.regexp);
    heap.markValueLive(d.string);
}

fn requireStringIterator(arena: std.mem.Allocator, this_val: Value) !*MatchAllIterData {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp String Iterator.prototype.next called on a non-object");
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .regexp_string_iterator or obj.internal_slot == null)
        return realm_mod.throwTypeError(arena, "RegExp String Iterator.prototype.next called on an incompatible receiver");
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// %RegExpStringIteratorPrototype%.next ( ) — ES §22.2.9.2.1.
pub fn nativeRegExpStringIterNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireStringIterator(arena, this_val);
    if (d.done) return makeMatchIterResult(arena, try val_mod.makeUndefined(arena), true);

    const match = try regExpExec(arena, d.regexp, d.string);
    if (match.bits == 0 or match.unbox() == .null_) {
        d.done = true;
        return makeMatchIterResult(arena, try val_mod.makeUndefined(arena), true);
    }
    if (!d.global) {
        d.done = true;
        return makeMatchIterResult(arena, match, false);
    }
    // Global: if the match is empty, bump lastIndex so we make progress.
    const match_str = try getStrProp(arena, match, "0");
    if (match_str.len == 0) {
        const li = try realm_mod.toLengthValue(arena, try ctxGetProp(arena, d.regexp, "lastIndex"));
        try ctxSetProp(arena, d.regexp, "lastIndex", try val_mod.makeNumber(arena, @floatFromInt(advanceStringIndex(d.string_bytes, li, d.unicode))));
    }
    return makeMatchIterResult(arena, match, false);
}

/// CreateIterResultObject (ES §7.4.14).
fn makeMatchIterResult(arena: std.mem.Allocator, value: Value, done: bool) !Value {
    const proto = realm_mod.active_object_proto;
    const obj = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    return val_mod.makeObject(arena, obj);
}

/// Build %RegExpStringIteratorPrototype% (called at realm init, after
/// %IteratorPrototype% exists).
pub fn initStringIteratorProto(arena: std.mem.Allocator, iterator_proto: ?*JsObject) !void {
    const cfg: @import("../../object/object.zig").PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const tag_cfg: @import("../../object/object.zig").PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    const proto = try JsObject.create(arena, iterator_proto orelse realm_mod.active_object_proto);
    _ = try proto.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeRegExpStringIterNext, "next", 0), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try proto.setSymAttr(tag, try val_mod.makeString(arena, "RegExp String Iterator"), tag_cfg);
    active_regexp_string_iter_proto = proto;
}

/// RegExp.prototype[@@matchAll] (ES §22.2.6.9): construct a matcher clone of R
/// and return a lazy RegExp String Iterator over it.
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

    // CreateRegExpStringIterator(matcher, S, global, fullUnicode).
    const d = try arena.create(MatchAllIterData);
    d.* = .{
        .regexp = matcher,
        .string = s_val,
        .string_bytes = s_str,
        .global = global,
        .unicode = unicode,
        .done = false,
    };
    const proto = active_regexp_string_iter_proto orelse realm_mod.active_object_proto;
    const iter = if (realm_mod.active_heap) |h| try JsObject.createOnHeap(h, proto) else try JsObject.create(arena, proto);
    iter.internal_slot = d;
    iter.internal_kind = .regexp_string_iterator;
    return val_mod.makeObject(arena, iter);
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
    // §22.2.6.13: a *generic* function. It reads `source` and `flags` through
    // ordinary [[Get]] (following the prototype chain and firing any getter or
    // Proxy trap) and ToString's each — there is NO [[RegExpMatcher]] brand check
    // on `this`, so it works on any object with those properties.
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.toString called on non-object");
    const ctx = realm_mod.active_context orelse
        return realm_mod.throwTypeError(arena, "RegExp.prototype.toString requires a runtime context");
    const src = try ctx.getProp(arena, this_val, "source");
    const src_s = try realm_mod.stringPrimitive(arena, src);
    const flags = try ctx.getProp(arena, this_val, "flags");
    const flags_s = try realm_mod.stringPrimitive(arena, flags);
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "/{s}/{s}", .{ src_s, flags_s }));
}

pub fn nativeRegExpGetSource(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // §22.2.6.13: only %RegExp.prototype% may lack [[OriginalSource]] (→ "(?:)");
    // any other non-RegExp object is an incompatible receiver → TypeError.
    _ = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeString(arena, "(?:)");
    const obj = this_val.toPtr().object;
    if (obj.getOwn("[[OriginalSource]]")) |sv| {
        if (sv.bits != 0 and sv.unbox() == .string)
            return val_mod.makeString(arena, try escapeRegExpPattern(arena, sv.toPtr().string));
        return sv;
    }
    return val_mod.makeString(arena, "(?:)");
}

/// EscapeRegExpPattern (ES §22.2.6.13.1): produce a source string that is a valid
/// pattern between "/…/" — empty → "(?:)"; an unescaped "/" → "\/"; a raw line
/// terminator → its backslash escape. Preserves already-escaped sequences.
fn escapeRegExpPattern(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (src.len == 0) return "(?:)";
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    var escaped = false; // preceding char was an unescaped backslash
    var in_class = false; // inside a character class [...] where '/' need not be escaped
    while (i < src.len) {
        const c = src[i];
        if (c == '\\') {
            try buf.append(arena, '\\');
            escaped = !escaped;
            i += 1;
            continue;
        }
        if (c == '[' and !escaped) {
            in_class = true;
        } else if (c == ']' and !escaped) {
            in_class = false;
        }
        // A raw LineTerminator must be escaped. When it is already preceded by an
        // (unescaped) backslash we emitted, that backslash + the escape letter
        // together form the sequence, so we append only the letter.
        if (c == '/' and !escaped and !in_class) {
            try buf.appendSlice(arena, "\\/");
        } else if (c == '\n') {
            try buf.appendSlice(arena, if (escaped) "n" else "\\n");
        } else if (c == '\r') {
            try buf.appendSlice(arena, if (escaped) "r" else "\\r");
        } else if (c == 0xE2 and i + 2 < src.len and src[i + 1] == 0x80 and (src[i + 2] == 0xA8 or src[i + 2] == 0xA9)) {
            const is_u2028 = src[i + 2] == 0xA8;
            try buf.appendSlice(arena, if (escaped) (if (is_u2028) "u2028" else "u2029") else (if (is_u2028) "\\u2028" else "\\u2029"));
            i += 3;
            escaped = false;
            continue;
        } else {
            try buf.append(arena, c);
        }
        escaped = false;
        i += 1;
    }
    return buf.toOwnedSlice(arena);
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

/// Brand guard shared by the flag getters (ES §22.2.6): the receiver must be an
/// Object; if it lacks a [[RegExpMatcher]] slot, only %RegExp.prototype% itself is
/// tolerated (→ null, so the caller returns undefined) — any other object throws.
fn regexpFlagBrand(arena: std.mem.Allocator, this_val: Value) anyerror!?*CompiledRegex {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp flag getter called on incompatible receiver");
    if (getCompiledRegex(this_val)) |cr| return cr;
    if (realm_mod.regexpProtoForActiveNative()) |proto| {
        if (this_val.toPtr().object == proto) return null;
    }
    return realm_mod.throwTypeError(arena, "RegExp flag getter called on incompatible receiver");
}

pub fn nativeRegExpGetGlobal(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.global);
}

pub fn nativeRegExpGetIgnoreCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.ignore_case);
}

pub fn nativeRegExpGetMultiline(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.multiline);
}

pub fn nativeRegExpGetDotAll(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.dotall);
}

pub fn nativeRegExpGetSticky(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.sticky);
}

pub fn nativeRegExpGetUnicode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.unicode);
}

pub fn nativeRegExpGetHasIndices(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const cr = try regexpFlagBrand(arena, this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeBool(arena, cr.flags.has_indices);
}

pub fn nativeRegExpGetUnicodeSets(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "RegExp.prototype.unicodeSets called on incompatible receiver");
    if (getCompiledRegex(this_val) == null) {
        // No [[OriginalFlags]]: only %RegExpPrototype% itself yields undefined;
        // any other object is an incompatible receiver (ES §22.2.6.18 step 3).
        if (realm_mod.regexpProtoForActiveNative()) |proto| {
            if (this_val.toPtr().object == proto) return val_mod.makeUndefined(arena);
        }
        return realm_mod.throwTypeError(arena, "RegExp.prototype.unicodeSets called on incompatible receiver");
    }
    return val_mod.makeBool(arena, getCompiledRegex(this_val).?.flags.unicode_sets);
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

test "regexp: pattern early errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A quantifier needs an Atom, and an assertion is not one (except the
    // Annex B `(?=)`/`(?!)` exception, checked below).
    const rejected = [_][2][]const u8{
        .{ "a**", "" },      .{ "+a", "" },      .{ "(*)", "" },
        .{ "a{1}{1,}", "" }, .{ "{1}", "" },     .{ "^*", "" },
        .{ "$*", "" },       .{ "(?<=a)*", "" },
        // /u tightens the grammar: no Annex B literals or legacy escapes.
        .{ "(?=.)*", "u" },
        .{ "a{1", "u" },     .{ "}", "u" },      .{ "]", "u" },
        .{ "\\1", "u" },     .{ "\\01", "u" },   .{ "\\x", "u" },
        .{ "\\c", "u" },     .{ "\\A", "u" },    .{ "[\\d-a]", "u" },
        .{ "[a-\\d]", "u" }, .{ "[\\c]", "u" },
    };
    for (rejected) |c| {
        std.testing.expectError(error.InvalidPattern, compileRegex(alloc, c[0], c[1])) catch |e| {
            std.debug.print("expected /{s}/{s} to be rejected\n", .{ c[0], c[1] });
            return e;
        };
    }
    const accepted = [_][2][]const u8{
        .{ "a??", "" },     .{ "(?=a)*", "" },  .{ "{", "" },
        .{ "]", "" },       .{ "a{", "" },      .{ "\\c", "" },
        .{ "\\1", "" },     .{ "[\\d-a]", "" }, .{ "\\x", "" },
        .{ "\\1(a)", "u" }, .{ "\\$", "u" },    .{ "[\\-]", "u" },
        .{ "\\cA", "u" },   .{ "[\\b]", "u" },
    };
    for (accepted) |c| {
        _ = compileRegex(alloc, c[0], c[1]) catch |e| {
            std.debug.print("expected /{s}/{s} to compile\n", .{ c[0], c[1] });
            return e;
        };
    }
}

test "regexp: a bare assertion is a valid whole pattern" {
    // Regression: the Pike VM's `look` instruction used to hold a pointer to
    // compileRegex's stack-local root, so a pattern that IS an assertion read
    // freed memory.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cr = try compileRegex(arena.allocator(), "(?=a)", "");
    const m = findMatch(&cr, "ba", 0) orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 1), m.state.pos);
}

test "regexp: a positive assertion keeps its captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cr = try compileRegex(arena.allocator(), "(?=(a+))", "");
    const m = findMatch(&cr, "baaabac", 0) orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 1), m.state.captures[1].start);
    try std.testing.expectEqual(@as(usize, 4), m.state.captures[1].end);
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

test "regexp/u: decodeCpAt folds WTF-8 surrogate pairs" {
    // U+1E900 stored as a single 4-byte UTF-8 sequence (source literal form).
    const flat = "\xF0\x9E\xA4\x80";
    const a = decodeCpAt(flat, 0);
    try std.testing.expectEqual(@as(u21, 0x1E900), a.cp);
    try std.testing.expectEqual(@as(u8, 4), a.len);

    // The same character stored as a WTF-8 surrogate pair, which is what
    // `\u{1E900}` and String.fromCodePoint produce: U+D83A then U+DD00.
    const pair = "\xED\xA0\xBA\xED\xB4\x80";
    const b = decodeCpAt(pair, 0);
    try std.testing.expectEqual(@as(u21, 0x1E900), b.cp);
    try std.testing.expectEqual(@as(u8, 6), b.len);

    // A high surrogate NOT followed by a low one stays a lone surrogate.
    const lone = "\xED\xA0\xBA";
    const c = decodeCpAt(lone, 0);
    try std.testing.expectEqual(@as(u21, 0xD83A), c.cp);
    try std.testing.expectEqual(@as(u8, 3), c.len);

    // decodeUtf8At itself must keep splitting the pair (non-`/u` mode relies
    // on seeing the two UTF-16 code units separately).
    const raw = decodeUtf8At(pair, 0);
    try std.testing.expectEqual(@as(u21, 0xD83A), raw.cp);
    try std.testing.expectEqual(@as(u8, 3), raw.len);
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
