// SPDX-License-Identifier: Apache-2.0
//! Wave 45c: non-ISO calendar support for Temporal.
//!
//! Temporal objects keep their canonical `ISODate` (proleptic Gregorian) plus a
//! `CalendarId` tag; this module is the only place that knows how to project an
//! ISO date onto a calendar's own {era, eraYear, year, month, monthCode, day}
//! and back again. Everything else (epoch-day math, range gates, serialization)
//! keeps operating on the ISO date, exactly as the spec's [[ISODate]] +
//! [[Calendar]] slot model prescribes.
//!
//! Every calendar here is *arithmetic*: it is defined entirely by two functions,
//! `yearStartDays` (the epoch day on which a given year begins) and
//! `daysInMonth`. Conversion in both directions is then uniform — walk months
//! from the start of the year — so adding a calendar means adding those two
//! rules and its era labels, not another pair of conversion formulas.
//!
//! Not implemented: the astronomical lunisolar calendars (chinese, dangi) and
//! islamic-umalqura, which need observational or tabulated month data rather
//! than a closed-form year start.
const std = @import("std");
const shared = @import("shared.zig");
const ISODate = shared.ISODate;

pub const CalendarId = enum(u8) {
    iso8601,
    // Gregorian-derived: ISO's month structure, different year numbering.
    gregory,
    buddhist,
    roc,
    japanese,
    // Coptic-derived: 12 months of 30 days plus a short 13th month.
    coptic,
    ethiopic,
    ethioaa,
    // Tabular Islamic: 12 alternating 30/29-day months, 30-year leap cycle.
    islamic_civil,
    islamic_tbla,
    // Solar, non-Gregorian month lengths.
    persian,
    indian,
    // Lunisolar: 12 or 13 months, with a leap month interpolated after M05.
    hebrew,

    /// The canonical BCP-47 `-u-ca-` identifier, as reported by `calendarId`.
    pub fn str(self: CalendarId) []const u8 {
        return switch (self) {
            .iso8601 => "iso8601",
            .gregory => "gregory",
            .buddhist => "buddhist",
            .roc => "roc",
            .japanese => "japanese",
            .coptic => "coptic",
            .ethiopic => "ethiopic",
            .ethioaa => "ethioaa",
            .islamic_civil => "islamic-civil",
            .islamic_tbla => "islamic-tbla",
            .persian => "persian",
            .indian => "indian",
            .hebrew => "hebrew",
        };
    }
};

/// Non-canonical identifiers that alias a supported calendar.
const aliases = [_]struct { name: []const u8, id: CalendarId }{
    .{ .name = "islamicc", .id = .islamic_civil },
    .{ .name = "ethiopic-amete-alem", .id = .ethioaa },
};

/// Case-insensitive identifier lookup (CanonicalizeCalendar). Returns null for
/// anything this engine does not implement, which callers surface as a
/// RangeError.
pub fn canonicalize(name: []const u8) ?CalendarId {
    if (name.len == 0 or name.len > 32) return null;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    inline for (@typeInfo(CalendarId).@"enum".fields) |f| {
        const c: CalendarId = @enumFromInt(f.value);
        if (std.mem.eql(u8, lower, c.str())) return c;
    }
    for (aliases) |a| {
        if (std.mem.eql(u8, lower, a.name)) return a.id;
    }
    return null;
}

/// A date expressed in a calendar's own field system.
pub const CalFields = struct {
    /// Era code (e.g. "ce", "be", "reiwa"); null for calendars without eras.
    era: ?[]const u8 = null,
    era_year: ?i32 = null,
    /// Arithmetic (era-independent, monotonic) year.
    year: i32,
    /// 1-based ordinal position of the month within its year.
    month: u8,
    /// Month code number, e.g. 3 for "M03".
    code_num: u8,
    /// Whether the month code carries the leap-month "L" suffix.
    code_leap: bool = false,
    day: u8,
};

// ------------------------------------------------------------------- epochs ---

// Epoch days (days since 1970-01-01) of each calendar's year 1, month 1, day 1.
// Derived from the Rata Die values in Calendrical Calculations: RD 719163 is
// 1970-01-01, so `epoch_days = RD - 719163`.
const coptic_epoch: i64 = 103605 - 719163; // Julian 284-08-29
const ethiopic_epoch: i64 = 2796 - 719163; // Julian 8-08-29
const islamic_civil_epoch: i64 = 227015 - 719163; // Julian 622-07-16
const islamic_tbla_epoch: i64 = 227014 - 719163; // Julian 622-07-15 (astronomical)
const persian_epoch: i64 = 226896 - 719163; // Julian 622-03-19
const hebrew_epoch: i64 = -1373427 - 719163; // Gregorian -3760-09-07

