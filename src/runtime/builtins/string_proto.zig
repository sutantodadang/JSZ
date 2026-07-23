// SPDX-License-Identifier: Apache-2.0
//! Phase 4b/4c/4d: String.prototype native functions.
//! All operate on the string `this` value (first arg = this_val).
//! No mutation — all return new strings or numbers.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const regexp_mod = @import("./regexp.zig");
const function_proto_mod = @import("./function_proto.zig");
const realm_mod = @import("../realm.zig");
const coercion_mod = @import("./coercion.zig");
const unorm = @import("unicode_normalize.zig");
const ucase = @import("unicode_case_tables.zig");
const uprops = @import("unicode_prop_tables.zig");

/// Throw a TypeError with `msg` and return error.JsException.
/// Used by coerceThis for null/undefined/Symbol receivers.
fn throwTypeErrorStr(arena: std.mem.Allocator, msg: []const u8) anyerror![]const u8 {
    const JsObject = @import("../../object/object.zig").JsObject;
    const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

fn throwRangeErrorStr(arena: std.mem.Allocator, msg: []const u8) anyerror![]const u8 {
    const JsObject = @import("../../object/object.zig").JsObject;
    const obj = try JsObject.create(arena, realm_mod.error_proto_RangeError);
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// RequireObjectCoercible + ToString for the `this` receiver of String.prototype
/// methods (ES2024 22.1.3 preamble).
/// - null / undefined  → TypeError
/// - string            → the slice as-is
/// - number            → ES Number::toString (handles NaN, ±Infinity, -0 → "0")
/// - boolean           → "true" / "false"
/// - bigint            → decimal string
/// - symbol            → TypeError ("Cannot convert a Symbol value to a string")
/// - object            → ToPrimitive(hint: string) then re-stringify; falls back
///                       to "[object Object]" when toPrimitive returns null/object
fn coerceThis(arena: std.mem.Allocator, this_val: Value) anyerror![]const u8 {
    if (this_val.bits == 0) return throwTypeErrorStr(arena, "String.prototype method called on null or undefined");
    switch (this_val.unbox()) {
        .undefined_, .null_ => return throwTypeErrorStr(arena, "String.prototype method called on null or undefined"),
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .bigint => |bi| return try val_mod.bigIntToString(arena, bi),
        .symbol => return throwTypeErrorStr(arena, "Cannot convert a Symbol value to a string"),
        .object => {
            const prim_maybe = try coercion_mod.toPrimitive(arena, this_val, .string);
            if (prim_maybe) |prim| {
                if (coercion_mod.isPrimitive(prim)) {
                    return try coerceThis(arena, prim);
                }
            }
            // ToPrimitive could not produce a primitive (toString/valueOf/
            // @@toPrimitive all non-callable) → ToString throws TypeError.
            return throwTypeErrorStr(arena, "Cannot convert object to primitive value");
        },
        // Callable receivers: ToString goes through the full ToPrimitive(string),
        // trying "toString" then "valueOf" (with the callable itself as `this`, so
        // Function.prototype.toString's brand check passes). A toString that
        // returns a non-primitive must fall through to valueOf, not throw.
        .function, .bc_function, .native_function => {
            const prim_maybe = try coercion_mod.toPrimitive(arena, this_val, .string);
            if (prim_maybe) |prim| {
                if (coercion_mod.isPrimitive(prim)) return try coerceThis(arena, prim);
            }
            return throwTypeErrorStr(arena, "Cannot convert object to primitive value");
        },
    }
}

/// ES ToString applied to an argument (not the receiver): undefined → "undefined",
/// null → "null", symbol → TypeError, object → ToPrimitive(string) then stringify.
fn argToString(arena: std.mem.Allocator, v: Value) anyerror![]const u8 {
    if (v.bits == 0) return "undefined";
    switch (v.unbox()) {
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .null_ => return "null",
        .undefined_ => return "undefined",
        .bigint => |bi| return try val_mod.bigIntToString(arena, bi),
        .symbol => {
            _ = try throwTypeErrorStr(arena, "Cannot convert a Symbol value to a string");
            unreachable;
        },
        .object, .function, .bc_function, .native_function => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .string)) orelse return "[object Object]";
            if (!coercion_mod.isPrimitive(prim)) return "[object Object]";
            return argToString(arena, prim);
        },
    }
}

/// ES ToNumber that throws TypeError for Symbol / BigInt (unlike the VM's lenient
/// toNumberValue which returns NaN). Used by string-method argument coercion.
fn toNumberChecked(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    // Spec ToNumber: an object with no callable valueOf/toString is a TypeError,
    // not a silent NaN, and a Symbol/BigInt argument throws.
    return coercion_mod.toNumberThrowing(arena, v);
}

/// ES ToIntegerOrInfinity: ToNumber then NaN → 0, ±Infinity preserved, else trunc.
fn argToInteger(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    const n = try toNumberChecked(arena, v);
    if (std.math.isNan(n)) return 0;
    if (std.math.isInf(n)) return n;
    return std.math.trunc(n);
}

/// Clamp an ES ToIntegerOrInfinity result to a byte offset in [0, len].
fn clampToLen(pos: f64, len: usize) usize {
    if (pos <= 0) return 0;
    const flen: f64 = @floatFromInt(len);
    if (pos >= flen) return len;
    return @intFromFloat(pos);
}

/// ES RequireObjectCoercible: TypeError for null / undefined receivers.
fn requireObjectCoercible(arena: std.mem.Allocator, v: Value) anyerror!void {
    if (v.bits == 0) {
        _ = try throwTypeErrorStr(arena, "String.prototype method called on null or undefined");
        unreachable;
    }
    switch (v.unbox()) {
        .undefined_, .null_ => {
            _ = try throwTypeErrorStr(arena, "String.prototype method called on null or undefined");
            unreachable;
        },
        else => {},
    }
}

/// ES GetMethod(v, symKey): returns the callable method, null when the property
/// is undefined/null (or `v` is a primitive with no such symbol), throws when it
/// is present but not callable.
fn getSymMethodOf(arena: std.mem.Allocator, v: Value, sym: Value) anyerror!?Value {
    if (v.bits == 0 or v.unbox() != .object) return null;
    // GetMethod is defined in terms of [[Get]], so an accessor-backed @@match /
    // @@replace / @@split must have its getter *invoked* (and its result used) —
    // reading the raw slot would hand back the get/set holder object instead.
    const m = if (realm_mod.active_context) |ctx|
        try ctx.getPropSym(arena, v, sym)
    else
        v.toPtr().object.getSym(sym) orelse return null;
    if (m.bits == 0) return null;
    switch (m.unbox()) {
        .undefined_, .null_ => return null,
        else => {},
    }
    if (!isCallable(m)) {
        _ = try throwTypeErrorStr(arena, "value is not a function");
        unreachable;
    }
    return m;
}

/// RegExpCreate(pattern, flags) for the String-method fallback path: compiles a
/// RegExp from `pattern_val` (undefined/null → empty pattern) with the given flags.
fn makeRegExpFor(arena: std.mem.Allocator, pattern_val: Value, flags: []const u8) anyerror!Value {
    // RegExpInitialize: undefined pattern → ""; every other value (incl. null) is
    // ToString-coerced ("null", "123", …).
    var pat: []const u8 = "";
    const is_undef = pattern_val.bits == 0 or pattern_val.unbox() == .undefined_;
    if (!is_undef) pat = try argToString(arena, pattern_val);
    const cr = try arena.create(regexp_mod.CompiledRegex);
    cr.* = regexp_mod.compileRegex(arena, pat, flags) catch {
        const JsObject = @import("../../object/object.zig").JsObject;
        const eo = try JsObject.create(arena, realm_mod.error_proto_SyntaxError);
        try eo.set("name", try val_mod.makeString(arena, "SyntaxError"));
        try eo.set("message", try val_mod.makeString(arena, "Invalid regular expression"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, eo);
        return error.JsException;
    };
    return regexp_mod.makeRegExpObject(arena, cr, pat, flags);
}

/// ES Invoke(rx, symKey, [arg]): look the symbol method up on `rx` (honoring any
/// user override of RegExp.prototype[@@match/@@search/@@matchAll]) and call it.
fn invokeRegExpSym(arena: std.mem.Allocator, rx: Value, sym: Value, arg: Value) anyerror!Value {
    const m = (try getSymMethodOf(arena, rx, sym)) orelse {
        _ = try throwTypeErrorStr(arena, "RegExp method is not callable");
        unreachable;
    };
    return function_proto_mod.invokeCallback(arena, rx, m, &[_]Value{arg});
}

/// True for any code point in the ES WhiteSpace or LineTerminator production
/// (used by trim / trimStart / trimEnd). Covers the Unicode Zs category plus
/// TAB/LF/VT/FF/CR/LS/PS and the ZWNBSP (BOM, U+FEFF).
fn isStrWhiteSpace(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

/// Compute trimmed byte bounds [start, end) over the WTF-8 string `s`.
fn trimBounds(s: []const u8, left: bool, right: bool) struct { start: usize, end: usize } {
    var start: usize = 0;
    if (left) {
        while (start < s.len) {
            const dec = decodeWtf8At(s, start);
            if (!isStrWhiteSpace(dec.cp)) break;
            start += dec.len;
        }
    }
    var end: usize = s.len;
    if (right) {
        var i: usize = start;
        var last_end: usize = start;
        while (i < s.len) {
            const dec = decodeWtf8At(s, i);
            i += dec.len;
            if (!isStrWhiteSpace(dec.cp)) last_end = i;
        }
        end = last_end;
    }
    return .{ .start = start, .end = end };
}

/// Normalize a (possibly negative) index for string of given length.
/// Returns clamped usize in [0, len].
fn normalizeIndex(idx: f64, len: usize) usize {
    if (std.math.isNan(idx)) return 0;
    const i: i64 = val_mod.f64ToI64Sat(idx);
    if (i < 0) {
        const pos: i64 = @intCast(len);
        const r = pos + i;
        return if (r < 0) 0 else @intCast(r);
    }
    if (i > @as(i64, @intCast(len))) return len;
    return @intCast(i);
}

pub fn nativeCharAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const i: usize = if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeString(arena, "") else @intCast(val_mod.f64ToI64Sat(idx));
    const unit = cuUnitAt(s, i) orelse return val_mod.makeString(arena, "");
    return val_mod.makeString(arena, try cuToString(arena, unit));
}

pub fn nativeCharCodeAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const i: usize = if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeNumber(arena, std.math.nan(f64)) else @intCast(val_mod.f64ToI64Sat(idx));
    const unit = cuUnitAt(s, i) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @floatFromInt(unit));
}

