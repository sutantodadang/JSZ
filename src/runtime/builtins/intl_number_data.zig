// Locale data for `Intl.NumberFormat`.
//
// A full CLDR import is out of scope for this engine, so this table carries the
// handful of locales the conformance suite actually exercises (en-US, en-IN,
// de-DE, ja-JP, ko-KR, zh-TW, pt-PT) plus an en-US-shaped fallback. Everything
// here is pure data: `intl_number.zig` owns the formatting algorithm and only
// asks this module which separators / affixes / compact suffixes to splice in.

const std = @import("std");

/// One rung of a locale's compact-notation ladder: values of magnitude ≥ 10^exp
/// (and below the next rung) are divided by 10^exp and suffixed.
pub const CompactEntry = struct {
    exp: i32,
    /// Literal placed between the digits and `suffix` (a `literal` part).
    sep: []const u8 = "",
    suffix: []const u8,
};

/// How a `style: "unit"` amount is wrapped. Several CJK locales put part of the
/// unit *before* the number ("時速 987 キロメートル"), so both sides are modelled.
pub const UnitForm = struct {
    /// Unit text before the number.
    prefix: []const u8 = "",
    /// Literal between `prefix` and the number.
    prefix_sep: []const u8 = "",
    /// Literal between the number and `suffix`.
    sep: []const u8 = " ",
    /// Unit text after the number.
    suffix: []const u8 = "",
};

pub const UnitEntry = struct {
    unit: []const u8,
    short: UnitForm,
    narrow: UnitForm,
    long: UnitForm,
    /// CLDR `one`-category forms ("1 month" vs "2 months"). A null field means
    /// the locale spells the unit the same way for every count.
    short_one: ?UnitForm = null,
    narrow_one: ?UnitForm = null,
    long_one: ?UnitForm = null,
    /// CLDR `perUnitPattern` tail — what a compound `x-per-<this unit>` appends
    /// after the numerator ("/s", " per second"). Empty means the generic
    /// "<num>/<den>" fallback applies.
    per_short: []const u8 = "",
    per_narrow: []const u8 = "",
    per_long: []const u8 = "",
};

/// A locale-specific currency symbol. `narrow` falls back to `symbol` when empty.
pub const CurrencyEntry = struct {
    code: []const u8,
    symbol: []const u8,
    narrow: []const u8 = "",
};

pub const LocaleData = struct {
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    /// Digits in the rightmost group.
    group_primary: u8 = 3,
    /// Digits in every group left of the first one (en-IN groups 12,34,567).
    group_secondary: u8 = 3,
    /// CLDR minimumGroupingDigits: grouping starts once the integer part has
    /// `group_primary + min_grouping` digits. `useGrouping: "min2"` forces 2.
    min_grouping: u8 = 1,
    nan: []const u8 = "NaN",
    infinity: []const u8 = "\u{221e}",
    /// Currency amounts put the symbol after the digits (de-DE, pt-PT).
    currency_suffix: bool = false,
    /// Literal between the digits and the currency symbol.
    currency_sep: []const u8 = "",
    /// `currencySign: "accounting"` wraps negatives in parentheses here.
    accounting_parens: bool = true,
    /// `formatRange` separator when the two ends are not collapsed.
    range_sep: []const u8 = " \u{2013} ",
    compact_short: []const CompactEntry = &en_compact_short,
    compact_long: []const CompactEntry = &en_compact_long,
    units: []const UnitEntry = &en_units,
    /// Symbol overrides layered on top of `currencies_root`.
    currencies: []const CurrencyEntry = &.{},
};

const en_compact_short = [_]CompactEntry{
    .{ .exp = 3, .suffix = "K" },
    .{ .exp = 6, .suffix = "M" },
    .{ .exp = 9, .suffix = "B" },
    .{ .exp = 12, .suffix = "T" },
};
const en_compact_long = [_]CompactEntry{
    .{ .exp = 3, .sep = " ", .suffix = "thousand" },
    .{ .exp = 6, .sep = " ", .suffix = "million" },
    .{ .exp = 9, .sep = " ", .suffix = "billion" },
    .{ .exp = 12, .sep = " ", .suffix = "trillion" },
};

