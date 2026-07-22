// Intl.NumberFormat: option resolution, the shared number-formatting core, and
// the `format` / `formatToParts` / `formatRange*` / `resolvedOptions` natives.
//
// Split out of `intl.zig` so the numeric machinery (rounding, digit layout,
// locale patterns) lives apart from the date/locale services it has nothing in
// common with. `intl.zig` re-exports the natives under their original names, so
// the realm registration is unchanged.

const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const intl = @import("intl.zig");

const throwRangeError = intl.throwRangeError;
const throwTypeErrorIntl = intl.throwTypeErrorIntl;
const dnGetOption = intl.dnGetOption;
const dnGetNumOption = intl.dnGetNumOption;
const coerceOptionsToObject = intl.coerceOptionsToObject;
const resolveAndStoreLocale = intl.resolveAndStoreLocale;
const isWellFormedNumberingSystem = intl.isWellFormedNumberingSystem;
const upperDup = intl.upperDup;
const getNum = intl.getNum;
const resolvedLocaleOf = intl.resolvedLocaleOf;
const legacyServiceObj = intl.numberFormatServiceObj;

fn pow10(n: u32) u64 {
    var r: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}

/// Format `int_part` (a non-negative integer) with ASCII thousands separators.
fn groupInteger(arena: std.mem.Allocator, int_part: u64, group: bool) ![]const u8 {
    const digits = try std.fmt.allocPrint(arena, "{d}", .{int_part});
    if (!group or digits.len <= 3) return digits;
    var out = std.ArrayListUnmanaged(u8){};
    const first = digits.len % 3;
    var idx: usize = 0;
    if (first != 0) {
        try out.appendSlice(arena, digits[0..first]);
        idx = first;
    }
    while (idx < digits.len) : (idx += 3) {
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, digits[idx .. idx + 3]);
    }
    return out.items;
}

/// The resolved NumberFormat options that affect digit output.
const NfOptions = struct {
    style: []const u8 = "decimal",
    currency: []const u8 = "USD",
    currency_display: []const u8 = "symbol",
    /// `style: "unit"` identifier ("" when the style is not "unit").
    unit: []const u8 = "",
    unit_display: []const u8 = "short",
    min_frac: u32 = 0,
    max_frac: u32 = 3,
    group: bool = true,
    sign_display: []const u8 = "auto",
    /// Significant digits take precedence over fraction digits when set.
    min_sig: u32 = 0,
    max_sig: u32 = 0,
    use_sig: bool = false,
    rounding_mode: RoundMode = .half_expand,
    /// Round to a multiple of this many units of the last fraction digit.
    rounding_increment: u32 = 1,
    /// trailingZeroDisplay "stripIfInteger".
    strip_if_integer: bool = false,
};