/// Decode one WTF-8 code point starting at byte offset `i` in `s`.
/// WTF-8 admits lone surrogates (U+D800..U+DFFF) encoded as 3 bytes, matching
/// how this engine stores `\uD834`-style escapes. Returns the code point and the
/// number of bytes consumed. `i` must be < s.len.
pub fn decodeWtf8At(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 >= 0xF0 and i + 3 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x07) << 18) | (@as(u21, s[i + 1] & 0x3F) << 12) | (@as(u21, s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
        return .{ .cp = cp, .len = 4 };
    }
    if (b0 >= 0xE0 and i + 2 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 >= 0xC0 and i + 1 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x1F) << 6) | (s[i + 1] & 0x3F);
        return .{ .cp = cp, .len = 2 };
    }
    return .{ .cp = b0, .len = 1 };
}

// ---------------------------------------------------------------------------
// UTF-16 code-unit view over WTF-8 storage
//
// JSZ stores strings as WTF-8 bytes, but ECMAScript indexes strings by UTF-16
// code unit. These helpers translate between the two without changing storage:
// an astral code point occupies 2 code units, whether it is stored as a 4-byte
// UTF-8 sequence (literal source) or as a surrogate pair of two 3-byte WTF-8
// sequences (`\u`/`fromCodePoint`). Both decode identically via `decodeWtf8At`.
// Pure-ASCII strings incur only a tight byte-walk (byte len == code-unit len).
// ---------------------------------------------------------------------------

/// UTF-16 code-unit length of WTF-8 string `s` (BMP cp → 1 unit, astral → 2).
pub fn cuLen(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            i += 1;
            n += 1;
            continue;
        }
        const dec = decodeWtf8At(s, i);
        n += if (dec.cp > 0xFFFF) 2 else 1;
        i += dec.len;
    }
    return n;
}

/// Where a UTF-16 code-unit index lands inside a WTF-8 string.
pub const CuLoc = struct {
    /// Byte offset of the code point containing the requested code unit.
    byte: usize,
    /// True when the index is the trailing (low-surrogate) half of a 4-byte
    /// astral code point stored as a single UTF-8 sequence.
    low_half: bool,
    /// True when the index is at/after the string's code-unit length.
    past: bool,
};

/// Locate UTF-16 code-unit index `idx` within WTF-8 string `s`.
pub fn cuLocate(s: []const u8, idx: usize) CuLoc {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (idx == n) return .{ .byte = i, .low_half = false, .past = false };
            i += 1;
            n += 1;
            continue;
        }
        const dec = decodeWtf8At(s, i);
        const units: usize = if (dec.cp > 0xFFFF) 2 else 1;
        if (idx < n + units) return .{ .byte = i, .low_half = (units == 2 and idx == n + 1), .past = false };
        n += units;
        i += dec.len;
    }
    return .{ .byte = s.len, .low_half = false, .past = true };
}

/// Byte offset of code-unit index `idx`, clamped to `s.len` when out of range.
/// A split-astral index resolves to the start of the astral code point.
pub fn cuByteOf(s: []const u8, idx: usize) usize {
    return cuLocate(s, idx).byte;
}

/// Code-unit index for byte offset `byte` (number of code units before it).
pub fn cuIndexOfByte(s: []const u8, byte: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < byte and i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            i += 1;
            n += 1;
            continue;
        }
        const dec = decodeWtf8At(s, i);
        n += if (dec.cp > 0xFFFF) 2 else 1;
        i += dec.len;
    }
    return n;
}

/// The UTF-16 code unit at code-unit index `idx`, or null if out of range.
pub fn cuUnitAt(s: []const u8, idx: usize) ?u16 {
    const loc = cuLocate(s, idx);
    if (loc.past) return null;
    const dec = decodeWtf8At(s, loc.byte);
    if (dec.cp > 0xFFFF) {
        const v: u21 = dec.cp - 0x10000;
        return if (loc.low_half) @intCast(0xDC00 + (v & 0x3FF)) else @intCast(0xD800 + (v >> 10));
    }
    return @intCast(dec.cp);
}

/// Encode one UTF-16 code unit as a 1-code-unit WTF-8 string (surrogates → 3B).
pub fn cuToString(arena: std.mem.Allocator, unit: u16) ![]const u8 {
    if (unit < 0x80) return arena.dupe(u8, &[_]u8{@intCast(unit)});
    if (unit < 0x800) return arena.dupe(u8, &[_]u8{ @intCast(0xC0 | (unit >> 6)), @intCast(0x80 | (unit & 0x3F)) });
    return arena.dupe(u8, &[_]u8{ @intCast(0xE0 | (unit >> 12)), @intCast(0x80 | ((unit >> 6) & 0x3F)), @intCast(0x80 | (unit & 0x3F)) });
}

/// Slice WTF-8 string `s` by UTF-16 code-unit range [start_cu, end_cu). When a
/// boundary splits a 4-byte astral code point, the exposed half is re-encoded as
/// a lone surrogate so the result has exact code-unit semantics.
pub fn cuSliceAlloc(arena: std.mem.Allocator, s: []const u8, start_cu: usize, end_cu: usize) ![]const u8 {
    if (start_cu >= end_cu) return "";
    const a = cuLocate(s, start_cu);
    if (a.past) return "";
    const b = cuLocate(s, end_cu);
    // Fast path: neither boundary splits an astral code point → raw byte slice
    // (preserves the original 4-byte encoding).
    if (!a.low_half and !b.low_half) return arena.dupe(u8, s[a.byte..b.byte]);
    var buf = std.ArrayList(u8){};
    var i = a.byte;
    if (a.low_half) {
        const dec = decodeWtf8At(s, i);
        const v: u21 = dec.cp - 0x10000;
        try encodeWtf8Cp(&buf, arena, @intCast(0xDC00 + (v & 0x3FF)));
        i += dec.len;
    }
    if (b.byte > i) try buf.appendSlice(arena, s[i..b.byte]);
    if (b.low_half) {
        const dec = decodeWtf8At(s, b.byte);
        const v: u21 = dec.cp - 0x10000;
        try encodeWtf8Cp(&buf, arena, @intCast(0xD800 + (v >> 10)));
    }
    return arena.dupe(u8, buf.items);
}

/// String.prototype.codePointAt(pos): the code point at UTF-16 code-unit index
/// `pos`. A leading surrogate followed by a trailing surrogate combines into the
/// astral code point; a lone/low surrogate yields its own value. Returns
/// undefined when `pos` is out of range.
pub fn nativeCodePointAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeUndefined(arena);
    const cu: usize = @intCast(val_mod.f64ToI64Sat(idx));
    // CodePointAt (ES 21.1.3.4): read the code unit at `cu`; if it is a leading
    // surrogate immediately followed by a trailing surrogate, combine them into
    // the astral code point. Working through cuUnitAt makes this correct for both
    // storage forms — a 4-byte UTF-8 astral char and a two-sequence surrogate
    // pair both surface as a leading/trailing code-unit pair.
    const first = cuUnitAt(s, cu) orelse return val_mod.makeUndefined(arena);
    if (first < 0xD800 or first > 0xDBFF) return val_mod.makeNumber(arena, @floatFromInt(first));
    const second = cuUnitAt(s, cu + 1) orelse return val_mod.makeNumber(arena, @floatFromInt(first));
    if (second < 0xDC00 or second > 0xDFFF) return val_mod.makeNumber(arena, @floatFromInt(first));
    const cp: u32 = (@as(u32, first - 0xD800) << 10) + (@as(u32, second - 0xDC00)) + 0x10000;
    return val_mod.makeNumber(arena, @floatFromInt(cp));
}

