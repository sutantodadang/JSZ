// Intl.NumberFormat: option resolution, the shared number-formatting core, and
// the `format` / `formatToParts` / `formatRange*` / `resolvedOptions` natives.
//
// Split out of `intl.zig` so the numeric machinery (rounding, digit layout,
// locale patterns) lives apart from the date/locale services it has nothing in
// common with. `intl.zig` re-exports the natives under their original names, so
// the realm registration is unchanged.
//
// The formatting core works on decimal *digit strings*, never on scaled
// integers: ECMA-402 defines `format` over a mathematical value, and the tests
// round-trip inputs like "12344501000000000000000000000000000" and
// "0.00000000000000000000000000000123" that no binary float can carry.

const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const coercion = @import("coercion.zig");
const intl = @import("intl.zig");
const data = @import("intl_number_data.zig");

const throwRangeError = intl.throwRangeError;
const throwTypeErrorIntl = intl.throwTypeErrorIntl;
const dnGetOption = intl.dnGetOption;
const dnGetNumOption = intl.dnGetNumOption;
const coerceOptionsToObject = intl.coerceOptionsToObject;
const resolveAndStoreLocale = intl.resolveAndStoreLocale;
const isWellFormedNumberingSystem = intl.isWellFormedNumberingSystem;
const upperDup = intl.upperDup;
const resolvedLocaleOf = intl.resolvedLocaleOf;
const legacyServiceObj = intl.numberFormatServiceObj;

// ------------------------------------------------------------------- decimals ---

/// A finite decimal magnitude plus a sign, or one of the two non-finite values.
///
/// `digits` holds the significant digits with no leading or trailing zeros, and
/// `e` is the base-10 exponent of `digits[0]`, so the magnitude is
/// `digits × 10^(e - digits.len + 1)`. An empty `digits` means zero (`e` is then
/// meaningless), which keeps "is this value zero" a length test.
const Decimal = struct {
    neg: bool = false,
    digits: []const u8 = "",
    e: i32 = 0,
    kind: Kind = .finite,

    const Kind = enum { finite, nan, infinity };

    fn isZero(self: Decimal) bool {
        return self.kind == .finite and self.digits.len == 0;
    }
};

/// Exponents beyond this are not representable in any output we can produce, and
/// letting them through would make the digit-layout buffers explode.
const max_exponent: i32 = 10000;

/// Drop leading and trailing zeros, adjusting `e` for each leading zero removed.
fn normalizeDecimal(neg: bool, raw: []const u8, e_in: i32) Decimal {
    var digits = raw;
    var e = e_in;
    while (digits.len > 0 and digits[0] == '0') {
        digits = digits[1..];
        e -= 1;
    }
    while (digits.len > 0 and digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    if (digits.len == 0) return .{ .neg = neg };
    return .{ .neg = neg, .digits = digits, .e = e };
}

/// Build a Decimal from an f64 via the shortest round-trip representation, the
/// same trick `value.formatNumber` uses: Zig's `{e}` gives exactly the digits
/// ECMAScript's Number::toString would produce.
fn decimalFromF64(arena: std.mem.Allocator, x: f64) !Decimal {
    if (std.math.isNan(x)) return .{ .kind = .nan };
    const neg = std.math.signbit(x);
    if (std.math.isInf(x)) return .{ .neg = neg, .kind = .infinity };
    const a = @abs(x);
    if (a == 0) return .{ .neg = neg };

    var sbuf: [64]u8 = undefined;
    const sci = try std.fmt.bufPrint(&sbuf, "{e}", .{a});
    const e_idx = std.mem.indexOfScalar(u8, sci, 'e') orelse std.mem.indexOfScalar(u8, sci, 'E').?;
    const exp = try std.fmt.parseInt(i32, sci[e_idx + 1 ..], 10);
    var out = try arena.alloc(u8, e_idx);
    var k: usize = 0;
    for (sci[0..e_idx]) |c| {
        if (c >= '0' and c <= '9') {
            out[k] = c;
            k += 1;
        }
    }
    return normalizeDecimal(neg, out[0..k], exp);
}

fn isStrWhiteSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

/// ToIntlMathematicalValue's String case (§15.5.1): a String argument is read as
/// an exact `StringNumericLiteral`, *not* rounded through ToNumber first, so
/// `format("1.0000000000000001")` keeps all seventeen digits.
fn decimalFromString(arena: std.mem.Allocator, s_in: []const u8) !Decimal {
    var s = s_in;
    while (s.len > 0 and isStrWhiteSpace(s[0])) s = s[1..];
    while (s.len > 0 and isStrWhiteSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    if (s.len == 0) return .{}; // StrWhiteSpace only → +0

    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (std.mem.eql(u8, s, "Infinity")) return .{ .neg = neg, .kind = .infinity };

    // Non-decimal integer literals keep the ordinary numeric-literal rules; they
    // are never large in practice, so a u64 parse is enough (overflow → NaN).
    if (!neg and s.len > 2 and s[0] == '0') {
        const radix: ?u8 = switch (s[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            const v = std.fmt.parseInt(u64, s[2..], r) catch return .{ .kind = .nan };
            const txt = try std.fmt.allocPrint(arena, "{d}", .{v});
            return normalizeDecimal(false, txt, @as(i32, @intCast(txt.len)) - 1);
        }
    }

    var digits = std.ArrayListUnmanaged(u8){};
    // Exponent of the first digit collected, filled in once the point is placed.
    var int_len: i32 = 0;
    var saw_digit = false;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        try digits.append(arena, s[i]);
        int_len += 1;
        saw_digit = true;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            try digits.append(arena, s[i]);
            saw_digit = true;
        }
    }
    if (!saw_digit) return .{ .kind = .nan };
    var exp: i32 = 0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        var esign: i32 = 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            if (s[i] == '-') esign = -1;
            i += 1;
        }
        if (i >= s.len) return .{ .kind = .nan };
        var acc: i64 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            acc = @min(acc * 10 + (s[i] - '0'), max_exponent * 2);
        }
        exp = esign * @as(i32, @intCast(acc));
    }
    if (i != s.len) return .{ .kind = .nan };

    var dec = normalizeDecimal(neg, digits.items, int_len - 1 + exp);
    if (dec.kind == .finite and !dec.isZero()) {
        if (dec.e > max_exponent) return .{ .neg = neg, .kind = .infinity };
        if (dec.e < -max_exponent) return .{ .neg = neg };
    }
    return dec;
}

/// ToIntlMathematicalValue (§15.5.1): ToPrimitive with the number hint, then an
/// exact reading of Strings and BigInts. Symbols throw, as ToNumber would.
fn toIntlMathematicalValue(arena: std.mem.Allocator, v: Value) anyerror!Decimal {
    var prim = v;
    if (!coercion.isPrimitive(v)) {
        prim = (try coercion.toPrimitive(arena, v, .number)) orelse
            return realm_mod.throwTypeError(arena, "Cannot convert object to a number");
    }
    if (prim.bits == 0) return .{ .kind = .nan };
    return switch (prim.unbox()) {
        .undefined_ => Decimal{ .kind = .nan },
        .null_ => Decimal{},
        .boolean => |b| if (b) Decimal{ .digits = "1", .e = 0 } else Decimal{},
        .number => |n| try decimalFromF64(arena, n),
        .string => |s| try decimalFromString(arena, s),
        .bigint => try decimalFromString(arena, try val_mod.bigIntToString(arena, prim.toPtr().bigint)),
        .symbol => realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        else => Decimal{ .kind = .nan },
    };
}

// ------------------------------------------------------- digit-string helpers ---

fn allZeros(s: []const u8) bool {
    for (s) |c| if (c != '0') return false;
    return true;
}

fn zeroRun(arena: std.mem.Allocator, n: usize) ![]const u8 {
    const buf = try arena.alloc(u8, n);
    @memset(buf, '0');
    return buf;
}

/// Strip leading zeros; the empty string is this module's canonical zero.
fn trimLeadingZeros(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == '0') i += 1;
    return s[i..];
}

/// Long division of a decimal digit string by a small divisor.
fn divSmall(arena: std.mem.Allocator, a: []const u8, m: u32) !struct { q: []const u8, r: u32 } {
    if (m == 1) return .{ .q = trimLeadingZeros(a), .r = 0 };
    var out = try arena.alloc(u8, a.len);
    var r: u64 = 0;
    for (a, 0..) |c, i| {
        r = r * 10 + (c - '0');
        out[i] = @intCast('0' + r / m);
        r %= m;
    }
    return .{ .q = trimLeadingZeros(out), .r = @intCast(r) };
}