/// Ethiopic's Amete Alem numbering runs 5500 years ahead of Amete Mihret.
const ethioaa_offset: i32 = 5500;

/// ISO year in which a Gregorian-derived calendar's arithmetic year 0 begins;
/// for that family the whole projection is this single offset.
fn gregorianOffset(cal: CalendarId) i32 {
    return switch (cal) {
        .iso8601, .gregory, .japanese => 0,
        .buddhist => -543,
        .roc => 1911,
        else => unreachable,
    };
}

fn isGregorianFamily(cal: CalendarId) bool {
    return switch (cal) {
        .iso8601, .gregory, .buddhist, .roc, .japanese => true,
        else => false,
    };
}

// -------------------------------------------------------------- year shape ---

/// Epoch day on which `year` of `cal` begins.
fn yearStartDays(cal: CalendarId, year: i32) i64 {
    if (isGregorianFamily(cal)) {
        return shared.isoDateToEpochDays(year + gregorianOffset(cal), 1, 1);
    }
    const y: i64 = year;
    return switch (cal) {
        .coptic => coptic_epoch + 365 * (y - 1) + @divFloor(y, 4),
        .ethiopic => ethiopic_epoch + 365 * (y - 1) + @divFloor(y, 4),
        .ethioaa => yearStartDays(.ethiopic, year - ethioaa_offset),
        .islamic_civil => islamic_civil_epoch + 354 * (y - 1) + @divFloor(3 + 11 * y, 30),
        .islamic_tbla => islamic_tbla_epoch + 354 * (y - 1) + @divFloor(3 + 11 * y, 30),
        .persian => persianYearStart(year),
        .hebrew => hebrewNewYear(year),
        // Saka year Y begins on 22 March of Gregorian year Y+78, or 21 March
        // when that Gregorian year is a leap year.
        .indian => shared.isoDateToEpochDays(year + 78, 3, if (shared.isLeapYear(year + 78)) 21 else 22),
        else => unreachable,
    };
}

/// Persian (Solar Hijri) leap years, by the 33-year cycle: 8 leap years per
/// cycle at these positions of `year mod 33`. This is the rule ICU implements,
/// and it differs from Birashk's 2820-year cycle in scattered years (e.g. 978
/// and 1048 AP), so the two disagree on roughly 5% of dates.
const persian_leap_positions = [_]i64{ 1, 5, 9, 13, 17, 22, 26, 30 };

/// Number of Persian leap years in [1, y].
fn persianLeapsUpTo(y: i64) i64 {
    const cycles = @divFloor(y - 1, 33);
    const pos = @mod(y - 1, 33) + 1; // 1..33
    var extra: i64 = 0;
    for (persian_leap_positions) |p| {
        if (p <= pos) extra += 1;
    }
    return cycles * 8 + extra;
}

fn persianYearStart(year: i32) i64 {
    const y: i64 = year;
    // The leap count runs one ahead of the epoch's own year, hence the -1.
    return persian_epoch - 1 + 365 * (y - 1) + persianLeapsUpTo(y - 1);
}

// ------------------------------------------------------------------- Hebrew ---

/// A Hebrew leap year interpolates a 13th month; 7 of every 19 years are leap.
fn hebrewIsLeap(year: i32) bool {
    return @mod(7 * @as(i64, year) + 1, 19) < 7;
}

/// Days elapsed from the epoch to the mean new moon (molad) of `year`, with the
/// first of the four postponement rules (dehiyyot) already applied.
fn hebrewElapsedDays(year: i64) i64 {
    const months_elapsed = @divFloor(235 * year - 234, 19);
    const parts_elapsed = 12084 + 13753 * months_elapsed;
    var day = 29 * months_elapsed + @divFloor(parts_elapsed, 25920);
    // Rosh Hashanah may not fall on a Sunday, Wednesday or Friday.
    if (@mod(3 * (day + 1), 7) < 3) day += 1;
    return day;
}