pub fn nativeIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const len = cuLen(s);
    const pos: f64 = if (args.len > 1) try argToInteger(arena, args[1]) else 0;
    const from_cu = clampToLen(pos, len);
    const from = cuByteOf(s, from_cu);

    if (from_cu >= len and search.len > 0) return val_mod.makeNumber(arena, -1.0);
    if (std.mem.indexOf(u8, s[from..], search)) |p| {
        return val_mod.makeNumber(arena, @floatFromInt(cuIndexOfByte(s, p + from)));
    }
    return val_mod.makeNumber(arena, -1.0);
}

pub fn nativeSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = cuLen(s);

    const start_raw: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const end_raw: f64 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        try argToInteger(arena, args[1])
    else
        @floatFromInt(len);

    const start = normalizeIndex(start_raw, len);
    const end_ = normalizeIndex(end_raw, len);

    if (start >= end_) return val_mod.makeString(arena, "");
    return val_mod.makeString(arena, try cuSliceAlloc(arena, s, start, end_));
}

/// Decode one code point at byte offset `i`, joining a surrogate PAIR into the
/// astral code point it represents. Strings reach this module either as 4-byte
/// WTF-8 or as two 3-byte surrogate halves (from `\uD83D\uDE00`-style escapes);
/// case conversion must see the same code point either way.
fn decodeCpJoined(s: []const u8, i: usize) struct { cp: u21, len: usize, paired: bool } {
    const d = decodeWtf8At(s, i);
    if (d.cp >= 0xD800 and d.cp <= 0xDBFF and i + d.len < s.len) {
        const lo = decodeWtf8At(s, i + d.len);
        if (lo.cp >= 0xDC00 and lo.cp <= 0xDFFF) {
            const cp: u21 = 0x10000 + ((d.cp - 0xD800) << 10) + (lo.cp - 0xDC00);
            return .{ .cp = cp, .len = d.len + lo.len, .paired = true };
        }
    }
    return .{ .cp = d.cp, .len = d.len, .paired = false };
}

/// Encode `cp`, reproducing the surrogate-PAIR spelling when the source code
/// point used one. Both spellings denote the same JS string, but they are
/// distinct byte sequences, and `===` compares bytes — so `"\uD801\uDC00"
/// .toLowerCase()` must come back as a pair, not as 4-byte WTF-8.
fn encodeCpAs(buf: *std.ArrayList(u8), arena: std.mem.Allocator, cp: u21, as_pair: bool) !void {
    if (as_pair and cp > 0xFFFF) {
        const v: u21 = cp - 0x10000;
        try encodeWtf8Cp(buf, arena, 0xD800 + (v >> 10));
        try encodeWtf8Cp(buf, arena, 0xDC00 + (v & 0x3FF));
        return;
    }
    try encodeWtf8Cp(buf, arena, cp);
}

fn cpHasProp(table_name: []const u8, cp: u21) bool {
    const ranges = uprops.lookup(table_name) orelse return false;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r[0]) hi = mid else if (cp > r[1]) lo = mid + 1 else return true;
    }
    return false;
}

/// SpecialCasing.txt `Final_Sigma`: U+03A3 lowercases to ς rather than σ when it
/// is preceded by a Cased code point and NOT followed by one, skipping
/// Case_Ignorable code points on both sides.
fn isFinalSigma(s: []const u8, sigma_start: usize, sigma_len: usize) bool {
    var before = false;
    var i: usize = 0;
    while (i < sigma_start) {
        const d = decodeCpJoined(s, i);
        if (!cpHasProp("Case_Ignorable", d.cp)) before = cpHasProp("Cased", d.cp);
        i += d.len;
    }
    if (!before) return false;
    var j = sigma_start + sigma_len;
    while (j < s.len) {
        const d = decodeCpJoined(s, j);
        if (!cpHasProp("Case_Ignorable", d.cp)) return !cpHasProp("Cased", d.cp);
        j += d.len;
    }
    return true;
}

/// Unicode Default Case Conversion over a WTF-8 string. Uses the FULL mappings
/// (a code point may expand: ß → SS, ﬀ → FF, U+0130 → i + combining dot) plus
/// the Final_Sigma context rule.
fn caseConvert(arena: std.mem.Allocator, s: []const u8, to_upper: bool) ![]const u8 {
    // ASCII-only fast path — by far the common case, and it needs no tables.
    var ascii = true;
    for (s) |c| {
        if (c >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        const out = try arena.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = if (to_upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        return out;
    }

    const table = if (to_upper) ucase.to_upper else ucase.to_lower;
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeCpJoined(s, i);
        if (!to_upper and d.cp == 0x03A3 and isFinalSigma(s, i, d.len)) {
            try encodeWtf8Cp(&buf, arena, 0x03C2);
        } else if (ucase.lookup(table, d.cp)) |mapped| {
            for (mapped) |m| try encodeCpAs(&buf, arena, m, d.paired);
        } else {
            try buf.appendSlice(arena, s[i .. i + d.len]);
        }
        i += d.len;
    }
    return buf.items;
}

pub fn nativeToUpperCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    return val_mod.makeString(arena, try caseConvert(arena, s, true));
}

pub fn nativeToLowerCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    return val_mod.makeString(arena, try caseConvert(arena, s, false));
}

/// ES ToUint32 of a coerced Number.
fn toUint32(n: f64) u32 {
    if (!std.math.isFinite(n) or n == 0) return 0;
    const int = @trunc(n);
    const m = @mod(int, 4294967296.0);
    const mm = if (m < 0) m + 4294967296.0 else m;
    return @intFromFloat(mm);
}

pub fn nativeSplit(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr_proto: ?*JsObject = realm_mod.active_array_proto;

    const separator = if (args.len > 0) args[0] else Value{ .bits = 0 };
    const limit_arg = if (args.len > 1) args[1] else Value{ .bits = 0 };

    // @@split dispatch (RegExp separators and custom splitters). Step 2.
    if (realm_mod.active_sym_split) |sym| {
        if (try getSymMethodOf(arena, separator, sym)) |m| {
            return function_proto_mod.invokeCallback(arena, separator, m, &[_]Value{ this_val, limit_arg });
        }
    }

    const s = try coerceThis(arena, this_val); // step 3: S = ToString(O)

    // step 4: lim = ToUint32(limit); undefined → 2^32-1.
    const lim: u32 = if (limit_arg.bits != 0 and limit_arg.unbox() != .undefined_)
        toUint32(try toNumberChecked(arena, limit_arg))
    else
        0xFFFF_FFFF;

    const sep_undefined = separator.bits == 0 or separator.unbox() == .undefined_;
    // step 5: R = ToString(separator) — runs (and can throw) before the lim==0 test.
    const sep_s: []const u8 = if (sep_undefined) "" else try argToString(arena, separator);

    // step 6: a zero limit yields [] regardless of separator.
    if (lim == 0) {
        const empty = try JsObject.createArray(arena, arr_proto);
        empty.array_length = 0;
        return val_mod.makeObject(arena, empty);
    }

    const arr = try JsObject.createArray(arena, arr_proto);

    // step 7: undefined separator → the whole string is the single element.
    if (sep_undefined) {
        try arr.set("0", try val_mod.makeString(arena, s));
        arr.array_length = 1;
        return val_mod.makeObject(arena, arr);
    }

    // Empty source string: [""] unless the separator also matches empty ("") → [].
    if (s.len == 0) {
        if (sep_s.len != 0) {
            try arr.set("0", try val_mod.makeString(arena, ""));
            arr.array_length = 1;
        } else {
            arr.array_length = 0;
        }
        return val_mod.makeObject(arena, arr);
    }

    if (sep_s.len == 0) {
        // Split into individual code units, honouring the limit.
        var i: usize = 0;
        var idx: u32 = 0;
        while (i < s.len and idx < lim) : (i += 1) {
            const ch = try arena.dupe(u8, s[i .. i + 1]);
            const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(key, try val_mod.makeString(arena, ch));
            idx += 1;
        }
        arr.array_length = idx;
        return val_mod.makeObject(arena, arr);
    }

    // Split by non-empty string separator, honouring the limit.
    var idx: u32 = 0;
    var rest = s;
    while (idx < lim) {
        if (std.mem.indexOf(u8, rest, sep_s)) |pos| {
            const part = try arena.dupe(u8, rest[0..pos]);
            const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(key, try val_mod.makeString(arena, part));
            idx += 1;
            rest = rest[pos + sep_s.len ..];
        } else {
            const part = try arena.dupe(u8, rest);
            const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(key, try val_mod.makeString(arena, part));
            idx += 1;
            break;
        }
    }
    arr.array_length = idx;
    return val_mod.makeObject(arena, arr);
}