fn mulSmall(arena: std.mem.Allocator, a: []const u8, m: u32) ![]const u8 {
    if (m == 1 or a.len == 0) return a;
    var out = std.ArrayListUnmanaged(u8){};
    var carry: u64 = 0;
    var i = a.len;
    while (i > 0) {
        i -= 1;
        const p = @as(u64, a[i] - '0') * m + carry;
        try out.append(arena, @intCast('0' + p % 10));
        carry = p / 10;
    }
    while (carry > 0) {
        try out.append(arena, @intCast('0' + carry % 10));
        carry /= 10;
    }
    std.mem.reverse(u8, out.items);
    return trimLeadingZeros(out.items);
}

fn addOne(arena: std.mem.Allocator, a: []const u8) ![]const u8 {
    var out = try arena.alloc(u8, a.len + 1);
    out[0] = '0';
    @memcpy(out[1..], a);
    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (out[i] == '9') {
            out[i] = '0';
        } else {
            out[i] += 1;
            break;
        }
    }
    return trimLeadingZeros(out);
}

// ------------------------------------------------------------------- rounding ---

/// ECMA-402 roundingMode.
pub const RoundMode = enum {
    ceil,
    floor,
    expand,
    trunc,
    half_ceil,
    half_floor,
    half_expand,
    half_trunc,
    half_even,
};

fn roundModeFromString(s_: []const u8) ?RoundMode {
    const table = .{
        .{ "ceil", RoundMode.ceil },
        .{ "floor", RoundMode.floor },
        .{ "expand", RoundMode.expand },
        .{ "trunc", RoundMode.trunc },
        .{ "halfCeil", RoundMode.half_ceil },
        .{ "halfFloor", RoundMode.half_floor },
        .{ "halfExpand", RoundMode.half_expand },
        .{ "halfTrunc", RoundMode.half_trunc },
        .{ "halfEven", RoundMode.half_even },
    };
    inline for (table) |e| if (std.mem.eql(u8, s_, e[0])) return e[1];
    return null;
}

/// GetUnsignedRoundingMode: how to round a *magnitude*, given the sign of the
/// value it came from. "ceil" on a negative number rounds its magnitude down.
const UnsignedMode = enum { zero, infinity, half_zero, half_infinity, half_even };

fn unsignedRoundingMode(mode: RoundMode, negative: bool) UnsignedMode {
    return switch (mode) {
        .ceil => if (negative) .zero else .infinity,
        .floor => if (negative) .infinity else .zero,
        .expand => .infinity,
        .trunc => .zero,
        .half_ceil => if (negative) .half_zero else .half_infinity,
        .half_floor => if (negative) .half_infinity else .half_zero,
        .half_expand => .half_infinity,
        .half_trunc => .half_zero,
        .half_even => .half_even,
    };
}

/// A rounded magnitude: `digits × 10^position`, with the empty digit string
/// standing for zero.
const Rounded = struct {
    digits: []const u8,
    position: i32,

    /// Base-10 exponent of the leading digit; only meaningful when non-zero.
    fn exponent(self: Rounded) i32 {
        return self.position + @as(i32, @intCast(self.digits.len)) - 1;
    }
};

/// Round `dec`'s magnitude to a multiple of `increment × 10^position` under an
/// unsigned rounding mode, entirely in decimal digit space (§15.5, "round to a
/// multiple of the rounding increment at the given magnitude").
fn roundDecimalAt(
    arena: std.mem.Allocator,
    dec: Decimal,
    position: i32,
    increment: u32,
    mode: UnsignedMode,
) !Rounded {
    // Split the magnitude at 10^position into the truncated integer `i0` and the
    // leftover fraction digits `rest`, by pure slicing and zero padding.
    var trunc: []const u8 = "";
    var rest: []const u8 = "";
    if (dec.digits.len != 0) {
        const len: i32 = @intCast(dec.digits.len);
        const n = dec.e - position + 1; // integer digits at this scale
        if (n <= 0) {
            const pad = @min(-n, max_exponent);
            trunc = "";
            rest = try std.mem.concat(arena, u8, &.{ try zeroRun(arena, @intCast(pad)), dec.digits });
        } else if (n >= len) {
            const pad = @min(n - len, max_exponent);
            trunc = try std.mem.concat(arena, u8, &.{ dec.digits, try zeroRun(arena, @intCast(pad)) });
        } else {
            trunc = dec.digits[0..@intCast(n)];
            rest = dec.digits[@intCast(n)..];
        }
    }

    const dv = try divSmall(arena, trunc, increment);
    var q = dv.q;
    const r = dv.r;
    const exact = r == 0 and allZeros(rest);
    if (!exact) {
        // Compare (r + 0.rest) against increment/2 without leaving integers:
        // t = 2r - increment tells all but the two near-half cases.
        const t: i64 = 2 * @as(i64, r) - @as(i64, increment);
        const cmp: HalfCmp = if (t > 0)
            .above
        else if (t < -1)
            .below
        else if (t == 0)
            (if (allZeros(rest)) .tie else .above)
        else
            compareHalf(rest);
        const up = switch (mode) {
            .zero => false,
            .infinity => true,
            .half_zero => cmp == .above,
            .half_infinity => cmp != .below,
            .half_even => switch (cmp) {
                .above => true,
                .below => false,
                .tie => q.len > 0 and (q[q.len - 1] - '0') % 2 == 1,
            },
        };
        if (up) q = try addOne(arena, q);
    }
    return .{ .digits = try mulSmall(arena, q, increment), .position = position };
}

/// Where a leftover fraction sits relative to one half.
const HalfCmp = enum { below, tie, above };

/// Compare the fraction `0.rest` against one half.
fn compareHalf(rest: []const u8) HalfCmp {
    if (rest.len == 0) return .below;
    if (rest[0] > '5') return .above;
    if (rest[0] < '5') return .below;
    return if (allZeros(rest[1..])) .tie else .above;
}

// --------------------------------------------------------------- digit layout ---

/// The outcome of ToRawFixed / ToRawPrecision: the laid-out digit string plus
/// the facts PartitionNumberPattern needs about the rounded value.
const RawResult = struct {
    /// Digits with an ASCII "." decimal point; no sign, no grouping.
    string: []const u8,
    /// Base-10 exponent of the last retained digit; smaller means more precise.
    magnitude: i32,
    rounded: Rounded,

    fn isZero(self: RawResult) bool {
        return self.rounded.digits.len == 0;
    }
};

/// ToRawFixed (§15.5.10).
fn toRawFixed(
    arena: std.mem.Allocator,
    dec: Decimal,
    min_int: u32,
    min_frac: u32,
    max_frac: u32,
    increment: u32,
    mode: UnsignedMode,
) !RawResult {
    const f: i32 = @intCast(max_frac);
    const rr = try roundDecimalAt(arena, dec, -f, increment, mode);
    var m: []const u8 = if (rr.digits.len == 0) "0" else rr.digits;
    var int_len: usize = m.len;
    if (max_frac != 0) {
        if (m.len <= max_frac) {
            m = try std.mem.concat(arena, u8, &.{ try zeroRun(arena, max_frac + 1 - m.len), m });
        }
        int_len = m.len - max_frac;
        m = try std.mem.concat(arena, u8, &.{ m[0..int_len], ".", m[int_len..] });
    }
    m = stripTrailingZeros(m, max_frac - min_frac);
    if (int_len < min_int) {
        m = try std.mem.concat(arena, u8, &.{ try zeroRun(arena, min_int - int_len), m });
    }
    return .{ .string = m, .magnitude = -f, .rounded = rr };
}

