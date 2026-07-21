// SPDX-License-Identifier: Apache-2.0
//! `Intl.Segmenter` (ECMA-402 §18) — grapheme / word / sentence segmentation.
//!
//! The boundary rules are a dependency-free approximation of UAX #29 built on
//! the general-category tables already shipped for RegExp `\p{…}`: grapheme
//! clusters keep surrogate pairs, combining marks, CRLF, Hangul jamo and
//! regional-indicator pairs together; word breaks group letter/digit runs,
//! whitespace runs and Katakana runs, and treat each ideograph as its own
//! segment; sentence breaks split after terminator punctuation plus trailing
//! closers and spaces. No dictionary-based segmentation (Thai, Lao, Khmer) —
//! those languages segment at the same granularity as their letter runs.
//!
//! Everything is indexed in UTF-16 code units, matching the spec's
//! [[IteratedStringNextSegmentCodeUnitIndex]] and `containing(index)`, even
//! though strings are stored as WTF-8 (see string_proto's `cu*` helpers).
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const object_mod = @import("../../object/object.zig");
const JsObject = object_mod.JsObject;
const PropAttr = object_mod.PropAttr;
const realm_mod = @import("../realm.zig");
const intl_mod = @import("intl.zig");
const string_proto = @import("string_proto.zig");
const utab = @import("unicode_tables.zig");

// ------------------------------------------------------------------ slot keys ---
// `[[`-prefixed keys are hidden from every reflection path (see
// JsObject.isInternalSlotKey), so instances expose no extra own properties.
const SLOT_LOCALE = "[[SegmenterLocale]]";
const SLOT_GRANULARITY = "[[SegmenterGranularity]]";
const SLOT_SEGMENTER = "[[SegmentsSegmenter]]";
const SLOT_STRING = "[[SegmentsString]]";
const SLOT_INDEX = "[[SegmentIteratorIndex]]";

/// %Segments.prototype% and %SegmentIterator.prototype% are not reachable from
/// any global, so the realm keeps them here for `segment()` / `@@iterator`.
pub var active_segments_proto: ?*JsObject = null;
pub var active_segment_iter_proto: ?*JsObject = null;

fn newObj(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
    if (realm_mod.active_heap) |h| return JsObject.createOnHeap(h, proto);
    return JsObject.create(arena, proto);
}

// -------------------------------------------------------------- code point scan ---

const CodePoint = struct {
    cp: u21,
    /// Code-unit offset of this code point within the string.
    cu: usize,
    /// 1, or 2 for a supplementary-plane code point (a surrogate pair).
    units: usize,
};

