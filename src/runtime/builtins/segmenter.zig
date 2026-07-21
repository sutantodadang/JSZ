// SPDX-License-Identifier: Apache-2.0
//! `Intl.Segmenter` (ECMA-402 §18) plus the UAX #29 text-boundary algorithms it
//! needs: extended grapheme clusters, word boundaries and sentence boundaries.
//!
//! There is no CLDR/ICU data in this build, so the two locale-sensitive parts of
//! UAX #29 are approximated: dictionary-driven word breaking for scripts with no
//! spaces (Thai, Lao, Khmer, Han, Japanese) falls back to the rule-based default,
//! and `isWordLike` is derived from the segment's own characters rather than from
//! locale data. Boundary *rules* themselves are implemented faithfully, which is
//! what makes grapheme clusters (Hangul jamo, emoji ZWJ sequences, skin-tone
//! modifiers, combining marks) come out right.
//!
//! Indices are UTF-16 code units throughout, matching ECMAScript string indexing,
//! while storage stays WTF-8 — `decodeAll` bridges the two and also re-joins a
//! surrogate pair that was stored as two 3-byte WTF-8 sequences, so `"𐀀"`
//! is one astral code point either way it was written.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const str_mod = @import("string_proto.zig");
const prop_tables = @import("unicode_prop_tables.zig");
const t_shared = @import("temporal/shared.zig");
const intl = @import("intl.zig");
const coercion = @import("coercion.zig");

// ---------------------------------------------------------------------------
// Code-point view
// ---------------------------------------------------------------------------

/// One decoded code point together with where it starts in the UTF-16 code-unit
/// index space and how many code units it occupies (2 for astral).
pub const Cp = struct { cp: u21, cu: u32, units: u2 };

/// Decode a WTF-8 string into code points carrying their UTF-16 offsets. A
/// high surrogate immediately followed by a low surrogate (the encoding used for
/// `"👋"`-style literals) is re-combined into the astral code point it
/// denotes, so boundary rules see the same character regardless of storage form.
pub fn decodeAll(arena: std.mem.Allocator, s: []const u8) ![]Cp {
    var out = std.ArrayListUnmanaged(Cp){};
    var i: usize = 0;
    var cu: u32 = 0;
    while (i < s.len) {
        var dec = str_mod.decodeWtf8At(s, i);
        var adv = dec.len;
        if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF and i + dec.len < s.len) {
            const lo = str_mod.decodeWtf8At(s, i + dec.len);
            if (lo.cp >= 0xDC00 and lo.cp <= 0xDFFF) {
                dec.cp = 0x10000 + ((dec.cp - 0xD800) << 10) + (lo.cp - 0xDC00);
                adv = dec.len + lo.len;
            }
        }
        const units: u2 = if (dec.cp > 0xFFFF) 2 else 1;
        try out.append(arena, .{ .cp = dec.cp, .cu = cu, .units = units });
        cu += units;
        i += adv;
    }
    return out.items;
}