/// ToRawPrecision (§15.5.11).
fn toRawPrecision(
    arena: std.mem.Allocator,
    dec: Decimal,
    min_sig: u32,
    max_sig: u32,
    mode: UnsignedMode,
) !RawResult {
    const p: i32 = @intCast(max_sig);
    var e: i32 = 0;
    var digits: []const u8 = "";
    var rr = Rounded{ .digits = "", .position = 1 - p };
    if (!dec.isZero()) {
        rr = try roundDecimalAt(arena, dec, dec.e - p + 1, 1, mode);
        digits = rr.digits;
        e = dec.e;
        // Rounding up can carry into a new leading digit (999.9 at p = 3 → 1000).
        if (digits.len > max_sig) {
            e += 1;
            digits = digits[0..max_sig];
        }
    } else {
        digits = try zeroRun(arena, max_sig);
    }

    var m: []const u8 = digits;
    if (e >= p - 1) {
        m = try std.mem.concat(arena, u8, &.{ digits, try zeroRun(arena, @intCast(e - p + 1)) });
    } else if (e >= 0) {
        const head: usize = @intCast(e + 1);
        m = try std.mem.concat(arena, u8, &.{ digits[0..head], ".", digits[head..] });
    } else {
        m = try std.mem.concat(arena, u8, &.{ "0.", try zeroRun(arena, @intCast(-(e + 1))), digits });
    }
    m = stripTrailingZeros(m, max_sig - min_sig);
    return .{ .string = m, .magnitude = e - p + 1, .rounded = rr };
}

/// Remove up to `cut` trailing fraction zeros, then a dangling decimal point.
fn stripTrailingZeros(m_in: []const u8, cut_in: u32) []const u8 {
    var m = m_in;
    if (std.mem.indexOfScalar(u8, m, '.') == null) return m;
    var cut = cut_in;
    while (cut > 0 and m.len > 0 and m[m.len - 1] == '0') {
        m = m[0 .. m.len - 1];
        cut -= 1;
    }
    if (m.len > 0 and m[m.len - 1] == '.') m = m[0 .. m.len - 1];
    return m;
}

/// FormatNumericToString (§15.5.9): dispatch on the resolved rounding type, then
/// apply `trailingZeroDisplay`.
fn formatNumericToString(arena: std.mem.Allocator, opt: NfOptions, dec: Decimal) !RawResult {
    const mode = unsignedRoundingMode(opt.rounding_mode, dec.neg);
    var res: RawResult = switch (opt.rounding_type) {
        .significant_digits => try toRawPrecision(arena, dec, opt.min_sig, opt.max_sig, mode),
        .fraction_digits => try toRawFixed(
            arena,
            dec,
            opt.min_int,
            opt.min_frac,
            opt.max_frac,
            opt.rounding_increment,
            mode,
        ),
        .more_precision, .less_precision => blk: {
            const sr = try toRawPrecision(arena, dec, opt.min_sig, opt.max_sig, mode);
            const fr = try toRawFixed(arena, dec, opt.min_int, opt.min_frac, opt.max_frac, 1, mode);
            // A smaller rounding magnitude keeps more digits; ties go to the
            // significant-digits result.
            const take_sig = if (opt.rounding_type == .more_precision)
                sr.magnitude <= fr.magnitude
            else
                sr.magnitude >= fr.magnitude;
            break :blk if (take_sig) sr else fr;
        },
    };
    if (opt.strip_if_integer) {
        if (std.mem.indexOfScalar(u8, res.string, '.')) |dot| {
            if (allZeros(res.string[dot + 1 ..])) res.string = res.string[0..dot];
        }
    }
    return res;
}

// -------------------------------------------------------------------- options ---

const RoundingType = enum { fraction_digits, significant_digits, more_precision, less_precision };

fn roundingTypeFromString(s: []const u8) RoundingType {
    if (std.mem.eql(u8, s, "significantDigits")) return .significant_digits;
    if (std.mem.eql(u8, s, "morePrecision")) return .more_precision;
    if (std.mem.eql(u8, s, "lessPrecision")) return .less_precision;
    return .fraction_digits;
}

fn roundingTypeToString(t: RoundingType) []const u8 {
    return switch (t) {
        .fraction_digits => "fractionDigits",
        .significant_digits => "significantDigits",
        .more_precision => "morePrecision",
        .less_precision => "lessPrecision",
    };
}

/// The resolved NumberFormat options that affect output.
pub const NfOptions = struct {
    locale: []const u8 = "en-US",
    style: []const u8 = "decimal",
    currency: []const u8 = "USD",
    currency_display: []const u8 = "symbol",
    currency_sign: []const u8 = "standard",
    unit: []const u8 = "",
    unit_display: []const u8 = "short",
    notation: []const u8 = "standard",
    compact_display: []const u8 = "short",
    min_int: u32 = 1,
    min_frac: u32 = 0,
    max_frac: u32 = 3,
    min_sig: u32 = 1,
    max_sig: u32 = 21,
    rounding_type: RoundingType = .fraction_digits,
    /// "auto" / "always" / "min2" / "false".
    use_grouping: []const u8 = "auto",
    sign_display: []const u8 = "auto",
    rounding_mode: RoundMode = .half_expand,
    rounding_increment: u32 = 1,
    /// trailingZeroDisplay "stripIfInteger".
    strip_if_integer: bool = false,
};

// ------------------------------------------------------------------ formatting ---

/// One element of a `formatToParts` result.
pub const NumberPart = struct {
    type: []const u8,
    value: []const u8,
    /// Which end of a range this part came from. Only `formatRangeToParts`
    /// reports it; plain `formatToParts` parts leave it null.
    source: ?[]const u8 = null,
};

/// ComputeExponentForMagnitude (§15.5.7): which power of ten the notation wants
/// to divide by, for a value whose leading digit sits at 10^magnitude.
fn exponentForMagnitude(opt: NfOptions, ld: *const data.LocaleData, magnitude: i32) i32 {
    if (std.mem.eql(u8, opt.notation, "scientific")) return magnitude;
    if (std.mem.eql(u8, opt.notation, "engineering")) return @divFloor(magnitude, 3) * 3;
    if (!std.mem.eql(u8, opt.notation, "compact")) return 0;
    const table = if (std.mem.eql(u8, opt.compact_display, "long")) ld.compact_long else ld.compact_short;
    var best: i32 = 0;
    for (table) |entry| {
        if (entry.exp <= magnitude and entry.exp > best) best = entry.exp;
    }
    return best;
}

/// ComputeExponent (§15.5.6): pick the exponent, then re-check it against the
/// rounded mantissa, because rounding 999.9K up produces 1000K → 1M.
fn computeExponent(arena: std.mem.Allocator, opt: NfOptions, ld: *const data.LocaleData, dec: Decimal) !i32 {
    if (dec.kind != .finite or dec.isZero()) return 0;
    const magnitude = dec.e;
    const exponent = exponentForMagnitude(opt, ld, magnitude);
    var scaled = dec;
    scaled.e -= exponent;
    const r = try formatNumericToString(arena, opt, scaled);
    if (r.isZero()) return exponent;
    if (r.rounded.exponent() == magnitude - exponent) return exponent;
    return exponentForMagnitude(opt, ld, magnitude + 1);
}

/// The three sign patterns of GetNumberFormatPattern (§15.5.4).
const SignKind = enum { zero, positive, negative };

fn chooseSign(sign_display: []const u8, is_nan: bool, neg: bool, is_zero: bool) SignKind {
    if (std.mem.eql(u8, sign_display, "never")) return .zero;
    if (std.mem.eql(u8, sign_display, "always")) {
        return if (is_nan or !neg) .positive else .negative;
    }
    if (std.mem.eql(u8, sign_display, "exceptZero")) {
        if (is_nan or is_zero) return .zero;
        return if (neg) .negative else .positive;
    }
    if (std.mem.eql(u8, sign_display, "negative")) {
        if (is_nan or is_zero or !neg) return .zero;
        return .negative;
    }
    // "auto": the sign of the *rounded* value decides, so -0.0001 at three
    // fraction digits still prints "-0".
    return if (!is_nan and neg) .negative else .zero;
}

/// The locale's symbol for `code`, or the code itself when this build has none
/// (which is what ECMA-402 falls back to).
fn currencySymbol(ld: *const data.LocaleData, code: []const u8, narrow: bool) []const u8 {
    for (ld.currencies) |c| {
        if (std.mem.eql(u8, c.code, code)) return if (narrow and c.narrow.len > 0) c.narrow else c.symbol;
    }
    for (data.currencies_root) |c| {
        if (std.mem.eql(u8, c.code, code)) return if (narrow and c.narrow.len > 0) c.narrow else c.symbol;
    }
    return code;
}