/// Decode `s` (WTF-8) into code points tagged with their UTF-16 offsets.
fn scan(arena: std.mem.Allocator, s: []const u8) ![]CodePoint {
    var out = std.ArrayListUnmanaged(CodePoint){};
    var i: usize = 0;
    var cu: usize = 0;
    while (i < s.len) {
        var d = string_proto.decodeWtf8At(s, i);
        var len = d.len;
        // A supplementary code point can be stored either as one 4-byte UTF-8
        // sequence or (when it came from a `😀`-style literal) as two
        // WTF-8-encoded surrogates. Recombine the latter so both spellings
        // segment identically.
        if (d.cp >= 0xD800 and d.cp <= 0xDBFF and i + d.len < s.len) {
            const lo = string_proto.decodeWtf8At(s, i + d.len);
            if (lo.cp >= 0xDC00 and lo.cp <= 0xDFFF) {
                d.cp = 0x10000 + ((d.cp - 0xD800) << 10) + (lo.cp - 0xDC00);
                len += lo.len;
            }
        }
        const units: usize = if (d.cp > 0xFFFF) 2 else 1;
        try out.append(arena, .{ .cp = d.cp, .cu = cu, .units = units });
        i += len;
        cu += units;
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

// ------------------------------------------------------------- character classes ---

fn isExtend(cp: u21) bool {
    // Grapheme_Extend ≈ the Mark categories, plus the two zero-width joiners
    // (Cf) and the emoji skin-tone modifiers (Sk) — neither is a Mark, but both
    // carry GCB=Extend and must stay attached to the preceding character.
    if (cp == 0x200D or cp == 0x200C) return true;
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true;
    return inTable(utab.unicode_M, cp);
}

fn isControlBreak(cp: u21) bool {
    // GB4/GB5: Control | CR | LF always break on both sides. Line/paragraph
    // separators and the C0/C1 controls qualify; TAB does not (it is
    // whitespace, handled by the word rules).
    return switch (cp) {
        0x0A, 0x0D, 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F, 0x2028, 0x2029 => true,
        else => false,
    };
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

const Hangul = enum { none, l, v, t, lv, lvt };

fn hangulKind(cp: u21) Hangul {
    if (cp >= 0x1100 and cp <= 0x115F) return .l;
    if (cp >= 0x1160 and cp <= 0x11A7) return .v;
    if (cp >= 0x11A8 and cp <= 0x11FF) return .t;
    if (cp >= 0xAC00 and cp <= 0xD7A3) {
        return if ((cp - 0xAC00) % 28 == 0) .lv else .lvt;
    }
    return .none;
}

/// Ideographic / syllabic scripts ICU segments without word boundaries between
/// adjacent characters. Each such code point is its own word segment (Katakana
/// runs excepted — see `isKatakana`).
fn isIdeographic(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x4DBF) or // CJK ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK unified
        (cp >= 0xF900 and cp <= 0xFAFF) or // compatibility ideographs
        (cp >= 0x20000 and cp <= 0x3FFFF) or // CJK ext B+
        (cp >= 0x3040 and cp <= 0x309F); // Hiragana
}

fn isKatakana(cp: u21) bool {
    return (cp >= 0x30A0 and cp <= 0x30FF) or (cp >= 0xFF66 and cp <= 0xFF9F);
}

fn isWordChar(cp: u21) bool {
    if (cp == '_') return true;
    return inTable(utab.unicode_L, cp) or inTable(utab.unicode_N, cp);
}

fn isSpaceChar(cp: u21) bool {
    return cp == 0x09 or inTable(utab.unicode_Z, cp);
}

/// WB6/WB7 — MidLetter and MidNumLet: punctuation that does not break a word
/// when it sits between two *letters*.
fn isMidLetter(cp: u21) bool {
    return switch (cp) {
        '\'', '.', ':', 0x00B7, 0x0387, 0x05F4, 0x2018, 0x2019, 0x2027, 0x00A0 => true,
        else => false,
    };
}

/// WB11/WB12 — MidNum and MidNumLet: punctuation that does not break a number
/// when it sits between two *digits* (`1,000`, `1.23`).
fn isMidNum(cp: u21) bool {
    return switch (cp) {
        ',', ';', '.', ':', '\'', 0x037E, 0x0589, 0x060C, 0x066C, 0x2018, 0x2019, 0x00A0 => true,
        else => false,
    };
}

fn isDigit(cp: u21) bool {
    return inTable(utab.unicode_N, cp);
}

/// A plain letter/digit word character — ideographs and Katakana are segmented
/// by their own rules, so they are excluded here.
fn isPlainWordChar(cp: u21) bool {
    return isWordChar(cp) and !isIdeographic(cp) and !isKatakana(cp);
}

/// Advance past the Extend run after `cps[i - 1]`, following WB3c (ZWJ never
/// breaks before the pictograph it joins) as far as the run continues.
fn skipExtend(cps: []const CodePoint, i: *usize) void {
    while (i.* < cps.len) {
        if (isExtend(cps[i.*].cp)) {
            const was_zwj = cps[i.*].cp == 0x200D;
            i.* += 1;
            if (was_zwj and i.* < cps.len) i.* += 1; // ZWJ x Extended_Pictographic
        } else break;
    }
}

fn isSentenceTerminator(cp: u21) bool {
    return switch (cp) {
        '.', '!', '?', 0x2026, 0x3002, 0xFF01, 0xFF0E, 0xFF1F, 0x0964, 0x0965 => true,
        else => false,
    };
}

fn isSentenceCloser(cp: u21) bool {
    return switch (cp) {
        ')', ']', '}', '"', '\'', 0x201D, 0x2019, 0x300D, 0x300F, 0xFF09 => true,
        else => false,
    };
}

// ---------------------------------------------------------------- boundary rules ---

const Granularity = enum { grapheme, word, sentence };

/// A segment expressed in code-unit offsets, plus its word-likeness (only
/// meaningful for `word` granularity).
const Segment = struct { start: usize, end: usize, word_like: bool };

/// True when a grapheme cluster boundary falls between `cps[i-1]` and `cps[i]`.
fn graphemeBreak(cps: []const CodePoint, i: usize) bool {
    const prev = cps[i - 1].cp;
    const cur = cps[i].cp;
    if (prev == 0x0D and cur == 0x0A) return false; // GB3
    if (isControlBreak(prev) or isControlBreak(cur)) return true; // GB4/GB5
    if (isExtend(cur)) return false; // GB9 (+GB9a: SpacingMark is in M)
    if (prev == 0x200D) return false; // GB11 (approximated: ZWJ never breaks)
    const hp = hangulKind(prev);
    const hc = hangulKind(cur);
    if (hp == .l and (hc == .l or hc == .v or hc == .lv or hc == .lvt)) return false; // GB6
    if ((hp == .lv or hp == .v) and (hc == .v or hc == .t)) return false; // GB7
    if ((hp == .lvt or hp == .t) and hc == .t) return false; // GB8
    if (isRegionalIndicator(prev) and isRegionalIndicator(cur)) {
        // GB12/GB13: join only into *pairs* — count the unbroken RI run behind.
        var run: usize = 0;
        var k = i;
        while (k > 0 and isRegionalIndicator(cps[k - 1].cp)) : (k -= 1) run += 1;
        return run % 2 == 0;
    }
    return true;
}

fn graphemeSegments(arena: std.mem.Allocator, cps: []const CodePoint, total_cu: usize) ![]Segment {
    var out = std.ArrayListUnmanaged(Segment){};
    if (cps.len == 0) return out.items;
    var start: usize = 0;
    var i: usize = 1;
    while (i < cps.len) : (i += 1) {
        if (!graphemeBreak(cps, i)) continue;
        try out.append(arena, .{ .start = cps[start].cu, .end = cps[i].cu, .word_like = false });
        start = i;
    }
    try out.append(arena, .{ .start = cps[start].cu, .end = total_cu, .word_like = false });
    return out.items;
}

fn wordSegments(arena: std.mem.Allocator, cps: []const CodePoint, total_cu: usize) ![]Segment {
    var out = std.ArrayListUnmanaged(Segment){};
    var i: usize = 0;
    while (i < cps.len) {
        const start = i;
        const cp = cps[i].cp;
        var word_like = false;
        if (isPlainWordChar(cp)) {
            // WB5/WB8/WB9/WB10: a run of letters and digits, with MidLetter /
            // MidNum punctuation swallowed only between two of the same kind.
            word_like = true;
            i += 1;
            skipExtend(cps, &i);
            while (i < cps.len) {
                const c = cps[i].cp;
                if (isPlainWordChar(c)) {
                    i += 1;
                    skipExtend(cps, &i);
                    continue;
                }
                if (i + 1 >= cps.len or !isPlainWordChar(cps[i + 1].cp)) break;
                const prev = cps[i - 1].cp;
                const next = cps[i + 1].cp;
                const joins = if (isDigit(prev) and isDigit(next)) isMidNum(c) else isMidLetter(c);
                if (!joins) break;
                i += 2;
                skipExtend(cps, &i);
            }
        } else if (isKatakana(cp)) {
            word_like = true; // WB13: Katakana x Katakana
            i += 1;
            skipExtend(cps, &i);
            while (i < cps.len and isKatakana(cps[i].cp)) {
                i += 1;
                skipExtend(cps, &i);
            }
        } else if (isIdeographic(cp)) {
            word_like = true; // one ideograph per segment (no dictionary data)
            i += 1;
            skipExtend(cps, &i);
        } else if (isSpaceChar(cp)) {
            i += 1; // WB3d: WSegSpace x WSegSpace
            skipExtend(cps, &i);
            while (i < cps.len and isSpaceChar(cps[i].cp)) {
                i += 1;
                skipExtend(cps, &i);
            }
        } else {
            // Everything else (punctuation, symbols, emoji, lone surrogates, a
            // leading combining mark) is a single non-word-like segment.
            i += 1;
            skipExtend(cps, &i);
        }
        const end = if (i < cps.len) cps[i].cu else total_cu;
        try out.append(arena, .{ .start = cps[start].cu, .end = end, .word_like = word_like });
    }
    return out.items;
}

fn sentenceSegments(arena: std.mem.Allocator, cps: []const CodePoint, total_cu: usize) ![]Segment {
    var out = std.ArrayListUnmanaged(Segment){};
    var start: usize = 0;
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const cp = cps[i].cp;
        var brk = false;
        if (cp == 0x0A or cp == 0x2028 or cp == 0x2029) {
            brk = true;
        } else if (cp == 0x0D) {
            if (i + 1 < cps.len and cps[i + 1].cp == 0x0A) i += 1;
            brk = true;
        } else if (isSentenceTerminator(cp)) {
            // SB11: consume trailing closers, then the space run that separates
            // this sentence from the next. A terminator at end-of-string just
            // closes the final segment.
            var j = i + 1;
            while (j < cps.len and (isSentenceCloser(cps[j].cp) or isExtend(cps[j].cp))) : (j += 1) {}
            var k = j;
            while (k < cps.len and isSpaceChar(cps[k].cp)) : (k += 1) {}
            if (k > j or k >= cps.len) {
                i = k - 1;
                brk = true;
            }
        }
        if (brk) {
            const end = if (i + 1 < cps.len) cps[i + 1].cu else total_cu;
            try out.append(arena, .{ .start = cps[start].cu, .end = end, .word_like = false });
            start = i + 1;
        }
    }
    if (start < cps.len) {
        try out.append(arena, .{ .start = cps[start].cu, .end = total_cu, .word_like = false });
    }
    return out.items;
}

fn segmentsOf(arena: std.mem.Allocator, s: []const u8, g: Granularity) ![]Segment {
    const cps = try scan(arena, s);
    const total = string_proto.cuLen(s);
    return switch (g) {
        .grapheme => graphemeSegments(arena, cps, total),
        .word => wordSegments(arena, cps, total),
        .sentence => sentenceSegments(arena, cps, total),
    };
}

// -------------------------------------------------------------------- helpers ---

fn slotStr(o: *JsObject, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() != .string) return null;
    return v.unbox().string;
}

