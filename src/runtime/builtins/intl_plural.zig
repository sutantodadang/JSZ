//! CLDR plural rules (cardinal) for the locales ECMA-402 conformance exercises.
//!
//! `Intl.PluralRules` needs two things per locale: which categories the locale
//! can ever produce (`resolvedOptions().pluralCategories`, sorted zero < one <
//! two < few < many < other) and which one a given set of plural operands
//! selects. Both come from the same `Rule` classification, so a locale can only
//! resolve to a category its list advertises.
//!
//! The operand names (n, i, v, w, f, t, e) are CLDR's: `n` is the absolute
//! value, `i` its integer part, `v`/`w` the count of visible fraction digits
//! with/without trailing zeros, `f`/`t` those digits as an integer, and `e` the
//! compact/scientific exponent.

const std = @import("std");

/// CLDR plural operands. Mirrors `intl_number.PluralOperands` field-for-field;
/// kept separate so this module stays free of the formatter's imports.
pub const Ops = struct {
    n: f64 = 0,
    i: u64 = 0,
    v: u32 = 0,
    w: u32 = 0,
    f: u64 = 0,
    t: u64 = 0,
    e: i32 = 0,
};

/// A CLDR cardinal rule set, named after a representative language.
pub const Rule = enum {
    /// ja, ko, zh, … — no plural distinctions at all.
    other_only,
    /// en, de, nl, … — `one` only for a bare integer 1. Also the fallback.
    en,
    /// fa, hi — `one` covers 0 and 1.
    fa,
    fr,
    pt,
    es,
    it,
    ar,
    gv,
    sl,
    pl,
    ru,
    cs,
    lt,
    lv,
    ga,
    ro,
    he,
    hr,
};

const RuleEntry = struct { lang: []const u8, rule: Rule };

/// Language subtag → rule. Anything absent falls back to `.en`, the rule the
/// plurality of CLDR locales use.
const RULES = [_]RuleEntry{
    .{ .lang = "ja", .rule = .other_only },
    .{ .lang = "ko", .rule = .other_only },
    .{ .lang = "zh", .rule = .other_only },
    .{ .lang = "yue", .rule = .other_only },
    .{ .lang = "th", .rule = .other_only },
    .{ .lang = "vi", .rule = .other_only },
    .{ .lang = "id", .rule = .other_only },
    .{ .lang = "ms", .rule = .other_only },
    .{ .lang = "lo", .rule = .other_only },
    .{ .lang = "my", .rule = .other_only },
    .{ .lang = "km", .rule = .other_only },
    .{ .lang = "bo", .rule = .other_only },
    .{ .lang = "dz", .rule = .other_only },
    .{ .lang = "ig", .rule = .other_only },
    .{ .lang = "yo", .rule = .other_only },
    .{ .lang = "to", .rule = .other_only },
    .{ .lang = "wo", .rule = .other_only },
    .{ .lang = "sah", .rule = .other_only },
    .{ .lang = "fa", .rule = .fa },
    .{ .lang = "hi", .rule = .fa },
    .{ .lang = "fr", .rule = .fr },
    .{ .lang = "pt", .rule = .pt },
    .{ .lang = "es", .rule = .es },
    .{ .lang = "it", .rule = .it },
    .{ .lang = "ca", .rule = .it },
    .{ .lang = "ar", .rule = .ar },
    .{ .lang = "gv", .rule = .gv },
    .{ .lang = "sl", .rule = .sl },
    .{ .lang = "pl", .rule = .pl },
    .{ .lang = "ru", .rule = .ru },
    .{ .lang = "uk", .rule = .ru },
    .{ .lang = "cs", .rule = .cs },
    .{ .lang = "sk", .rule = .cs },
    .{ .lang = "lt", .rule = .lt },
    .{ .lang = "lv", .rule = .lv },
    .{ .lang = "ga", .rule = .ga },
    .{ .lang = "ro", .rule = .ro },
    .{ .lang = "he", .rule = .he },
    .{ .lang = "iw", .rule = .he },
    .{ .lang = "hr", .rule = .hr },
    .{ .lang = "sr", .rule = .hr },
    .{ .lang = "bs", .rule = .hr },
};