/// en-US short unit symbols; unlisted units fall back to the identifier itself.
fn unitSymbol(unit: []const u8, long: bool) []const u8 {
    if (long) return unit;
    const table = [_]struct { u: []const u8, s: []const u8 }{
        .{ .u = "meter", .s = "m" },         .{ .u = "kilometer", .s = "km" },
        .{ .u = "centimeter", .s = "cm" },   .{ .u = "millimeter", .s = "mm" },
        .{ .u = "mile", .s = "mi" },         .{ .u = "foot", .s = "ft" },
        .{ .u = "inch", .s = "in" },         .{ .u = "yard", .s = "yd" },
        .{ .u = "gram", .s = "g" },          .{ .u = "kilogram", .s = "kg" },
        .{ .u = "ounce", .s = "oz" },        .{ .u = "pound", .s = "lb" },
        .{ .u = "second", .s = "sec" },      .{ .u = "minute", .s = "min" },
        .{ .u = "hour", .s = "hr" },         .{ .u = "day", .s = "days" },
        .{ .u = "week", .s = "wks" },        .{ .u = "month", .s = "mths" },
        .{ .u = "year", .s = "yrs" },        .{ .u = "byte", .s = "byte" },
        .{ .u = "percent", .s = "%" },       .{ .u = "liter", .s = "L" },
        .{ .u = "celsius", .s = "\u{b0}C" }, .{ .u = "fahrenheit", .s = "\u{b0}F" },
    };
    for (table) |e| if (std.mem.eql(u8, e.u, unit)) return e.s;
    return unit;
}

/// The locale's simple-unit forms for `name`, or null when it lists none.
/// `is_one` picks the CLDR `one` plural form where the locale distinguishes it.
fn simpleUnitForm(ld: *const data.LocaleData, name: []const u8, display: []const u8, is_one: bool) ?data.UnitForm {
    for (ld.units) |e| {
        if (!std.mem.eql(u8, e.unit, name)) continue;
        if (std.mem.eql(u8, display, "narrow")) return if (is_one) e.narrow_one orelse e.narrow else e.narrow;
        if (std.mem.eql(u8, display, "long")) return if (is_one) e.long_one orelse e.long else e.long;
        return if (is_one) e.short_one orelse e.short else e.short;
    }
    return null;
}

/// The `perUnitPattern` tail a compound unit appends after its numerator.
fn perUnitTail(ld: *const data.LocaleData, name: []const u8, display: []const u8) []const u8 {
    for (ld.units) |e| {
        if (!std.mem.eql(u8, e.unit, name)) continue;
        if (std.mem.eql(u8, display, "narrow")) return e.per_narrow;
        if (std.mem.eql(u8, display, "long")) return e.per_long;
        return e.per_short;
    }
    return "";
}

/// The wrapping for `style: "unit"`. A compound `x-per-y` uses the numerator's
/// form plus the denominator's `perUnitPattern`; units the locale table does not
/// list at all fall back to a generic "<number> <symbol>" shape.
fn unitForm(arena: std.mem.Allocator, ld: *const data.LocaleData, opt: NfOptions, is_one: bool) !data.UnitForm {
    if (simpleUnitForm(ld, opt.unit, opt.unit_display, is_one)) |f| return f;

    const long = std.mem.eql(u8, opt.unit_display, "long");
    const sep: []const u8 = if (std.mem.eql(u8, opt.unit_display, "narrow")) "" else " ";
    if (std.mem.indexOf(u8, opt.unit, "-per-")) |i| {
        const num_name = opt.unit[0..i];
        const den_name = opt.unit[i + 5 ..];
        const num: data.UnitForm = simpleUnitForm(ld, num_name, opt.unit_display, is_one) orelse
            .{ .sep = sep, .suffix = unitSymbol(num_name, long) };
        const tail = perUnitTail(ld, den_name, opt.unit_display);
        if (tail.len > 0) {
            return .{
                .prefix = num.prefix,
                .prefix_sep = num.prefix_sep,
                .sep = num.sep,
                .suffix = try std.fmt.allocPrint(arena, "{s}{s}", .{ num.suffix, tail }),
            };
        }
        const den = unitSymbol(den_name, long);
        const joined = if (long)
            try std.fmt.allocPrint(arena, "{s} per {s}", .{ num.suffix, den })
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ num.suffix, den });
        return .{ .sep = num.sep, .suffix = joined };
    }
    return .{ .sep = sep, .suffix = unitSymbol(opt.unit, long) };
}

/// Emit the digits of `digit_str` as alternating integer/group runs plus the
/// decimal and fraction parts, which is what distinguishes formatToParts from a
/// plain grouped string.
fn emitDigits(
    arena: std.mem.Allocator,
    parts: *std.ArrayList(NumberPart),
    digit_str: []const u8,
    ld: *const data.LocaleData,
    opt: NfOptions,
) !void {
    const dot = std.mem.indexOfScalar(u8, digit_str, '.');
    const int_str = if (dot) |d| digit_str[0..d] else digit_str;
    const frac_str = if (dot) |d| digit_str[d + 1 ..] else "";

    // useGrouping picks the minimum integer-digit count that earns separators;
    // scientific/engineering mantissas are never grouped.
    const sci = std.mem.eql(u8, opt.notation, "scientific") or std.mem.eql(u8, opt.notation, "engineering");
    const min_grouping: ?u8 = if (sci or std.mem.eql(u8, opt.use_grouping, "false"))
        null
    else if (std.mem.eql(u8, opt.use_grouping, "always"))
        1
    else if (std.mem.eql(u8, opt.use_grouping, "min2"))
        2
    else
        ld.min_grouping;

    var grouped = false;
    if (min_grouping) |mg| grouped = int_str.len >= @as(usize, ld.group_primary) + mg;

    if (!grouped) {
        try parts.append(arena, .{ .type = "integer", .value = int_str });
    } else {
        // Walk right-to-left collecting group boundaries, then emit left-to-right.
        var cuts: [24]usize = undefined;
        var n_cuts: usize = 0;
        var pos: usize = int_str.len - ld.group_primary;
        cuts[n_cuts] = pos;
        n_cuts += 1;
        while (pos > ld.group_secondary and n_cuts < cuts.len) {
            pos -= ld.group_secondary;
            cuts[n_cuts] = pos;
            n_cuts += 1;
        }
        var start: usize = 0;
        var i = n_cuts;
        while (i > 0) {
            i -= 1;
            try parts.append(arena, .{ .type = "integer", .value = int_str[start..cuts[i]] });
            try parts.append(arena, .{ .type = "group", .value = ld.group });
            start = cuts[i];
        }
        try parts.append(arena, .{ .type = "integer", .value = int_str[start..] });
    }

    if (frac_str.len > 0) {
        try parts.append(arena, .{ .type = "decimal", .value = ld.decimal });
        try parts.append(arena, .{ .type = "fraction", .value = frac_str });
    }
}