fn granularityOf(o: *JsObject) Granularity {
    const s = slotStr(o, SLOT_GRANULARITY) orelse "grapheme";
    if (std.mem.eql(u8, s, "word")) return .word;
    if (std.mem.eql(u8, s, "sentence")) return .sentence;
    return .grapheme;
}

/// Brand check: `this` must be an object carrying `slot`.
fn brand(arena: std.mem.Allocator, this_val: Value, slot: []const u8, what: []const u8) anyerror!*JsObject {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get(slot) != null) return o;
    }
    return intl_mod.throwTypeErrorIntl(arena, what);
}

/// ECMA-402 GetOption(options, key, "string", values, fallback) — a [[Get]] (so
/// accessors run), ToString on a present value, RangeError when it is not in
/// `values`. Returns `fallback` when the property is absent or undefined.
fn getStringOption(
    arena: std.mem.Allocator,
    options: Value,
    key: []const u8,
    values: []const []const u8,
    fallback: []const u8,
) anyerror![]const u8 {
    if (options.bits == 0 or options.unbox() != .object) return fallback;
    const ctx = realm_mod.active_context orelse return fallback;
    const v = try ctx.getProp(arena, options, key);
    if (v.bits == 0 or v.unbox() == .undefined_) return fallback;
    if (v.unbox() == .symbol)
        return intl_mod.throwTypeErrorIntl(arena, "Cannot convert a Symbol value to a string");
    const s = try realm_mod.stringPrimitive(arena, v);
    for (values) |a| if (std.mem.eql(u8, a, s)) return a;
    return intl_mod.throwRangeError(arena, "value out of range for Intl.Segmenter options property");
}