fn inTable(table: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < table[mid][0]) {
            hi = mid;
        } else if (cp > table[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// `prop_tables.lookup` resolves a property name through a long chain of string
/// comparisons. Boundary classification asks for the same handful of properties
/// once per character, so each name resolves once and is then cached in its own
/// comptime-instantiated static.
fn propTable(comptime name: []const u8) []const [2]u21 {
    const S = struct {
        /// Naming `name` here is load-bearing: a struct body that does not
        /// mention the comptime parameter is the *same* type for every
        /// instantiation, so all properties would share one `cached` slot and
        /// whichever name was asked for first would answer for all of them.
        const key = name;
        var cached: ?[]const [2]u21 = null;
    };
    _ = S.key;
    if (S.cached) |t| return t;
    const t = prop_tables.lookup(name) orelse &[_][2]u21{};
    S.cached = t;
    return t;
}

fn prop(comptime name: []const u8, cp: u21) bool {
    return inTable(propTable(name), cp);
}

fn inAny(cp: u21, ranges: []const [2]u21) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn inList(cp: u21, list: []const u21) bool {
    for (list) |c| if (c == cp) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Shared character classes
// ---------------------------------------------------------------------------

const zwj: u21 = 0x200D;

/// UAX #29 `Extend`: `Grapheme_Extend=Yes` plus the emoji modifiers (skin tones),
/// which are `Sk` and therefore absent from `Grapheme_Extend` but must still bind
/// to the preceding character.
fn isExtend(cp: u21) bool {
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true; // Emoji_Modifier
    return prop("Grapheme_Extend", cp);
}

/// `Format`: `Cf` minus ZWJ/ZWNJ, which UAX #29 classifies as `Extend`/`ZWJ`.
fn isFormat(cp: u21) bool {
    if (cp == zwj or cp == 0x200C) return false;
    return prop("Cf", cp);
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isExtPict(cp: u21) bool {
    return prop("Extended_Pictographic", cp);
}

// ---------------------------------------------------------------------------
// Grapheme cluster boundaries (UAX #29 §3.1)
// ---------------------------------------------------------------------------

const GraphemeClass = enum { other, cr, lf, control, extend, zwj, ri, prepend, spacing_mark, hangul_l, hangul_v, hangul_t, hangul_lv, hangul_lvt };

/// `Prepend` — the prepended concatenation marks plus the few letters that
/// behave like them. Small enough to spell out.
const prepend_ranges = [_][2]u21{
    .{ 0x600, 0x605 }, .{ 0x6DD, 0x6DD },   .{ 0x70F, 0x70F },     .{ 0x890, 0x891 },
    .{ 0x8E2, 0x8E2 }, .{ 0xD4E, 0xD4E },   .{ 0x110BD, 0x110BD }, .{ 0x110CD, 0x110CD },
    .{ 0x111C2, 0x111C3 }, .{ 0x1193F, 0x1193F }, .{ 0x11941, 0x11941 }, .{ 0x11A3A, 0x11A3A },
    .{ 0x11A84, 0x11A89 }, .{ 0x11D46, 0x11D46 }, .{ 0x11F02, 0x11F02 },
};

/// `SpacingMark` is `Mc` minus a documented exception list (marks that behave as
/// `Extend`), plus a couple of additions.
const spacing_mark_exceptions = [_]u21{
    0x102B, 0x102C, 0x1038, 0x1062, 0x1063, 0x1064, 0x1067, 0x1068,
    0x1069, 0x106A, 0x106B, 0x106C, 0x106D, 0x1083, 0x1087, 0x1088,
    0x1089, 0x108A, 0x108B, 0x108C, 0x108F, 0x109A, 0x109B, 0x109C,
    0x1A61, 0x1A63, 0x1A64, 0xAA7B, 0xAA7D, 0x11720, 0x11721,
};

fn graphemeClass(cp: u21) GraphemeClass {
    if (cp == 0x0D) return .cr;
    if (cp == 0x0A) return .lf;
    if (cp == zwj) return .zwj;
    // Hangul jamo and precomposed syllables.
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0xA960 and cp <= 0xA97C)) return .hangul_l;
    if ((cp >= 0x1160 and cp <= 0x11A7) or (cp >= 0xD7B0 and cp <= 0xD7C6)) return .hangul_v;
    if ((cp >= 0x11A8 and cp <= 0x11FF) or (cp >= 0xD7CB and cp <= 0xD7FB)) return .hangul_t;
    if (cp >= 0xAC00 and cp <= 0xD7A3)
        return if ((cp - 0xAC00) % 28 == 0) .hangul_lv else .hangul_lvt;
    if (isExtend(cp)) return .extend;
    if (isRegionalIndicator(cp)) return .ri;
    if (inAny(cp, &prepend_ranges)) return .prepend;
    // Control: Cc/Cf/Zl/Zp and the unassigned default-ignorables, minus CR/LF/ZWJ
    // (handled above). Surrogates count as Control in UAX #29, but a lone
    // surrogate reaching here is its own cluster either way.
    if (prop("Cc", cp) or isFormat(cp) or prop("Zl", cp) or prop("Zp", cp)) return .control;
    if (prop("Mc", cp) and !inList(cp, &spacing_mark_exceptions)) return .spacing_mark;
    return .other;
}

/// Is there a grapheme-cluster boundary between `cps[i-1]` and `cps[i]`?
fn graphemeBreakAt(cps: []const Cp, i: usize) bool {
    if (i == 0 or i >= cps.len) return true; // GB1 / GB2
    const a = graphemeClass(cps[i - 1].cp);
    const b = graphemeClass(cps[i].cp);
    if (a == .cr and b == .lf) return false; // GB3
    if (a == .cr or a == .lf or a == .control) return true; // GB4
    if (b == .cr or b == .lf or b == .control) return true; // GB5
    if (a == .hangul_l and (b == .hangul_l or b == .hangul_v or b == .hangul_lv or b == .hangul_lvt)) return false; // GB6
    if ((a == .hangul_lv or a == .hangul_v) and (b == .hangul_v or b == .hangul_t)) return false; // GB7
    if ((a == .hangul_lvt or a == .hangul_t) and b == .hangul_t) return false; // GB8
    if (b == .extend or b == .zwj) return false; // GB9
    if (b == .spacing_mark) return false; // GB9a
    if (a == .prepend) return false; // GB9b
    // GB11: ExtPict Extend* ZWJ × ExtPict
    if (a == .zwj and isExtPict(cps[i].cp)) {
        var j = i - 1;
        while (j > 0 and graphemeClass(cps[j - 1].cp) == .extend) j -= 1;
        if (j > 0 and isExtPict(cps[j - 1].cp)) return false;
    }
    // GB12/GB13: break only between *pairs* of regional indicators.
    if (a == .ri and b == .ri) {
        var count: usize = 0;
        var j = i;
        while (j > 0 and graphemeClass(cps[j - 1].cp) == .ri) : (j -= 1) count += 1;
        return count % 2 == 0;
    }
    return true; // GB999
}

// ---------------------------------------------------------------------------
// Word boundaries (UAX #29 §4.1)
// ---------------------------------------------------------------------------

const WordClass = enum {
    other,      cr,          lf,        newline,     extend,     zwj,
    ri,         format,      katakana,  hebrew,      aletter,    single_quote,
    double_quote, midnumlet, midletter, midnum,      numeric,    extendnumlet,
    wsegspace,
};

const katakana_ranges = [_][2]u21{
    .{ 0x3031, 0x3035 },  .{ 0x309B, 0x309C }, .{ 0x30A0, 0x30FA }, .{ 0x30FC, 0x30FF },
    .{ 0x31F0, 0x31FF },  .{ 0x32D0, 0x32FE }, .{ 0x3300, 0x3357 }, .{ 0xFF66, 0xFF9D },
    .{ 0x1B000, 0x1B000 },
};

const hebrew_ranges = [_][2]u21{
    .{ 0x5D0, 0x5EA }, .{ 0x5EF, 0x5F2 }, .{ 0xFB1D, 0xFB1D }, .{ 0xFB1F, 0xFB28 }, .{ 0xFB2A, 0xFB4F },
};

const midletter_list = [_]u21{ 0x3A, 0xB7, 0x387, 0x55F, 0x5F4, 0x2027, 0xFE13, 0xFE55, 0xFF1A, 0xA789 };
const midnum_list = [_]u21{ 0x2C, 0x3B, 0x37E, 0x589, 0x60C, 0x60D, 0x66C, 0x7F8, 0x2044, 0xFE10, 0xFE14, 0xFE50, 0xFE54, 0xFF0C, 0xFF1B };
const midnumlet_list = [_]u21{ 0x2E, 0x2018, 0x2019, 0x2024, 0xFE52, 0xFF07, 0xFF0E };
const extendnumlet_list = [_]u21{ 0x5F, 0x202F, 0x203F, 0x2040, 0x2054, 0xFE33, 0xFE34, 0xFE4D, 0xFE4E, 0xFE4F, 0xFF3F };

fn wordClass(cp: u21) WordClass {
    if (cp == 0x0D) return .cr;
    if (cp == 0x0A) return .lf;
    if (cp == 0x0B or cp == 0x0C or cp == 0x85 or cp == 0x2028 or cp == 0x2029) return .newline;
    if (cp == zwj) return .zwj;
    if (cp == 0x27) return .single_quote;
    if (cp == 0x22) return .double_quote;
    if (isRegionalIndicator(cp)) return .ri;
    if (isExtend(cp)) return .extend;
    if (isFormat(cp)) return .format;
    // WSegSpace: Zs minus the no-break spaces (which glue words together).
    if (prop("Zs", cp) and cp != 0xA0 and cp != 0x2007 and cp != 0x202F) return .wsegspace;
    if (inList(cp, &extendnumlet_list)) return .extendnumlet;
    if (inList(cp, &midnumlet_list)) return .midnumlet;
    if (inList(cp, &midletter_list)) return .midletter;
    if (inList(cp, &midnum_list)) return .midnum;
    if (prop("Nd", cp)) return .numeric;
    if (inAny(cp, &katakana_ranges)) return .katakana;
    if (inAny(cp, &hebrew_ranges)) return .hebrew;
    // ALetter: alphabetic, except the ideographic/syllabic scripts that break
    // per character (Han, Hiragana, Thai, …) — those fall through to `other`.
    if (prop("Alphabetic", cp) and !isIdeographicish(cp)) return .aletter;
    return .other;
}

/// Scripts whose text has no spaces and which UAX #29 leaves to dictionary
/// breaking. Without a dictionary each character becomes its own word segment,
/// which still yields a valid partition of the input.
fn isIdeographicish(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x303F) or // CJK radicals, punctuation
        (cp >= 0x3040 and cp <= 0x30FF) or // Hiragana, Katakana
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK unified
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compatibility
        (cp >= 0x0E00 and cp <= 0x0E7F) or // Thai
        (cp >= 0x0E80 and cp <= 0x0EFF) or // Lao
        (cp >= 0x1780 and cp <= 0x17FF) or // Khmer
        (cp >= 0x1000 and cp <= 0x109F) or // Myanmar
        (cp >= 0x20000 and cp <= 0x2FA1F); // CJK ext B+
}

fn isAHLetter(c: WordClass) bool {
    return c == .aletter or c == .hebrew;
}
fn isMidNumLetQ(c: WordClass) bool {
    return c == .midnumlet or c == .single_quote;
}

/// WB4 — `Extend`, `Format` and `ZWJ` are transparent: they attach to the
/// preceding character rather than forming boundaries of their own. Returns the
/// index of the last non-transparent code point at or before `i`, or null when
/// every preceding character is transparent.
fn wbSkipBack(cps: []const Cp, i: usize) ?usize {
    var j = i;
    while (true) {
        const c = wordClass(cps[j].cp);
        if (c != .extend and c != .format and c != .zwj) return j;
        if (j == 0) return null;
        j -= 1;
    }
}

/// Index of the next non-transparent code point at or after `i`, or null.
fn wbSkipForward(cps: []const Cp, i: usize) ?usize {
    var j = i;
    while (j < cps.len) : (j += 1) {
        const c = wordClass(cps[j].cp);
        if (c != .extend and c != .format and c != .zwj) return j;
    }
    return null;
}

fn wordBreakAt(cps: []const Cp, i: usize) bool {
    if (i == 0 or i >= cps.len) return true; // WB1 / WB2
    const prev_raw = wordClass(cps[i - 1].cp);
    const cur = wordClass(cps[i].cp);
    if (prev_raw == .cr and cur == .lf) return false; // WB3
    if (prev_raw == .newline or prev_raw == .cr or prev_raw == .lf) return true; // WB3a
    if (cur == .newline or cur == .cr or cur == .lf) return true; // WB3b
    if (prev_raw == .zwj and isExtPict(cps[i].cp)) return false; // WB3c
    // WB4: transparent characters never start a boundary, and the effective
    // left context is the last character before them.
    if (cur == .extend or cur == .format or cur == .zwj) return false;
    const li = wbSkipBack(cps, i - 1) orelse return true;
    const left = wordClass(cps[li].cp);
    if (left == .wsegspace and cur == .wsegspace) return false; // WB3d
    if (isAHLetter(left) and isAHLetter(cur)) return false; // WB5
    // WB6/WB7: a single mid-letter between two letters does not break.
    if (isAHLetter(left) and (cur == .midletter or isMidNumLetQ(cur))) {
        if (wbSkipForward(cps, i + 1)) |ni| if (isAHLetter(wordClass(cps[ni].cp))) return false;
    }
    if (cur != .midletter and !isMidNumLetQ(cur) and isAHLetter(cur)) {
        if ((left == .midletter or isMidNumLetQ(left)) and li > 0) {
            if (wbSkipBack(cps, li - 1)) |pi| if (isAHLetter(wordClass(cps[pi].cp))) return false; // WB7
        }
    }
    if (left == .hebrew and cur == .single_quote) return false; // WB7a
    if (left == .hebrew and cur == .double_quote) { // WB7b
        if (wbSkipForward(cps, i + 1)) |ni| if (wordClass(cps[ni].cp) == .hebrew) return false;
    }
    if (left == .double_quote and cur == .hebrew and li > 0) { // WB7c
        if (wbSkipBack(cps, li - 1)) |pi| if (wordClass(cps[pi].cp) == .hebrew) return false;
    }
    if (left == .numeric and cur == .numeric) return false; // WB8
    if (isAHLetter(left) and cur == .numeric) return false; // WB9
    if (left == .numeric and isAHLetter(cur)) return false; // WB10
    if (cur == .numeric and (left == .midnum or isMidNumLetQ(left)) and li > 0) { // WB11
        if (wbSkipBack(cps, li - 1)) |pi| if (wordClass(cps[pi].cp) == .numeric) return false;
    }
    if (left == .numeric and (cur == .midnum or isMidNumLetQ(cur))) { // WB12
        if (wbSkipForward(cps, i + 1)) |ni| if (wordClass(cps[ni].cp) == .numeric) return false;
    }
    if (left == .katakana and cur == .katakana) return false; // WB13
    if ((isAHLetter(left) or left == .numeric or left == .katakana or left == .extendnumlet) and cur == .extendnumlet) return false; // WB13a
    if (left == .extendnumlet and (isAHLetter(cur) or cur == .numeric or cur == .katakana)) return false; // WB13b
    if (left == .ri and cur == .ri) { // WB15/WB16
        var count: usize = 0;
        var j = li;
        while (true) {
            if (wordClass(cps[j].cp) != .ri) break;
            count += 1;
            if (j == 0) break;
            j -= 1;
        }
        return count % 2 == 0;
    }
    return true; // WB999
}

// ---------------------------------------------------------------------------
// Sentence boundaries (UAX #29 §5.1)
// ---------------------------------------------------------------------------

const SentClass = enum { other, cr, lf, sep, format, sp, lower, upper, oletter, numeric, aterm, sterm, close, scontinue, extend };

const sterm_list = [_]u21{
    0x21,   0x3F,   0x203C, 0x203D, 0x2047, 0x2048, 0x2049, 0x2E2E,
    0x2E3C, 0x3002, 0xFE52, 0xFE56, 0xFE57, 0xFF01, 0xFF1F, 0xFF61,
    0x61B,  0x61D,  0x61E,  0x61F,  0x6D4,  0x7F9,  0x104A, 0x104B,
    0x1362, 0x1367, 0x1368, 0x166E, 0x1803, 0x1809,
};
const aterm_list = [_]u21{ 0x2E, 0x2024, 0xFE52, 0xFF0E };
const scontinue_list = [_]u21{ 0x2C, 0x2D, 0x3A, 0x55D, 0x60C, 0x60D, 0x7F8, 0x1802, 0x1808, 0x2013, 0x2014, 0x3001, 0xFE10, 0xFE11, 0xFE13, 0xFE31, 0xFE32, 0xFE50, 0xFE51, 0xFE55, 0xFE58, 0xFE63, 0xFF0C, 0xFF0D, 0xFF1A };

fn sentClass(cp: u21) SentClass {
    if (cp == 0x0D) return .cr;
    if (cp == 0x0A) return .lf;
    if (cp == 0x85 or cp == 0x2028 or cp == 0x2029) return .sep;
    if (isExtend(cp)) return .extend;
    if (isFormat(cp)) return .format;
    if (cp == 0x09 or (prop("Zs", cp) and cp != 0xA0)) return .sp;
    if (inList(cp, &aterm_list)) return .aterm;
    if (inList(cp, &sterm_list)) return .sterm;
    if (inList(cp, &scontinue_list)) return .scontinue;
    if (prop("Nd", cp)) return .numeric;
    // Close: the bracketing and quoting punctuation that may follow a terminator
    // before the sentence really ends.
    if (prop("Ps", cp) or prop("Pe", cp) or prop("Pi", cp) or prop("Pf", cp) or cp == 0x22 or cp == 0x27) return .close;
    if (prop("Ll", cp)) return .lower;
    if (prop("Lu", cp) or prop("Lt", cp)) return .upper;
    if (prop("Alphabetic", cp)) return .oletter;
    return .other;
}

/// SB5 — `Extend`/`Format` are transparent, as in the word rules.
fn sbSkipBack(cps: []const Cp, i: usize) ?usize {
    var j = i;
    while (true) {
        const c = sentClass(cps[j].cp);
        if (c != .extend and c != .format) return j;
        if (j == 0) return null;
        j -= 1;
    }
}

/// Does a `(STerm|ATerm) Close* Sp*` run end at `li` (inclusive)? Returns the
/// class of the terminator when it does.
fn sbTerminatorBefore(cps: []const Cp, li: usize) ?SentClass {
    // Walking backwards the run reads `Sp* Close* (STerm|ATerm)`, so spaces may
    // only appear before the first Close is seen.
    var j = li;
    var spaces_allowed = true;
    while (true) {
        const idx = sbSkipBack(cps, j) orelse return null;
        const c = sentClass(cps[idx].cp);
        switch (c) {
            .sp => if (!spaces_allowed) return null,
            .close => spaces_allowed = false,
            .aterm, .sterm => return c,
            else => return null,
        }
        if (idx == 0) return null;
        j = idx - 1;
    }
}

fn sentenceBreakAt(cps: []const Cp, i: usize) bool {
    if (i == 0 or i >= cps.len) return true; // SB1 / SB2
    const prev_raw = sentClass(cps[i - 1].cp);
    const cur = sentClass(cps[i].cp);
    if (prev_raw == .cr and cur == .lf) return false; // SB3
    if (prev_raw == .sep or prev_raw == .cr or prev_raw == .lf) return true; // SB4
    if (cur == .extend or cur == .format) return false; // SB5
    const li = sbSkipBack(cps, i - 1) orelse return false;
    const left = sentClass(cps[li].cp);
    if (left == .aterm and cur == .numeric) return false; // SB6
    if (left == .aterm and cur == .upper and li > 0) { // SB7
        if (sbSkipBack(cps, li - 1)) |pi| {
            const pc = sentClass(cps[pi].cp);
            if (pc == .upper or pc == .lower) return false;
        }
    }
    const term = sbTerminatorBefore(cps, li);
    if (term) |t| {
        // SB8a: a terminator followed by continuation punctuation or another
        // terminator does not end the sentence.
        if (cur == .scontinue or cur == .sterm or cur == .aterm) return false;
        // SB9/SB10: trailing Close/Sp/ParaSep stay with the sentence.
        if (cur == .close or cur == .sp or cur == .sep or cur == .cr or cur == .lf) return false;
        // SB8: `ATerm Close* Sp* × (¬…)* Lower` — an abbreviation, not an end.
        if (t == .aterm) {
            var j = i;
            while (j < cps.len) : (j += 1) {
                switch (sentClass(cps[j].cp)) {
                    .lower => return false,
                    .oletter, .upper, .sep, .cr, .lf, .sterm, .aterm => break,
                    else => {},
                }
            }
        }
        return true; // SB11
    }
    return false; // SB998
}

// ---------------------------------------------------------------------------
// Boundary queries
// ---------------------------------------------------------------------------

pub const Granularity = enum { grapheme, word, sentence };

fn breakAt(gran: Granularity, cps: []const Cp, i: usize) bool {
    return switch (gran) {
        .grapheme => graphemeBreakAt(cps, i),
        .word => wordBreakAt(cps, i),
        .sentence => sentenceBreakAt(cps, i),
    };
}

/// Index into `cps` of the code point starting at code-unit offset `cu`. A code
/// unit that lands inside an astral pair resolves to that pair's start.
fn cpIndexOfCu(cps: []const Cp, cu: u32) usize {
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        if (cu < cps[i].cu + cps[i].units) return i;
    }
    return cps.len;
}