const en_in_compact_short = [_]CompactEntry{
    .{ .exp = 3, .suffix = "K" },
    .{ .exp = 5, .suffix = "L" },
    .{ .exp = 7, .suffix = "Cr" },
};
const en_in_compact_long = [_]CompactEntry{
    .{ .exp = 3, .sep = " ", .suffix = "thousand" },
    .{ .exp = 5, .sep = " ", .suffix = "lakh" },
    .{ .exp = 7, .sep = " ", .suffix = "crore" },
};

// German has no short form for thousands: 98765 stays "98.765".
const de_compact_short = [_]CompactEntry{
    .{ .exp = 6, .sep = "\u{00a0}", .suffix = "Mio." },
    .{ .exp = 9, .sep = "\u{00a0}", .suffix = "Mrd." },
    .{ .exp = 12, .sep = "\u{00a0}", .suffix = "Bio." },
};
const de_compact_long = [_]CompactEntry{
    .{ .exp = 3, .sep = " ", .suffix = "Tausend" },
    .{ .exp = 6, .sep = " ", .suffix = "Millionen" },
    .{ .exp = 9, .sep = " ", .suffix = "Milliarden" },
    .{ .exp = 12, .sep = " ", .suffix = "Billionen" },
};

// The CJK ladders count in myriads (10^4), and short and long forms coincide.
const ja_compact = [_]CompactEntry{
    .{ .exp = 4, .suffix = "\u{4e07}" },
    .{ .exp = 8, .suffix = "\u{5104}" },
    .{ .exp = 12, .suffix = "\u{5146}" },
};
const zh_tw_compact = [_]CompactEntry{
    .{ .exp = 4, .suffix = "\u{842c}" },
    .{ .exp = 8, .suffix = "\u{5104}" },
    .{ .exp = 12, .suffix = "\u{5146}" },
};
const ko_compact = [_]CompactEntry{
    .{ .exp = 3, .suffix = "\u{cc9c}" },
    .{ .exp = 4, .suffix = "\u{b9cc}" },
    .{ .exp = 8, .suffix = "\u{c5b5}" },
    .{ .exp = 12, .suffix = "\u{c870}" },
};

// `percent` as a *unit* abuts the digits; every other unit takes a space.
const percent_unit = UnitEntry{
    .unit = "percent",
    .short = .{ .sep = "", .suffix = "%" },
    .narrow = .{ .sep = "", .suffix = "%" },
    .long = .{ .sep = " ", .suffix = "percent" },
};