/// Build the `{ segment, index, input[, isWordLike] }` result object, in the
/// property order CreateSegmentDataObject defines.
fn segmentData(
    arena: std.mem.Allocator,
    s: []const u8,
    seg: Segment,
    granularity: Granularity,
) !Value {
    const r = try newObj(arena, realm_mod.active_object_proto);
    try r.set("segment", try val_mod.makeString(arena, try string_proto.cuSliceAlloc(arena, s, seg.start, seg.end)));
    try r.set("index", try val_mod.makeNumber(arena, @floatFromInt(seg.start)));
    try r.set("input", try val_mod.makeString(arena, s));
    if (granularity == .word) try r.set("isWordLike", try val_mod.makeBool(arena, seg.word_like));
    return val_mod.makeObject(arena, r);
}

// ---------------------------------------------------------------- Intl.Segmenter ---

pub fn nativeSegmenterCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing)
        return intl_mod.throwTypeErrorIntl(arena, "Constructor Intl.Segmenter requires 'new'");

    const requested = try intl_mod.canonicalizeLocaleList(arena, if (args.len > 0) args[0] else Value{});

    // GetOptionsObject: undefined → an empty options bag; any non-object is a
    // TypeError (including null, which ToObject would also reject).
    const options: Value = if (args.len > 1) args[1] else Value{};
    if (options.bits != 0 and options.unbox() != .undefined_ and options.unbox() != .object)
        return intl_mod.throwTypeErrorIntl(arena, "Intl.Segmenter options must be an object");

    // Order matters: localeMatcher is read (and coerced) before granularity.
    _ = try getStringOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const granularity = try getStringOption(arena, options, "granularity", &.{ "grapheme", "word", "sentence" }, "grapheme");

    // ResolveLocale: every requested tag is validated (RangeError on a
    // malformed one), and the first whose language this implementation has data
    // for wins. An empty list — or one of only unknown languages — falls back to
    // the default locale.
    var locale: []const u8 = "en-US";
    var found = false;
    for (requested) |t| {
        const canon = try intl_mod.canonicalizeTag(arena, t);
        if (found or !intl_mod.languageAvailable(canon)) continue;
        locale = canon;
        found = true;
    }

    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try newObj(arena, realm_mod.active_object_proto);
    try obj.set(SLOT_LOCALE, try val_mod.makeString(arena, locale));
    try obj.set(SLOT_GRANULARITY, try val_mod.makeString(arena, granularity));
    return val_mod.makeObject(arena, obj);
}