/// Epoch day of 1 Tishri of `year`, applying the remaining postponement rules,
/// which exist only to keep the year length one of 353/354/355/383/384/385.
fn hebrewNewYear(year: i32) i64 {
    const y: i64 = year;
    const prev = hebrewElapsedDays(y - 1);
    const cur = hebrewElapsedDays(y);
    const next = hebrewElapsedDays(y + 1);
    const correction: i64 = if (next - cur == 356) 2 else if (cur - prev == 382) 1 else 0;
    return hebrew_epoch + cur + correction;
}

/// Month lengths counted from Tishri. Heshvan and Kislev are the two variable
/// months: the year's total length (…3 deficient, …4 regular, …5 complete)
/// decides them, which is how the calendar absorbs the postponement rules.
fn hebrewDaysInMonth(year: i32, month: u8) u8 {
    const leap = hebrewIsLeap(year);
    const year_len = @mod(daysInYear(.hebrew, year), 10);
    return switch (month) {
        1 => 30, // Tishri
        2 => if (year_len == 5) 30 else 29, // Heshvan, long in a complete year
        3 => if (year_len == 3) 29 else 30, // Kislev, short in a deficient year
        4 => 29, // Tevet
        5 => 30, // Shevat
        // In a leap year month 6 is Adar I (30 days) and month 7 Adar II (29);
        // in a common year month 6 is the sole Adar.
        6 => if (leap) 30 else 29,
        // From here the leap year runs one ordinal behind the common year, so
        // the alternating 30/29 pattern flips parity.
        else => if (leap)
            (if (month % 2 == 1) 29 else 30)
        else
            (if (month % 2 == 1) 30 else 29),
    };
}

/// Hebrew month codes are year-dependent: the leap month Adar I sits at ordinal
/// 6 and carries the code "M05L", pushing Adar..Elul one ordinal later.
fn hebrewCodeFromMonth(year: i32, month: u8) shared.MonthCode {
    if (!hebrewIsLeap(year)) return .{ .num = month };
    if (month <= 5) return .{ .num = month };
    if (month == 6) return .{ .num = 5, .leap = true };
    return .{ .num = month - 1 };
}

fn hebrewMonthFromCode(year: i32, code_num: u8, code_leap: bool) ?u8 {
    const leap = hebrewIsLeap(year);
    if (code_leap) {
        // Adar I exists only in a leap year.
        if (!leap or code_num != 5) return null;
        return 6;
    }
    if (code_num < 1 or code_num > 12) return null;
    if (!leap) return code_num;
    return if (code_num <= 5) code_num else code_num + 1;
}

pub fn monthsInYear(cal: CalendarId, cal_year: i32) u8 {
    return switch (cal) {
        .coptic, .ethiopic, .ethioaa => 13,
        // A Hebrew leap year interpolates Adar I, giving 13 months.
        .hebrew => if (hebrewIsLeap(cal_year)) 13 else 12,
        else => 12,
    };
}

pub fn inLeapYear(cal: CalendarId, cal_year: i32) bool {
    if (isGregorianFamily(cal)) return shared.isLeapYear(cal_year + gregorianOffset(cal));
    return switch (cal) {
        // A 6-day epagomenal month falls in the year before each leap day.
        .coptic, .ethiopic => @mod(cal_year, 4) == 3,
        .ethioaa => @mod(cal_year - ethioaa_offset, 4) == 3,
        .islamic_civil, .islamic_tbla => @mod(14 + 11 * @as(i64, cal_year), 30) < 11,
        // Both are simply "the year is 366 days long".
        .persian, .indian => daysInYear(cal, cal_year) == 366,
        .hebrew => hebrewIsLeap(cal_year),
        else => unreachable,
    };
}

pub fn daysInMonth(cal: CalendarId, cal_year: i32, month: u8) u8 {
    if (isGregorianFamily(cal)) return shared.isoDaysInMonth(cal_year + gregorianOffset(cal), month);
    return switch (cal) {
        // Twelve 30-day months plus a short epagomenal 13th.
        .coptic, .ethiopic, .ethioaa => if (month <= 12)
            30
        else if (inLeapYear(cal, cal_year)) 6 else 5,
        // Odd months 30 days, even months 29, with a leap day in month 12.
        .islamic_civil, .islamic_tbla => if (month % 2 == 1)
            30
        else if (month == 12 and inLeapYear(cal, cal_year)) 30 else 29,
        .persian => if (month <= 6)
            31
        else if (month <= 11) 30 else if (inLeapYear(cal, cal_year)) 30 else 29,
        .indian => if (month == 1)
            (if (shared.isLeapYear(cal_year + 78)) 31 else 30)
        else if (month <= 6) 31 else 30,
        .hebrew => hebrewDaysInMonth(cal_year, month),
        else => unreachable,
    };
}

