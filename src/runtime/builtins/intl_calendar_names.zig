// SPDX-License-Identifier: Apache-2.0
//! Wave 56c: the display names `Intl.DateTimeFormat` needs to render a date in a
//! non-ISO calendar — month names, era names, and the lunisolar year name.
//!
//! Only the `en` forms are modelled (this build ships no CLDR); the one
//! exception is the sexagenary year name, which the Chinese/Korean lunisolar
//! calendars write in CJK characters rather than in pinyin.
const std = @import("std");
const cal_mod = @import("temporal/calendar.zig");
const CalendarId = cal_mod.CalendarId;

/// Which family's month-name table a calendar draws on.
fn monthNames(cal: CalendarId) ?[]const []const u8 {
    return switch (cal) {
        .coptic => &coptic_months,
        .ethiopic, .ethioaa => &ethiopic_months,
        .islamic_civil, .islamic_tbla, .islamic_umalqura => &islamic_months,
        .persian => &persian_months,
        .indian => &indian_months,
        .hebrew => &hebrew_months,
        // The Gregorian family and the lunisolar pair are handled by the caller:
        // the former uses the ISO month tables, the latter has only numbers.
        else => null,
    };
}

const coptic_months = [_][]const u8{
    "Tout",   "Baba", "Hator", "Kiahk", "Toba", "Amshir", "Baramhat",
    "Baramouda", "Bashans", "Paona", "Epep", "Mesra", "Nasie",
};
const ethiopic_months = [_][]const u8{
    "Meskerem", "Tekemt", "Hedar", "Tahsas", "Ter",     "Yekatit", "Megabit",
    "Miazia",   "Genbot", "Sene",  "Hamle",  "Nehasse", "Pagumen",
};
const islamic_months = [_][]const u8{
    "Muharram", "Safar",  "Rabiʻ I", "Rabiʻ II", "Jumada I",     "Jumada II",
    "Rajab",    "Shaʻban", "Ramadan", "Shawwal",  "Dhuʻl-Qiʻdah", "Dhuʻl-Hijjah",
};
const persian_months = [_][]const u8{
    "Farvardin", "Ordibehesht", "Khordad", "Tir",    "Mordad",  "Shahrivar",
    "Mehr",      "Aban",        "Azar",    "Dey",    "Bahman",  "Esfand",
};
const indian_months = [_][]const u8{
    "Chaitra", "Vaisakha", "Jyaistha",    "Asadha", "Sravana", "Bhadra",
    "Asvina",  "Kartika",  "Agrahayana", "Pausa",  "Magha",   "Phalguna",
};
/// Hebrew months are named by their *code*, not their ordinal: a leap year
/// inserts Adar I as M05L, which pushes every later ordinal along by one.
const hebrew_months = [_][]const u8{
    "Tishri", "Heshvan", "Kislev", "Tevet", "Shevat", "Adar",
    "Nisan",  "Iyar",    "Sivan",  "Tamuz", "Av",     "Elul",
};

/// The month's display name in `cal`, or null when the calendar has no names of
/// its own (the Gregorian family, and the lunisolar pair's bare numbers).
pub fn monthName(arena: std.mem.Allocator, cal: CalendarId, code_num: u8, code_leap: bool, ordinal: u8) !?[]const u8 {
    if (cal == .hebrew) {
        if (code_leap) return "Adar I";
        if (code_num < 1 or code_num > hebrew_months.len) return null;
        // In a leap year the plain Adar (M06) is the *second* Adar.
        if (code_num == 6 and ordinal == 7) return "Adar II";
        return hebrew_months[code_num - 1];
    }
    const table = monthNames(cal) orelse return null;
    if (code_num < 1 or code_num > table.len) return null;
    if (code_leap) return try std.fmt.allocPrint(arena, "{s} (leap)", .{table[code_num - 1]});
    return table[code_num - 1];
}

/// The era's display name in `en` for the era codes `calendar.fields` produces.
pub fn eraName(code: []const u8, style: []const u8) []const u8 {
    const long = std.mem.eql(u8, style, "long");
    const narrow = std.mem.eql(u8, style, "narrow");
    const eq = std.mem.eql;
    if (eq(u8, code, "ce")) return if (long) "Anno Domini" else if (narrow) "A" else "AD";
    if (eq(u8, code, "bce")) return if (long) "Before Christ" else if (narrow) "B" else "BC";
    if (eq(u8, code, "be")) return if (long) "Buddhist Era" else "BE";
    if (eq(u8, code, "roc")) return if (narrow) "M" else "Minguo";
    if (eq(u8, code, "broc")) return if (long) "Before R.O.C." else if (narrow) "B" else "B.R.O.C.";
    if (eq(u8, code, "ah")) return if (long) "AH" else "AH";
    if (eq(u8, code, "bh")) return if (long) "Before Hijrah" else "BH";
    if (eq(u8, code, "am")) return if (long) "Anno Mundi" else "AM";
    if (eq(u8, code, "aa")) return if (long) "Amete Alem" else "A.A.";
    if (eq(u8, code, "ap")) return if (long) "Anno Persico" else "AP";
    if (eq(u8, code, "shaka")) return "Saka";
    if (eq(u8, code, "meiji")) return "Meiji";
    if (eq(u8, code, "taisho")) return "Taishō";
    if (eq(u8, code, "showa")) return "Shōwa";
    if (eq(u8, code, "heisei")) return "Heisei";
    if (eq(u8, code, "reiwa")) return "Reiwa";
    return code;
}

const stems_latin = [_][]const u8{ "jia", "yi", "bing", "ding", "wu", "ji", "geng", "xin", "ren", "gui" };
const branches_latin = [_][]const u8{ "zi", "chou", "yin", "mao", "chen", "si", "wu", "wei", "shen", "you", "xu", "hai" };
const stems_cjk = [_][]const u8{ "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" };
const branches_cjk = [_][]const u8{ "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" };

/// The sexagenary cycle name of a Chinese/Korean lunisolar year — pinyin
/// ("ji-hai") for a Latin-script locale, CJK ("己亥") for one that writes it.
pub fn sexagenaryYearName(arena: std.mem.Allocator, year: i32, cjk: bool) ![]const u8 {
    const s: usize = @intCast(@mod(year - 4, 10));
    const b: usize = @intCast(@mod(year - 4, 12));
    if (cjk) return std.fmt.allocPrint(arena, "{s}{s}", .{ stems_cjk[s], branches_cjk[b] });
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ stems_latin[s], branches_latin[b] });
}

test "sexagenary cycle" {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectEqualStrings("ji-hai", try sexagenaryYearName(fba.allocator(), 2019, false));
}