pub fn nativeSegmenterResolvedOptions(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try brand(arena, this_val, SLOT_GRANULARITY, "Intl.Segmenter.prototype.resolvedOptions called on incompatible receiver");
    const r = try newObj(arena, realm_mod.active_object_proto);
    try r.set("locale", try val_mod.makeString(arena, slotStr(o, SLOT_LOCALE) orelse "en-US"));
    try r.set("granularity", try val_mod.makeString(arena, slotStr(o, SLOT_GRANULARITY) orelse "grapheme"));
    return val_mod.makeObject(arena, r);
}

pub fn nativeSegmenterSegment(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try brand(arena, this_val, SLOT_GRANULARITY, "Intl.Segmenter.prototype.segment called on incompatible receiver");
    const arg: Value = if (args.len > 0) args[0] else Value{};
    if (arg.bits != 0 and arg.unbox() == .symbol)
        return intl_mod.throwTypeErrorIntl(arena, "Cannot convert a Symbol value to a string");
    const s = try realm_mod.stringPrimitive(arena, arg);

    const segments = try newObj(arena, active_segments_proto orelse realm_mod.active_object_proto);
    try segments.set(SLOT_SEGMENTER, this_val);
    try segments.set(SLOT_STRING, try val_mod.makeString(arena, s));
    return val_mod.makeObject(arena, segments);
}

// ------------------------------------------------------------- %Segments.prototype% ---