/// The segment containing code-unit index `cu`, as a `[start, end)` code-unit
/// range. Implements FindBoundary in both directions.
pub fn segmentContaining(gran: Granularity, cps: []const Cp, total_cu: u32, cu: u32) struct { start: u32, end: u32 } {
    const i = cpIndexOfCu(cps, cu);
    if (i >= cps.len) return .{ .start = total_cu, .end = total_cu };
    var s = i;
    while (s > 0 and !breakAt(gran, cps, s)) s -= 1;
    var e = i + 1;
    while (e < cps.len and !breakAt(gran, cps, e)) e += 1;
    const end_cu: u32 = if (e >= cps.len) total_cu else cps[e].cu;
    return .{ .start = cps[s].cu, .end = end_cu };
}

/// End of the segment starting at code-unit offset `start_cu`.
pub fn segmentEndFrom(gran: Granularity, cps: []const Cp, total_cu: u32, start_cu: u32) u32 {
    const i = cpIndexOfCu(cps, start_cu);
    if (i >= cps.len) return total_cu;
    var e = i + 1;
    while (e < cps.len and !breakAt(gran, cps, e)) e += 1;
    return if (e >= cps.len) total_cu else cps[e].cu;
}

/// "Word-like" in the sense ECMA-402 leaves implementation-defined: the segment
/// carries at least one letter or digit, which is what distinguishes a word from
/// the runs of spaces and punctuation between words.
pub fn isWordLike(cps: []const Cp, start_cu: u32, end_cu: u32) bool {
    for (cps) |c| {
        if (c.cu < start_cu) continue;
        if (c.cu >= end_cu) break;
        if (prop("Alphabetic", c.cp) or prop("Nd", c.cp) or isIdeographicish(c.cp)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Intl.Segmenter
// ---------------------------------------------------------------------------

const throwTypeError = intl.throwTypeErrorIntl;
const throwRangeError = intl.throwRangeError;

fn newObj(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
    return if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto)
    else
        try JsObject.create(arena, proto);
}

/// GetOption(options, key, string, allowed, default) — reads through the active
/// context so throwing getters propagate, then ToString-coerces and validates.
fn getOption(arena: std.mem.Allocator, options: Value, key: []const u8, allowed: []const []const u8, default: ?[]const u8) anyerror!?[]const u8 {
    const v = if (realm_mod.active_context) |c|
        try c.getProp(arena, options, key)
    else if (options.bits != 0 and options.unbox() == .object)
        (options.toPtr().object.get(key) orelse Value{})
    else
        Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return default;
    const s = try t_shared.valueToString(arena, v);
    for (allowed) |a| if (std.mem.eql(u8, a, s)) return s;
    return throwRangeError(arena, "invalid option value for Intl.Segmenter");
}

/// Prototypes for the two objects `segment()` produces. They have no global
/// binding (the spec reaches them only through instances), so the realm hands
/// them to this module at registration time.
pub var segments_proto: ?*JsObject = null;
pub var segment_iterator_proto: ?*JsObject = null;

pub fn nativeSegmenterCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing)
        return throwTypeError(arena, "Constructor Intl.Segmenter requires 'new'");
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try newObj(arena, realm_mod.active_object_proto);

    try intl.resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});

    const options = try intl.dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);
    _ = try getOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const gran = (try getOption(arena, options, "granularity", &.{ "grapheme", "word", "sentence" }, "grapheme")).?;

    try obj.set("[[seg_granularity]]", try val_mod.makeString(arena, gran));
    return val_mod.makeObject(arena, obj);
}