/// PartitionNumberPattern (§15.5.3): the whole formatting pipeline, as the
/// `formatToParts` part list. `format` is the concatenation of these values, so
/// the two cannot drift apart.
fn partitionNumberPattern(arena: std.mem.Allocator, dec_in: Decimal, opt: NfOptions) ![]NumberPart {
    const ld = data.forLocale(opt.locale);
    var parts: std.ArrayList(NumberPart) = .empty;

    var dec = dec_in;
    const is_percent = std.mem.eql(u8, opt.style, "percent");
    const is_currency = std.mem.eql(u8, opt.style, "currency");
    const is_unit = std.mem.eql(u8, opt.style, "unit");
    if (is_percent and dec.kind == .finite and !dec.isZero()) dec.e += 2;

    // Rounding runs first: it is the rounded value, not the argument, that
    // decides which sign pattern applies.
    var exponent: i32 = 0;
    var body: []const u8 = "";
    var is_zero = false;
    if (dec.kind == .finite) {
        exponent = try computeExponent(arena, opt, ld, dec);
        var scaled = dec;
        scaled.e -= exponent;
        const r = try formatNumericToString(arena, opt, scaled);
        body = r.string;
        is_zero = r.isZero();
    }

    const is_nan = dec.kind == .nan;
    const sign = chooseSign(opt.sign_display, is_nan, dec.neg, is_zero);
    // `currencySign: "accounting"` replaces the minus sign with parentheses.
    const accounting = is_currency and ld.accounting_parens and
        std.mem.eql(u8, opt.currency_sign, "accounting") and sign == .negative;

    // CLDR plural selection for the unit name. In en the `one` category is
    // "i = 1 and v = 0" — an integer 1 with no visible fraction digits — applied
    // to the value actually rendered, so a compacted 1000 ("1K") stays plural.
    const is_one_plural = is_unit and exponent == 0 and std.mem.eql(u8, body, "1");
    const unit_form: data.UnitForm = if (is_unit) try unitForm(arena, ld, opt, is_one_plural) else .{};
    const cur_symbol: []const u8 = if (is_currency) blk: {
        if (std.mem.eql(u8, opt.currency_display, "code")) break :blk opt.currency;
        if (std.mem.eql(u8, opt.currency_display, "name")) break :blk opt.currency;
        break :blk currencySymbol(ld, opt.currency, std.mem.eql(u8, opt.currency_display, "narrowSymbol"));
    } else "";
    // A code standing in for a symbol is separated from the digits by a NBSP.
    const cur_sep: []const u8 = if (!is_currency)
        ""
    else if (ld.currency_sep.len > 0)
        ld.currency_sep
    else if (std.mem.eql(u8, cur_symbol, opt.currency))
        "\u{00a0}"
    else
        "";

    if (accounting) try parts.append(arena, .{ .type = "literal", .value = "(" });
    if (is_unit and unit_form.prefix.len > 0) {
        try parts.append(arena, .{ .type = "unit", .value = unit_form.prefix });
        if (unit_form.prefix_sep.len > 0)
            try parts.append(arena, .{ .type = "literal", .value = unit_form.prefix_sep });
    }
    if (!accounting and sign != .zero) {
        try parts.append(arena, if (sign == .negative)
            .{ .type = "minusSign", .value = "-" }
        else
            .{ .type = "plusSign", .value = "+" });
    }
    if (is_currency and !ld.currency_suffix) {
        try parts.append(arena, .{ .type = "currency", .value = cur_symbol });
        if (cur_sep.len > 0) try parts.append(arena, .{ .type = "literal", .value = cur_sep });
    }

    if (is_nan) {
        try parts.append(arena, .{ .type = "nan", .value = ld.nan });
    } else if (dec.kind == .infinity) {
        try parts.append(arena, .{ .type = "infinity", .value = ld.infinity });
    } else {
        try emitDigits(arena, &parts, body, ld, opt);
    }

    // Notation suffixes: the compact word, or the E-notation exponent.
    if (dec.kind == .finite and std.mem.eql(u8, opt.notation, "compact") and exponent != 0) {
        const table = if (std.mem.eql(u8, opt.compact_display, "long")) ld.compact_long else ld.compact_short;
        for (table) |entry| {
            if (entry.exp != exponent) continue;
            if (entry.sep.len > 0) try parts.append(arena, .{ .type = "literal", .value = entry.sep });
            try parts.append(arena, .{ .type = "compact", .value = entry.suffix });
            break;
        }
    } else if (dec.kind == .finite and
        (std.mem.eql(u8, opt.notation, "scientific") or std.mem.eql(u8, opt.notation, "engineering")))
    {
        try parts.append(arena, .{ .type = "exponentSeparator", .value = "E" });
        if (exponent < 0) try parts.append(arena, .{ .type = "exponentMinusSign", .value = "-" });
        try parts.append(arena, .{
            .type = "exponentInteger",
            .value = try std.fmt.allocPrint(arena, "{d}", .{@abs(exponent)}),
        });
    }

    if (is_percent) try parts.append(arena, .{ .type = "percentSign", .value = "%" });
    if (is_currency and ld.currency_suffix) {
        if (cur_sep.len > 0) try parts.append(arena, .{ .type = "literal", .value = cur_sep });
        try parts.append(arena, .{ .type = "currency", .value = cur_symbol });
    }
    if (is_unit and unit_form.suffix.len > 0) {
        if (unit_form.sep.len > 0) try parts.append(arena, .{ .type = "literal", .value = unit_form.sep });
        try parts.append(arena, .{ .type = "unit", .value = unit_form.suffix });
    }
    if (accounting) try parts.append(arena, .{ .type = "literal", .value = ")" });
    return parts.items;
}

/// `format`: the part values concatenated.
fn formatDecimal(arena: std.mem.Allocator, dec: Decimal, opt: NfOptions) ![]const u8 {
    const parts = try partitionNumberPattern(arena, dec, opt);
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| try out.appendSlice(arena, p.value);
    return out.items;
}

/// Format a plain f64 — the entry point the Zig unit tests and `Number.prototype
/// .toLocaleString` share.
pub fn formatNumber(arena: std.mem.Allocator, value: f64, opt: NfOptions) ![]const u8 {
    return formatDecimal(arena, try decimalFromF64(arena, value), opt);
}

/// The same, as parts: `intl.zig`'s RelativeTimeFormat splices grouped digits
/// into its own patterns and needs the part list, not the joined string.
pub fn formatNumberParts(arena: std.mem.Allocator, value: f64, opt: NfOptions) ![]NumberPart {
    return partitionNumberPattern(arena, try decimalFromF64(arena, value), opt);
}

/// Format an exact decimal string (`"-1.500000000"`). `Intl.DurationFormat`
/// needs this: the fractional seconds it folds sub-second fields into can carry
/// more significant digits than an f64 holds.
pub fn formatDecimalStringParts(arena: std.mem.Allocator, s: []const u8, opt: NfOptions) ![]NumberPart {
    return partitionNumberPattern(arena, try decimalFromString(arena, s), opt);
}

// -------------------------------------------------------------- option parsing ---

/// Coerce an Intl fraction-digits option to u32. Per ECMA-402 these must be
/// integers in a bounded range; a NaN / negative / huge value would panic
/// `@intFromFloat`, so validate and throw RangeError (the spec error) instead.
fn toFracDigits(arena: std.mem.Allocator, m: f64) anyerror!u32 {
    if (std.math.isNan(m) or m < 0 or m > 100) return throwRangeError(arena, "fraction digits value is out of range");
    return @intFromFloat(@floor(m));
}

/// Significant-digit options are restricted to 1..21.
fn toSigDigits(arena: std.mem.Allocator, m: f64) anyerror!u32 {
    if (std.math.isNan(m) or m < 1 or m > 21) return throwRangeError(arena, "significant digits value is out of range");
    return @intFromFloat(@floor(m));
}

/// roundingIncrement is restricted to this exact set by ECMA-402.
fn isValidRoundingIncrement(x: f64) bool {
    if (x != @floor(x)) return false;
    for ([_]f64{ 1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000 }) |v| {
        if (x == v) return true;
    }
    return false;
}

/// IsWellFormedCurrencyCode: exactly three ASCII letters.
fn isWellFormedCurrencyCode(s: []const u8) bool {
    if (s.len != 3) return false;
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

/// IsWellFormedUnitIdentifier: a sanctioned single unit, or `x-per-y` over two
/// of them.
fn isWellFormedUnitIdentifier(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "-per-")) |i|
        return isSanctionedUnit(s[0..i]) and isSanctionedUnit(s[i + 5 ..]);
    return isSanctionedUnit(s);
}

/// Table 2 of ECMA-402: the simple units a `style: "unit"` formatter accepts.
pub const sanctioned_units = [_][]const u8{
    "acre",        "bit",         "byte",     "celsius",           "centimeter", "day",        "degree",      "fahrenheit",
    "fluid-ounce", "foot",        "gallon",   "gigabit",           "gigabyte",   "gram",       "hectare",     "hour",
    "inch",        "kilobit",     "kilobyte", "kilogram",          "kilometer",  "liter",      "megabit",     "megabyte",
    "meter",       "microsecond", "mile",     "mile-scandinavian", "milliliter", "millimeter", "millisecond", "minute",
    "month",       "nanosecond",  "ounce",    "percent",           "petabyte",   "pound",      "second",      "stone",
    "terabit",     "terabyte",    "week",     "yard",              "year",
};

fn isSanctionedUnit(s: []const u8) bool {
    for (sanctioned_units) |u| if (std.mem.eql(u8, u, s)) return true;
    return false;
}