fn splitByRegex(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, arr_proto: anytype, lim: u32) !Value {
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr = try JsObject.createArray(arena, arr_proto);
    var idx: u32 = 0;

    // ES 22.2.6.14: an empty source string yields [] if the pattern matches at 0,
    // else [""].
    if (s.len == 0) {
        if (regexp_mod.matchAnywhere(cr, s, 0) == null) {
            try arr.set("0", try val_mod.makeString(arena, ""));
            arr.array_length = 1;
        } else {
            arr.array_length = 0;
        }
        return val_mod.makeObject(arena, arr);
    }

    // p = start of the current segment; q = scan cursor. A match that ends at p
    // (empty, or right where the previous segment began) is skipped so adjacent
    // separators and zero-width matches behave per spec.
    var p: usize = 0;
    var q: usize = 0;
    while (q < s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, q) orelse break;
        const match_start = m.start;
        const match_end = m.state.pos;
        if (match_start >= s.len) break;
        if (match_end == p) {
            // No progress at the segment start: advance the scan cursor.
            q = match_start + 1;
            continue;
        }
        // Emit the text between the previous split point and this match.
        const part = try arena.dupe(u8, s[p..match_start]);
        const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
        try arr.set(key, try val_mod.makeString(arena, part));
        idx += 1;
        if (idx >= lim) {
            arr.array_length = idx;
            return val_mod.makeObject(arena, arr);
        }
        // Include capture groups from this match (unmatched → undefined, using
        // the same start==0 && end==0 sentinel as RegExp exec).
        var ci: u32 = 1;
        while (ci <= cr.num_captures) : (ci += 1) {
            const cap = m.state.captures[ci];
            const cv = if (cap.unset())
                try val_mod.makeUndefined(arena)
            else
                try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end]));
            const kk = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(kk, cv);
            idx += 1;
            if (idx >= lim) {
                arr.array_length = idx;
                return val_mod.makeObject(arena, arr);
            }
        }
        p = match_end;
        q = match_end;
    }
    // Trailing segment from the last split point to the end.
    const rem = try arena.dupe(u8, s[p..]);
    const rk = try std.fmt.allocPrint(arena, "{d}", .{idx});
    try arr.set(rk, try val_mod.makeString(arena, rem));
    idx += 1;

    arr.array_length = idx;
    return val_mod.makeObject(arena, arr);
}

/// String.prototype.match(re|str)
pub fn nativeMatch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const regexp = if (args.len > 0) args[0] else Value{ .bits = 0 };
    if (realm_mod.active_sym_match) |sym| {
        if (try getSymMethodOf(arena, regexp, sym)) |m| {
            return function_proto_mod.invokeCallback(arena, regexp, m, &[_]Value{this_val});
        }
    }
    const s = try coerceThis(arena, this_val);
    const s_val = try val_mod.makeString(arena, try arena.dupe(u8, s));
    const rx = try makeRegExpFor(arena, regexp, "");
    return invokeRegExpSym(arena, rx, realm_mod.active_sym_match.?, s_val);
}

fn doExec(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex) !Value {
    const result = regexp_mod.matchAnywhere(cr, s, 0) orelse return val_mod.makeNull(arena);
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);

    const full = try arena.dupe(u8, s[result.start..result.state.pos]);
    const fv = try val_mod.makeString(arena, full);
    try arr.set("0", fv);

    var i: u32 = 1;
    while (i <= cr.num_captures) : (i += 1) {
        const cap = result.state.captures[i];
        const cv: Value = if (cap.unset())
            try val_mod.makeUndefined(arena)
        else
            try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end]));
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(key, cv);
    }
    arr.array_length = cr.num_captures + 1;

    const idx_val = try val_mod.makeNumber(arena, @floatFromInt(result.start));
    try arr.set("index", idx_val);
    const input_val = try val_mod.makeString(arena, s);
    try arr.set("input", input_val);

    return val_mod.makeObject(arena, arr);
}

/// String.prototype.search(re|str) -> index or -1
pub fn nativeSearch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const regexp = if (args.len > 0) args[0] else Value{ .bits = 0 };
    if (realm_mod.active_sym_search) |sym| {
        if (try getSymMethodOf(arena, regexp, sym)) |m| {
            return function_proto_mod.invokeCallback(arena, regexp, m, &[_]Value{this_val});
        }
    }
    const s = try coerceThis(arena, this_val);
    const s_val = try val_mod.makeString(arena, try arena.dupe(u8, s));
    const rx = try makeRegExpFor(arena, regexp, "");
    return invokeRegExpSym(arena, rx, realm_mod.active_sym_search.?, s_val);
}

/// String.prototype.matchAll(regexp) — ES2020. Dispatches to @@matchAll; when
/// `regexp` is a global RegExp requires the "g" flag, else creates a global one.
pub fn nativeMatchAll(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const regexp = if (args.len > 0) args[0] else Value{ .bits = 0 };
    const is_nullish = regexp.bits == 0 or switch (regexp.unbox()) {
        .undefined_, .null_ => true,
        else => false,
    };
    if (!is_nullish) {
        // If regexp is a RegExp, read its `flags` property and require "g"
        // (spec step 3.a-c: RequireObjectCoercible(flags) then check for 'g').
        if (regexp_mod.getCompiledRegex(regexp) != null) {
            const flags_val = if (realm_mod.active_context) |ctx|
                try ctx.getProp(arena, regexp, "flags")
            else
                Value{ .bits = 0 };
            if (flags_val.bits == 0 or switch (flags_val.unbox()) {
                .undefined_, .null_ => true,
                else => false,
            }) {
                _ = try throwTypeErrorStr(arena, "RegExp flags is undefined or null");
                unreachable;
            }
            const flags_str = try argToString(arena, flags_val);
            if (std.mem.indexOfScalar(u8, flags_str, 'g') == null) {
                _ = try throwTypeErrorStr(arena, "String.prototype.matchAll called with a non-global RegExp argument");
                unreachable;
            }
        }
        if (realm_mod.active_sym_match_all) |sym| {
            if (try getSymMethodOf(arena, regexp, sym)) |m| {
                return function_proto_mod.invokeCallback(arena, regexp, m, &[_]Value{this_val});
            }
        }
    }
    const s = try coerceThis(arena, this_val);
    const s_val = try val_mod.makeString(arena, try arena.dupe(u8, s));
    const rx = try makeRegExpFor(arena, regexp, "g");
    return invokeRegExpSym(arena, rx, realm_mod.active_sym_match_all.?, s_val);
}

/// Return true if a Value is callable (function, bc_function, native_function, bound_function).
fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        // A built-in constructor object (and the Annex B `document.all` stand-in)
        // keeps its [[Call]] behind the `__call__` slot; `invokeCallback` routes
        // both through the VM, so IsCallable has to agree.
        .object => |obj| obj.is_callable_intrinsic or obj.internal_kind == .bound_function or obj.get("__call__") != null,
        else => false,
    };
}

/// String.prototype.replace(searchValue, replaceValue) — ES 22.1.3.18.
pub fn nativeReplace(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const search = if (args.len > 0) args[0] else Value{ .bits = 0 };
    const repl_arg = if (args.len > 1) args[1] else Value{ .bits = 0 };

    // @@replace dispatch (handles RegExp searchValue and custom replacers).
    if (realm_mod.active_sym_replace) |sym| {
        if (try getSymMethodOf(arena, search, sym)) |m| {
            return function_proto_mod.invokeCallback(arena, search, m, &[_]Value{ this_val, repl_arg });
        }
    }

    const s = try coerceThis(arena, this_val);
    const pat = try argToString(arena, search);
    const functional = isCallable(repl_arg);
    const repl_str: []const u8 = if (functional) "" else try argToString(arena, repl_arg);

    const idx = std.mem.indexOf(u8, s, pat) orelse return val_mod.makeString(arena, try arena.dupe(u8, s));
    const match_str = s[idx .. idx + pat.len];
    const expanded: []const u8 = if (functional) blk: {
        const undefined_val = try val_mod.makeUndefined(arena);
        const cb_args = [_]Value{
            try val_mod.makeString(arena, match_str),
            try val_mod.makeNumber(arena, @floatFromInt(idx)),
            try val_mod.makeString(arena, s),
        };
        const rv = try function_proto_mod.invokeCallback(arena, undefined_val, repl_arg, &cb_args);
        break :blk try argToString(arena, rv);
    } else try applyReplacement(arena, repl_str, match_str, s, idx, &[_][]const u8{});

    const result = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ s[0..idx], expanded, s[idx + pat.len ..] });
    return val_mod.makeString(arena, result);
}

/// ES2021 String.prototype.replaceAll(searchValue, replaceValue) — 22.1.3.19.
pub fn nativeReplaceAll(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireObjectCoercible(arena, this_val);
    const search = if (args.len > 0) args[0] else Value{ .bits = 0 };
    const repl_arg = if (args.len > 1) args[1] else Value{ .bits = 0 };

    const is_nullish = search.bits == 0 or switch (search.unbox()) {
        .undefined_, .null_ => true,
        else => false,
    };
    if (!is_nullish) {
        // If searchValue is a RegExp it must carry the "g" flag (read the
        // `flags` property so overrides / abrupt getters are observed).
        if (try regexp_mod.isRegExpValue(arena, search)) {
            const flags_val = if (realm_mod.active_context) |ctx|
                try ctx.getProp(arena, search, "flags")
            else
                Value{ .bits = 0 };
            if (flags_val.bits == 0 or switch (flags_val.unbox()) {
                .undefined_, .null_ => true,
                else => false,
            }) {
                _ = try throwTypeErrorStr(arena, "RegExp flags is undefined or null");
                unreachable;
            }
            const flags_str = try argToString(arena, flags_val);
            if (std.mem.indexOfScalar(u8, flags_str, 'g') == null) {
                _ = try throwTypeErrorStr(arena, "String.prototype.replaceAll called with a non-global RegExp argument");
                unreachable;
            }
        }
        if (realm_mod.active_sym_replace) |sym| {
            if (try getSymMethodOf(arena, search, sym)) |m| {
                return function_proto_mod.invokeCallback(arena, search, m, &[_]Value{ this_val, repl_arg });
            }
        }
    }

    const s = try coerceThis(arena, this_val);
    const pat = try argToString(arena, search);
    const functional = isCallable(repl_arg);
    const repl_str: []const u8 = if (functional) "" else try argToString(arena, repl_arg);
    return replaceAllString(arena, s, pat, repl_str, if (functional) repl_arg else null);
}