fn segmenterGranularity(o: *JsObject) Granularity {
    const v = o.getOwn("[[seg_granularity]]") orelse return .grapheme;
    if (v.bits == 0 or v.unbox() != .string) return .grapheme;
    const s = v.unbox().string;
    if (std.mem.eql(u8, s, "word")) return .word;
    if (std.mem.eql(u8, s, "sentence")) return .sentence;
    return .grapheme;
}

fn requireSegmenter(arena: std.mem.Allocator, this_val: Value, what: []const u8) anyerror!*JsObject {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.getOwn("[[seg_granularity]]") != null) return o;
    }
    return throwTypeError(arena, what);
}

pub fn nativeSegmenterResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireSegmenter(arena, this_val, "Intl.Segmenter.prototype.resolvedOptions called on an incompatible receiver");
    const r = try newObj(arena, realm_mod.active_object_proto);
    try r.set("locale", try val_mod.makeString(arena, intl.resolvedLocaleOf(this_val)));
    try r.set("granularity", o.getOwn("[[seg_granularity]]").?);
    return val_mod.makeObject(arena, r);
}

pub fn nativeSegmenterSegment(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const seg = try requireSegmenter(arena, this_val, "Intl.Segmenter.prototype.segment called on an incompatible receiver");
    const s = try t_shared.valueToString(arena, if (args.len > 0) args[0] else Value{});
    const segments = try newObj(arena, segments_proto);
    try segments.set("[[segs_string]]", try val_mod.makeString(arena, s));
    try segments.set("[[segs_segmenter]]", try val_mod.makeObject(arena, seg));
    return val_mod.makeObject(arena, segments);
}