/// ECMA-402 roundingMode.
const RoundMode = enum {
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

/// Round a non-negative magnitude to an integer under an unsigned mode.
fn roundMagnitude(x: f64, mode: UnsignedMode) f64 {
    const fl = @floor(x);
    const frac = x - fl;
    if (frac == 0) return fl;
    return switch (mode) {
        .zero => fl,
        .infinity => fl + 1,
        .half_zero => if (frac > 0.5) fl + 1 else fl,
        .half_infinity => if (frac >= 0.5) fl + 1 else fl,
        .half_even => if (frac > 0.5) fl + 1 else if (frac < 0.5) fl else (if (@mod(fl, 2) == 0) fl else fl + 1),
    };
}

/// One element of a `formatToParts` result.
pub const NumberPart = struct {
    type: []const u8,
    value: []const u8,
    /// Which end of a range this part came from. Only `formatRangeToParts`
    /// reports it; plain `formatToParts` parts leave it null.
    source: ?[]const u8 = null,
};

/// Core en-US number formatting, as the `formatToParts` part list. `format` is
/// the concatenation of these values, so both share one implementation and
/// cannot drift apart.
pub fn formatNumberParts(arena: std.mem.Allocator, value: f64, opt: NfOptions) ![]NumberPart {
    const style = opt.style;
    const currency = opt.currency;
    const group = opt.group;
    const sign_display = opt.sign_display;
    var parts: std.ArrayList(NumberPart) = .empty;
    if (std.math.isNan(value)) {
        try parts.append(arena, .{ .type = "nan", .value = "NaN" });
        return parts.items;
    }

    var n = value;
    // ECMA-402 counts -0 as negative, so `format(-0)` is "-0".
    const negative = std.math.signbit(n);
    n = @abs(n);

    const is_percent = std.mem.eql(u8, style, "percent");
    const is_currency = std.mem.eql(u8, style, "currency");
    if (is_percent) n *= 100;

    var min_frac = opt.min_frac;
    var max_frac = opt.max_frac;
    // Significant digits, when requested, fix the digit positions instead:
    // express them as an equivalent fraction-digit window plus, when the value
    // is wider than maxSig, a power-of-ten increment that zeroes the low
    // integer digits (123456 at 3 significant digits is 123,000).
    var sig_increment: u64 = 1;
    if (opt.use_sig and n != 0 and !std.math.isInf(n)) {
        const e: i32 = @intFromFloat(@floor(@log10(n)));
        const max_sig: i32 = @intCast(opt.max_sig);
        const min_sig: i32 = @intCast(opt.min_sig);
        if (e + 1 >= max_sig) {
            max_frac = 0;
            min_frac = 0;
            const shift = e + 1 - max_sig;
            sig_increment = pow10(@intCast(@min(shift, 18)));
        } else {
            max_frac = @intCast(@min(max_sig - 1 - e, 18));
            min_frac = if (min_sig - 1 - e > 0) @intCast(@min(min_sig - 1 - e, 18)) else 0;
        }
    } else if (opt.use_sig) {
        max_frac = if (opt.min_sig > 1) opt.min_sig - 1 else 0;
        min_frac = max_frac;
    }
    if (max_frac < min_frac) max_frac = min_frac;
    // `pow10(max_frac)` must fit u64 (10^18 < 2^63) and f64 carries only ~17
    // significant digits, so a larger fraction-digit count cannot be represented;
    // clamp the scale exponent to avoid integer overflow in pow10.
    if (max_frac > 18) max_frac = 18;
    // roundingIncrement counts units of the last fraction digit, and per spec
    // applies only in fraction-digit mode.
    const increment: u64 = if (opt.use_sig) sig_increment else @max(opt.rounding_increment, 1);

    // signDisplay: auto (default) / always / exceptZero / negative / never.
    const sign_prefix: []const u8 = blk: {
        if (std.mem.eql(u8, sign_display, "never")) break :blk "";
        // exceptZero and negative suppress the sign on zero (including -0),
        // so they must be tested before the sign bit.
        if (std.mem.eql(u8, sign_display, "exceptZero")) {
            if (value == 0 or std.math.isNan(value)) break :blk "";
            break :blk if (negative) "-" else "+";
        }
        if (std.mem.eql(u8, sign_display, "negative")) {
            if (value == 0 or std.math.isNan(value)) break :blk "";
            break :blk if (negative) "-" else "";
        }
        if (negative) break :blk "-";
        if (std.mem.eql(u8, sign_display, "always")) break :blk "+";
        break :blk "";
    };
    var cur_prefix: []const u8 = "";
    var suffix: []const u8 = "";
    if (is_currency) {
        // currencyDisplay "code" writes the ISO code followed by a NBSP; the
        // symbol forms abut the digits directly.
        const sym = currencySymbol(currency);
        // A code used in place of a symbol (either explicitly, or because this
        // build has no symbol for it) is separated from the digits by a NBSP.
        cur_prefix = if (std.mem.eql(u8, opt.currency_display, "code") or std.mem.eql(u8, sym, currency))
            try std.fmt.allocPrint(arena, "{s}\u{00a0}", .{currency})
        else
            sym;
    }
    if (is_percent) suffix = "%";

    if (sign_prefix.len > 0) {
        try parts.append(arena, .{
            .type = if (sign_prefix[0] == '-') "minusSign" else "plusSign",
            .value = sign_prefix,
        });
    }
    if (cur_prefix.len > 0) try parts.append(arena, .{ .type = "currency", .value = cur_prefix });

    if (std.math.isInf(value)) {
        try parts.append(arena, .{ .type = "infinity", .value = "\u{221e}" });
        if (suffix.len > 0) try parts.append(arena, .{ .type = "percentSign", .value = suffix });
        return parts.items;
    }

    const scale = pow10(max_frac);
    const scale_f: f64 = @floatFromInt(scale);
    const inc_f: f64 = @floatFromInt(increment);
    const umode = unsignedRoundingMode(opt.rounding_mode, negative);
    // Round in units of `increment`, then scale back up.
    const scaled: f64 = roundMagnitude(n * scale_f / inc_f, umode) * inc_f;
    // Guard the float→int conversion: a value large enough to overflow u64 (or NaN)
    // would panic @intFromFloat. Saturate instead of crashing.
    const scaled_u: u64 = if (std.math.isNan(scaled) or scaled < 0 or scaled >= 1.8446744073709552e19)
        std.math.maxInt(u64)
    else
        @intFromFloat(scaled);
    const int_part = scaled_u / scale;
    const frac_part = scaled_u % scale;

    // The integer digits are emitted as alternating integer/group runs, which is
    // what distinguishes formatToParts from a plain grouped string.
    const int_str = try groupInteger(arena, int_part, group);
    var run_start: usize = 0;
    for (int_str, 0..) |c, i| {
        if (c != ',') continue;
        try parts.append(arena, .{ .type = "integer", .value = int_str[run_start..i] });
        try parts.append(arena, .{ .type = "group", .value = "," });
        run_start = i + 1;
    }
    try parts.append(arena, .{ .type = "integer", .value = int_str[run_start..] });

    // Fraction: zero-pad to max_frac, then trim trailing zeros down to min_frac.
    if (max_frac > 0 and !(opt.strip_if_integer and frac_part == 0)) {
        const buf = try std.fmt.allocPrint(arena, "{d:0>[1]}", .{ frac_part, max_frac });
        var keep = buf.len;
        while (keep > min_frac and buf[keep - 1] == '0') keep -= 1;
        if (keep > 0) {
            try parts.append(arena, .{ .type = "decimal", .value = "." });
            try parts.append(arena, .{ .type = "fraction", .value = buf[0..keep] });
        }
    }

    if (suffix.len > 0) try parts.append(arena, .{ .type = "percentSign", .value = suffix });
    // `style: "unit"` appends the unit after a space (en-US "short"/"long"; the
    // per-unit pattern nuances of CLDR are approximated by one shape).
    if (opt.unit.len > 0 and std.mem.eql(u8, style, "unit")) {
        try parts.append(arena, .{ .type = "literal", .value = " " });
        const long = std.mem.eql(u8, opt.unit_display, "long");
        const sym = unitSymbol(opt.unit, long);
        // The long form is a full English noun, so it pluralizes.
        try parts.append(arena, .{ .type = "unit", .value = if (long and @abs(value) != 1)
            try std.fmt.allocPrint(arena, "{s}s", .{sym})
        else
            sym });
    }
    return parts.items;
}

/// `format`: the part values concatenated.
pub fn formatNumber(arena: std.mem.Allocator, value: f64, opt: NfOptions) ![]const u8 {
    const parts = try formatNumberParts(arena, value, opt);
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| try out.appendSlice(arena, p.value);
    return out.items;
}

/// The en-US symbol for `code`, or the code itself when this build has no
/// symbol for it (which is what ECMA-402 falls back to).
fn currencySymbol(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "USD")) return "$";
    if (std.mem.eql(u8, code, "EUR")) return "\u{20ac}";
    if (std.mem.eql(u8, code, "GBP")) return "\u{a3}";
    if (std.mem.eql(u8, code, "JPY")) return "\u{a5}";
    if (std.mem.eql(u8, code, "CNY")) return "CN\u{a5}";
    if (std.mem.eql(u8, code, "KRW")) return "\u{20a9}";
    if (std.mem.eql(u8, code, "INR")) return "\u{20b9}";
    if (std.mem.eql(u8, code, "VND")) return "\u{20ab}";
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