/// Replace every occurrence of `pat` in `s`. When `fn_val` is non-null the match
/// is passed to it and its ToString result is substituted; otherwise `repl` is
/// applied with GetSubstitution ($-pattern) expansion.
fn replaceAllString(arena: std.mem.Allocator, s: []const u8, pat: []const u8, repl: []const u8, fn_val: ?Value) !Value {
    const undefined_val = try val_mod.makeUndefined(arena);
    var result = std.ArrayList(u8){};
    // Advance by 1 byte on an empty pattern so we visit every position once.
    const step: usize = if (pat.len == 0) 1 else pat.len;
    var pos: usize = 0;
    var search_from: usize = 0;
    while (search_from <= s.len) {
        const rel = std.mem.indexOf(u8, s[search_from..], pat) orelse break;
        const abs = search_from + rel;
        try result.appendSlice(arena, s[pos..abs]);
        const match_str = s[abs .. abs + pat.len];
        if (fn_val) |fv| {
            const cb_args = [_]Value{
                try val_mod.makeString(arena, match_str),
                try val_mod.makeNumber(arena, @floatFromInt(abs)),
                try val_mod.makeString(arena, s),
            };
            const rv = try function_proto_mod.invokeCallback(arena, undefined_val, fv, &cb_args);
            try result.appendSlice(arena, try argToString(arena, rv));
        } else {
            try result.appendSlice(arena, try applyReplacement(arena, repl, match_str, s, abs, &[_][]const u8{}));
        }
        pos = abs + pat.len;
        search_from = abs + step;
    }
    try result.appendSlice(arena, s[pos..]);
    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

/// Replace with function callback for regex pattern.
fn doReplaceWithFn(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, fn_val: Value) !Value {
    var result = std.ArrayList(u8){};
    var pos: usize = 0;
    const undefined_val = try val_mod.makeUndefined(arena);

    while (pos <= s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, pos) orelse break;
        // Append text before match.
        try result.appendSlice(arena, s[pos..m.start]);

        const full_match = s[m.start..m.state.pos];

        // Build args: (match, cap1..capN, offset, source)
        const n_caps = cr.num_captures;
        const total_args = 1 + n_caps + 2; // match + captures + offset + source
        const cb_args = try arena.alloc(Value, total_args);
        cb_args[0] = try val_mod.makeString(arena, full_match);
        var ci: u32 = 1;
        while (ci <= n_caps) : (ci += 1) {
            const cap = m.state.captures[ci];
            if (cap.unset()) {
                cb_args[ci] = try val_mod.makeUndefined(arena);
            } else {
                cb_args[ci] = try val_mod.makeString(arena, s[cap.start..cap.end]);
            }
        }
        cb_args[1 + n_caps] = try val_mod.makeNumber(arena, @floatFromInt(m.start));
        cb_args[1 + n_caps + 1] = try val_mod.makeString(arena, s);

        const repl_val = function_proto_mod.invokeCallback(arena, undefined_val, fn_val, cb_args) catch |e| {
            if (e == error.JsException) return error.JsException;
            return error.OutOfMemory;
        };
        const repl_s: []const u8 = try argToStr(arena, repl_val);
        try result.appendSlice(arena, repl_s);

        if (m.state.pos == m.start) {
            if (pos < s.len) {
                try result.append(arena, s[pos]);
            }
            pos += 1;
        } else {
            pos = m.state.pos;
        }

        if (!cr.flags.global) break;
    }

    // Append remainder.
    if (pos <= s.len) {
        try result.appendSlice(arena, s[pos..]);
    }

    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

fn doReplace(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, repl_str: []const u8) !Value {
    var result = std.ArrayList(u8){};
    var pos: usize = 0;

    while (pos <= s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, pos) orelse break;
        // Append text before match
        try result.appendSlice(arena, s[pos..m.start]);
        // Build captures array for $N
        const full_match = s[m.start..m.state.pos];
        var caps: [regexp_mod.MAX_CAPTURES][]const u8 = undefined;
        var i: u32 = 0;
        while (i < regexp_mod.MAX_CAPTURES) : (i += 1) caps[i] = "";
        var ci: u32 = 1;
        while (ci <= cr.num_captures) : (ci += 1) {
            const cap = m.state.captures[ci];
            if (cap.start != 0 or cap.end != 0) {
                caps[ci] = s[cap.start..cap.end];
            }
        }
        // Apply replacement
        const expanded = try applyReplacement(arena, repl_str, full_match, s, m.start, caps[0 .. cr.num_captures + 1]);
        try result.appendSlice(arena, expanded);

        if (m.state.pos == m.start) {
            if (pos < s.len) {
                try result.append(arena, s[pos]);
            }
            pos += 1;
        } else {
            pos = m.state.pos;
        }

        if (!cr.flags.global) break;
    }

    // Append remainder
    if (pos <= s.len) {
        try result.appendSlice(arena, s[pos..]);
    }

    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

/// Apply $& $$ $1..$9 substitution in replacement string.
fn applyReplacement(
    arena: std.mem.Allocator,
    repl: []const u8,
    full_match: []const u8,
    input: []const u8,
    match_start: usize,
    caps: []const []const u8,
) ![]const u8 {
    const match_end = match_start + full_match.len;
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] == '$' and i + 1 < repl.len) {
            const next = repl[i + 1];
            switch (next) {
                '&' => {
                    try out.appendSlice(arena, full_match);
                    i += 2;
                    continue;
                },
                '`' => {
                    try out.appendSlice(arena, input[0..match_start]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try out.appendSlice(arena, input[match_end..]);
                    i += 2;
                    continue;
                },
                '$' => {
                    try out.append(arena, '$');
                    i += 2;
                    continue;
                },
                '1'...'9' => {
                    // `caps` holds groups at indices 1..=(caps.len-1); an out-of-range
                    // reference is emitted literally ("$1" stays "$1").
                    const n: usize = next - '0';
                    // Prefer a valid two-digit $NN.
                    if (i + 2 < repl.len and repl[i + 2] >= '0' and repl[i + 2] <= '9') {
                        const nn: usize = n * 10 + (repl[i + 2] - '0');
                        if (nn >= 1 and nn < caps.len) {
                            try out.appendSlice(arena, caps[nn]);
                            i += 3;
                            continue;
                        }
                    }
                    if (n >= 1 and n < caps.len) {
                        try out.appendSlice(arena, caps[n]);
                        i += 2;
                        continue;
                    }
                    // Invalid group: keep the '$' literal, advance one char.
                    try out.append(arena, '$');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(arena, repl[i]);
        i += 1;
    }
    return try arena.dupe(u8, out.items);
}

pub fn nativeConcat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var buf = std.ArrayList(u8){};
    try buf.appendSlice(arena, s);
    for (args) |a| {
        try buf.appendSlice(arena, try argToString(arena, a));
    }
    return val_mod.makeString(arena, buf.items);
}

/// Coerce an argument to a string slice for search methods (string/number/bool/
/// null/undefined; objects → "[object Object]"). Mirrors nativeConcat's coercion.
fn argToStr(arena: std.mem.Allocator, a: Value) ![]const u8 {
    if (a.bits == 0) return "undefined";
    return switch (a.unbox()) {
        .string => |ss| ss,
        .number => |n| try formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .null_ => "null",
        .undefined_ => "undefined",
        else => "[object Object]",
    };
}

/// Throw a TypeError if `a` is a RegExp (per String.prototype.{startsWith,endsWith,
/// includes}: a RegExp searchString is not allowed). Uses the spec IsRegExp, which
/// reads `@@match` — so a plain object with a truthy `@@match` is rejected too, and
/// an abrupt getter propagates.
fn rejectRegExp(arena: std.mem.Allocator, a: Value) !void {
    if (!(try regexp_mod.isRegExpValue(arena, a))) return;
    const JsObject = @import("../../object/object.zig").JsObject;
    const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, "First argument to String.prototype.startsWith/endsWith/includes must not be a regular expression"));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// ES2015 String.prototype.startsWith(searchString [, position]).
pub fn nativeStartsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const pos_cu = if (args.len > 1) clampToLen(try argToInteger(arena, args[1]), cuLen(s)) else 0;
    const pos = cuByteOf(s, pos_cu);
    if (pos + search.len > s.len) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[pos .. pos + search.len], search));
}

/// ES2015 String.prototype.endsWith(searchString [, endPosition]).
pub fn nativeEndsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const end_cu: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        clampToLen(try argToInteger(arena, args[1]), cuLen(s))
    else
        cuLen(s);
    const end_ = cuByteOf(s, end_cu);
    if (search.len > end_) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[end_ - search.len .. end_], search));
}