pub fn daysInYear(cal: CalendarId, cal_year: i32) u16 {
    return @intCast(yearStartDays(cal, cal_year + 1) - yearStartDays(cal, cal_year));
}

// -------------------------------------------------------------- conversion ---

const YMD = struct { year: i32, month: u8, day: u8 };

/// Split an epoch day into `cal`'s {year, month, day}.
fn ymdFromEpochDays(cal: CalendarId, days: i64) YMD {
    // Seed from the calendar's mean year length, then correct — one step at
    // most in practice, but the loops keep this exact for every calendar.
    var year = estimateYear(cal, days);
    while (days < yearStartDays(cal, year)) year -= 1;
    while (days >= yearStartDays(cal, year + 1)) year += 1;

    var remaining: i64 = days - yearStartDays(cal, year);
    var month: u8 = 1;
    const last = monthsInYear(cal, year);
    while (month < last) : (month += 1) {
        const dim = daysInMonth(cal, year, month);
        if (remaining < dim) break;
        remaining -= dim;
    }
    return .{ .year = year, .month = month, .day = @intCast(remaining + 1) };
}

fn estimateYear(cal: CalendarId, days: i64) i32 {
    if (isGregorianFamily(cal)) {
        return shared.epochDaysToISODate(days).year - gregorianOffset(cal);
    }
    return switch (cal) {
        .coptic => @intCast(@divFloor(days - coptic_epoch, 365) + 1),
        .ethiopic => @intCast(@divFloor(days - ethiopic_epoch, 365) + 1),
        .ethioaa => @as(i32, @intCast(@divFloor(days - ethiopic_epoch, 365) + 1)) + ethioaa_offset,
        .islamic_civil => @intCast(@divFloor((days - islamic_civil_epoch) * 30, 10631) + 1),
        .islamic_tbla => @intCast(@divFloor((days - islamic_tbla_epoch) * 30, 10631) + 1),
        .persian => @intCast(@divFloor((days - persian_epoch) * 1000, 365242) + 1),
        .indian => shared.epochDaysToISODate(days).year - 78,
        // Mean Hebrew year is ~365.2468 days.
        .hebrew => @intCast(@divFloor((days - hebrew_epoch) * 10000, 3652468) + 1),
        else => unreachable,
    };
}

/// Epoch day of `cal`'s {year, month, day} (which must already be in range).
fn epochDaysFromYmd(cal: CalendarId, year: i32, month: u8, day: i32) i64 {
    var days = yearStartDays(cal, year);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += daysInMonth(cal, year, m);
    return days + day - 1;
}

// -------------------------------------------------------------- projection ---

/// Project an ISO date onto `cal`'s field system.
pub fn fields(cal: CalendarId, d: ISODate) CalFields {
    const ymd = if (isGregorianFamily(cal))
        YMD{ .year = d.year - gregorianOffset(cal), .month = d.month, .day = d.day }
    else
        ymdFromEpochDays(cal, shared.isoDateToEpochDays(d.year, d.month, d.day));

    var out = CalFields{
        .year = ymd.year,
        .month = ymd.month,
        .code_num = ymd.month,
        .day = ymd.day,
    };
    const y = ymd.year;
    switch (cal) {
        .iso8601 => {},
        .gregory => setEra(&out, y > 0, "ce", y, "bce", 1 - y),
        .buddhist => {
            out.era = "be";
            out.era_year = y;
        },
        .roc => setEra(&out, y > 0, "roc", y, "broc", 1 - y),
        .japanese => {
            if (japaneseEraFor(d)) |e| {
                out.era = e.name;
                out.era_year = d.year - e.y0 + 1;
            } else setEra(&out, d.year > 0, "ce", d.year, "bce", 1 - d.year);
        },
        .coptic => {
            out.era = "am";
            out.era_year = y;
        },
        // Amete Mihret from year 1 on; earlier years fall back to the Amete
        // Alem numbering, which runs 5500 years ahead.
        .ethiopic => setEra(&out, y > 0, "am", y, "aa", y + ethioaa_offset),
        .ethioaa => {
            out.era = "aa";
            out.era_year = y;
        },
        .islamic_civil, .islamic_tbla => setEra(&out, y > 0, "ah", y, "bh", 1 - y),
        .persian => {
            out.era = "ap";
            out.era_year = y;
        },
        .indian => {
            out.era = "shaka";
            out.era_year = y;
        },
        .hebrew => {
            out.era = "am";
            out.era_year = y;
        },
    }
    const code = codeFromMonth(cal, ymd.year, ymd.month);
    out.code_num = code.num;
    out.code_leap = code.leap;
    return out;
}