/// The `[[SegmentsString]]` / granularity pair behind a Segments or
/// SegmentIterator receiver.
const SegState = struct { str: []const u8, gran: Granularity };

fn segState(arena: std.mem.Allocator, this_val: Value, str_slot: []const u8, what: []const u8) anyerror!SegState {
    if (this_val.bits == 0 or this_val.unbox() != .object) return throwTypeError(arena, what);
    const o = this_val.toPtr().object;
    const sv = o.getOwn(str_slot) orelse return throwTypeError(arena, what);
    const segv = o.getOwn("[[segs_segmenter]]") orelse return throwTypeError(arena, what);
    if (sv.bits == 0 or sv.unbox() != .string or segv.bits == 0 or segv.unbox() != .object)
        return throwTypeError(arena, what);
    return .{ .str = sv.unbox().string, .gran = segmenterGranularity(segv.toPtr().object) };
}

/// CreateSegmentDataObject — `{ segment, index, input }`, plus `isWordLike` when
/// the granularity is "word". Property order is observable (the tests compare
/// `Object.getOwnPropertyNames`), so the sets below must stay in this order.
fn makeSegmentData(arena: std.mem.Allocator, st: SegState, cps: []const Cp, start: u32, end: u32) !Value {
    const r = try newObj(arena, realm_mod.active_object_proto);
    try r.set("segment", try val_mod.makeString(arena, try str_mod.cuSliceAlloc(arena, st.str, start, end)));
    try r.set("index", try val_mod.makeNumber(arena, @floatFromInt(start)));
    try r.set("input", try val_mod.makeString(arena, st.str));
    if (st.gran == .word)
        try r.set("isWordLike", try val_mod.makeBool(arena, isWordLike(cps, start, end)));
    return val_mod.makeObject(arena, r);
}