/// ES2015 String.prototype.includes(searchString [, position]).
pub fn nativeStringIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const pos_cu = if (args.len > 1) clampToLen(try argToInteger(arena, args[1]), cuLen(s)) else 0;
    const pos = cuByteOf(s, pos_cu);
    if (pos > s.len) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.indexOf(u8, s[pos..], search) != null);
}

/// ToNumber for a position arg (number → itself; absent/other → 0). NaN handled by normalizeIndex.
fn toNum(a: Value) f64 {
    if (a.bits == 0) return 0;
    return switch (a.unbox()) {
        .number => |n| n,
        else => 0,
    };
}

pub fn nativeTrim(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const b = trimBounds(s, true, true);
    return val_mod.makeString(arena, try arena.dupe(u8, s[b.start..b.end]));
}

/// ES2019 String.prototype.trimStart.
pub fn nativeTrimStart(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const b = trimBounds(s, true, false);
    return val_mod.makeString(arena, try arena.dupe(u8, s[b.start..b.end]));
}

/// ES2019 String.prototype.trimEnd.
pub fn nativeTrimEnd(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const b = trimBounds(s, false, true);
    return val_mod.makeString(arena, try arena.dupe(u8, s[b.start..b.end]));
}

fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    return val_mod.formatNumber(arena, n);
}

/// Build a pad filler of exactly `count` UTF-16 code units by repeating `pad`
/// (truncating the final repeat at a code-unit boundary).
fn buildFiller(arena: std.mem.Allocator, pad: []const u8, count: usize) ![]const u8 {
    const pad_cu = cuLen(pad);
    var buf = std.ArrayList(u8){};
    var have: usize = 0;
    while (have + pad_cu <= count) {
        try buf.appendSlice(arena, pad);
        have += pad_cu;
    }
    if (have < count) try buf.appendSlice(arena, try cuSliceAlloc(arena, pad, 0, count - have));
    return buf.items;
}

fn padImpl(arena: std.mem.Allocator, this_val: Value, args: []const Value, at_start: bool) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const s_cu = cuLen(s);
    const max_len = if (args.len > 0) try argToInteger(arena, args[0]) else 0;
    const target: usize = if (max_len <= 0) 0 else @intCast(val_mod.f64ToI64Sat(max_len));
    if (target <= s_cu) return val_mod.makeString(arena, s);
    const pad: []const u8 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        try argToString(arena, args[1])
    else
        " ";
    if (pad.len == 0) return val_mod.makeString(arena, s);
    const filler = try buildFiller(arena, pad, target - s_cu);
    var buf = std.ArrayList(u8){};
    if (at_start) {
        try buf.appendSlice(arena, filler);
        try buf.appendSlice(arena, s);
    } else {
        try buf.appendSlice(arena, s);
        try buf.appendSlice(arena, filler);
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES2017 String.prototype.padStart.
pub fn nativePadStart(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return padImpl(arena, this_val, args, true);
}

/// ES2017 String.prototype.padEnd.
pub fn nativePadEnd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return padImpl(arena, this_val, args, false);
}

// ---------------------------------------------------------------------------
// HTML wrapper methods (Annex B B.2.3)
// ---------------------------------------------------------------------------

/// Wrap receiver S in an HTML tag. When attrName is non-null, escapes `"` in
/// attrVal to `&quot;` and produces `<tag attrName="attrVal">S</tag>`.
fn htmlWrap(
    arena: std.mem.Allocator,
    s: []const u8,
    tag: []const u8,
    attr_name: ?[]const u8,
    attr_val: ?[]const u8,
) !Value {
    if (attr_name) |aname| {
        const av = attr_val orelse "undefined";
        var esc = std.ArrayList(u8){};
        for (av) |c| {
            if (c == '"') {
                try esc.appendSlice(arena, "&quot;");
            } else {
                try esc.append(arena, c);
            }
        }
        const result = try std.fmt.allocPrint(arena, "<{s} {s}=\"{s}\">{s}</{s}>", .{ tag, aname, esc.items, s, tag });
        return val_mod.makeString(arena, result);
    } else {
        const result = try std.fmt.allocPrint(arena, "<{s}>{s}</{s}>", .{ tag, s, tag });
        return val_mod.makeString(arena, result);
    }
}

pub fn nativeAnchor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const name = if (args.len > 0) try argToString(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "a", "name", name);
}

pub fn nativeLink(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const url = if (args.len > 0) try argToString(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "a", "href", url);
}

pub fn nativeFontcolor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const c = if (args.len > 0) try argToString(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "font", "color", c);
}

pub fn nativeFontsize(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const sz = if (args.len > 0) try argToString(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "font", "size", sz);
}

pub fn nativeBig(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "big", null, null);
}

pub fn nativeBlink(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "blink", null, null);
}

pub fn nativeBold(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "b", null, null);
}

pub fn nativeFixed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "tt", null, null);
}

pub fn nativeItalics(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "i", null, null);
}

pub fn nativeSmall(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "small", null, null);
}

pub fn nativeStrike(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "strike", null, null);
}

pub fn nativeSub(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "sub", null, null);
}

pub fn nativeSup(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "sup", null, null);
}

// ---------------------------------------------------------------------------
// Core string methods
// ---------------------------------------------------------------------------

/// String.prototype.substring(start, end) — ES5.
/// NaN/negatives → 0; clamped to [0, len]; min(a,b)..max(a,b).
pub fn nativeSubstring(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = cuLen(s);

    const clampIdx = struct {
        fn f(n: f64, l: usize) usize {
            if (std.math.isNan(n) or n < 0.0) return 0;
            const i: i64 = val_mod.f64ToI64Sat(n);
            if (i > @as(i64, @intCast(l))) return l;
            return @intCast(i);
        }
    }.f;

    const a0: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const a = clampIdx(a0, len);

    const b: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        clampIdx(try argToInteger(arena, args[1]), len)
    else
        len;

    const from = if (a < b) a else b;
    const to = if (a < b) b else a;
    return val_mod.makeString(arena, try cuSliceAlloc(arena, s, from, to));
}

/// String.prototype.substr(start, length) — legacy (Annex B).
pub fn nativeSubstr(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = cuLen(s);

    const start_f: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const int_start: i64 = if (std.math.isNan(start_f)) 0 else val_mod.f64ToI64Sat(start_f);

    const start: usize = if (int_start < 0) blk: {
        const r = @as(i64, @intCast(len)) + int_start;
        break :blk if (r < 0) 0 else @intCast(r);
    } else blk: {
        const u: usize = @intCast(int_start);
        break :blk if (u > len) len else u;
    };

    const size: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) blk: {
        const n: f64 = try argToInteger(arena, args[1]);
        if (n <= 0.0 or std.math.isNan(n)) break :blk 0;
        const u: usize = @intCast(val_mod.f64ToI64Sat(n));
        const max = len - start;
        break :blk if (u > max) max else u;
    } else len - start;

    return val_mod.makeString(arena, try cuSliceAlloc(arena, s, start, start + size));
}

/// String.prototype.at(index) — ES2022.
pub fn nativeStringAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = cuLen(s);
    const raw: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    var k: i64 = if (std.math.isNan(raw)) 0 else val_mod.f64ToI64Sat(raw);
    if (k < 0) k = @as(i64, @intCast(len)) + k;
    if (k < 0 or k >= @as(i64, @intCast(len))) return val_mod.makeUndefined(arena);
    const unit = cuUnitAt(s, @intCast(k)) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, try cuToString(arena, unit));
}

/// String.prototype.repeat(count) — ES2015.
pub fn nativeRepeat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const n_raw: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;

    if (n_raw < 0.0 or std.math.isInf(n_raw)) {
        const JsObject = @import("../../object/object.zig").JsObject;
        const eo = try JsObject.create(arena, realm_mod.error_proto_RangeError);
        try eo.set("message", try val_mod.makeString(arena, "Invalid count value"));
        try eo.set("name", try val_mod.makeString(arena, "RangeError"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, eo);
        return error.JsException;
    }

    if (std.math.isNan(n_raw) or n_raw == 0.0 or s.len == 0) return val_mod.makeString(arena, "");
    const n: usize = @intCast(val_mod.f64ToI64Sat(n_raw));
    const buf = try arena.alloc(u8, s.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(buf[i * s.len .. (i + 1) * s.len], s);
    }
    return val_mod.makeString(arena, buf);
}

/// String.prototype.lastIndexOf(searchString, position).
pub fn nativeLastIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });

    // position uses ToNumber (not ToIntegerOrInfinity); NaN / undefined → +Infinity.
    var pos: f64 = std.math.inf(f64);
    if (args.len > 1) {
        const num_pos = try toNumberChecked(arena, args[1]);
        if (!std.math.isNan(num_pos)) {
            pos = if (std.math.isInf(num_pos)) num_pos else std.math.trunc(num_pos);
        }
    }
    const len_cu = cuLen(s);
    const pos_limit_cu: usize = clampToLen(pos, len_cu);

    if (search.len == 0) {
        return val_mod.makeNumber(arena, @floatFromInt(if (pos_limit_cu > len_cu) len_cu else pos_limit_cu));
    }
    if (s.len < search.len) return val_mod.makeNumber(arena, -1.0);

    // Match start must be at code-unit index <= pos_limit_cu; translate that
    // ceiling to a byte offset, then search backwards over bytes.
    const pos_limit_byte = cuByteOf(s, pos_limit_cu);
    const max_start: usize = if (pos_limit_byte > s.len - search.len) s.len - search.len else pos_limit_byte;

    var i: usize = max_start + 1;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, s[i .. i + search.len], search)) {
            return val_mod.makeNumber(arena, @floatFromInt(cuIndexOfByte(s, i)));
        }
    }
    return val_mod.makeNumber(arena, -1.0);
}