fn setEra(out: *CalFields, positive: bool, name: []const u8, y: i32, inverse: []const u8, inverse_y: i32) void {
    if (positive) {
        out.era = name;
        out.era_year = y;
    } else {
        out.era = inverse;
        out.era_year = inverse_y;
    }
}

/// Convert an {era, eraYear} pair into `cal`'s arithmetic year. Returns null if
/// the era code is not one of this calendar's eras.
///
/// Out-of-range era years are deliberately *not* rejected: the spec resolves
/// e.g. `{era: "reiwa", eraYear: 0}` by mapping through the arithmetic year and
/// then re-deriving whichever era actually contains the resulting date.
pub fn yearFromEra(cal: CalendarId, era: []const u8, era_year: i32) ?i32 {
    const eq = std.mem.eql;
    return switch (cal) {
        .iso8601 => null,
        .gregory => if (eq(u8, era, "ce") or eq(u8, era, "ad"))
            era_year
        else if (eq(u8, era, "bce") or eq(u8, era, "bc"))
            1 - era_year
        else
            null,
        .buddhist => if (eq(u8, era, "be")) era_year else null,
        .roc => if (eq(u8, era, "roc"))
            era_year
        else if (eq(u8, era, "broc")) 1 - era_year else null,
        .japanese => blk: {
            if (japaneseEraByName(era)) |e| break :blk e.y0 + era_year - 1;
            if (eq(u8, era, "ce") or eq(u8, era, "ad")) break :blk era_year;
            if (eq(u8, era, "bce") or eq(u8, era, "bc")) break :blk 1 - era_year;
            break :blk null;
        },
        .coptic => if (eq(u8, era, "am")) era_year else null,
        .ethiopic => if (eq(u8, era, "am"))
            era_year
        else if (eq(u8, era, "aa")) era_year - ethioaa_offset else null,
        .ethioaa => if (eq(u8, era, "aa")) era_year else null,
        .islamic_civil, .islamic_tbla => if (eq(u8, era, "ah"))
            era_year
        else if (eq(u8, era, "bh")) 1 - era_year else null,
        .persian => if (eq(u8, era, "ap")) era_year else null,
        .indian => if (eq(u8, era, "shaka")) era_year else null,
        .hebrew => if (eq(u8, era, "am")) era_year else null,
    };
}

/// Whether `cal` numbers its years by era. Calendars that do not (ISO 8601)
/// have no "era"/"eraYear" fields at all, so those properties are ignored
/// rather than validated when they appear in a property bag.
pub fn hasEras(cal: CalendarId) bool {
    return cal != .iso8601;
}

/// Whether `cal` can have leap months (i.e. month codes with an "L" suffix).
pub fn hasLeapMonths(cal: CalendarId) bool {
    return cal == .hebrew;
}

/// Map a month code onto its ordinal position in `cal_year`, or null when the
/// year has no such month.
pub fn monthFromCode(cal: CalendarId, cal_year: i32, code_num: u8, code_leap: bool) ?u8 {
    if (cal == .hebrew) return hebrewMonthFromCode(cal_year, code_num, code_leap);
    if (code_leap) return null;
    if (code_num < 1 or code_num > monthsInYear(cal, cal_year)) return null;
    return code_num;
}

/// Whether `cal` ever has this month code, in any year. A code that is merely
/// absent from one year (Hebrew's M05L in a common year) is still valid and gets
/// constrained; a code the calendar never uses at all is a RangeError whatever
/// the overflow option says.
pub fn isValidCode(cal: CalendarId, code_num: u8, code_leap: bool) bool {
    if (code_leap) {
        // Hebrew's sole leap month is Adar I, which follows M05.
        return cal == .hebrew and code_num == 5;
    }
    return switch (cal) {
        // The epagomenal 13th month is an ordinary M13.
        .coptic, .ethiopic, .ethioaa => code_num >= 1 and code_num <= 13,
        else => code_num >= 1 and code_num <= 12,
    };
}

/// The month code of an ordinal month position — the inverse of
/// `monthFromCode`. Only lunisolar calendars make this year-dependent.
fn codeFromMonth(cal: CalendarId, cal_year: i32, month: u8) shared.MonthCode {
    if (cal == .hebrew) return hebrewCodeFromMonth(cal_year, month);
    return .{ .num = month };
}