// en (CLDR 46) `style: "unit"` forms for every sanctioned simple unit, plus the
// compound `perUnitPattern` tails. Generated from ICU via `Intl.NumberFormat`;
// see the harvest script in the wave 50c notes.
const en_units = [_]UnitEntry{
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = " ", .suffix = "km/h" },
        .narrow = .{ .sep = "", .suffix = "km/h" },
        .long = .{ .sep = " ", .suffix = "kilometers per hour" },
        .long_one = .{ .sep = " ", .suffix = "kilometer per hour" },
    },
    .{
        .unit = "acre",
        .short = .{ .sep = " ", .suffix = "ac" },
        .narrow = .{ .sep = "", .suffix = "ac" },
        .long = .{ .sep = " ", .suffix = "acres" },
        .long_one = .{ .sep = " ", .suffix = "acre" },
        .per_short = "/ac",
        .per_narrow = "/ac",
        .per_long = " per acre",
    },
    .{
        .unit = "bit",
        .short = .{ .sep = " ", .suffix = "bit" },
        .narrow = .{ .sep = "", .suffix = "bit" },
        .long = .{ .sep = " ", .suffix = "bits" },
        .long_one = .{ .sep = " ", .suffix = "bit" },
        .per_short = "/bit",
        .per_narrow = "/bit",
        .per_long = " per bit",
    },
    .{
        .unit = "byte",
        .short = .{ .sep = " ", .suffix = "byte" },
        .narrow = .{ .sep = "", .suffix = "B" },
        .long = .{ .sep = " ", .suffix = "bytes" },
        .long_one = .{ .sep = " ", .suffix = "byte" },
        .per_short = "/byte",
        .per_narrow = "/B",
        .per_long = " per byte",
    },
    .{
        .unit = "celsius",
        .short = .{ .sep = "", .suffix = "\u{b0}C" },
        .narrow = .{ .sep = "", .suffix = "\u{b0}C" },
        .long = .{ .sep = " ", .suffix = "degrees Celsius" },
        .long_one = .{ .sep = " ", .suffix = "degree Celsius" },
        .per_short = "/\u{b0}C",
        .per_narrow = "/\u{b0}C",
        .per_long = " per degree Celsius",
    },
    .{
        .unit = "centimeter",
        .short = .{ .sep = " ", .suffix = "cm" },
        .narrow = .{ .sep = "", .suffix = "cm" },
        .long = .{ .sep = " ", .suffix = "centimeters" },
        .long_one = .{ .sep = " ", .suffix = "centimeter" },
        .per_short = "/cm",
        .per_narrow = "/cm",
        .per_long = " per centimeter",
    },
    .{
        .unit = "day",
        .short = .{ .sep = " ", .suffix = "days" },
        .narrow = .{ .sep = "", .suffix = "d" },
        .long = .{ .sep = " ", .suffix = "days" },
        .short_one = .{ .sep = " ", .suffix = "day" },
        .long_one = .{ .sep = " ", .suffix = "day" },
        .per_short = "/d",
        .per_narrow = "/d",
        .per_long = " per day",
    },
    .{
        .unit = "degree",
        .short = .{ .sep = " ", .suffix = "deg" },
        .narrow = .{ .sep = "", .suffix = "\u{b0}" },
        .long = .{ .sep = " ", .suffix = "degrees" },
        .long_one = .{ .sep = " ", .suffix = "degree" },
        .per_short = "/deg",
        .per_narrow = "/\u{b0}",
        .per_long = " per degree",
    },
    .{
        .unit = "fahrenheit",
        .short = .{ .sep = "", .suffix = "\u{b0}F" },
        .narrow = .{ .sep = "", .suffix = "\u{b0}" },
        .long = .{ .sep = " ", .suffix = "degrees Fahrenheit" },
        .long_one = .{ .sep = " ", .suffix = "degree Fahrenheit" },
        .per_short = "/\u{b0}F",
        .per_narrow = "/\u{b0}",
        .per_long = " per degree Fahrenheit",
    },
    .{
        .unit = "fluid-ounce",
        .short = .{ .sep = " ", .suffix = "fl oz" },
        .narrow = .{ .sep = "", .suffix = "fl oz" },
        .long = .{ .sep = " ", .suffix = "fluid ounces" },
        .long_one = .{ .sep = " ", .suffix = "fluid ounce" },
        .per_short = "/fl oz",
        .per_narrow = "/fl oz",
        .per_long = " per fluid ounce",
    },
    .{
        .unit = "foot",
        .short = .{ .sep = " ", .suffix = "ft" },
        .narrow = .{ .sep = "", .suffix = "\u{2032}" },
        .long = .{ .sep = " ", .suffix = "feet" },
        .long_one = .{ .sep = " ", .suffix = "foot" },
        .per_short = "/ft",
        .per_narrow = "/ft",
        .per_long = " per foot",
    },
    .{
        .unit = "gallon",
        .short = .{ .sep = " ", .suffix = "gal" },
        .narrow = .{ .sep = "", .suffix = "gal" },
        .long = .{ .sep = " ", .suffix = "gallons" },
        .long_one = .{ .sep = " ", .suffix = "gallon" },
        .per_short = "/gal US",
        .per_narrow = "/gal",
        .per_long = " per gallon",
    },
    .{
        .unit = "gigabit",
        .short = .{ .sep = " ", .suffix = "Gb" },
        .narrow = .{ .sep = "", .suffix = "Gb" },
        .long = .{ .sep = " ", .suffix = "gigabits" },
        .long_one = .{ .sep = " ", .suffix = "gigabit" },
        .per_short = "/Gb",
        .per_narrow = "/Gb",
        .per_long = " per gigabit",
    },
    .{
        .unit = "gigabyte",
        .short = .{ .sep = " ", .suffix = "GB" },
        .narrow = .{ .sep = "", .suffix = "GB" },
        .long = .{ .sep = " ", .suffix = "gigabytes" },
        .long_one = .{ .sep = " ", .suffix = "gigabyte" },
        .per_short = "/GB",
        .per_narrow = "/GB",
        .per_long = " per gigabyte",
    },
    .{
        .unit = "gram",
        .short = .{ .sep = " ", .suffix = "g" },
        .narrow = .{ .sep = "", .suffix = "g" },
        .long = .{ .sep = " ", .suffix = "grams" },
        .long_one = .{ .sep = " ", .suffix = "gram" },
        .per_short = "/g",
        .per_narrow = "/g",
        .per_long = " per gram",
    },
    .{
        .unit = "hectare",
        .short = .{ .sep = " ", .suffix = "ha" },
        .narrow = .{ .sep = "", .suffix = "ha" },
        .long = .{ .sep = " ", .suffix = "hectares" },
        .long_one = .{ .sep = " ", .suffix = "hectare" },
        .per_short = "/ha",
        .per_narrow = "/ha",
        .per_long = " per hectare",
    },
    .{
        .unit = "hour",
        .short = .{ .sep = " ", .suffix = "hr" },
        .narrow = .{ .sep = "", .suffix = "h" },
        .long = .{ .sep = " ", .suffix = "hours" },
        .long_one = .{ .sep = " ", .suffix = "hour" },
        .per_short = "/h",
        .per_narrow = "/h",
        .per_long = " per hour",
    },
    .{
        .unit = "inch",
        .short = .{ .sep = " ", .suffix = "in" },
        .narrow = .{ .sep = "", .suffix = "\u{2033}" },
        .long = .{ .sep = " ", .suffix = "inches" },
        .long_one = .{ .sep = " ", .suffix = "inch" },
        .per_short = "/in",
        .per_narrow = "/in",
        .per_long = " per inch",
    },
    .{
        .unit = "kilobit",
        .short = .{ .sep = " ", .suffix = "kb" },
        .narrow = .{ .sep = "", .suffix = "kb" },
        .long = .{ .sep = " ", .suffix = "kilobits" },
        .long_one = .{ .sep = " ", .suffix = "kilobit" },
        .per_short = "/kb",
        .per_narrow = "/kb",
        .per_long = " per kilobit",
    },
    .{
        .unit = "kilobyte",
        .short = .{ .sep = " ", .suffix = "kB" },
        .narrow = .{ .sep = "", .suffix = "kB" },
        .long = .{ .sep = " ", .suffix = "kilobytes" },
        .long_one = .{ .sep = " ", .suffix = "kilobyte" },
        .per_short = "/kB",
        .per_narrow = "/kB",
        .per_long = " per kilobyte",
    },
    .{
        .unit = "kilogram",
        .short = .{ .sep = " ", .suffix = "kg" },
        .narrow = .{ .sep = "", .suffix = "kg" },
        .long = .{ .sep = " ", .suffix = "kilograms" },
        .long_one = .{ .sep = " ", .suffix = "kilogram" },
        .per_short = "/kg",
        .per_narrow = "/kg",
        .per_long = " per kilogram",
    },
    .{
        .unit = "kilometer",
        .short = .{ .sep = " ", .suffix = "km" },
        .narrow = .{ .sep = "", .suffix = "km" },
        .long = .{ .sep = " ", .suffix = "kilometers" },
        .long_one = .{ .sep = " ", .suffix = "kilometer" },
        .per_short = "/km",
        .per_narrow = "/km",
        .per_long = " per kilometer",
    },
    .{
        .unit = "liter",
        .short = .{ .sep = " ", .suffix = "L" },
        .narrow = .{ .sep = "", .suffix = "L" },
        .long = .{ .sep = " ", .suffix = "liters" },
        .long_one = .{ .sep = " ", .suffix = "liter" },
        .per_short = "/L",
        .per_narrow = "/L",
        .per_long = " per liter",
    },
    .{
        .unit = "megabit",
        .short = .{ .sep = " ", .suffix = "Mb" },
        .narrow = .{ .sep = "", .suffix = "Mb" },
        .long = .{ .sep = " ", .suffix = "megabits" },
        .long_one = .{ .sep = " ", .suffix = "megabit" },
        .per_short = "/Mb",
        .per_narrow = "/Mb",
        .per_long = " per megabit",
    },
    .{
        .unit = "megabyte",
        .short = .{ .sep = " ", .suffix = "MB" },
        .narrow = .{ .sep = "", .suffix = "MB" },
        .long = .{ .sep = " ", .suffix = "megabytes" },
        .long_one = .{ .sep = " ", .suffix = "megabyte" },
        .per_short = "/MB",
        .per_narrow = "/MB",
        .per_long = " per megabyte",
    },
    .{
        .unit = "meter",
        .short = .{ .sep = " ", .suffix = "m" },
        .narrow = .{ .sep = "", .suffix = "m" },
        .long = .{ .sep = " ", .suffix = "meters" },
        .long_one = .{ .sep = " ", .suffix = "meter" },
        .per_short = "/m",
        .per_narrow = "/m",
        .per_long = " per meter",
    },
    .{
        .unit = "microsecond",
        .short = .{ .sep = " ", .suffix = "\u{3bc}s" },
        .narrow = .{ .sep = "", .suffix = "\u{3bc}s" },
        .long = .{ .sep = " ", .suffix = "microseconds" },
        .long_one = .{ .sep = " ", .suffix = "microsecond" },
        .per_short = "/\u{3bc}s",
        .per_narrow = "/\u{3bc}s",
        .per_long = " per microsecond",
    },
    .{
        .unit = "mile",
        .short = .{ .sep = " ", .suffix = "mi" },
        .narrow = .{ .sep = "", .suffix = "mi" },
        .long = .{ .sep = " ", .suffix = "miles" },
        .long_one = .{ .sep = " ", .suffix = "mile" },
        .per_short = "/mi",
        .per_narrow = "/mi",
        .per_long = " per mile",
    },
    .{
        .unit = "mile-scandinavian",
        .short = .{ .sep = " ", .suffix = "smi" },
        .narrow = .{ .sep = "", .suffix = "smi" },
        .long = .{ .sep = " ", .suffix = "miles-scandinavian" },
        .long_one = .{ .sep = " ", .suffix = "mile-scandinavian" },
        .per_short = "/smi",
        .per_narrow = "/smi",
        .per_long = " per mile-scandinavian",
    },
    .{
        .unit = "milliliter",
        .short = .{ .sep = " ", .suffix = "mL" },
        .narrow = .{ .sep = "", .suffix = "mL" },
        .long = .{ .sep = " ", .suffix = "milliliters" },
        .long_one = .{ .sep = " ", .suffix = "milliliter" },
        .per_short = "/mL",
        .per_narrow = "/mL",
        .per_long = " per milliliter",
    },
    .{
        .unit = "millimeter",
        .short = .{ .sep = " ", .suffix = "mm" },
        .narrow = .{ .sep = "", .suffix = "mm" },
        .long = .{ .sep = " ", .suffix = "millimeters" },
        .long_one = .{ .sep = " ", .suffix = "millimeter" },
        .per_short = "/mm",
        .per_narrow = "/mm",
        .per_long = " per millimeter",
    },
    .{
        .unit = "millisecond",
        .short = .{ .sep = " ", .suffix = "ms" },
        .narrow = .{ .sep = "", .suffix = "ms" },
        .long = .{ .sep = " ", .suffix = "milliseconds" },
        .long_one = .{ .sep = " ", .suffix = "millisecond" },
        .per_short = "/ms",
        .per_narrow = "/ms",
        .per_long = " per millisecond",
    },
    .{
        .unit = "minute",
        .short = .{ .sep = " ", .suffix = "min" },
        .narrow = .{ .sep = "", .suffix = "m" },
        .long = .{ .sep = " ", .suffix = "minutes" },
        .long_one = .{ .sep = " ", .suffix = "minute" },
        .per_short = "/min",
        .per_narrow = "/min",
        .per_long = " per minute",
    },
    .{
        .unit = "month",
        .short = .{ .sep = " ", .suffix = "mths" },
        .narrow = .{ .sep = "", .suffix = "m" },
        .long = .{ .sep = " ", .suffix = "months" },
        .short_one = .{ .sep = " ", .suffix = "mth" },
        .long_one = .{ .sep = " ", .suffix = "month" },
        .per_short = "/m",
        .per_narrow = "/m",
        .per_long = " per month",
    },
    .{
        .unit = "nanosecond",
        .short = .{ .sep = " ", .suffix = "ns" },
        .narrow = .{ .sep = "", .suffix = "ns" },
        .long = .{ .sep = " ", .suffix = "nanoseconds" },
        .long_one = .{ .sep = " ", .suffix = "nanosecond" },
        .per_short = "/ns",
        .per_narrow = "/ns",
        .per_long = " per nanosecond",
    },
    .{
        .unit = "ounce",
        .short = .{ .sep = " ", .suffix = "oz" },
        .narrow = .{ .sep = "", .suffix = "oz" },
        .long = .{ .sep = " ", .suffix = "ounces" },
        .long_one = .{ .sep = " ", .suffix = "ounce" },
        .per_short = "/oz",
        .per_narrow = "/oz",
        .per_long = " per ounce",
    },
    .{
        .unit = "percent",
        .short = .{ .sep = "", .suffix = "%" },
        .narrow = .{ .sep = "", .suffix = "%" },
        .long = .{ .sep = " ", .suffix = "percent" },
        .per_short = "/%",
        .per_narrow = "/%",
        .per_long = " per percent",
    },
    .{
        .unit = "petabyte",
        .short = .{ .sep = " ", .suffix = "PB" },
        .narrow = .{ .sep = "", .suffix = "PB" },
        .long = .{ .sep = " ", .suffix = "petabytes" },
        .long_one = .{ .sep = " ", .suffix = "petabyte" },
        .per_short = "/PB",
        .per_narrow = "/PB",
        .per_long = " per petabyte",
    },
    .{
        .unit = "pound",
        .short = .{ .sep = " ", .suffix = "lb" },
        .narrow = .{ .sep = "", .suffix = "#" },
        .long = .{ .sep = " ", .suffix = "pounds" },
        .long_one = .{ .sep = " ", .suffix = "pound" },
        .per_short = "/lb",
        .per_narrow = "/lb",
        .per_long = " per pound",
    },
    .{
        .unit = "second",
        .short = .{ .sep = " ", .suffix = "sec" },
        .narrow = .{ .sep = "", .suffix = "s" },
        .long = .{ .sep = " ", .suffix = "seconds" },
        .long_one = .{ .sep = " ", .suffix = "second" },
        .per_short = "/s",
        .per_narrow = "/s",
        .per_long = " per second",
    },
    .{
        .unit = "stone",
        .short = .{ .sep = " ", .suffix = "st" },
        .narrow = .{ .sep = "", .suffix = "st" },
        .long = .{ .sep = " ", .suffix = "stones" },
        .long_one = .{ .sep = " ", .suffix = "stone" },
        .per_short = "/st",
        .per_narrow = "/st",
        .per_long = " per stone",
    },
    .{
        .unit = "terabit",
        .short = .{ .sep = " ", .suffix = "Tb" },
        .narrow = .{ .sep = "", .suffix = "Tb" },
        .long = .{ .sep = " ", .suffix = "terabits" },
        .long_one = .{ .sep = " ", .suffix = "terabit" },
        .per_short = "/Tb",
        .per_narrow = "/Tb",
        .per_long = " per terabit",
    },
    .{
        .unit = "terabyte",
        .short = .{ .sep = " ", .suffix = "TB" },
        .narrow = .{ .sep = "", .suffix = "TB" },
        .long = .{ .sep = " ", .suffix = "terabytes" },
        .long_one = .{ .sep = " ", .suffix = "terabyte" },
        .per_short = "/TB",
        .per_narrow = "/TB",
        .per_long = " per terabyte",
    },
    .{
        .unit = "week",
        .short = .{ .sep = " ", .suffix = "wks" },
        .narrow = .{ .sep = "", .suffix = "w" },
        .long = .{ .sep = " ", .suffix = "weeks" },
        .short_one = .{ .sep = " ", .suffix = "wk" },
        .long_one = .{ .sep = " ", .suffix = "week" },
        .per_short = "/w",
        .per_narrow = "/w",
        .per_long = " per week",
    },
    .{
        .unit = "yard",
        .short = .{ .sep = " ", .suffix = "yd" },
        .narrow = .{ .sep = "", .suffix = "yd" },
        .long = .{ .sep = " ", .suffix = "yards" },
        .long_one = .{ .sep = " ", .suffix = "yard" },
        .per_short = "/yd",
        .per_narrow = "/yd",
        .per_long = " per yard",
    },
    .{
        .unit = "year",
        .short = .{ .sep = " ", .suffix = "yrs" },
        .narrow = .{ .sep = "", .suffix = "y" },
        .long = .{ .sep = " ", .suffix = "years" },
        .short_one = .{ .sep = " ", .suffix = "yr" },
        .long_one = .{ .sep = " ", .suffix = "year" },
        .per_short = "/y",
        .per_narrow = "/y",
        .per_long = " per year",
    },
};