// ---------------------------------------------------------------------------
// Locale aliases
// ---------------------------------------------------------------------------

/// The language whose SpecialCasing tailoring `locales` selects, or "" for the
/// (untailored) root. §19.1.2 TransformCase canonicalizes the whole list first,
/// so an invalid tag anywhere in it is a RangeError even when it is never used.
fn caseTailoringLanguage(arena: std.mem.Allocator, args: []const Value) ![]const u8 {
    const intl_mod = @import("intl.zig");
    const list = try intl_mod.canonicalizeLocaleList(arena, if (args.len > 0) args[0] else Value{});
    if (list.len == 0) return "";
    const tag = list[0];
    const end = std.mem.indexOfScalar(u8, tag, '-') orelse tag.len;
    const lang = tag[0..end];
    // Only the three tailorings SpecialCasing.txt defines are modelled.
    for ([_][]const u8{ "tr", "az", "lt" }) |l| {
        if (std.ascii.eqlIgnoreCase(lang, l)) return l;
    }
    return "";
}

pub fn nativeToLocaleLowerCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const lang = try caseTailoringLanguage(arena, args);
    if (lang.len == 0) return val_mod.makeString(arena, try caseConvert(arena, s, false));
    return val_mod.makeString(arena, try caseConvertTailored(arena, s, false, lang));
}

pub fn nativeToLocaleUpperCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const lang = try caseTailoringLanguage(arena, args);
    if (lang.len == 0) return val_mod.makeString(arena, try caseConvert(arena, s, true));
    return val_mod.makeString(arena, try caseConvertTailored(arena, s, true, lang));
}

/// One decoded code point of the input, remembering whether it was spelled as a
/// surrogate pair so the output can reproduce the same bytes.
const DecodedCp = struct { cp: u21, paired: bool, off: usize, len: usize };

/// SpecialCasing's `More_Above`: some following character has combining class
/// 230 (Above), with nothing of class 0 or 230 in between.
fn moreAbove(cps: []const DecodedCp, idx: usize) bool {
    var i = idx + 1;
    while (i < cps.len) : (i += 1) {
        const c = unorm.ccc(cps[i].cp);
        if (c == 230) return true;
        if (c == 0) return false;
    }
    return false;
}

/// SpecialCasing's `Before_Dot`: a COMBINING DOT ABOVE follows, with nothing of
/// combining class 0 or 230 in between.
fn beforeDot(cps: []const DecodedCp, idx: usize) bool {
    var i = idx + 1;
    while (i < cps.len) : (i += 1) {
        if (cps[i].cp == 0x0307) return true;
        const c = unorm.ccc(cps[i].cp);
        if (c == 0 or c == 230) return false;
    }
    return false;
}

/// SpecialCasing's `After_I` / `After_Soft_Dotted`: scan backwards for the
/// trigger character, stopping at anything of combining class 0 or 230.
fn afterBase(cps: []const DecodedCp, idx: usize, soft_dotted: bool) bool {
    var i = idx;
    while (i > 0) {
        i -= 1;
        const cp = cps[i].cp;
        if (soft_dotted) {
            if (cpHasProp("Soft_Dotted", cp)) return true;
        } else if (cp == 0x0049) return true;
        const c = unorm.ccc(cp);
        if (c == 0 or c == 230) return false;
    }
    return false;
}

/// Case conversion with the Turkish/Azeri/Lithuanian tailorings from
/// SpecialCasing.txt. Every code point the tailoring does not name falls through
/// to the same tables `caseConvert` uses.
fn caseConvertTailored(arena: std.mem.Allocator, s: []const u8, to_upper: bool, lang: []const u8) ![]const u8 {
    var cps = std.ArrayList(DecodedCp){};
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeCpJoined(s, i);
        try cps.append(arena, .{ .cp = d.cp, .paired = d.paired, .off = i, .len = d.len });
        i += d.len;
    }

    const turkic = std.mem.eql(u8, lang, "tr") or std.mem.eql(u8, lang, "az");
    const table = if (to_upper) ucase.to_upper else ucase.to_lower;
    var buf = std.ArrayList(u8){};
    for (cps.items, 0..) |d, idx| {
        // Each branch either emits its own replacement or falls through to the
        // untailored mapping below.
        const replacement: ?[]const u21 = blk: {
            if (turkic) {
                if (to_upper) {
                    if (d.cp == 0x0069) break :blk &[_]u21{0x0130};
                } else {
                    if (d.cp == 0x0130) break :blk &[_]u21{0x0069};
                    if (d.cp == 0x0307 and afterBase(cps.items, idx, false)) break :blk &[_]u21{};
                    if (d.cp == 0x0049 and !beforeDot(cps.items, idx)) break :blk &[_]u21{0x0131};
                }
            } else { // Lithuanian
                if (to_upper) {
                    if (d.cp == 0x0307 and afterBase(cps.items, idx, true)) break :blk &[_]u21{};
                } else {
                    // Capital I/J/Į keep an explicit dot when more accents follow.
                    if (moreAbove(cps.items, idx)) switch (d.cp) {
                        0x0049 => break :blk &[_]u21{ 0x0069, 0x0307 },
                        0x004A => break :blk &[_]u21{ 0x006A, 0x0307 },
                        0x012E => break :blk &[_]u21{ 0x012F, 0x0307 },
                        else => {},
                    };
                    switch (d.cp) {
                        0x00CC => break :blk &[_]u21{ 0x0069, 0x0307, 0x0300 },
                        0x00CD => break :blk &[_]u21{ 0x0069, 0x0307, 0x0301 },
                        0x0128 => break :blk &[_]u21{ 0x0069, 0x0307, 0x0303 },
                        else => {},
                    }
                }
            }
            break :blk null;
        };
        if (replacement) |rep| {
            for (rep) |m| try encodeCpAs(&buf, arena, m, d.paired);
        } else if (!to_upper and d.cp == 0x03A3 and isFinalSigma(s, d.off, d.len)) {
            try encodeWtf8Cp(&buf, arena, 0x03C2);
        } else if (ucase.lookup(table, d.cp)) |mapped| {
            for (mapped) |m| try encodeCpAs(&buf, arena, m, d.paired);
        } else {
            try buf.appendSlice(arena, s[d.off .. d.off + d.len]);
        }
    }
    return buf.items;
}

// ---------------------------------------------------------------------------
// localeCompare
// ---------------------------------------------------------------------------

/// String.prototype.localeCompare(that [, locales [, options]]) — §19.1.1.
/// Both strings are coerced first, then an Intl.Collator is constructed from the
/// remaining arguments and asked to compare them, so `localeCompare` and
/// `new Intl.Collator(...).compare` agree by construction (including which
/// arguments throw).
pub fn nativeLocaleCompare(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const intl_mod = @import("intl.zig");
    const s = try coerceThis(arena, this_val);
    const that = if (args.len > 0) try argToString(arena, args[0]) else "undefined";
    const collator = try intl_mod.collatorFor(
        arena,
        if (args.len > 1) args[1] else Value{},
        if (args.len > 2) args[2] else Value{},
    );
    return intl_mod.nativeCollatorCompare(arena, collator, &[_]Value{
        try val_mod.makeString(arena, s),
        try val_mod.makeString(arena, that),
    });
}

// ---------------------------------------------------------------------------
// ES2024 well-formed
// ---------------------------------------------------------------------------

/// String.prototype.isWellFormed() — true iff no *lone* surrogates. A high (lead)
/// surrogate immediately followed by a low (trail) surrogate forms a valid UTF-16
/// pair even when the two are stored as separate 3-byte WTF-8 code units (e.g. the
/// string built from `'\uD83D' + '\uDCA9'`), so only unpaired surrogates count.
pub fn nativeIsWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF) {
            // High surrogate — well-formed only when paired with a trailing low.
            const next = i + dec.len;
            if (next < s.len) {
                const dec2 = decodeWtf8At(s, next);
                if (dec2.cp >= 0xDC00 and dec2.cp <= 0xDFFF) {
                    i = next + dec2.len;
                    continue;
                }
            }
            return val_mod.makeBool(arena, false);
        }
        if (dec.cp >= 0xDC00 and dec.cp <= 0xDFFF) return val_mod.makeBool(arena, false);
        i += dec.len;
    }
    return val_mod.makeBool(arena, true);
}

