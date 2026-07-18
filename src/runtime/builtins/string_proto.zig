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
            return "[object Object]";
        },
        else => return "[object Object]",
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
        .object => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .string)) orelse return "[object Object]";
            if (prim.bits != 0 and prim.unbox() == .object) return "[object Object]";
            return argToString(arena, prim);
        },
        else => return "[object Object]",
    }
}

/// ES ToNumber that throws TypeError for Symbol / BigInt (unlike the VM's lenient
/// toNumberValue which returns NaN). Used by string-method argument coercion.
fn toNumberChecked(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    if (v.bits == 0) return std.math.nan(f64);
    switch (v.unbox()) {
        .number => |n| return n,
        .boolean => |b| return if (b) 1 else 0,
        .null_ => return 0,
        .undefined_ => return std.math.nan(f64),
        .string => |s| return val_mod.jsStringToNumber(s),
        .symbol => {
            _ = try throwTypeErrorStr(arena, "Cannot convert a Symbol value to a number");
            unreachable;
        },
        .bigint => {
            _ = try throwTypeErrorStr(arena, "Cannot convert a BigInt value to a number");
            unreachable;
        },
        .object => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .number)) orelse return std.math.nan(f64);
            if (prim.bits != 0 and prim.unbox() == .object) return std.math.nan(f64);
            return toNumberChecked(arena, prim);
        },
        else => return std.math.nan(f64),
    }
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
    const m = v.toPtr().object.getSym(sym) orelse return null;
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
    if (i >= s.len) return val_mod.makeString(arena, "");
    const ch = try arena.dupe(u8, s[i .. i + 1]);
    return val_mod.makeString(arena, ch);
}

pub fn nativeCharCodeAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const i: usize = if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeNumber(arena, std.math.nan(f64)) else @intCast(val_mod.f64ToI64Sat(idx));
    if (i >= s.len) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @floatFromInt(s[i]));
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

/// String.prototype.codePointAt(pos): the code point whose WTF-8 encoding begins
/// at byte offset `pos` (this engine indexes strings by byte, consistent with
/// charCodeAt). Returns undefined when `pos` is out of range.
pub fn nativeCodePointAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeUndefined(arena);
    const i: usize = @intCast(val_mod.f64ToI64Sat(idx));
    if (i >= s.len) return val_mod.makeUndefined(arena);
    const dec = decodeWtf8At(s, i);
    return val_mod.makeNumber(arena, @floatFromInt(dec.cp));
}

pub fn nativeIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const pos: f64 = if (args.len > 1) try argToInteger(arena, args[1]) else 0;
    const from = clampToLen(pos, s.len);

    if (from >= s.len and search.len > 0) return val_mod.makeNumber(arena, -1.0);
    if (std.mem.indexOf(u8, s[from..], search)) |p| {
        return val_mod.makeNumber(arena, @floatFromInt(p + from));
    }
    return val_mod.makeNumber(arena, -1.0);
}

pub fn nativeSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = s.len;

    const start_raw: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const end_raw: f64 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        try argToInteger(arena, args[1])
    else
        @floatFromInt(len);

    const start = normalizeIndex(start_raw, len);
    const end_ = normalizeIndex(end_raw, len);

    if (start >= end_) return val_mod.makeString(arena, "");
    const slice = try arena.dupe(u8, s[start..end_]);
    return val_mod.makeString(arena, slice);
}

pub fn nativeToUpperCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return val_mod.makeString(arena, out);
}

pub fn nativeToLowerCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return val_mod.makeString(arena, out);
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
            const cv = if (cap.start == 0 and cap.end == 0)
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
        const cv: Value = if (cap.start == 0 and cap.end == 0)
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
        .object => |obj| obj.internal_kind == .bound_function,
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
        if (regexp_mod.getCompiledRegex(search) != null) {
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
            if (cap.start == 0 and cap.end == 0) {
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
/// includes}: a RegExp searchString is not allowed).
fn rejectRegExp(arena: std.mem.Allocator, a: Value) !void {
    if (a.bits != 0 and a.unbox() == .object and a.toPtr().object.internal_kind == .regexp) {
        const JsObject = @import("../../object/object.zig").JsObject;
        const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
        try obj.set("message", try val_mod.makeString(arena, "First argument to String.prototype.startsWith/endsWith/includes must not be a regular expression"));
        try obj.set("name", try val_mod.makeString(arena, "TypeError"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
        return error.JsException;
    }
}

/// ES2015 String.prototype.startsWith(searchString [, position]).
pub fn nativeStartsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const pos = if (args.len > 1) clampToLen(try argToInteger(arena, args[1]), s.len) else 0;
    if (pos + search.len > s.len) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[pos .. pos + search.len], search));
}

/// ES2015 String.prototype.endsWith(searchString [, endPosition]).
pub fn nativeEndsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const end_: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        clampToLen(try argToInteger(arena, args[1]), s.len)
    else
        s.len;
    if (search.len > end_) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[end_ - search.len .. end_], search));
}