const de_units = [_]UnitEntry{
    percent_unit,
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = " ", .suffix = "km/h" },
        .narrow = .{ .sep = " ", .suffix = "km/h" },
        .long = .{ .sep = " ", .suffix = "Kilometer pro Stunde" },
    },
};

const ja_units = [_]UnitEntry{
    percent_unit,
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = " ", .suffix = "km/h" },
        .narrow = .{ .sep = "", .suffix = "km/h" },
        .long = .{
            .prefix = "\u{6642}\u{901f}",
            .prefix_sep = " ",
            .sep = " ",
            .suffix = "\u{30ad}\u{30ed}\u{30e1}\u{30fc}\u{30c8}\u{30eb}",
        },
    },
};

const ko_units = [_]UnitEntry{
    percent_unit,
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = "", .suffix = "km/h" },
        .narrow = .{ .sep = "", .suffix = "km/h" },
        .long = .{
            .prefix = "\u{c2dc}\u{c18d}",
            .prefix_sep = " ",
            .sep = "",
            .suffix = "\u{d0ac}\u{b85c}\u{bbf8}\u{d130}",
        },
    },
};

const zh_tw_units = [_]UnitEntry{
    percent_unit,
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = " ", .suffix = "\u{516c}\u{91cc}/\u{5c0f}\u{6642}" },
        .narrow = .{ .sep = "", .suffix = "\u{516c}\u{91cc}/\u{5c0f}\u{6642}" },
        .long = .{
            .prefix = "\u{6bcf}\u{5c0f}\u{6642}",
            .prefix_sep = " ",
            .sep = " ",
            .suffix = "\u{516c}\u{91cc}",
        },
    },
};

