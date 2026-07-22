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

const en_units = [_]UnitEntry{
    percent_unit,
    .{
        .unit = "kilometer-per-hour",
        .short = .{ .sep = " ", .suffix = "km/h" },
        .narrow = .{ .sep = "", .suffix = "km/h" },
        .long = .{ .sep = " ", .suffix = "kilometers per hour" },
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