fn isSanctionedUnit(s: []const u8) bool {
    const units = [_][]const u8{
        "acre",        "bit",         "byte",     "celsius",           "centimeter", "day",        "degree",      "fahrenheit",
        "fluid-ounce", "foot",        "gallon",   "gigabit",           "gigabyte",   "gram",       "hectare",     "hour",
        "inch",        "kilobit",     "kilobyte", "kilogram",          "kilometer",  "liter",      "megabit",     "megabyte",
        "meter",       "microsecond", "mile",     "mile-scandinavian", "milliliter", "millimeter", "millisecond", "minute",
        "month",       "nanosecond",  "ounce",    "percent",           "petabyte",   "pound",      "second",      "stone",
        "terabit",     "terabyte",    "week",     "yard",              "year",
    };
    for (units) |u| if (std.mem.eql(u8, u, s)) return true;
    return false;
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
    const is_jpy = std.mem.eql(u8, currency, "JPY");
    // Default fraction digits per style (en-US).
    const default_min: u32 = if (is_currency) (if (is_jpy) 0 else 2) else 0;
    const default_max: u32 = if (is_currency) (if (is_jpy) 0 else 2) else if (std.mem.eql(u8, style, "percent")) 0 else 3;

    // SetNumberFormatDigitOptions (§15.1.3).
    const min_int = if (try dnGetNumOption(arena, options, "minimumIntegerDigits")) |m| blk: {
        if (std.math.isNan(m) or m < 1 or m > 21) return throwRangeError(arena, "minimumIntegerDigits is out of range");
        break :blk @as(u32, @intFromFloat(@floor(m)));
    } else 1;
    const min_frac_v = try dnGetNumOption(arena, options, "minimumFractionDigits");
    const max_frac_v = try dnGetNumOption(arena, options, "maximumFractionDigits");
    const min_sig_v = try dnGetNumOption(arena, options, "minimumSignificantDigits");
    const max_sig_v = try dnGetNumOption(arena, options, "maximumSignificantDigits");
    const min_frac: u32 = if (min_frac_v) |m| try toFracDigits(arena, m) else default_min;
    const max_frac: u32 = if (max_frac_v) |m| try toFracDigits(arena, m) else @max(default_max, min_frac);
    if (min_frac > max_frac) return throwRangeError(arena, "minimumFractionDigits exceeds maximumFractionDigits");

    const notation = (try dnGetOption(arena, options, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard")).?;
    _ = try dnGetOption(arena, options, "compactDisplay", &.{ "short", "long" }, "short");
    const grouping_v = if (realm_mod.active_context) |c| try c.getProp(arena, options, "useGrouping") else Value{};
    const group: bool = if (grouping_v.bits == 0 or grouping_v.unbox() == .undefined_)
        true
    else if (grouping_v.unbox() == .string) blk: {
        const gs = grouping_v.unbox().string;
        for ([_][]const u8{ "min2", "auto", "always", "true", "false" }) |a| {
            if (std.mem.eql(u8, a, gs)) break :blk !std.mem.eql(u8, gs, "false");
        }
        return throwRangeError(arena, "invalid useGrouping");
    } else val_mod.toBoolean(grouping_v);
    const sign_display = (try dnGetOption(arena, options, "signDisplay", &.{ "auto", "never", "always", "exceptZero", "negative" }, "auto")).?;
    const mode_str = (try dnGetOption(arena, options, "roundingMode", &.{}, "halfExpand")).?;
    if (roundModeFromString(mode_str) == null) return throwRangeError(arena, "invalid roundingMode");
    var inc: u32 = 1;
    if (try dnGetNumOption(arena, options, "roundingIncrement")) |ri| {
        if (!isValidRoundingIncrement(ri)) return throwRangeError(arena, "invalid roundingIncrement");
        inc = @intFromFloat(ri);
    }
    if (try dnGetOption(arena, options, "trailingZeroDisplay", &.{ "auto", "stripIfInteger" }, "auto")) |tz| {
        if (std.mem.eql(u8, tz, "stripIfInteger"))
            try obj.set("__intl_stripZero", try val_mod.makeBool(arena, true));
    }

    try obj.set("__intl_style", try val_mod.makeString(arena, style));
    try obj.set("__intl_currency", try val_mod.makeString(arena, currency));
    try obj.set("__intl_currencyDisplay", try val_mod.makeString(arena, currency_display));
    try obj.set("__intl_currencySign", try val_mod.makeString(arena, currency_sign));
    if (unit_opt) |u| try obj.set("__intl_unit", try val_mod.makeString(arena, u));
    try obj.set("__intl_unitDisplay", try val_mod.makeString(arena, unit_display));
    try obj.set("__intl_notation", try val_mod.makeString(arena, notation));
    try obj.set("__intl_minInt", try val_mod.makeNumber(arena, @floatFromInt(min_int)));
    try obj.set("__intl_minFrac", try val_mod.makeNumber(arena, @floatFromInt(min_frac)));
    try obj.set("__intl_maxFrac", try val_mod.makeNumber(arena, @floatFromInt(max_frac)));
    try obj.set("__intl_group", try val_mod.makeBool(arena, group));
    try obj.set("__intl_sign", try val_mod.makeString(arena, sign_display));
    try obj.set("__intl_roundMode", try val_mod.makeString(arena, mode_str));
    try obj.set("__intl_roundInc", try val_mod.makeNumber(arena, @floatFromInt(inc)));

    if (min_sig_v != null or max_sig_v != null) {
        const min_sig = if (min_sig_v) |m| try toSigDigits(arena, m) else 1;
        const max_sig = if (max_sig_v) |m| try toSigDigits(arena, m) else 21;
        if (min_sig > max_sig) return throwRangeError(arena, "minimumSignificantDigits exceeds maximumSignificantDigits");
        try obj.set("__intl_minSig", try val_mod.makeNumber(arena, @floatFromInt(min_sig)));
        try obj.set("__intl_maxSig", try val_mod.makeNumber(arena, @floatFromInt(max_sig)));
    }
    return val_mod.makeObject(arena, obj);
}

pub fn nativeNumberFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // The bound format function passes its NumberFormat via native userdata; a
    // direct `nf.format(x)` call arrives with the instance as `this`.
    const recv: Value = if (val_mod.g_active_native_data) |d|
        try val_mod.makeObject(arena, @ptrCast(@alignCast(d)))
    else
        this_val;
    try requireNumberFormat(arena, recv);
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const s = try formatNumber(arena, n, readNfOptions(recv));
    return val_mod.makeString(arena, s);
}

/// §15.3.3 `get Intl.NumberFormat.prototype.format`: an accessor whose getter
/// returns a function bound to this instance, created once and cached in the
/// `[[BoundFormat]]` slot so repeated reads give the same object.
pub fn nativeNumberFormatFormatGetter(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    try requireNumberFormat(arena, this_val);
    const o = this_val.toPtr().object;
    if (o.getOwn("[[BoundFormat]]")) |bound| return bound;
    const bound = try val_mod.makeNativeFunctionDataLen(arena, nativeNumberFormatFormat, @ptrCast(o), 1);
    _ = try o.defineOwnData("[[BoundFormat]]", bound, .{ .writable = false, .enumerable = false, .configurable = false });
    return bound;
}

/// Brand check: our NumberFormat instances carry the internal `__intl_style`
/// marker, so anything without it is not an initialized NumberFormat.
fn requireNumberFormat(arena: std.mem.Allocator, this_val: Value) !void {
    if (this_val.bits == 0 or this_val.unbox() != .object or
        this_val.toPtr().object.getOwn("__intl_style") == null)
        return realm_mod.throwTypeError(arena, "called on incompatible receiver");
}

fn readNfOptions(this_val: Value) NfOptions {
    var r = NfOptions{};
    if (this_val.bits == 0 or this_val.unbox() != .object) return r;
    const o = this_val.toPtr().object;
    if (o.get("__intl_style")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.style = v.unbox().string;
    };
    if (o.get("__intl_currency")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.currency = v.unbox().string;
    };
    if (o.get("__intl_minFrac")) |v| if (v.bits != 0 and v.unbox() == .number) {
        r.min_frac = @intFromFloat(v.unbox().number);
    };
    if (o.get("__intl_maxFrac")) |v| if (v.bits != 0 and v.unbox() == .number) {
        r.max_frac = @intFromFloat(v.unbox().number);
    };
    if (o.get("__intl_group")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
        r.group = v.unbox().boolean;
    };
    if (o.get("__intl_sign")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.sign_display = v.unbox().string;
    };
    if (o.get("__intl_roundMode")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.rounding_mode = roundModeFromString(v.unbox().string) orelse .half_expand;
    };
    if (o.get("__intl_roundInc")) |v| if (v.bits != 0 and v.unbox() == .number) {
        r.rounding_increment = @intFromFloat(v.unbox().number);
    };
    if (o.get("__intl_minSig")) |v| if (v.bits != 0 and v.unbox() == .number) {
        r.min_sig = @intFromFloat(v.unbox().number);
        r.use_sig = true;
    };
    if (o.get("__intl_maxSig")) |v| if (v.bits != 0 and v.unbox() == .number) {
        r.max_sig = @intFromFloat(v.unbox().number);
    };
    if (o.get("__intl_stripZero")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
        r.strip_if_integer = v.unbox().boolean;
    };
    if (o.get("__intl_currencyDisplay")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.currency_display = v.unbox().string;
    };
    if (o.get("__intl_unit")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.unit = v.unbox().string;
    };
    if (o.get("__intl_unitDisplay")) |v| if (v.bits != 0 and v.unbox() == .string) {
        r.unit_display = v.unbox().string;
    };
    return r;
}

fn nfParts(arena: std.mem.Allocator, this_val: Value, value: f64) ![]NumberPart {
    const r = readNfOptions(this_val);
    return formatNumberParts(arena, value, r);
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
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return partsToArray(arena, try nfParts(arena, this_val, n));
}

/// The en-US range separator is an en dash with no surrounding spaces.
pub const range_separator = "\u{2013}";

/// `formatRange` / `formatRangeToParts`. When both ends format identically the
/// spec collapses the range to the single approximate value; we format the two
/// ends and join them, which is what the en-US pattern does.
fn rangeParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) ![]NumberPart {
    try requireNumberFormat(arena, this_val);
    // Both endpoints are required: undefined is a TypeError, NaN a RangeError.
    const start = if (args.len > 0) args[0] else Value{};
    const end = if (args.len > 1) args[1] else Value{};
    if (start.bits == 0 or start.unbox() == .undefined_ or end.bits == 0 or end.unbox() == .undefined_)
        return realm_mod.throwTypeError(arena, "formatRange requires two arguments");
    // ToIntlMathematicalValue rejects Symbols rather than coercing them.
    if (start.unbox() == .symbol or end.unbox() == .symbol)
        return realm_mod.throwTypeError(arena, "cannot convert a Symbol to a number");
    const a = getNum(start);
    const b = getNum(end);
    if (std.math.isNan(a) or std.math.isNan(b)) return throwRangeError(arena, "formatRange arguments must not be NaN");
    var out: std.ArrayList(NumberPart) = .empty;
    for (try nfParts(arena, this_val, a)) |p| {
        try out.append(arena, .{ .type = p.type, .value = p.value, .source = "startRange" });
    }
    try out.append(arena, .{ .type = "literal", .value = range_separator, .source = "shared" });
    for (try nfParts(arena, this_val, b)) |p| {
        try out.append(arena, .{ .type = p.type, .value = p.value, .source = "endRange" });
    }
    return out.items;
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

/// `nf.resolvedOptions()` — en-US, latn numbering system.
pub fn nativeNumberFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    var style: []const u8 = "decimal";
    var currency: []const u8 = "";
    var min_frac: f64 = 0;
    var max_frac: f64 = 3;
    var group = true;
    var sign_display: []const u8 = "auto";
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get("__intl_style")) |v| if (v.bits != 0 and v.unbox() == .string) {
            style = v.unbox().string;
        };
        if (o.get("__intl_sign")) |v| if (v.bits != 0 and v.unbox() == .string) {
            sign_display = v.unbox().string;
        };
        if (o.get("__intl_currency")) |v| if (v.bits != 0 and v.unbox() == .string) {
            currency = v.unbox().string;
        };
        if (o.get("__intl_minFrac")) |v| if (v.bits != 0 and v.unbox() == .number) {
            min_frac = v.unbox().number;
        };
        if (o.get("__intl_maxFrac")) |v| if (v.bits != 0 and v.unbox() == .number) {
            max_frac = v.unbox().number;
        };
        if (o.get("__intl_group")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            group = v.unbox().boolean;
        };
    }
    const o = if (this_val.bits != 0 and this_val.unbox() == .object) this_val.toPtr().object else null;
    const slotStr = struct {
        fn f(obj: ?*JsObject, key: []const u8, dflt: []const u8) []const u8 {
            const oo = obj orelse return dflt;
            const v = oo.get(key) orelse return dflt;
            if (v.bits == 0 or v.unbox() != .string) return dflt;
            return v.unbox().string;
        }
    }.f;
    // Property order follows table 12 of §15.4.5 (the resolvedOptions test walks
    // Object.keys in order).
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("numberingSystem", try val_mod.makeString(arena, "latn"));
    try r.set("style", try val_mod.makeString(arena, style));
    if (std.mem.eql(u8, style, "currency")) {
        try r.set("currency", try val_mod.makeString(arena, if (currency.len > 0) currency else "USD"));
        try r.set("currencyDisplay", try val_mod.makeString(arena, slotStr(o, "__intl_currencyDisplay", "symbol")));
        try r.set("currencySign", try val_mod.makeString(arena, slotStr(o, "__intl_currencySign", "standard")));
    }
    if (std.mem.eql(u8, style, "unit")) {
        try r.set("unit", try val_mod.makeString(arena, slotStr(o, "__intl_unit", "")));
        try r.set("unitDisplay", try val_mod.makeString(arena, slotStr(o, "__intl_unitDisplay", "short")));
    }
    var min_int: f64 = 1;
    if (o) |oo| if (oo.get("__intl_minInt")) |v| if (v.bits != 0 and v.unbox() == .number) {
        min_int = v.unbox().number;
    };
    try r.set("minimumIntegerDigits", try val_mod.makeNumber(arena, min_int));
    const has_sig = if (o) |oo| oo.get("__intl_minSig") != null else false;
    if (has_sig) {
        const oo = o.?;
        if (oo.get("__intl_minSig")) |v| try r.set("minimumSignificantDigits", v);
        if (oo.get("__intl_maxSig")) |v| try r.set("maximumSignificantDigits", v);
    } else {
        try r.set("minimumFractionDigits", try val_mod.makeNumber(arena, min_frac));
        try r.set("maximumFractionDigits", try val_mod.makeNumber(arena, max_frac));
    }
    // Match modern Node semantics: grouping on → "auto", explicitly off → false.
    if (group) {
        try r.set("useGrouping", try val_mod.makeString(arena, "auto"));
    } else {
        try r.set("useGrouping", try val_mod.makeBool(arena, false));
    }
    try r.set("notation", try val_mod.makeString(arena, slotStr(o, "__intl_notation", "standard")));
    try r.set("signDisplay", try val_mod.makeString(arena, sign_display));
    try r.set("roundingIncrement", try val_mod.makeNumber(arena, blk: {
        const oo = o orelse break :blk 1;
        const v = oo.get("__intl_roundInc") orelse break :blk 1;
        break :blk if (v.bits != 0 and v.unbox() == .number) v.unbox().number else 1;
    }));
    try r.set("roundingMode", try val_mod.makeString(arena, slotStr(o, "__intl_roundMode", "halfExpand")));
    try r.set("roundingPriority", try val_mod.makeString(arena, "auto"));
    try r.set("trailingZeroDisplay", try val_mod.makeString(arena, blk: {
        const oo = o orelse break :blk "auto";
        const v = oo.get("__intl_stripZero") orelse break :blk "auto";
        break :blk if (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) "stripIfInteger" else "auto";
    }));
    return val_mod.makeObject(arena, r);
}