pub fn nativeSegmentsContaining(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const st = try segState(arena, this_val, "[[segs_string]]", "%Segments.prototype%.containing called on an incompatible receiver");
    const cps = try decodeAll(arena, st.str);
    const total: u32 = @intCast(str_mod.cuLen(st.str));

    // ToIntegerOrInfinity truncates *before* the range check, so `-0.49` becomes
    // +0 and selects the first segment rather than falling out of range.
    const n = try coercion.toNumberThrowing(arena, if (args.len > 0) args[0] else Value{});
    const integer: f64 = if (std.math.isNan(n)) 0 else @trunc(n);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(total)))
        return val_mod.makeUndefined(arena);
    const idx: u32 = @intFromFloat(integer);

    const r = segmentContaining(st.gran, cps, total, idx);
    return makeSegmentData(arena, st, cps, r.start, r.end);
}

pub fn nativeSegmentsIterator(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // Brand-check only; the iterator carries its own copy of the slots.
    _ = try segState(arena, this_val, "[[segs_string]]", "%Segments.prototype%[Symbol.iterator] called on an incompatible receiver");
    const o = this_val.toPtr().object;
    const it = try newObj(arena, segment_iterator_proto);
    try it.set("[[segit_string]]", o.getOwn("[[segs_string]]").?);
    try it.set("[[segs_segmenter]]", o.getOwn("[[segs_segmenter]]").?);
    try it.set("[[segit_index]]", try val_mod.makeNumber(arena, 0));
    return val_mod.makeObject(arena, it);
}