/// Currency symbols shared by every locale in this table.
pub const currencies_root = [_]CurrencyEntry{
    .{ .code = "USD", .symbol = "$" },
    .{ .code = "EUR", .symbol = "\u{20ac}" },
    .{ .code = "GBP", .symbol = "\u{a3}" },
    .{ .code = "JPY", .symbol = "\u{a5}" },
    .{ .code = "CNY", .symbol = "CN\u{a5}", .narrow = "\u{a5}" },
    .{ .code = "KRW", .symbol = "\u{20a9}" },
    .{ .code = "INR", .symbol = "\u{20b9}" },
    .{ .code = "VND", .symbol = "\u{20ab}" },
};

/// ko-KR and zh-TW disambiguate the dollar sign; "$" alone means the local one.
const us_dollar_qualified = [_]CurrencyEntry{
    .{ .code = "USD", .symbol = "US$", .narrow = "$" },
};

const en_us = LocaleData{};

const en_in = LocaleData{
    .group_secondary = 2,
    .compact_short = &en_in_compact_short,
    .compact_long = &en_in_compact_long,
};

const de_de = LocaleData{
    .decimal = ",",
    .group = ".",
    .currency_suffix = true,
    .currency_sep = "\u{00a0}",
    // German accounting format keeps the minus sign rather than parenthesising.
    .accounting_parens = false,
    .compact_short = &de_compact_short,
    .compact_long = &de_compact_long,
    .units = &de_units,
};