test "intl: formatNumber decimal grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1,234,567.891", try formatNumber(a, 1234567.891, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 3, .group = true, .sign_display = "auto" }));
    try std.testing.expectEqualStrings("1000", try formatNumber(a, 1000, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 3, .group = false, .sign_display = "auto" }));
    try std.testing.expectEqualStrings("5.00", try formatNumber(a, 5, .{ .style = "decimal", .currency = "USD", .min_frac = 2, .max_frac = 3, .group = true, .sign_display = "auto" }));
}

test "intl: formatNumber currency and percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("-$1,234.50", try formatNumber(a, -1234.5, .{ .style = "currency", .currency = "USD", .min_frac = 2, .max_frac = 2, .group = true, .sign_display = "auto" }));
    try std.testing.expectEqualStrings("26%", try formatNumber(a, 0.255, .{ .style = "percent", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "auto" }));
}

test "intl: formatNumber signDisplay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("+5", try formatNumber(a, 5, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "always" }));
    try std.testing.expectEqualStrings("+0", try formatNumber(a, 0, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "always" }));
    try std.testing.expectEqualStrings("+5", try formatNumber(a, 5, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "exceptZero" }));
    try std.testing.expectEqualStrings("0", try formatNumber(a, 0, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "exceptZero" }));
    try std.testing.expectEqualStrings("5", try formatNumber(a, -5, .{ .style = "decimal", .currency = "USD", .min_frac = 0, .max_frac = 0, .group = true, .sign_display = "never" }));
}