pub fn nativeSegmentIteratorNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const st = try segState(arena, this_val, "[[segit_string]]", "%SegmentIterator.prototype%.next called on an incompatible receiver");
    const o = this_val.toPtr().object;
    const cps = try decodeAll(arena, st.str);
    const total: u32 = @intCast(str_mod.cuLen(st.str));
    const start: u32 = blk: {
        const v = o.getOwn("[[segit_index]]") orelse break :blk 0;
        if (v.bits == 0 or v.unbox() != .number) break :blk 0;
        break :blk @intFromFloat(v.unbox().number);
    };
    const res = try newObj(arena, realm_mod.active_object_proto);
    if (start >= total) {
        try res.set("value", Value{});
        try res.set("done", try val_mod.makeBool(arena, true));
        return val_mod.makeObject(arena, res);
    }
    const end = segmentEndFrom(st.gran, cps, total, start);
    try o.set("[[segit_index]]", try val_mod.makeNumber(arena, @floatFromInt(end)));
    try res.set("value", try makeSegmentData(arena, st, cps, start, end));
    try res.set("done", try val_mod.makeBool(arena, false));
    return val_mod.makeObject(arena, res);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Split `s` into segments, returning each segment's `[start,end)` code units.
fn testSegments(arena: std.mem.Allocator, gran: Granularity, s: []const u8) ![]const [2]u32 {
    const cps = try decodeAll(arena, s);
    const total: u32 = @intCast(str_mod.cuLen(s));
    var out = std.ArrayListUnmanaged([2]u32){};
    var pos: u32 = 0;
    while (pos < total) {
        const end = segmentEndFrom(gran, cps, total, pos);
        try out.append(arena, .{ pos, end });
        pos = end;
    }
    return out.items;
}