/// The ISO year holding `cal_year`'s first month. Only meaningful for the
/// Gregorian-derived family, where a year maps 1:1 onto an ISO year.
pub fn isoYearOf(cal: CalendarId, cal_year: i32) i32 {
    if (isGregorianFamily(cal)) return cal_year + gregorianOffset(cal);
    return shared.epochDaysToISODate(yearStartDays(cal, cal_year)).year;
}

// ------------------------------------------------------------------ Japanese ---

/// Japanese era boundaries, most recent first. `y0` is the Gregorian year in
/// which the era's year 1 falls, so `era_year = iso_year - y0 + 1`.
const JapaneseEra = struct { name: []const u8, y0: i32, month: u8, day: u8 };
const japanese_eras = [_]JapaneseEra{
    .{ .name = "reiwa", .y0 = 2019, .month = 5, .day = 1 },
    .{ .name = "heisei", .y0 = 1989, .month = 1, .day = 8 },
    .{ .name = "showa", .y0 = 1926, .month = 12, .day = 25 },
    .{ .name = "taisho", .y0 = 1912, .month = 7, .day = 30 },
    .{ .name = "meiji", .y0 = 1868, .month = 9, .day = 8 },
};

/// The era in force on `d`, or null for pre-Meiji dates (which fall back to the
/// Gregorian ce/bce eras).
fn japaneseEraFor(d: ISODate) ?JapaneseEra {
    for (japanese_eras) |e| {
        if (d.year > e.y0) return e;
        if (d.year == e.y0 and (d.month > e.month or (d.month == e.month and d.day >= e.day))) return e;
    }
    return null;
}

fn japaneseEraByName(name: []const u8) ?JapaneseEra {
    for (japanese_eras) |e| {
        if (std.mem.eql(u8, name, e.name)) return e;
    }
    return null;
}

// ---------------------------------------------------------- reconstitution ---

pub const Error = error{OutOfRange};

/// Shift a calendar-space {year, month} by a whole number of months, carrying
/// across year boundaries using each year's own month count.
pub fn addMonths(cal: CalendarId, cal_year: i32, month: u8, delta: i128) Error!struct { year: i32, month: u8 } {
    var y: i128 = cal_year;
    var m: i128 = @as(i128, month) + delta;
    if (hasLeapMonths(cal)) {
        // A lunisolar year's month count varies, so the carry has to walk a
        // year at a time. Bounded by the range gate below.
        while (m < 1) {
            y -= 1;
            if (y < -300_000) return error.OutOfRange;
            m += monthsInYear(cal, @intCast(y));
        }
        while (m > monthsInYear(cal, @intCast(y))) {
            m -= monthsInYear(cal, @intCast(y));
            y += 1;
            if (y > 300_000) return error.OutOfRange;
        }
    } else {
        // A fixed month count makes the carry exact division.
        const per_year = monthsInYear(cal, cal_year);
        if (m < 1 or m > per_year) {
            y += @divFloor(m - 1, per_year);
            m = @mod(m - 1, per_year) + 1;
        }
    }
    if (y > 300_000 or y < -300_000) return error.OutOfRange;
    return .{ .year = @intCast(y), .month = @intCast(m) };
}

/// Reconstitute an ISO date from calendar-space fields, applying `overflow`.
/// Under `.constrain` the month is clamped into the year and the day into the
/// month; under `.reject` an out-of-range field is an error.
pub fn toIso(cal: CalendarId, cal_year: i32, month: i32, day: i32, overflow: shared.Overflow) Error!ISODate {
    if (cal_year > 300_000 or cal_year < -300_000) return error.OutOfRange;
    const per_year = monthsInYear(cal, cal_year);
    var m = month;
    var d = day;
    if (overflow == .reject) {
        if (m < 1 or m > per_year) return error.OutOfRange;
        if (d < 1 or d > daysInMonth(cal, cal_year, @intCast(m))) return error.OutOfRange;
    } else {
        if (m < 1) m = 1;
        if (m > per_year) m = per_year;
        const dim = daysInMonth(cal, cal_year, @intCast(m));
        if (d < 1) d = 1;
        if (d > dim) d = dim;
    }
    if (isGregorianFamily(cal)) {
        return .{
            .year = cal_year + gregorianOffset(cal),
            .month = @intCast(m),
            .day = @intCast(d),
            .calendar = cal,
        };
    }
    const days = epochDaysFromYmd(cal, cal_year, @intCast(m), d);
    if (days > 400_000_000 or days < -400_000_000) return error.OutOfRange;
    var out = shared.epochDaysToISODate(days);
    out.calendar = cal;
    return out;
}