pub fn nativeSegmentsContaining(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const o = try brand(arena, this_val, SLOT_STRING, "%Segments.prototype%.containing called on incompatible receiver");
    const s = slotStr(o, SLOT_STRING) orelse "";
    const seg_v = o.get(SLOT_SEGMENTER) orelse Value{};
    const granularity = if (seg_v.bits != 0 and seg_v.unbox() == .object)
        granularityOf(seg_v.toPtr().object)
    else
        .grapheme;

    const idx_v: Value = if (args.len > 0) args[0] else Value{};
    // ToIntegerOrInfinity → ToNumber: Symbol and BigInt are TypeErrors, and
    // must be rejected before the out-of-bounds check swallows them.
    if (idx_v.bits != 0 and (idx_v.unbox() == .symbol or idx_v.unbox() == .bigint))
        return intl_mod.throwTypeErrorIntl(arena, "Cannot convert value to a number");
    const n = try realm_mod.toNumberValue(arena, idx_v);
    const len: f64 = @floatFromInt(string_proto.cuLen(s));
    const i = if (std.math.isNan(n)) 0 else std.math.trunc(n);
    if (i < 0 or i >= len) return val_mod.makeUndefined(arena);

    const target: usize = @intFromFloat(i);
    for (try segmentsOf(arena, s, granularity)) |seg| {
        if (target >= seg.start and target < seg.end) return segmentData(arena, s, seg, granularity);
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeSegmentsIterator(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try brand(arena, this_val, SLOT_STRING, "%Segments.prototype%[Symbol.iterator] called on incompatible receiver");
    const it = try newObj(arena, active_segment_iter_proto orelse realm_mod.active_object_proto);
    try it.set(SLOT_SEGMENTER, o.get(SLOT_SEGMENTER) orelse Value{});
    try it.set(SLOT_STRING, o.get(SLOT_STRING) orelse try val_mod.makeString(arena, ""));
    try it.set(SLOT_INDEX, try val_mod.makeNumber(arena, 0));
    return val_mod.makeObject(arena, it);
}

// -------------------------------------------------------- %SegmentIterator.prototype% ---

pub fn nativeSegmentIteratorNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try brand(arena, this_val, SLOT_INDEX, "%SegmentIterator.prototype%.next called on incompatible receiver");
    const s = slotStr(o, SLOT_STRING) orelse "";
    const seg_v = o.get(SLOT_SEGMENTER) orelse Value{};
    const granularity = if (seg_v.bits != 0 and seg_v.unbox() == .object)
        granularityOf(seg_v.toPtr().object)
    else
        .grapheme;

    const idx_v = o.get(SLOT_INDEX) orelse Value{};
    const start: usize = if (idx_v.bits != 0 and idx_v.unbox() == .number)
        @intFromFloat(@max(0, idx_v.unbox().number))
    else
        0;

    const result = try newObj(arena, realm_mod.active_object_proto);
    // The spec re-runs FindBoundary from the stored index, so the iterator's
    // position is the only state — nested loops over the same Segments object
    // (each with its own iterator) never interfere.
    for (try segmentsOf(arena, s, granularity)) |seg| {
        if (seg.start != start) continue;
        try o.set(SLOT_INDEX, try val_mod.makeNumber(arena, @floatFromInt(seg.end)));
        try result.set("value", try segmentData(arena, s, seg, granularity));
        try result.set("done", try val_mod.makeBool(arena, false));
        return val_mod.makeObject(arena, result);
    }
    try result.set("value", try val_mod.makeUndefined(arena));
    try result.set("done", try val_mod.makeBool(arena, true));
    return val_mod.makeObject(arena, result);
}

// ------------------------------------------------------------------- registration ---

/// Install `Intl.Segmenter` on `intl_obj`, plus the two hidden prototypes.
/// `iterator_proto` is %IteratorPrototype% (%SegmentIterator.prototype% inherits
/// from it so segment iterators get the iterator helpers and @@iterator).
pub fn register(
    arena: std.mem.Allocator,
    intl_obj: *JsObject,
    object_proto: ?*JsObject,
    function_proto: ?*JsObject,
    iterator_proto: ?*JsObject,
) !void {
    const cfg: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    const tag_cfg: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };

    // %Segments.prototype% — reachable only through `segment()`.
    const segments_proto = try JsObject.create(arena, object_proto);
    _ = try segments_proto.defineOwnData("containing", try val_mod.makeNativeFunctionNamed(arena, nativeSegmentsContaining, "containing", 1), cfg);
    if (realm_mod.active_sym_iterator) |sym|
        try segments_proto.setSymAttr(sym, try val_mod.makeNativeFunctionNamed(arena, nativeSegmentsIterator, "[Symbol.iterator]", 0), cfg);
    active_segments_proto = segments_proto;

    // %SegmentIterator.prototype% — a sibling of %ArrayIteratorPrototype%.
    const iter_proto = try JsObject.create(arena, iterator_proto orelse object_proto);
    _ = try iter_proto.defineOwnData("next", try val_mod.makeNativeFunctionNamed(arena, nativeSegmentIteratorNext, "next", 0), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try iter_proto.setSymAttr(tag, try val_mod.makeString(arena, "Segmenter String Iterator"), tag_cfg);
    active_segment_iter_proto = iter_proto;

    // Intl.Segmenter itself.
    const proto = try JsObject.create(arena, object_proto);
    _ = try proto.defineOwnData("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, nativeSegmenterResolvedOptions, "resolvedOptions", 0), cfg);
    _ = try proto.defineOwnData("segment", try val_mod.makeNativeFunctionNamed(arena, nativeSegmenterSegment, "segment", 1), cfg);
    if (realm_mod.active_sym_to_string_tag) |tag|
        try proto.setSymAttr(tag, try val_mod.makeString(arena, "Intl.Segmenter"), tag_cfg);

    const ctor = try JsObject.create(arena, function_proto);
    try ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeSegmenterCtor));
    _ = try ctor.defineOwnData("prototype", try val_mod.makeObject(arena, proto), .{ .writable = false, .enumerable = false, .configurable = false });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), cfg);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "Segmenter"), tag_cfg);
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), tag_cfg);
    _ = try ctor.defineOwnData("supportedLocalesOf", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDurationFormatSupportedLocalesOf, "supportedLocalesOf", 1), cfg);
    _ = try intl_obj.defineOwnData("Segmenter", try val_mod.makeObject(arena, ctor), cfg);
}