/// String.prototype.toWellFormed() — replace *lone* surrogates with U+FFFD, but
/// leave a valid lead+trail pair (even one stored as two 3-byte WTF-8 units)
/// untouched.
pub fn nativeToWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF) {
            const next = i + dec.len;
            if (next < s.len) {
                const dec2 = decodeWtf8At(s, next);
                if (dec2.cp >= 0xDC00 and dec2.cp <= 0xDFFF) {
                    // Valid surrogate pair — keep both code units verbatim.
                    try buf.appendSlice(arena, s[i .. next + dec2.len]);
                    i = next + dec2.len;
                    continue;
                }
            }
            // Lone high surrogate → U+FFFD (EF BF BD).
            try buf.appendSlice(arena, &[_]u8{ 0xEF, 0xBF, 0xBD });
            i += dec.len;
            continue;
        }
        if (dec.cp >= 0xDC00 and dec.cp <= 0xDFFF) {
            // Lone low surrogate → U+FFFD.
            try buf.appendSlice(arena, &[_]u8{ 0xEF, 0xBF, 0xBD });
            i += dec.len;
            continue;
        }
        try buf.appendSlice(arena, s[i .. i + dec.len]);
        i += dec.len;
    }
    return val_mod.makeString(arena, try arena.dupe(u8, buf.items));
}

// ============================================================ normalize =======

const NormForm = enum { nfc, nfd, nfkc, nfkd };

// Hangul syllable composition/decomposition constants (UAX #15).
const HANGUL_S_BASE: u21 = 0xAC00;
const HANGUL_L_BASE: u21 = 0x1100;
const HANGUL_V_BASE: u21 = 0x1161;
const HANGUL_T_BASE: u21 = 0x11A7;
const HANGUL_L_COUNT: u21 = 19;
const HANGUL_V_COUNT: u21 = 21;
const HANGUL_T_COUNT: u21 = 28;
const HANGUL_N_COUNT: u21 = HANGUL_V_COUNT * HANGUL_T_COUNT; // 588
const HANGUL_S_COUNT: u21 = HANGUL_L_COUNT * HANGUL_N_COUNT; // 11172

/// Encode a single code point as WTF-8, mirroring `decodeWtf8At` (surrogates →
/// 3-byte forms; astral → 4-byte forms) so normalize round-trips the engine's
/// string representation exactly.
fn encodeWtf8Cp(buf: *std.ArrayList(u8), arena: std.mem.Allocator, cp: u21) !void {
    if (cp <= 0x7F) {
        try buf.append(arena, @intCast(cp));
    } else if (cp <= 0x7FF) {
        try buf.append(arena, @intCast(0xC0 | (cp >> 6)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
        try buf.append(arena, @intCast(0xE0 | (cp >> 12)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try buf.append(arena, @intCast(0xF0 | (cp >> 18)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    }
}

/// Recursively append the (compat or canonical) decomposition of `cp` to `out`,
/// expanding Hangul syllables algorithmically.
fn appendDecomp(out: *std.ArrayList(u21), arena: std.mem.Allocator, cp: u21, compat: bool) !void {
    if (cp >= HANGUL_S_BASE and cp < HANGUL_S_BASE + HANGUL_S_COUNT) {
        const si = cp - HANGUL_S_BASE;
        try out.append(arena, HANGUL_L_BASE + si / HANGUL_N_COUNT);
        try out.append(arena, HANGUL_V_BASE + (si % HANGUL_N_COUNT) / HANGUL_T_COUNT);
        const ti = si % HANGUL_T_COUNT;
        if (ti != 0) try out.append(arena, HANGUL_T_BASE + ti);
        return;
    }
    const dm = if (compat) unorm.compatDecomp(cp) else unorm.canonDecomp(cp);
    if (dm) |seq| {
        for (seq) |c| try appendDecomp(out, arena, c, compat);
    } else {
        try out.append(arena, cp);
    }
}

/// NFD of `s`, as code points. `Intl.Collator` needs the decomposed form to
/// separate a character's base letter from its accents.
pub fn nfdCodePoints(arena: std.mem.Allocator, s: []const u8) ![]u21 {
    var cps = std.ArrayList(u21){};
    var i: usize = 0;
    while (i < s.len) {
        var dec = decodeWtf8At(s, i);
        var consumed = dec.len;
        // A string built from `𝅗𝅥` escapes stores the pair as two
        // 3-byte sequences; the decomposition table is keyed on the code point,
        // so recombine before looking it up.
        if (dec.cp >= 0xD800 and dec.cp <= 0xDBFF and i + dec.len < s.len) {
            const lo = decodeWtf8At(s, i + dec.len);
            if (lo.cp >= 0xDC00 and lo.cp <= 0xDFFF) {
                dec.cp = 0x10000 + ((dec.cp - 0xD800) << 10) + (lo.cp - 0xDC00);
                consumed += lo.len;
            }
        }
        try appendDecomp(&cps, arena, dec.cp, false);
        i += consumed;
    }
    canonicalOrder(cps.items);
    return cps.items;
}

/// Canonical ordering: stable-sort each maximal run of combining marks (ccc > 0)
/// by combining class (UAX #15 D109).
fn canonicalOrder(cps: []u21) void {
    var i: usize = 0;
    while (i < cps.len) {
        if (unorm.ccc(cps[i]) == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < cps.len and unorm.ccc(cps[j]) != 0) j += 1;
        // Stable insertion sort of cps[i..j] by combining class.
        var k = i + 1;
        while (k < j) : (k += 1) {
            const v = cps[k];
            const vc = unorm.ccc(v);
            var m = k;
            while (m > i and unorm.ccc(cps[m - 1]) > vc) : (m -= 1) cps[m] = cps[m - 1];
            cps[m] = v;
        }
        i = j;
    }
}

/// Compose a starter `a` with a following combining/starter `b`, handling Hangul
/// L+V and LV+T algorithmically, else the primary-composite table.
fn composePair(a: u21, b: u21) ?u21 {
    // Hangul L + V -> LV
    if (a >= HANGUL_L_BASE and a < HANGUL_L_BASE + HANGUL_L_COUNT and
        b >= HANGUL_V_BASE and b < HANGUL_V_BASE + HANGUL_V_COUNT)
    {
        const li = a - HANGUL_L_BASE;
        const vi = b - HANGUL_V_BASE;
        return HANGUL_S_BASE + (li * HANGUL_V_COUNT + vi) * HANGUL_T_COUNT;
    }
    // Hangul LV + T -> LVT
    if (a >= HANGUL_S_BASE and a < HANGUL_S_BASE + HANGUL_S_COUNT and
        (a - HANGUL_S_BASE) % HANGUL_T_COUNT == 0 and
        b > HANGUL_T_BASE and b < HANGUL_T_BASE + HANGUL_T_COUNT)
    {
        return a + (b - HANGUL_T_BASE);
    }
    return unorm.compose(a, b);
}

/// Canonical composition of an already-decomposed, canonically-ordered sequence
/// (UAX #15 D117). Composes in place, returning the new length.
fn canonicalCompose(cps: []u21) usize {
    if (cps.len == 0) return 0;
    var out_len: usize = 1;
    cps[0] = cps[0];
    var last_starter: isize = if (unorm.ccc(cps[0]) == 0) 0 else -1;
    var last_cc: u8 = unorm.ccc(cps[0]);
    var k: usize = 1;
    while (k < cps.len) : (k += 1) {
        const ch = cps[k];
        const cc = unorm.ccc(ch);
        if (last_starter >= 0 and (last_cc == 0 or last_cc < cc)) {
            const si: usize = @intCast(last_starter);
            if (composePair(cps[si], ch)) |p| {
                cps[si] = p;
                continue; // b consumed; last_cc/last_starter unchanged
            }
        }
        cps[out_len] = ch;
        if (cc == 0) {
            last_starter = @intCast(out_len);
            last_cc = 0;
        } else {
            last_cc = cc;
        }
        out_len += 1;
    }
    return out_len;
}

/// String.prototype.normalize([form]) — ES2024 22.1.3.14.
pub fn nativeNormalize(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val); // ToString(this); abrupt propagates
    // Determine form: undefined/absent → "NFC"; else ToString(form) (abrupt
    // propagates) BEFORE validating, per spec step order.
    var form: []const u8 = "NFC";
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        form = try argToString(arena, args[0]);
    }
    const nf: NormForm = if (std.mem.eql(u8, form, "NFC"))
        .nfc
    else if (std.mem.eql(u8, form, "NFD"))
        .nfd
    else if (std.mem.eql(u8, form, "NFKC"))
        .nfkc
    else if (std.mem.eql(u8, form, "NFKD"))
        .nfkd
    else {
        _ = try throwRangeErrorStr(arena, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
        unreachable;
    };

    const compat = (nf == .nfkc or nf == .nfkd);
    const do_compose = (nf == .nfc or nf == .nfkc);

    // Decode WTF-8 → code points.
    var cps = std.ArrayList(u21){};
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        try appendDecomp(&cps, arena, dec.cp, compat);
        i += dec.len;
    }
    canonicalOrder(cps.items);
    const out_len = if (do_compose) canonicalCompose(cps.items) else cps.items.len;

    var buf = std.ArrayList(u8){};
    for (cps.items[0..out_len]) |cp| try encodeWtf8Cp(&buf, arena, cp);
    return val_mod.makeString(arena, try arena.dupe(u8, buf.items));
}