/// GetBooleanOrStringNumberFormatOption (§15.1.5) for `useGrouping`: `true`
/// means "always", anything falsy means off, the string "true"/"false" falls
/// back, and any other unlisted string is a RangeError.
fn getUseGrouping(arena: std.mem.Allocator, options: Value, fallback: []const u8) anyerror![]const u8 {
    const v = if (realm_mod.active_context) |c| try c.getProp(arena, options, "useGrouping") else Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return fallback;
    if (v.unbox() == .boolean and v.unbox().boolean) return "always";
    if (!val_mod.toBoolean(v)) return "false";
    if (v.unbox() != .string) return throwRangeError(arena, "invalid useGrouping");
    const s = v.unbox().string;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return fallback;
    for ([_][]const u8{ "min2", "auto", "always" }) |a| {
        if (std.mem.eql(u8, a, s)) return a;
    }
    return throwRangeError(arena, "invalid useGrouping");
}

/// `new Intl.NumberFormat(locales, options)` — store resolved options on `this`.
/// InitializeNumberFormat (§15.1.2) reads the options in the order below; each
/// read goes through GetOption so a throwing getter propagates and an
/// out-of-range value is a RangeError before any later option is touched.
pub fn nativeNumberFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Intl.NumberFormat is callable without `new` (§15.1.1 ChainNumberFormat);
    // the plain call still yields an instance, so fall back to the service's own
    // prototype rather than a bare object.
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    const obj = if (constructing and this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try legacyServiceObj(arena);
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);

    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    if (try dnGetOption(arena, options, "numberingSystem", &.{}, null)) |ns| {
        if (!isWellFormedNumberingSystem(ns)) return throwRangeError(arena, "invalid numberingSystem");
    }

    // SetNumberFormatUnitOptions (§15.1.3).
    const style = (try dnGetOption(arena, options, "style", &.{ "decimal", "percent", "currency", "unit" }, "decimal")).?;
    const is_currency = std.mem.eql(u8, style, "currency");
    const currency_opt = try dnGetOption(arena, options, "currency", &.{}, null);
    if (currency_opt) |c| {
        if (!isWellFormedCurrencyCode(c)) return throwRangeError(arena, "invalid currency code");
    } else if (is_currency) {
        return throwTypeErrorIntl(arena, "Intl.NumberFormat: `currency` is required when style is \"currency\"");
    }
    const currency_display = (try dnGetOption(arena, options, "currencyDisplay", &.{ "code", "symbol", "narrowSymbol", "name" }, "symbol")).?;
    const currency_sign = (try dnGetOption(arena, options, "currencySign", &.{ "standard", "accounting" }, "standard")).?;
    const unit_opt = try dnGetOption(arena, options, "unit", &.{}, null);
    if (unit_opt) |u| {
        if (!isWellFormedUnitIdentifier(u)) return throwRangeError(arena, "invalid unit identifier");
    } else if (std.mem.eql(u8, style, "unit")) {
        return throwTypeErrorIntl(arena, "Intl.NumberFormat: `unit` is required when style is \"unit\"");
    }
    const unit_display = (try dnGetOption(arena, options, "unitDisplay", &.{ "short", "narrow", "long" }, "short")).?;
    const currency = try upperDup(arena, currency_opt orelse "USD");

    const notation = (try dnGetOption(arena, options, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard")).?;
    const is_compact = std.mem.eql(u8, notation, "compact");

    // Per-style digit defaults; a currency's own fraction-digit count applies
    // only in "standard" notation (§15.1.2 step 19).
    const std_currency = is_currency and std.mem.eql(u8, notation, "standard");
    const default_min: u32 = if (std_currency) data.currencyDigits(currency) else 0;
    const default_max: u32 = if (std_currency)
        data.currencyDigits(currency)
    else if (std.mem.eql(u8, style, "percent")) 0 else 3;

    // SetNumberFormatDigitOptions (§15.1.4).
    const min_int = if (try dnGetNumOption(arena, options, "minimumIntegerDigits")) |m| blk: {
        if (std.math.isNan(m) or m < 1 or m > 21) return throwRangeError(arena, "minimumIntegerDigits is out of range");
        break :blk @as(u32, @intFromFloat(@floor(m)));
    } else 1;
    const min_frac_v = try dnGetNumOption(arena, options, "minimumFractionDigits");
    const max_frac_v = try dnGetNumOption(arena, options, "maximumFractionDigits");
    const min_sig_v = try dnGetNumOption(arena, options, "minimumSignificantDigits");
    const max_sig_v = try dnGetNumOption(arena, options, "maximumSignificantDigits");
    var inc: u32 = 1;
    if (try dnGetNumOption(arena, options, "roundingIncrement")) |ri| {
        if (!isValidRoundingIncrement(ri)) return throwRangeError(arena, "invalid roundingIncrement");
        inc = @intFromFloat(ri);
    }
    const mode_str = (try dnGetOption(arena, options, "roundingMode", &.{}, "halfExpand")).?;
    if (roundModeFromString(mode_str) == null) return throwRangeError(arena, "invalid roundingMode");
    const priority = (try dnGetOption(arena, options, "roundingPriority", &.{ "auto", "morePrecision", "lessPrecision" }, "auto")).?;
    const trailing_zero = (try dnGetOption(arena, options, "trailingZeroDisplay", &.{ "auto", "stripIfInteger" }, "auto")).?;

    const has_sd = min_sig_v != null or max_sig_v != null;
    const has_fd = min_frac_v != null or max_frac_v != null;
    var need_sd = true;
    var need_fd = true;
    if (std.mem.eql(u8, priority, "auto")) {
        need_sd = has_sd;
        if (has_sd or (!has_fd and is_compact)) need_fd = false;
    }

    var min_sig: u32 = 1;
    var max_sig: u32 = 21;
    if (need_sd and has_sd) {
        min_sig = if (min_sig_v) |m| try toSigDigits(arena, m) else 1;
        max_sig = if (max_sig_v) |m| try toSigDigits(arena, m) else 21;
        if (min_sig > max_sig) return throwRangeError(arena, "minimumSignificantDigits exceeds maximumSignificantDigits");
    }

    var min_frac: u32 = default_min;
    var max_frac: u32 = default_max;
    if (need_fd and has_fd) {
        const mnfd: ?u32 = if (min_frac_v) |m| try toFracDigits(arena, m) else null;
        const mxfd: ?u32 = if (max_frac_v) |m| try toFracDigits(arena, m) else null;
        if (mnfd == null) {
            max_frac = mxfd.?;
            min_frac = @min(default_min, max_frac);
        } else if (mxfd == null) {
            min_frac = mnfd.?;
            max_frac = @max(default_max, min_frac);
        } else {
            min_frac = mnfd.?;
            max_frac = mxfd.?;
            if (min_frac > max_frac) return throwRangeError(arena, "minimumFractionDigits exceeds maximumFractionDigits");
        }
    }

    var rounding_type: RoundingType = undefined;
    if (!need_sd and !need_fd) {
        // Compact notation with no digit options at all: two significant digits,
        // no fraction digits, more-precision arbitration between them.
        min_frac = 0;
        max_frac = 0;
        min_sig = 1;
        max_sig = 2;
        rounding_type = .more_precision;
        inc = 1;
    } else if (std.mem.eql(u8, priority, "morePrecision")) {
        rounding_type = .more_precision;
    } else if (std.mem.eql(u8, priority, "lessPrecision")) {
        rounding_type = .less_precision;
    } else if (has_sd) {
        rounding_type = .significant_digits;
    } else {
        rounding_type = .fraction_digits;
    }
    if (inc != 1) {
        if (rounding_type != .fraction_digits)
            return throwTypeErrorIntl(arena, "roundingIncrement requires fraction-digit rounding");
        if (min_frac != max_frac)
            return throwRangeError(arena, "roundingIncrement requires equal min/max fraction digits");
    }

    const compact_display = (try dnGetOption(arena, options, "compactDisplay", &.{ "short", "long" }, "short")).?;
    const group = try getUseGrouping(arena, options, if (is_compact) "min2" else "auto");
    const sign_display = (try dnGetOption(arena, options, "signDisplay", &.{ "auto", "never", "always", "exceptZero", "negative" }, "auto")).?;

    try obj.set("__intl_style", try val_mod.makeString(arena, style));
    try obj.set("__intl_currency", try val_mod.makeString(arena, currency));
    try obj.set("__intl_currencyDisplay", try val_mod.makeString(arena, currency_display));
    try obj.set("__intl_currencySign", try val_mod.makeString(arena, currency_sign));
    if (unit_opt) |u| try obj.set("__intl_unit", try val_mod.makeString(arena, u));
    try obj.set("__intl_unitDisplay", try val_mod.makeString(arena, unit_display));
    try obj.set("__intl_notation", try val_mod.makeString(arena, notation));
    try obj.set("__intl_compactDisplay", try val_mod.makeString(arena, compact_display));
    try obj.set("__intl_minInt", try val_mod.makeNumber(arena, @floatFromInt(min_int)));
    try obj.set("__intl_minFrac", try val_mod.makeNumber(arena, @floatFromInt(min_frac)));
    try obj.set("__intl_maxFrac", try val_mod.makeNumber(arena, @floatFromInt(max_frac)));
    try obj.set("__intl_minSig", try val_mod.makeNumber(arena, @floatFromInt(min_sig)));
    try obj.set("__intl_maxSig", try val_mod.makeNumber(arena, @floatFromInt(max_sig)));
    try obj.set("__intl_roundType", try val_mod.makeString(arena, roundingTypeToString(rounding_type)));
    try obj.set("__intl_group", try val_mod.makeString(arena, group));
    try obj.set("__intl_sign", try val_mod.makeString(arena, sign_display));
    try obj.set("__intl_roundMode", try val_mod.makeString(arena, mode_str));
    try obj.set("__intl_roundInc", try val_mod.makeNumber(arena, @floatFromInt(inc)));
    try obj.set("__intl_roundPriority", try val_mod.makeString(arena, priority));
    try obj.set("__intl_trailingZero", try val_mod.makeString(arena, trailing_zero));
    const created = try val_mod.makeObject(arena, obj);
    if (constructing) return created;
    return intl.chainLegacyService(this_val, created, intl.numberFormatProto());
}

// ------------------------------------------------------------------- natives ---

/// Brand check: our NumberFormat instances carry the internal `__intl_style`
/// marker, so anything without it is not an initialized NumberFormat.
fn requireNumberFormat(arena: std.mem.Allocator, this_val: Value) !void {
    if (this_val.bits == 0 or this_val.unbox() != .object or
        this_val.toPtr().object.getOwn("__intl_style") == null)
        return realm_mod.throwTypeError(arena, "called on incompatible receiver");
}

fn slotStr(o: ?*JsObject, key: []const u8, dflt: []const u8) []const u8 {
    const oo = o orelse return dflt;
    const v = oo.get(key) orelse return dflt;
    if (v.bits == 0 or v.unbox() != .string) return dflt;
    return v.unbox().string;
}

fn slotNum(o: ?*JsObject, key: []const u8, dflt: u32) u32 {
    const oo = o orelse return dflt;
    const v = oo.get(key) orelse return dflt;
    if (v.bits == 0 or v.unbox() != .number) return dflt;
    const n = v.unbox().number;
    // roundingIncrement reaches 5000; anything past that is a corrupted slot.
    if (std.math.isNan(n) or n < 0 or n > 5000) return dflt;
    return @intFromFloat(n);
}

fn readNfOptions(this_val: Value) NfOptions {
    var r = NfOptions{};
    if (this_val.bits == 0 or this_val.unbox() != .object) return r;
    const o = this_val.toPtr().object;
    r.locale = resolvedLocaleOf(this_val);
    r.style = slotStr(o, "__intl_style", "decimal");
    r.currency = slotStr(o, "__intl_currency", "USD");
    r.currency_display = slotStr(o, "__intl_currencyDisplay", "symbol");
    r.currency_sign = slotStr(o, "__intl_currencySign", "standard");
    r.unit = slotStr(o, "__intl_unit", "");
    r.unit_display = slotStr(o, "__intl_unitDisplay", "short");
    r.notation = slotStr(o, "__intl_notation", "standard");
    r.compact_display = slotStr(o, "__intl_compactDisplay", "short");
    r.min_int = slotNum(o, "__intl_minInt", 1);
    r.min_frac = slotNum(o, "__intl_minFrac", 0);
    r.max_frac = slotNum(o, "__intl_maxFrac", 3);
    r.min_sig = slotNum(o, "__intl_minSig", 1);
    r.max_sig = slotNum(o, "__intl_maxSig", 21);
    r.rounding_type = roundingTypeFromString(slotStr(o, "__intl_roundType", "fractionDigits"));
    r.use_grouping = slotStr(o, "__intl_group", "auto");
    r.sign_display = slotStr(o, "__intl_sign", "auto");
    r.rounding_mode = roundModeFromString(slotStr(o, "__intl_roundMode", "halfExpand")) orelse .half_expand;
    r.rounding_increment = slotNum(o, "__intl_roundInc", 1);
    r.strip_if_integer = std.mem.eql(u8, slotStr(o, "__intl_trailingZero", "auto"), "stripIfInteger");
    return r;
}

pub fn nativeNumberFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // The bound format function passes its NumberFormat via native userdata; a
    // direct `nf.format(x)` call arrives with the instance as `this`.
    const recv: Value = if (val_mod.g_active_native_data) |d|
        try val_mod.makeObject(arena, @ptrCast(@alignCast(d)))
    else
        this_val;
    try requireNumberFormat(arena, recv);
    const dec = try toIntlMathematicalValue(arena, if (args.len > 0) args[0] else Value{});
    return val_mod.makeString(arena, try formatDecimal(arena, dec, readNfOptions(recv)));
}