/// ES2015 String.prototype.includes(searchString [, position]).
pub fn nativeStringIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = try argToString(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    const pos = if (args.len > 1) clampToLen(try argToInteger(arena, args[1]), s.len) else 0;
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

/// Build a pad filler of `count` bytes by repeating `pad`.
fn buildFiller(arena: std.mem.Allocator, pad: []const u8, count: usize) ![]const u8 {
    var buf = std.ArrayList(u8){};
    while (buf.items.len < count) {
        const remaining = count - buf.items.len;
        try buf.appendSlice(arena, if (pad.len <= remaining) pad else pad[0..remaining]);
    }
    return buf.items;
}

fn padImpl(arena: std.mem.Allocator, this_val: Value, args: []const Value, at_start: bool) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const max_len = if (args.len > 0) try argToInteger(arena, args[0]) else 0;
    const target: usize = if (max_len <= 0) 0 else @intCast(val_mod.f64ToI64Sat(max_len));
    if (target <= s.len) return val_mod.makeString(arena, s);
    const pad: []const u8 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        try argToString(arena, args[1])
    else
        " ";
    if (pad.len == 0) return val_mod.makeString(arena, s);
    const filler = try buildFiller(arena, pad, target - s.len);
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
    const len = s.len;

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
    return val_mod.makeString(arena, try arena.dupe(u8, s[from..to]));
}

/// String.prototype.substr(start, length) — legacy (Annex B).
pub fn nativeSubstr(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = s.len;

    const start_f: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    const int_start: i64 = if (std.math.isNan(start_f)) 0 else val_mod.f64ToI64Sat(start_f);

    const start: usize = if (int_start < 0) blk: {
        const r = @as(i64, @intCast(len)) + int_start;
        break :blk if (r < 0) 0 else @intCast(r);
    } else blk: {
        const u: usize = @intCast(int_start);
        break :blk if (u > len) len else u;
    };

    const size: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        blk: {
            const n: f64 = try argToInteger(arena, args[1]);
            if (n <= 0.0 or std.math.isNan(n)) break :blk 0;
            const u: usize = @intCast(val_mod.f64ToI64Sat(n));
            const max = len - start;
            break :blk if (u > max) max else u;
        }
    else
        len - start;

    return val_mod.makeString(arena, try arena.dupe(u8, s[start .. start + size]));
}

/// String.prototype.at(index) — ES2022.
pub fn nativeStringAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const raw: f64 = if (args.len > 0) try argToInteger(arena, args[0]) else 0.0;
    var k: i64 = if (std.math.isNan(raw)) 0 else val_mod.f64ToI64Sat(raw);
    if (k < 0) k = @as(i64, @intCast(s.len)) + k;
    if (k < 0 or k >= @as(i64, @intCast(s.len))) return val_mod.makeUndefined(arena);
    const idx: usize = @intCast(k);
    return val_mod.makeString(arena, try arena.dupe(u8, s[idx .. idx + 1]));
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
    const pos_limit: usize = clampToLen(pos, s.len);

    if (search.len == 0) {
        return val_mod.makeNumber(arena, @floatFromInt(if (pos_limit > s.len) s.len else pos_limit));
    }
    if (s.len < search.len) return val_mod.makeNumber(arena, -1.0);

    const max_start: usize = if (pos_limit > s.len - search.len) s.len - search.len else pos_limit;

    var i: usize = max_start + 1;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, s[i .. i + search.len], search)) {
            return val_mod.makeNumber(arena, @floatFromInt(i));
        }
    }
    return val_mod.makeNumber(arena, -1.0);
}

// ---------------------------------------------------------------------------
// Locale aliases
// ---------------------------------------------------------------------------

pub fn nativeToLocaleLowerCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeToLowerCase(arena, this_val, args);
}

pub fn nativeToLocaleUpperCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeToUpperCase(arena, this_val, args);
}

// ---------------------------------------------------------------------------
// localeCompare
// ---------------------------------------------------------------------------

/// String.prototype.localeCompare(that) — byte-wise lexicographic order.
pub fn nativeLocaleCompare(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const that = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    const result: f64 = switch (std.mem.order(u8, s, that)) {
        .lt => -1.0,
        .eq => 0.0,
        .gt => 1.0,
    };
    return val_mod.makeNumber(arena, result);
}

// ---------------------------------------------------------------------------
// ES2024 well-formed
// ---------------------------------------------------------------------------

/// String.prototype.isWellFormed() — true iff no lone surrogates in WTF-8.
pub fn nativeIsWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDFFF) return val_mod.makeBool(arena, false);
        i += dec.len;
    }
    return val_mod.makeBool(arena, true);
}

/// String.prototype.toWellFormed() — replace lone surrogates with U+FFFD.
pub fn nativeToWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDFFF) {
            // U+FFFD encoded as EF BF BD in UTF-8/WTF-8
            try buf.appendSlice(arena, &[_]u8{ 0xEF, 0xBF, 0xBD });
        } else {
            try buf.appendSlice(arena, s[i .. i + dec.len]);
        }
        i += dec.len;
    }
    return val_mod.makeString(arena, try arena.dupe(u8, buf.items));
}