/// The primary language subtag of `locale` ("pl-PL" → "pl"), lowercased into
/// `buf`. Returns a slice of `buf`.
fn languageOf(locale: []const u8, buf: []u8) []const u8 {
    const end = std.mem.indexOfAny(u8, locale, "-_") orelse locale.len;
    const n = @min(end, buf.len);
    for (locale[0..n], 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    return buf[0..n];
}

pub fn ruleFor(locale: []const u8) Rule {
    var buf: [16]u8 = undefined;
    const lang = languageOf(locale, &buf);
    for (RULES) |e| {
        if (std.mem.eql(u8, e.lang, lang)) return e.rule;
    }
    return .en;
}

/// The categories `selectCardinal` can return for `rule`, in CLDR's canonical
/// order (zero, one, two, few, many, other).
pub fn categoriesFor(rule: Rule) []const []const u8 {
    return switch (rule) {
        .other_only => &.{"other"},
        .en, .fa => &.{ "one", "other" },
        .fr, .pt, .es, .it => &.{ "one", "many", "other" },
        .ar => &.{ "zero", "one", "two", "few", "many", "other" },
        .gv, .ga => &.{ "one", "two", "few", "many", "other" },
        .sl => &.{ "one", "two", "few", "other" },
        .pl, .ru, .cs, .lt => &.{ "one", "few", "many", "other" },
        .lv => &.{ "zero", "one", "other" },
        .ro, .hr => &.{ "one", "few", "other" },
        .he => &.{ "one", "two", "other" },
    };
}

/// Categories for the ordinal (`type: "ordinal"`) rule set. Only the English
/// ordinal rules are modelled, so every locale advertises those.
pub fn ordinalCategories() []const []const u8 {
    return &.{ "one", "two", "few", "other" };
}

fn inRange(x: u64, lo: u64, hi: u64) bool {
    return x >= lo and x <= hi;
}

/// The "many" clause shared by the Romance rules (fr/pt/es/it): a whole million
/// in standard notation, or any compact/scientific exponent outside 0–5.
fn romanceMany(o: Ops) bool {
    if (o.e < 0 or o.e > 5) return true;
    return o.e == 0 and o.i != 0 and o.i % 1000000 == 0 and o.v == 0;
}

/// CLDR `PluralRuleSelect` for cardinal rules.
pub fn selectCardinal(rule: Rule, o: Ops) []const u8 {
    const n100 = @mod(o.n, 100);
    return switch (rule) {
        .other_only => "other",
        .en => if (o.i == 1 and o.v == 0) "one" else "other",
        .fa => if (o.i == 0 or o.n == 1) "one" else "other",
        .fr => if (o.i == 0 or o.i == 1) "one" else if (romanceMany(o)) "many" else "other",
        .pt => if (o.i <= 1) "one" else if (romanceMany(o)) "many" else "other",
        .es => if (o.n == 1) "one" else if (romanceMany(o)) "many" else "other",
        .it => if (o.i == 1 and o.v == 0) "one" else if (romanceMany(o)) "many" else "other",
        .ar => if (o.n == 0)
            "zero"
        else if (o.n == 1)
            "one"
        else if (o.n == 2)
            "two"
        else if (n100 >= 3 and n100 <= 10)
            "few"
        else if (n100 >= 11 and n100 <= 99)
            "many"
        else
            "other",
        .gv => if (o.v == 0 and o.i % 10 == 1)
            "one"
        else if (o.v == 0 and o.i % 10 == 2)
            "two"
        else if (o.v == 0 and switch (o.i % 100) {
            0, 20, 40, 60, 80 => true,
            else => false,
        })
            "few"
        else if (o.v != 0)
            "many"
        else
            "other",
        .sl => if (o.v == 0 and o.i % 100 == 1)
            "one"
        else if (o.v == 0 and o.i % 100 == 2)
            "two"
        else if ((o.v == 0 and inRange(o.i % 100, 3, 4)) or o.v != 0)
            "few"
        else
            "other",
        .pl => if (o.i == 1 and o.v == 0)
            "one"
        else if (o.v == 0 and inRange(o.i % 10, 2, 4) and !inRange(o.i % 100, 12, 14))
            "few"
        else if (o.v == 0 and ((o.i != 1 and inRange(o.i % 10, 0, 1)) or
            inRange(o.i % 10, 5, 9) or inRange(o.i % 100, 12, 14)))
            "many"
        else
            "other",
        .ru => if (o.v == 0 and o.i % 10 == 1 and o.i % 100 != 11)
            "one"
        else if (o.v == 0 and inRange(o.i % 10, 2, 4) and !inRange(o.i % 100, 12, 14))
            "few"
        else if (o.v == 0 and (o.i % 10 == 0 or inRange(o.i % 10, 5, 9) or inRange(o.i % 100, 11, 14)))
            "many"
        else
            "other",
        .cs => if (o.i == 1 and o.v == 0)
            "one"
        else if (inRange(o.i, 2, 4) and o.v == 0)
            "few"
        else if (o.v != 0)
            "many"
        else
            "other",
        .lt => blk: {
            const n10 = @mod(o.n, 10);
            const in_teens = n100 >= 11 and n100 <= 19;
            if (n10 == 1 and !in_teens) break :blk "one";
            if (n10 >= 2 and n10 <= 9 and !in_teens) break :blk "few";
            if (o.f != 0) break :blk "many";
            break :blk "other";
        },
        .lv => blk: {
            const n10 = @mod(o.n, 10);
            if (n10 == 0 or (n100 >= 11 and n100 <= 19) or (o.v == 2 and inRange(o.f % 100, 11, 19)))
                break :blk "zero";
            if ((n10 == 1 and n100 != 11) or
                (o.v == 2 and o.f % 10 == 1 and o.f % 100 != 11) or
                (o.v != 2 and o.f % 10 == 1))
                break :blk "one";
            break :blk "other";
        },
        .ga => if (o.n == 1)
            "one"
        else if (o.n == 2)
            "two"
        else if (o.n >= 3 and o.n <= 6)
            "few"
        else if (o.n >= 7 and o.n <= 10)
            "many"
        else
            "other",
        .ro => if (o.i == 1 and o.v == 0)
            "one"
        else if (o.v != 0 or o.n == 0 or (o.n != 1 and n100 >= 1 and n100 <= 19))
            "few"
        else
            "other",
        .he => if (o.i == 1 and o.v == 0)
            "one"
        else if (o.i == 2 and o.v == 0)
            "two"
        else
            "other",
        .hr => if ((o.v == 0 and o.i % 10 == 1 and o.i % 100 != 11) or
            (o.f % 10 == 1 and o.f % 100 != 11))
            "one"
        else if ((o.v == 0 and inRange(o.i % 10, 2, 4) and !inRange(o.i % 100, 12, 14)) or
            (inRange(o.f % 10, 2, 4) and !inRange(o.f % 100, 12, 14)))
            "few"
        else
            "other",
    };
}

/// English ordinal rules, used for `type: "ordinal"` in every locale.
pub fn selectOrdinal(o: Ops) []const u8 {
    if (!std.math.isFinite(o.n)) return "other";
    const iv = o.i;
    const m10 = iv % 10;
    const m100 = iv % 100;
    if (m10 == 1 and m100 != 11) return "one";
    if (m10 == 2 and m100 != 12) return "two";
    if (m10 == 3 and m100 != 13) return "few";
    return "other";
}

test "intl_plural: category lists are ordered and reachable" {
    // 'ar' is the only rule exercising every CLDR category.
    try std.testing.expectEqual(@as(usize, 6), categoriesFor(.ar).len);
    try std.testing.expectEqualStrings("zero", selectCardinal(.ar, .{ .n = 0 }));
    try std.testing.expectEqualStrings("few", selectCardinal(.ar, .{ .n = 103, .i = 103 }));
    try std.testing.expectEqualStrings("many", selectCardinal(.ar, .{ .n = 111, .i = 111 }));
}

test "intl_plural: language lookup ignores region and case" {
    try std.testing.expectEqual(Rule.pl, ruleFor("PL-pl"));
    try std.testing.expectEqual(Rule.ru, ruleFor("uk-UA"));
    try std.testing.expectEqual(Rule.en, ruleFor("xx-YY"));
}

test "intl_plural: fr treats whole millions as many" {
    try std.testing.expectEqualStrings("one", selectCardinal(.fr, .{ .n = 0 }));
    try std.testing.expectEqualStrings("many", selectCardinal(.fr, .{ .n = 1e6, .i = 1000000 }));
    try std.testing.expectEqualStrings("other", selectCardinal(.fr, .{ .n = 1.5e6, .i = 1500000 }));
}