/// §15.3.3 `get Intl.NumberFormat.prototype.format`: an accessor whose getter
/// returns a function bound to this instance, created once and cached in the
/// `[[BoundFormat]]` slot so repeated reads give the same object.
pub fn nativeNumberFormatFormatGetter(arena: std.mem.Allocator, this_raw: Value, _: []const Value) anyerror!Value {
    const this_val = try intl.unwrapLegacyService(arena, this_raw, "__intl_style");
    try requireNumberFormat(arena, this_val);
    const o = this_val.toPtr().object;
    if (o.getOwn("[[BoundFormat]]")) |bound| return bound;
    const bound = try val_mod.makeNativeFunctionDataLen(arena, nativeNumberFormatFormat, @ptrCast(o), 1);
    _ = try o.defineOwnData("[[BoundFormat]]", bound, .{ .writable = false, .enumerable = false, .configurable = false });
    return bound;
}

/// Build the JS array of `{type, value}` objects `formatToParts` returns.
pub fn partsToArray(arena: std.mem.Allocator, parts: []const NumberPart) !Value {
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts) |p| {
        const o = if (realm_mod.active_heap) |h|
            try JsObject.createOnHeap(h, realm_mod.active_object_proto)
        else
            try JsObject.create(arena, realm_mod.active_object_proto);
        try o.set("type", try val_mod.makeString(arena, p.type));
        try o.set("value", try val_mod.makeString(arena, p.value));
        if (p.source) |src| try o.set("source", try val_mod.makeString(arena, src));
        try arr.appendElement(try val_mod.makeObject(arena, o));
    }
    return val_mod.makeObject(arena, arr);
}

pub fn nativeNumberFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    try requireNumberFormat(arena, this_val);
    const dec = try toIntlMathematicalValue(arena, if (args.len > 0) args[0] else Value{});
    return partsToArray(arena, try partitionNumberPattern(arena, dec, readNfOptions(this_val)));
}

/// The en-US range separator, kept public because `intl.zig` re-exports it.
pub const range_separator = "\u{2013}";

/// PartitionNumberRangePattern (§15.5.5). When both ends format identically the
/// range collapses to one approximate value; otherwise the two part lists are
/// joined by the locale's range separator. Note that `x > y` is *not* an error.
fn rangeParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) ![]NumberPart {
    try requireNumberFormat(arena, this_val);
    // Both endpoints are required: undefined is a TypeError, NaN a RangeError.
    const start = if (args.len > 0) args[0] else Value{};
    const end = if (args.len > 1) args[1] else Value{};
    if (start.bits == 0 or start.unbox() == .undefined_ or end.bits == 0 or end.unbox() == .undefined_)
        return realm_mod.throwTypeError(arena, "formatRange requires two arguments");
    const a = try toIntlMathematicalValue(arena, start);
    const b = try toIntlMathematicalValue(arena, end);
    if (a.kind == .nan or b.kind == .nan) return throwRangeError(arena, "formatRange arguments must not be NaN");

    const opt = readNfOptions(this_val);
    const ld = data.forLocale(opt.locale);
    const pa = try partitionNumberPattern(arena, a, opt);
    const pb = try partitionNumberPattern(arena, b, opt);

    var out: std.ArrayList(NumberPart) = .empty;
    if (samePartList(pa, pb)) {
        try out.append(arena, .{ .type = "approximatelySign", .value = "~", .source = "shared" });
        for (pa) |p| try out.append(arena, .{ .type = p.type, .value = p.value, .source = "shared" });
        return out.items;
    }
    for (pa) |p| try out.append(arena, .{ .type = p.type, .value = p.value, .source = "startRange" });
    try out.append(arena, .{ .type = "literal", .value = ld.range_sep, .source = "shared" });
    for (pb) |p| try out.append(arena, .{ .type = p.type, .value = p.value, .source = "endRange" });
    return out.items;
}