test "segmenter: grapheme clusters keep combining sequences together" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Each of these is exactly one extended grapheme cluster.
    const unbreakable = [_][]const u8{
        "a",
        "\u{0301}", // lone combining acute
        "a\u{0301}", // ASCII + combining acute
        "\u{0E0B}\u{0E34}\u{0E48}", // Thai cluster
        "\u{10000}", // astral (surrogate pair)
        "\u{1F44B}\u{1F3FB}", // waving hand + skin tone
        "\u{1F468}\u{1F3FB}\u{200D}\u{1F9B0}", // man + skin tone + ZWJ + red hair
        "\u{1102}\u{1162}\u{11A9}", // Jamo LVT
        "\u{AC00}", // precomposed Hangul syllable
    };
    for (unbreakable) |s| {
        const segs = try testSegments(a, .grapheme, s);
        try testing.expectEqual(@as(usize, 1), segs.len);
    }

    // …and each of these is two.
    const breakable = [_][]const u8{ "a ", " a", "\u{0301} ", " \u{10000}", "\u{10000} " };
    for (breakable) |s| {
        const segs = try testSegments(a, .grapheme, s);
        try testing.expectEqual(@as(usize, 2), segs.len);
    }
}

test "segmenter: regional indicators pair up into flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Two flags: US then GB — four regional indicators, two clusters.
    const segs = try testSegments(a, .grapheme, "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}");
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expectEqual(@as(u32, 4), segs[1][0]);
}

test "segmenter: word boundaries split on spaces and punctuation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // "a c" → "a", " ", "c" (the test262 containing/one-index expectation).
    const segs = try testSegments(a, .word, "a c");
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expectEqual([2]u32{ 1, 2 }, segs[1]);

    // "Hello world!" → Hello / space / world / !
    const hw = try testSegments(a, .word, "Hello world!");
    try testing.expectEqual(@as(usize, 4), hw.len);

    // Decimals and thousands separators stay inside the number (WB11/WB12).
    const num = try testSegments(a, .word, "3.14");
    try testing.expectEqual(@as(usize, 1), num.len);
}

test "segmenter: isWordLike distinguishes words from separators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = "Hi there!";
    const cps = try decodeAll(a, s);
    try testing.expect(isWordLike(cps, 0, 2)); // "Hi"
    try testing.expect(!isWordLike(cps, 2, 3)); // " "
    try testing.expect(!isWordLike(cps, 8, 9)); // "!"
}

test "segmenter: sentences break after terminators but not abbreviations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(@as(usize, 1), (try testSegments(a, .sentence, "a b c")).len);
    try testing.expectEqual(@as(usize, 2), (try testSegments(a, .sentence, "Hello world! Foo bar.")).len);
    // SB8: a lowercase continuation means the period was not a sentence end.
    try testing.expectEqual(@as(usize, 1), (try testSegments(a, .sentence, "e.g. this")).len);
}

test "segmenter: every granularity partitions the input exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const inputs = [_][]const u8{
        "Hello world!",
        " Hello world? Foo bar!",
        "Jedovatou mambu objevila žena v zahrádkářské kolonii.",
        "台北》抹黑柯P失敗？朱學恒酸：姚文智氣pupu嗆大老闆",
        "九州北部の一部が暴風域に入りました(日直予報士 2018年10月06日)",
        "법원 “다스 지분 처분권·수익권 모두 MB가 보유”",
        "\u{1F468}\u{1F3FB}\u{200D}\u{1F9B0} waves",
    };
    for ([_]Granularity{ .grapheme, .word, .sentence }) |gran| {
        for (inputs) |s| {
            const total: u32 = @intCast(str_mod.cuLen(s));
            const segs = try testSegments(a, gran, s);
            try testing.expect(segs.len > 0);
            try testing.expectEqual(@as(u32, 0), segs[0][0]);
            try testing.expectEqual(total, segs[segs.len - 1][1]);
            for (segs) |seg| try testing.expect(seg[1] > seg[0]); // no empty segments
            for (segs[1..], 0..) |seg, i| try testing.expectEqual(segs[i][1], seg[0]); // contiguous
        }
    }
}

test "segmenter: containing finds the segment around any index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const s = "a c";
    const cps = try decodeAll(a, s);
    const total: u32 = @intCast(str_mod.cuLen(s));
    const mid = segmentContaining(.word, cps, total, 1);
    try testing.expectEqual(@as(u32, 1), mid.start);
    try testing.expectEqual(@as(u32, 2), mid.end);

    // A single unbreakable cluster: every index maps to the whole string.
    const emoji = "\u{1F468}\u{1F3FB}\u{200D}\u{1F9B0}";
    const ecps = try decodeAll(a, emoji);
    const etotal: u32 = @intCast(str_mod.cuLen(emoji));
    var i: u32 = 0;
    while (i < etotal) : (i += 1) {
        const r = segmentContaining(.grapheme, ecps, etotal, i);
        try testing.expectEqual(@as(u32, 0), r.start);
        try testing.expectEqual(etotal, r.end);
    }
}