/// As `toIso`, but the month is given as a month code. A code naming a month the
/// year does not have (e.g. a leap month in a common year) is constrained to the
/// nearest ordinary month, or rejected.
pub fn toIsoFromCode(cal: CalendarId, cal_year: i32, code_num: u8, code_leap: bool, day: i32, overflow: shared.Overflow) Error!ISODate {
    // A code the calendar never uses is always an error; overflow only governs
    // codes that exist but are absent from this particular year.
    if (!isValidCode(cal, code_num, code_leap)) return error.OutOfRange;
    const m = monthFromCode(cal, cal_year, code_num, code_leap) orelse {
        if (overflow == .reject) return error.OutOfRange;
        // Constrain: drop the leap flag and clamp into the year.
        const per_year = monthsInYear(cal, cal_year);
        const fallback: i32 = if (code_num < 1) 1 else if (code_num > per_year) per_year else code_num;
        return toIso(cal, cal_year, fallback, day, .constrain);
    };
    return toIso(cal, cal_year, m, day, overflow);
}

/// CalendarMonthDayToISOReferenceDate: the ISO date a PlainMonthDay stores for
/// a given month code and day — the latest date on or before 1972-12-31 whose
/// calendar month code and day match. Walking back matters for month/day pairs
/// that only occur in some years (e.g. a 30th day of an Islamic month 12, which
/// needs a leap year).
pub fn monthDayReference(cal: CalendarId, code_num: u8, code_leap: bool, day: i32, overflow: shared.Overflow) Error!ISODate {
    const limit = shared.isoDateToEpochDays(1972, 12, 31);
    const start_year = fields(cal, shared.epochDaysToISODate(limit)).year;
    // Two passes: first demanding the exact day, then — only when constraining
    // — allowing it to be clamped into the month.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        if (pass == 1 and overflow == .reject) return error.OutOfRange;
        var y = start_year;
        // A month/day recurs at least once per leap cycle; the Islamic 30-year
        // cycle is the longest among the implemented calendars.
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            if (monthFromCode(cal, y, code_num, code_leap)) |m| {
                const dim = daysInMonth(cal, y, m);
                const use_day = if (pass == 1 and day > dim) dim else day;
                if (use_day >= 1 and use_day <= dim) {
                    const iso = try toIso(cal, y, m, use_day, .reject);
                    if (shared.isoDateToEpochDays(iso.year, iso.month, iso.day) <= limit) return iso;
                }
            }
            y -= 1;
        }
    }
    return error.OutOfRange;
}

// ----------------------------------------------------------------- tests ---

test "gregorian-family projection round-trips" {
    const d = ISODate{ .year = 2021, .month = 7, .day = 16 };
    try std.testing.expectEqual(@as(i32, 2564), fields(.buddhist, d).year);
    try std.testing.expectEqualStrings("be", fields(.buddhist, d).era.?);
    try std.testing.expectEqual(@as(i32, 110), fields(.roc, d).year);
    try std.testing.expectEqualStrings("roc", fields(.roc, d).era.?);
    try std.testing.expectEqualStrings("ce", fields(.gregory, d).era.?);
    try std.testing.expectEqual(@as(i32, 2021), fields(.gregory, d).era_year.?);
}

test "japanese era boundaries" {
    // 2019-04-30 is Heisei 31; 2019-05-01 begins Reiwa 1.
    const apr = fields(.japanese, .{ .year = 2019, .month = 4, .day = 30 });
    try std.testing.expectEqualStrings("heisei", apr.era.?);
    try std.testing.expectEqual(@as(i32, 31), apr.era_year.?);
    const may = fields(.japanese, .{ .year = 2019, .month = 5, .day = 1 });
    try std.testing.expectEqualStrings("reiwa", may.era.?);
    try std.testing.expectEqual(@as(i32, 1), may.era_year.?);
    // 1989-01-07 is still Showa 64.
    const jan7 = fields(.japanese, .{ .year = 1989, .month = 1, .day = 7 });
    try std.testing.expectEqualStrings("showa", jan7.era.?);
    try std.testing.expectEqual(@as(i32, 64), jan7.era_year.?);
}

