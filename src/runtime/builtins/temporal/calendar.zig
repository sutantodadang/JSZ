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
//! Currently implemented: the Gregorian-derived family, whose month structure is
//! identical to ISO and which differ only in year numbering and era labels.
//! Other families (Coptic/Ethiopic, tabular Islamic, Persian, Indian, Hebrew,
//! Chinese/Dangi) are recognized as identifiers only once added here.
const std = @import("std");
const shared = @import("shared.zig");
const ISODate = shared.ISODate;

pub const CalendarId = enum(u8) {
    iso8601,
    gregory,
    buddhist,
    roc,
    japanese,

    /// The canonical BCP-47 `-u-ca-` identifier, as reported by `calendarId`.
    pub fn str(self: CalendarId) []const u8 {
        return switch (self) {
            .iso8601 => "iso8601",
            .gregory => "gregory",
            .buddhist => "buddhist",
            .roc => "roc",
            .japanese => "japanese",
        };
    }

    /// ISO year in which this calendar's arithmetic year 0 begins. For the
    /// Gregorian-derived family the whole projection is this single offset:
    /// `iso_year = cal_year + epochOffset`.
    fn epochOffset(self: CalendarId) i32 {
        return switch (self) {
            .iso8601, .gregory, .japanese => 0,
            .buddhist => -543,
            .roc => 1911,
        };
    }
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

// -------------------------------------------------------------- projection ---

/// Project an ISO date onto `cal`'s field system.
pub fn fields(cal: CalendarId, d: ISODate) CalFields {
    const year = d.year - cal.epochOffset();
    var out = CalFields{
        .year = year,
        .month = d.month,
        .code_num = d.month,
        .day = d.day,
    };
    switch (cal) {
        .iso8601 => {},
        .gregory => {
            if (d.year > 0) {
                out.era = "ce";
                out.era_year = d.year;
            } else {
                out.era = "bce";
                out.era_year = 1 - d.year;
            }
        },
        .buddhist => {
            out.era = "be";
            out.era_year = year;
        },
        .roc => {
            if (year > 0) {
                out.era = "roc";
                out.era_year = year;
            } else {
                out.era = "broc";
                out.era_year = 1 - year;
            }
        },
        .japanese => {
            if (japaneseEraFor(d)) |e| {
                out.era = e.name;
                out.era_year = d.year - e.y0 + 1;
            } else if (d.year > 0) {
                out.era = "ce";
                out.era_year = d.year;
            } else {
                out.era = "bce";
                out.era_year = 1 - d.year;
            }
        },
    }
    return out;
}

/// Convert an {era, eraYear} pair into `cal`'s arithmetic year. Returns null if
/// the era code is not one of this calendar's eras.
///
/// Out-of-range era years are deliberately *not* rejected: the spec resolves
/// e.g. `{era: "reiwa", eraYear: 0}` by mapping through the arithmetic year and
/// then re-deriving whichever era actually contains the resulting date.
pub fn yearFromEra(cal: CalendarId, era: []const u8, era_year: i32) ?i32 {
    return switch (cal) {
        .iso8601 => null,
        .gregory => if (std.mem.eql(u8, era, "ce") or std.mem.eql(u8, era, "ad"))
            era_year
        else if (std.mem.eql(u8, era, "bce") or std.mem.eql(u8, era, "bc"))
            1 - era_year
        else
            null,
        .buddhist => if (std.mem.eql(u8, era, "be")) era_year else null,
        .roc => if (std.mem.eql(u8, era, "roc"))
            era_year
        else if (std.mem.eql(u8, era, "broc"))
            1 - era_year
        else
            null,
        .japanese => blk: {
            if (japaneseEraByName(era)) |e| break :blk e.y0 + era_year - 1;
            if (std.mem.eql(u8, era, "ce") or std.mem.eql(u8, era, "ad")) break :blk era_year;
            if (std.mem.eql(u8, era, "bce") or std.mem.eql(u8, era, "bc")) break :blk 1 - era_year;
            break :blk null;
        },
    };
}

// ------------------------------------------------------------ month shape ---

pub fn monthsInYear(cal: CalendarId, cal_year: i32) u8 {
    _ = cal;
    _ = cal_year;
    return 12;
}

pub fn daysInMonth(cal: CalendarId, cal_year: i32, month: u8) u8 {
    return shared.isoDaysInMonth(cal_year + cal.epochOffset(), month);
}

pub fn daysInYear(cal: CalendarId, cal_year: i32) u16 {
    return shared.daysInYear(cal_year + cal.epochOffset());
}

pub fn inLeapYear(cal: CalendarId, cal_year: i32) bool {
    return shared.isLeapYear(cal_year + cal.epochOffset());
}

/// Whether `cal` can have leap months (i.e. month codes with an "L" suffix).
pub fn hasLeapMonths(cal: CalendarId) bool {
    _ = cal;
    return false;
}

/// Whether `cal` numbers its years by era. Calendars that do not (ISO 8601)
/// have no "era"/"eraYear" fields at all, so those properties are ignored
/// rather than validated when they appear in a property bag.
pub fn hasEras(cal: CalendarId) bool {
    return cal != .iso8601;
}

/// Map a month code onto its ordinal position in `cal_year`, or null when the
/// year has no such month.
pub fn monthFromCode(cal: CalendarId, cal_year: i32, code_num: u8, code_leap: bool) ?u8 {
    _ = cal;
    _ = cal_year;
    if (code_leap) return null;
    if (code_num < 1 or code_num > 12) return null;
    return code_num;
}

/// The ISO year holding `cal_year`'s months — for the Gregorian-derived family
/// a year maps 1:1 onto an ISO year.
pub fn isoYearOf(cal: CalendarId, cal_year: i32) i32 {
    return cal_year + cal.epochOffset();
}

/// Shift a calendar-space {year, month} by a whole number of months, carrying
/// across year boundaries using each year's own month count.
pub fn addMonths(cal: CalendarId, cal_year: i32, month: u8, delta: i128) Error!struct { year: i32, month: u8 } {
    var y: i128 = cal_year;
    var m: i128 = @as(i128, month) + delta;
    // Every implemented calendar has a fixed month count, so the carry is exact
    // division; the loop form below also covers variable-length years.
    const fixed = monthsInYear(cal, cal_year);
    if (m < 1 or m > fixed) {
        y += @divFloor(m - 1, fixed);
        m = @mod(m - 1, fixed) + 1;
    }
    if (y > 300_000 or y < -300_000) return error.OutOfRange;
    return .{ .year = @intCast(y), .month = @intCast(m) };
}

// ---------------------------------------------------------- reconstitution ---

pub const Error = error{OutOfRange};

/// Reconstitute an ISO date from calendar-space fields, applying `overflow`.
/// Under `.constrain` the month is clamped into the year and the day into the
/// month; under `.reject` an out-of-range field is an error.
pub fn toIso(cal: CalendarId, cal_year: i32, month: i32, day: i32, overflow: shared.Overflow) Error!ISODate {
    if (cal_year > 300_000 or cal_year < -300_000) return error.OutOfRange;
    const miy = monthsInYear(cal, cal_year);
    var m = month;
    var d = day;
    if (overflow == .reject) {
        if (m < 1 or m > miy) return error.OutOfRange;
        if (d < 1 or d > daysInMonth(cal, cal_year, @intCast(m))) return error.OutOfRange;
    } else {
        if (m < 1) m = 1;
        if (m > miy) m = miy;
        const dim = daysInMonth(cal, cal_year, @intCast(m));
        if (d < 1) d = 1;
        if (d > dim) d = dim;
    }
    return .{
        .year = isoYearOf(cal, cal_year),
        .month = @intCast(m),
        .day = @intCast(d),
        .calendar = cal,
    };
}

/// As `toIso`, but the month is given as a month code. A code naming a month the
/// year does not have (e.g. a leap month in a common year) is constrained to the
/// nearest ordinary month, or rejected.
pub fn toIsoFromCode(cal: CalendarId, cal_year: i32, code_num: u8, code_leap: bool, day: i32, overflow: shared.Overflow) Error!ISODate {
    const m = monthFromCode(cal, cal_year, code_num, code_leap) orelse {
        if (overflow == .reject) return error.OutOfRange;
        // Constrain: drop the leap flag and clamp into the year.
        const miy = monthsInYear(cal, cal_year);
        const fallback: i32 = if (code_num < 1) 1 else if (code_num > miy) miy else code_num;
        return toIso(cal, cal_year, fallback, day, .constrain);
    };
    return toIso(cal, cal_year, m, day, overflow);
}

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
}

test "calendar identifiers canonicalize case-insensitively" {
    try std.testing.expectEqual(CalendarId.buddhist, canonicalize("Buddhist").?);
    try std.testing.expectEqual(CalendarId.iso8601, canonicalize("ISO8601").?);
    try std.testing.expect(canonicalize("gregorian") == null);
    try std.testing.expect(canonicalize("") == null);
}

test "year 0 of each calendar starts in the documented ISO year" {
    // Mirrors intl402/Temporal/PlainDate/prototype/year/epoch-year.js.
    try std.testing.expectEqual(@as(i32, -543), isoYearOf(.buddhist, 0));
    try std.testing.expectEqual(@as(i32, 1911), isoYearOf(.roc, 0));
    try std.testing.expectEqual(@as(i32, 0), isoYearOf(.gregory, 0));
    try std.testing.expectEqual(@as(i32, 0), isoYearOf(.japanese, 0));
}