const ja_jp = LocaleData{
    .compact_short = &ja_compact,
    .compact_long = &ja_compact,
    .units = &ja_units,
};

const ko_kr = LocaleData{
    .compact_short = &ko_compact,
    .compact_long = &ko_compact,
    .units = &ko_units,
    .currencies = &us_dollar_qualified,
};

const zh_tw = LocaleData{
    .nan = "\u{975e}\u{6578}\u{503c}",
    .compact_short = &zh_tw_compact,
    .compact_long = &zh_tw_compact,
    .units = &zh_tw_units,
    .currencies = &us_dollar_qualified,
};

const pt_pt = LocaleData{
    .decimal = ",",
    .group = "\u{00a0}",
    .min_grouping = 2,
    .currency_suffix = true,
    .currency_sep = "\u{00a0}",
    .range_sep = " - ",
    .currencies = &us_dollar_qualified,
};

const table = [_]struct { tag: []const u8, data: *const LocaleData }{
    .{ .tag = "en-IN", .data = &en_in },
    .{ .tag = "de", .data = &de_de },
    .{ .tag = "ja", .data = &ja_jp },
    .{ .tag = "ko", .data = &ko_kr },
    .{ .tag = "zh-TW", .data = &zh_tw },
    .{ .tag = "zh-Hant", .data = &zh_tw },
    .{ .tag = "pt-PT", .data = &pt_pt },
    .{ .tag = "pt", .data = &pt_pt },
};

/// Pick the data for a resolved locale tag, longest match first, defaulting to
/// the en-US shape (which is also what an unlisted locale gets).
pub fn forLocale(tag: []const u8) *const LocaleData {
    var best: ?*const LocaleData = null;
    var best_len: usize = 0;
    for (table) |e| {
        const prefix_ok = std.mem.startsWith(u8, tag, e.tag) and
            (tag.len == e.tag.len or tag[e.tag.len] == '-');
        if (prefix_ok and e.tag.len > best_len) {
            best = e.data;
            best_len = e.tag.len;
        }
    }
    return best orelse &en_us;
}

/// CurrencyDigits (§15.1.4): the default fraction-digit count for a currency.
pub fn currencyDigits(code: []const u8) u32 {
    const zero = [_][]const u8{
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
        "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
    };
    const three = [_][]const u8{ "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND" };
    for (zero) |c| if (std.mem.eql(u8, c, code)) return 0;
    for (three) |c| if (std.mem.eql(u8, c, code)) return 3;
    if (std.mem.eql(u8, code, "CLF")) return 4;
    return 2;
}