test "era years resolve through the arithmetic year" {
    // Reiwa 1 before the era start resolves to the same ISO year, which then
    // re-derives as Heisei 31.
    try std.testing.expectEqual(@as(i32, 2019), yearFromEra(.japanese, "reiwa", 1).?);
    try std.testing.expectEqual(@as(i32, 2018), yearFromEra(.japanese, "reiwa", 0).?);
    try std.testing.expectEqual(@as(i32, 1988), yearFromEra(.japanese, "heisei", 0).?);
    try std.testing.expectEqual(@as(i32, 0), yearFromEra(.gregory, "bce", 1).?);
    // AH 0 is BH 1; AM 0 (ethiopic) is AA 5500.
    try std.testing.expectEqual(@as(i32, 0), yearFromEra(.islamic_civil, "bh", 1).?);
    try std.testing.expectEqual(@as(i32, 0), yearFromEra(.ethiopic, "am", 0).?);
    try std.testing.expectEqual(@as(i32, -5500), yearFromEra(.ethiopic, "aa", 0).?);
}

test "calendar identifiers canonicalize case-insensitively" {
    try std.testing.expectEqual(CalendarId.buddhist, canonicalize("Buddhist").?);
    try std.testing.expectEqual(CalendarId.iso8601, canonicalize("ISO8601").?);
    try std.testing.expectEqual(CalendarId.islamic_civil, canonicalize("islamic-civil").?);
    try std.testing.expectEqual(CalendarId.islamic_civil, canonicalize("islamicc").?);
    try std.testing.expectEqual(CalendarId.ethioaa, canonicalize("ethiopic-amete-alem").?);
    try std.testing.expect(canonicalize("gregorian") == null);
    try std.testing.expect(canonicalize("") == null);
}

test "year 0 of each calendar starts in the documented ISO year" {
    // Mirrors intl402/Temporal/PlainDate/prototype/year/epoch-year.js.
    const cases = [_]struct { cal: CalendarId, iso: i32 }{
        .{ .cal = .buddhist, .iso = -543 },
        .{ .cal = .coptic, .iso = 283 },
        .{ .cal = .ethioaa, .iso = -5493 },
        .{ .cal = .ethiopic, .iso = 7 },
        .{ .cal = .gregory, .iso = 0 },
        .{ .cal = .indian, .iso = 78 },
        .{ .cal = .islamic_civil, .iso = 621 },
        .{ .cal = .islamic_tbla, .iso = 621 },
        .{ .cal = .japanese, .iso = 0 },
        .{ .cal = .hebrew, .iso = -3761 },
        .{ .cal = .persian, .iso = 621 },
        .{ .cal = .roc, .iso = 1911 },
    };
    for (cases) |c| {
        const iso = try toIso(c.cal, 0, 1, 1, .constrain);
        try std.testing.expectEqual(c.iso, iso.year);
    }
}

test "epoch-day conversion round-trips across every calendar" {
    const cals = [_]CalendarId{
        .iso8601,       .gregory,        .buddhist, .roc,     .japanese,
        .coptic,        .ethiopic,       .ethioaa,  .persian, .indian,
        .islamic_civil, .islamic_tbla,   .hebrew,
    };
    // A spread of dates either side of the Unix epoch.
    const days = [_]i64{ -700_000, -100_000, -36_524, -1, 0, 1, 18_993, 100_000, 400_000 };
    for (cals) |cal| {
        for (days) |dd| {
            const iso = shared.epochDaysToISODate(dd);
            const f = fields(cal, iso);
            const back = try toIsoFromCode(cal, f.year, f.code_num, f.code_leap, f.day, .reject);
            try std.testing.expectEqual(iso.year, back.year);
            try std.testing.expectEqual(iso.month, back.month);
            try std.testing.expectEqual(iso.day, back.day);
        }
    }
}

test "year length equals the sum of its month lengths" {
    const cals = [_]CalendarId{
        .coptic, .ethiopic, .ethioaa, .persian, .indian, .islamic_civil, .islamic_tbla, .hebrew,
    };
    for (cals) |cal| {
        var year: i32 = 1300;
        while (year < 1340) : (year += 1) {
            var total: u16 = 0;
            var m: u8 = 1;
            while (m <= monthsInYear(cal, year)) : (m += 1) total += daysInMonth(cal, year, m);
            try std.testing.expectEqual(daysInYear(cal, year), total);
        }
    }
}