fn samePartList(a: []const NumberPart, b: []const NumberPart) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.type, y.type) or !std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

pub fn nativeNumberFormatFormatRange(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try rangeParts(arena, this_val, args);
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

pub fn nativeNumberFormatFormatRangeToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return partsToArray(arena, try rangeParts(arena, this_val, args));
}

/// `nf.resolvedOptions()` — the table-12 properties, in table order, skipping
/// the ones the resolved rounding type leaves undefined.
pub fn nativeNumberFormatResolved(arena: std.mem.Allocator, this_raw: Value, _: []const Value) anyerror!Value {
    const this_val = try intl.unwrapLegacyService(arena, this_raw, "__intl_style");
    try requireNumberFormat(arena, this_val);
    const o = this_val.toPtr().object;
    const opt = readNfOptions(this_val);
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);

    try r.set("locale", try val_mod.makeString(arena, opt.locale));
    try r.set("numberingSystem", try val_mod.makeString(arena, "latn"));
    try r.set("style", try val_mod.makeString(arena, opt.style));
    if (std.mem.eql(u8, opt.style, "currency")) {
        try r.set("currency", try val_mod.makeString(arena, opt.currency));
        try r.set("currencyDisplay", try val_mod.makeString(arena, opt.currency_display));
        try r.set("currencySign", try val_mod.makeString(arena, opt.currency_sign));
    }
    if (std.mem.eql(u8, opt.style, "unit")) {
        try r.set("unit", try val_mod.makeString(arena, opt.unit));
        try r.set("unitDisplay", try val_mod.makeString(arena, opt.unit_display));
    }
    try r.set("minimumIntegerDigits", try val_mod.makeNumber(arena, @floatFromInt(opt.min_int)));
    const has_frac = opt.rounding_type != .significant_digits;
    const has_sig = opt.rounding_type != .fraction_digits;
    if (has_frac) {
        try r.set("minimumFractionDigits", try val_mod.makeNumber(arena, @floatFromInt(opt.min_frac)));
        try r.set("maximumFractionDigits", try val_mod.makeNumber(arena, @floatFromInt(opt.max_frac)));
    }
    if (has_sig) {
        try r.set("minimumSignificantDigits", try val_mod.makeNumber(arena, @floatFromInt(opt.min_sig)));
        try r.set("maximumSignificantDigits", try val_mod.makeNumber(arena, @floatFromInt(opt.max_sig)));
    }
    // `useGrouping` round-trips its string forms; only an explicit off is false.
    if (std.mem.eql(u8, opt.use_grouping, "false")) {
        try r.set("useGrouping", try val_mod.makeBool(arena, false));
    } else {
        try r.set("useGrouping", try val_mod.makeString(arena, opt.use_grouping));
    }
    try r.set("notation", try val_mod.makeString(arena, opt.notation));
    if (std.mem.eql(u8, opt.notation, "compact"))
        try r.set("compactDisplay", try val_mod.makeString(arena, opt.compact_display));
    try r.set("signDisplay", try val_mod.makeString(arena, opt.sign_display));
    try r.set("roundingIncrement", try val_mod.makeNumber(arena, @floatFromInt(opt.rounding_increment)));
    try r.set("roundingMode", try val_mod.makeString(arena, slotStr(o, "__intl_roundMode", "halfExpand")));
    try r.set("roundingPriority", try val_mod.makeString(arena, slotStr(o, "__intl_roundPriority", "auto")));
    try r.set("trailingZeroDisplay", try val_mod.makeString(arena, slotStr(o, "__intl_trailingZero", "auto")));
    return val_mod.makeObject(arena, r);
}

// --------------------------------------------------------------------- tests ---

fn testRound(a: std.mem.Allocator, s: []const u8, position: i32, inc: u32, mode: UnsignedMode) ![]const u8 {
    const dec = try decimalFromString(a, s);
    const rr = try roundDecimalAt(a, dec, position, inc, mode);
    return if (rr.digits.len == 0) "0" else rr.digits;
}

test "intl: roundDecimalAt half modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1.25 at two fraction digits is exact; at one it is a tie.
    try std.testing.expectEqualStrings("125", try testRound(a, "1.25", -2, 1, .half_infinity));
    try std.testing.expectEqualStrings("13", try testRound(a, "1.25", -1, 1, .half_infinity));
    try std.testing.expectEqualStrings("12", try testRound(a, "1.25", -1, 1, .half_zero));
    try std.testing.expectEqualStrings("12", try testRound(a, "1.25", -1, 1, .half_even));
    try std.testing.expectEqualStrings("14", try testRound(a, "1.35", -1, 1, .half_even));
    try std.testing.expectEqualStrings("1", try testRound(a, "1.25", 0, 1, .zero));
    try std.testing.expectEqualStrings("2", try testRound(a, "1.25", 0, 1, .infinity));
}

test "intl: roundDecimalAt honours the rounding increment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Increment 5 at 10^-2 snaps to .00/.05/.10; 1.225 is the exact half.
    try std.testing.expectEqualStrings("125", try testRound(a, "1.24", -2, 5, .half_infinity));
    try std.testing.expectEqualStrings("120", try testRound(a, "1.21", -2, 5, .half_infinity));
    try std.testing.expectEqualStrings("125", try testRound(a, "1.225", -2, 5, .half_infinity));
    try std.testing.expectEqualStrings("120", try testRound(a, "1.225", -2, 5, .half_zero));
    // Exact multiples never move, whatever the mode.
    try std.testing.expectEqualStrings("125", try testRound(a, "1.25", -2, 5, .zero));
}

test "intl: decimal strings keep digits no f64 can hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dec = try decimalFromString(a, "12344501000000000000000000000000000");
    const r = try toRawPrecision(a, dec, 3, 5, .half_infinity);
    try std.testing.expectEqualStrings("12345000000000000000000000000000000", r.string);
    const tiny = try decimalFromString(a, "0.00000000000000000000000000000123");
    const t = try toRawPrecision(a, tiny, 3, 5, .half_infinity);
    try std.testing.expectEqualStrings("0.00000000000000000000000000000123", t.string);
}

test "intl: formatNumber decimal grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1,234,567.891", try formatNumber(a, 1234567.891, .{}));
    try std.testing.expectEqualStrings("1000", try formatNumber(a, 1000, .{ .use_grouping = "false" }));
    try std.testing.expectEqualStrings("5.00", try formatNumber(a, 5, .{ .min_frac = 2 }));
}

test "intl: formatNumber currency and percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("-$1,234.50", try formatNumber(a, -1234.5, .{
        .style = "currency",
        .min_frac = 2,
        .max_frac = 2,
    }));
    try std.testing.expectEqualStrings("26%", try formatNumber(a, 0.255, .{ .style = "percent", .max_frac = 0 }));
}

test "intl: formatNumber signDisplay uses the rounded value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("+5", try formatNumber(a, 5, .{ .max_frac = 0, .sign_display = "always" }));
    try std.testing.expectEqualStrings("+0", try formatNumber(a, 0, .{ .max_frac = 0, .sign_display = "always" }));
    try std.testing.expectEqualStrings("0", try formatNumber(a, 0, .{ .max_frac = 0, .sign_display = "exceptZero" }));
    try std.testing.expectEqualStrings("5", try formatNumber(a, -5, .{ .max_frac = 0, .sign_display = "never" }));
    // -0.0001 rounds to -0, which "auto" still signs but "exceptZero" does not.
    try std.testing.expectEqualStrings("-0", try formatNumber(a, -0.0001, .{}));
    try std.testing.expectEqualStrings("0", try formatNumber(a, -0.0001, .{ .sign_display = "exceptZero" }));
    try std.testing.expectEqualStrings("+NaN", try formatNumber(a, std.math.nan(f64), .{ .sign_display = "always" }));
}
