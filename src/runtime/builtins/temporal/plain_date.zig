// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.PlainDate — an ISO calendar date (year/month/day, no time
//! or zone). Storage: internal_kind = .temporal_plain_date, internal_slot ->
//! ISODate, whose `calendar` field is the [[Calendar]] slot (see calendar.zig).
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const duration = @import("duration.zig");
const calendar = @import("calendar.zig");
const ISODate = shared.ISODate;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

pub fn getDate(v: Value) ?*ISODate {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_plain_date) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireDate(arena: std.mem.Allocator, v: Value) !*ISODate {
    return getDate(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.PlainDate");
}

pub fn makeDate(arena: std.mem.Allocator, d: ISODate) !Value {
    if (!shared.isValidISODate(d.year, d.month, d.day)) return realm_mod.throwRangeError(arena, "invalid PlainDate");
    if (!shared.isoDateWithinLimits(d)) return realm_mod.throwRangeError(arena, "PlainDate out of range");
    const slot = try arena.create(ISODate);
    slot.* = d;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_plain_date;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, d: ISODate) !Value {
    if (!shared.isValidISODate(d.year, d.month, d.day)) return realm_mod.throwRangeError(arena, "invalid PlainDate");
    if (!shared.isoDateWithinLimits(d)) return realm_mod.throwRangeError(arena, "PlainDate out of range");
    const slot = try arena.create(ISODate);
    slot.* = d;
    this_val.toPtr().object.internal_kind = .temporal_plain_date;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.PlainDate requires new");
    const y = try shared.toIntegerWithTruncation(arena, if (args.len > 0) args[0] else Value{});
    const m = try shared.toIntegerWithTruncation(arena, if (args.len > 1) args[1] else Value{});
    const d = try shared.toIntegerWithTruncation(arena, if (args.len > 2) args[2] else Value{});
    // args[3] is the calendar. The constructor's calendar goes through
    // CanonicalizeCalendar, which accepts only a bare calendar identifier (not
    // an ISO date string). Note the constructor takes *ISO* year/month/day
    // regardless of the calendar.
    var cal: calendar.CalendarId = .iso8601;
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        // The calendar argument must be a String primitive; null/number/object
        // is a TypeError before canonicalization.
        if (args[3].unbox() != .string) return realm_mod.throwTypeError(arena, "calendar must be a string");
        cal = calendar.canonicalize(args[3].unbox().string) orelse return realm_mod.throwRangeError(arena, "unsupported calendar");
    }
    if (y != @trunc(y) or m != @trunc(m) or d != @trunc(d)) return realm_mod.throwRangeError(arena, "non-integer date field");
    const yi: i32 = floatToI32(y);
    const mi: i32 = floatToI32(m);
    const di: i32 = floatToI32(d);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid date");
    const date = ISODate{ .year = yi, .month = @intCast(mi), .day = @intCast(di), .calendar = cal };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, date);
    return makeDate(arena, date);
}

fn floatToI32(f: f64) i32 {
    if (f > 2147483647) return 2147483647;
    if (f < -2147483648) return -2147483648;
    return @intFromFloat(f);
}

/// Whether `v` is a Temporal object that carries an ISO [[Calendar]] slot and so
/// can stand in for a calendar identifier (GetTemporalCalendar fast path).
fn isTemporalCalendarObject(v: Value) bool {
    if (v.bits == 0 or v.unbox() != .object) return false;
    return switch (v.toPtr().object.internal_kind) {
        .temporal_plain_date, .temporal_plain_date_time, .temporal_zoned_date_time, .temporal_plain_year_month, .temporal_plain_month_day => true,
        else => false,
    };
}

pub fn isIsoCalendar(s: []const u8) bool {
    // Case-insensitive "iso8601".
    if (s.len != 7) return false;
    const lower = "iso8601";
    for (s, 0..) |c, i| {
        if (std.ascii.toLower(c) != lower[i]) return false;
    }
    return true;
}

// ---------------------------------------------------------------- ToDate ---

pub fn toTemporalDate(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODate {
    const d = try toTemporalDateUnchecked(arena, v, overflow);
    if (!shared.isoDateWithinLimits(d)) return realm_mod.throwRangeError(arena, "PlainDate out of range");
    return d;
}

fn toTemporalDateUnchecked(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODate {
    if (getDate(v)) |d| return d.*;
    if (v.bits != 0 and v.unbox() == .object) {
        const pdt = @import("plain_date_time.zig");
        if (pdt.getDateTime(v)) |dt| return dt.date;
        // A ZonedDateTime yields its wall-clock date.
        const zdt = @import("zoned_date_time.zig");
        if (zdt.getZoned(v)) |z| return zdt.localISODate(z);
        return try dateFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        const dt = shared.parseISODateTime(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainDate string");
        return dt.date;
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainDate");
}

/// ToTemporalDate with an options object. The field bag is read *before* the
/// overflow option, and both reads are observable, so the two cannot be folded
/// into one `toTemporalDate(v, overflow)` call.
pub fn toTemporalDateOpts(arena: std.mem.Allocator, v: Value, opts_v: ?Value) !ISODate {
    if (v.bits != 0 and v.unbox() == .object and getDate(v) == null) {
        const pdt = @import("plain_date_time.zig");
        const zdt = @import("zoned_date_time.zig");
        if (pdt.getDateTime(v) == null and zdt.getZoned(v) == null) {
            const bag = try readDateBag(arena, v.toPtr().object, .{});
            const opts = try shared.getOptionsObject(arena, opts_v);
            const overflow = try shared.getOverflow(arena, opts);
            return dateFromBag(arena, bag, overflow);
        }
    }
    const d = try toTemporalDate(arena, v, .constrain);
    _ = try shared.getOverflow(arena, try shared.getOptionsObject(arena, opts_v));
    return d;
}

/// CalendarDateFromFields: read {calendar, era/eraYear|year, month|monthCode,
/// day} off a property bag. Shared with PlainDateTime and ZonedDateTime, whose
/// date portion uses exactly these fields.
pub fn dateFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODate {
    const bag = try readDateBag(arena, o, .{});
    return dateFromBag(arena, bag, overflow);
}

/// The fields of a Temporal property bag, already coerced.
pub const DateBag = struct {
    calendar: calendar.CalendarId = .iso8601,
    day: ?f64 = null,
    era: ?[]const u8 = null,
    era_year: ?f64 = null,
    hour: ?f64 = null,
    microsecond: ?f64 = null,
    millisecond: ?f64 = null,
    minute: ?f64 = null,
    month: ?f64 = null,
    month_code: ?[]const u8 = null,
    nanosecond: ?f64 = null,
    offset: ?[]const u8 = null,
    second: ?f64 = null,
    time_zone: ?Value = null,
    year: ?f64 = null,

    /// Whether the bag carried any calendar-date field at all — what the
    /// `with` methods need before they can reject an empty bag.
    pub fn hasDateField(self: DateBag) bool {
        return self.day != null or self.era != null or self.era_year != null or
            self.month != null or self.month_code != null or self.year != null;
    }

    pub fn hasTimeField(self: DateBag) bool {
        return self.hour != null or self.minute != null or self.second != null or
            self.millisecond != null or self.microsecond != null or self.nanosecond != null;
    }
};

/// Which slice of the field list a receiver takes. Every Temporal type reads a
/// subset, but always in the same overall alphabetical sweep.
pub const BagWant = struct {
    day: bool = true,
    month: bool = true,
    time: bool = false,
    /// offset + timeZone, which only ZonedDateTime accepts.
    zoned: bool = false,
    /// ZonedDateTime.with reads the offset field but not timeZone (it already
    /// rejected a timeZone property separately), so this suppresses that read.
    skip_time_zone: bool = false,
    /// Set by the `with` methods, which already know the calendar and must not
    /// read one off the bag.
    fixed_cal: ?calendar.CalendarId = null,
};

/// PrepareTemporalFields: read a Temporal property bag. Both the order
/// (alphabetical over the whole field list, date and time fields interleaved)
/// and the timing (each value coerced the moment it is read) are observable
/// through getters and Proxy traps, so this is the single place any Temporal
/// type reads a bag.
pub fn readDateBag(arena: std.mem.Allocator, o: *JsObject, want: BagWant) !DateBag {
    var bag = DateBag{};
    if (want.fixed_cal) |c| {
        bag.calendar = c;
    } else if (try shared.optionGet(arena, o, "calendar")) |v| {
        bag.calendar = try shared.resolveCalendarArg(arena, v);
    }
    if (want.day) {
        if (try shared.optionGet(arena, o, "day")) |v| {
            bag.day = try shared.toIntegerWithTruncation(arena, v);
            // PrepareCalendarFields rejects a non-positive day at read time,
            // before any options object or calendar resolution is consulted.
            if (bag.day.? < 1) return realm_mod.throwRangeError(arena, "day must be a positive integer");
        }
    }
    // A calendar without eras has no era/eraYear in its field list at all.
    if (calendar.hasEras(bag.calendar)) {
        if (try shared.optionGet(arena, o, "era")) |v| bag.era = try shared.toPrimitiveRequireString(arena, v);
        if (try shared.optionGet(arena, o, "eraYear")) |v| bag.era_year = try shared.toIntegerWithTruncation(arena, v);
    }
    if (want.time) {
        if (try shared.optionGet(arena, o, "hour")) |v| bag.hour = try shared.toIntegerWithTruncation(arena, v);
        if (try shared.optionGet(arena, o, "microsecond")) |v| bag.microsecond = try shared.toIntegerWithTruncation(arena, v);
        if (try shared.optionGet(arena, o, "millisecond")) |v| bag.millisecond = try shared.toIntegerWithTruncation(arena, v);
        if (try shared.optionGet(arena, o, "minute")) |v| bag.minute = try shared.toIntegerWithTruncation(arena, v);
    }
    if (want.month) {
        if (try shared.optionGet(arena, o, "month")) |v| {
            bag.month = try shared.toIntegerWithTruncation(arena, v);
            // PrepareCalendarFields rejects a non-positive month immediately.
            if (bag.month.? < 1) return realm_mod.throwRangeError(arena, "month must be a positive integer");
        }
        if (try shared.optionGet(arena, o, "monthCode")) |v| {
            bag.month_code = try shared.toPrimitiveRequireString(arena, v);
            // The month-code *format* ("M" + two digits + optional "L") is
            // validated as it is read; whether that month exists in the calendar
            // (suitability) is checked later against the resolved year.
            try shared.checkMonthCodeSyntax(arena, bag.month_code.?);
        }
    }
    if (want.time) {
        if (try shared.optionGet(arena, o, "nanosecond")) |v| bag.nanosecond = try shared.toIntegerWithTruncation(arena, v);
    }
    if (want.zoned) {
        if (try shared.optionGet(arena, o, "offset")) |v| bag.offset = try shared.toPrimitiveRequireString(arena, v);
    }
    if (want.time) {
        if (try shared.optionGet(arena, o, "second")) |v| bag.second = try shared.toIntegerWithTruncation(arena, v);
    }
    if (want.zoned and !want.skip_time_zone) {
        if (try shared.optionGet(arena, o, "timeZone")) |v| bag.time_zone = v;
    }
    if (try shared.optionGet(arena, o, "year")) |v| bag.year = try shared.toIntegerWithTruncation(arena, v);
    return bag;
}

pub fn dateFromBag(arena: std.mem.Allocator, bag: DateBag, overflow: shared.Overflow) !ISODate {
    const day = bag.day orelse return realm_mod.throwTypeError(arena, "missing day");
    const cal_year = try yearFromBag(arena, bag);
    return try monthFieldsToIso(arena, bag, cal_year, floatToI32(day), overflow);
}

/// Resolve the calendar-space year from either a "year" field or an
/// {era, eraYear} pair. Exactly one of the two forms must be present.
pub fn yearFromBag(arena: std.mem.Allocator, bag: DateBag) !i32 {
    if ((bag.era != null) != (bag.era_year != null))
        return realm_mod.throwTypeError(arena, "era and eraYear must be provided together");
    if (bag.era) |era| {
        const from_era = calendar.yearFromEra(bag.calendar, era, floatToI32(bag.era_year.?)) orelse
            return realm_mod.throwRangeError(arena, "invalid era for this calendar");
        // When both forms are given they must agree.
        if (bag.year) |y| {
            if (floatToI32(y) != from_era) return realm_mod.throwRangeError(arena, "year and era/eraYear disagree");
        }
        return from_era;
    }
    const y = bag.year orelse return realm_mod.throwTypeError(arena, "missing year");
    return floatToI32(y);
}

/// Apply whichever of "month" / "monthCode" is present to produce an ISO date.
fn monthFieldsToIso(arena: std.mem.Allocator, bag: DateBag, cal_year: i32, day: i32, overflow: shared.Overflow) !ISODate {
    const cal = bag.calendar;
    if (bag.month_code) |code| {
        const mc = try shared.parseMonthCode(arena, code, calendar.hasLeapMonths(cal));
        const iso = calendar.toIsoFromCode(cal, cal_year, mc.num, mc.leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
        // A "month" given alongside "monthCode" must name the same month.
        if (bag.month) |m| {
            if (floatToI32(m) != calendar.fields(cal, iso).month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        return iso;
    }
    const month = floatToI32(bag.month orelse return realm_mod.throwTypeError(arena, "missing month or monthCode"));
    return calendar.toIso(cal, cal_year, month, day, overflow) catch
        realm_mod.throwRangeError(arena, "date out of range");
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    return makeDate(arena, try toTemporalDateOpts(arena, v, if (args.len > 1) args[1] else null));
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const b = try toTemporalDate(arena, if (args.len > 1) args[1] else Value{}, .constrain);
    return val_mod.makeNumber(arena, @floatFromInt(compareISODate(a, b)));
}

pub fn compareISODate(a: ISODate, b: ISODate) i8 {
    if (a.year != b.year) return if (a.year < b.year) -1 else 1;
    if (a.month != b.month) return if (a.month < b.month) -1 else 1;
    if (a.day != b.day) return if (a.day < b.day) -1 else 1;
    return 0;
}

// ------------------------------------------------------------- arithmetic ---

/// AddISODate: add a calendar duration to a date with overflow handling. All
/// intermediate math is i128 with range gates so out-of-range inputs surface as
/// RangeError rather than an integer-cast panic.
pub fn addISODate(date: ISODate, years: f64, months: f64, weeks: f64, days: f64, overflow: shared.Overflow, arena: std.mem.Allocator) !ISODate {
    return addISODateDayOverflow(date, years, months, weeks, days, overflow, overflow, arena);
}

/// `addISODate` with the day clamp governed separately from the month-code
/// resolution. PlainYearMonth arithmetic anchors on a synthetic day-of-month, so
/// `reject` must not fire just because the target month is shorter — but it
/// must still fire when the month code itself has no counterpart.
pub fn addISODateDayOverflow(date: ISODate, years: f64, months: f64, weeks: f64, days: f64, overflow: shared.Overflow, day_overflow: shared.Overflow, arena: std.mem.Allocator) !ISODate {
    // Years and months are *calendar* units: shift them in the calendar's own
    // field space (constrain/reject the day there), then add weeks+days as a
    // plain epoch-day offset.
    const cal = date.calendar;
    const f = calendar.fields(cal, date);
    const y0: i128 = @as(i128, f.year) + @as(i128, @intFromFloat(years));
    if (y0 > 300_000 or y0 < -300_000) return realm_mod.throwRangeError(arena, "date out of range");
    // A year step holds the month *code*, not its ordinal: a lunisolar leap
    // month has no counterpart in a common year, so under `reject` that step is
    // a RangeError rather than a silent slide onto the neighbouring month.
    const start_month: u8 = if (years == 0) f.month else calendar.monthFromCode(cal, @intCast(y0), f.code_num, f.code_leap) orelse blk: {
        if (overflow == .reject) return realm_mod.throwRangeError(arena, "month code does not exist in target year");
        break :blk calendar.monthFromCodeConstrained(cal, @intCast(y0), f.code_num, f.code_leap);
    };
    const ym = calendar.addMonths(cal, @intCast(y0), start_month, @intFromFloat(months)) catch
        return realm_mod.throwRangeError(arena, "date out of range");

    const dim = calendar.daysInMonth(cal, ym.year, ym.month);
    var day: i64 = f.day;
    if (day_overflow == .reject) {
        if (day > dim) return realm_mod.throwRangeError(arena, "day out of range for month");
    } else {
        if (day > dim) day = dim;
    }
    // `anchor` is the ISO date of day 1 of the target *calendar* month, which is
    // not generally the 1st of an ISO month — so the offset must be taken from
    // the anchor's own ISO day, not a literal 1.
    const anchor = calendar.toIso(cal, ym.year, ym.month, 1, .constrain) catch
        return realm_mod.throwRangeError(arena, "date out of range");

    const extra: i128 = @as(i128, @intFromFloat(days)) + @as(i128, @intFromFloat(weeks)) * 7;
    const target: i128 = @as(i128, shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day)) + (day - 1) + extra;
    // Valid epoch-day window for the Temporal year range (~±1e8 days).
    if (target > 400_000_000 or target < -400_000_000) return realm_mod.throwRangeError(arena, "date out of range");
    var out = shared.epochDaysToISODate(@intCast(target));
    out.calendar = cal;
    return out;
}

fn nativeAddSub(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const d = try requireDate(arena, this_val);
    var dur = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    if (subtract) {
        dur.years = -dur.years;
        dur.months = -dur.months;
        dur.weeks = -dur.weeks;
        dur.days = -dur.days;
        // The time units are balanced into days below, so they must be negated
        // for subtraction too — otherwise a duration like "1 day + 24 hours"
        // subtracts the day but adds the hours.
        dur.hours = -dur.hours;
        dur.minutes = -dur.minutes;
        dur.seconds = -dur.seconds;
        dur.milliseconds = -dur.milliseconds;
        dur.microseconds = -dur.microseconds;
        dur.nanoseconds = -dur.nanoseconds;
    }
    // Time units in the duration are balanced down into whole days.
    const time_ns = @as(i128, @intFromFloat(dur.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(dur.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(dur.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(dur.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(dur.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(dur.nanoseconds));
    const extra_days: f64 = @floatFromInt(@as(i128, (@divTrunc(time_ns, shared.NS_PER_DAY))));
    const result = try addISODate(d.*, dur.years, dur.months, dur.weeks, dur.days + extra_days, overflow, arena);
    return makeDate(arena, result);
}

pub fn nativeAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeAddSub(arena, this_val, args, false);
}
pub fn nativeSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeAddSub(arena, this_val, args, true);
}

/// DifferenceISODate: {years, months, weeks, days} from d1 to d2 at largestUnit.
pub fn differenceISODate(d1: ISODate, d2: ISODate, largest: shared.Unit) shared.DurationFields {
    var out = shared.DurationFields{};
    const cmp = compareISODate(d1, d2);
    if (cmp == 0) return out;
    switch (largest) {
        .day, .week => {
            var days = shared.isoDateToEpochDays(d2.year, d2.month, d2.day) - shared.isoDateToEpochDays(d1.year, d1.month, d1.day);
            if (largest == .week) {
                const weeks = @divTrunc(days, 7);
                days -= weeks * 7;
                out.weeks = @floatFromInt(weeks);
            }
            out.days = @floatFromInt(days);
            return out;
        },
        else => {
            // Always measure *from* d1, stepping toward d2. Computing the
            // earlier→later difference and negating it is wrong: calendar
            // arithmetic is not symmetric. 1997-07-16 until 2021-07-15 is
            // +23y 11m 29d, but 2021-07-15 until 1997-07-16 is -23y -11m -30d,
            // because each anchors its month walk on a different day-of-month.
            const step: i64 = if (cmp < 0) 1 else -1; // cmp<0 → d1 precedes d2
            const cal = d1.calendar;
            const fa = calendar.fields(cal, d1);
            const fb = calendar.fields(cal, d2);

            // Whole years first, stepping by *calendar year* rather than by a
            // month count. A year is not a fixed number of months (Hebrew leap
            // years have 13), and a year-over-year step must hold the month
            // *code* fixed, not its ordinal: Hebrew M07 is ordinal 8 in a leap
            // year and 7 in a common one, so counting ordinals loses a year.
            const target_days = shared.isoDateToEpochDays(d2.year, d2.month, d2.day);
            var years: i64 = 0;
            var base = d1;
            if (largest == .year) {
                years = @as(i64, fb.year) - @as(i64, fa.year);
                while (years != 0 and surpassesDays(addYearsUnclamped(d1, fa, years), target_days, step)) years -= step;
                while (!surpassesDays(addYearsUnclamped(d1, fa, years + step), target_days, step)) years += step;
                base = addYearsConstrain(d1, fa, years);
            }

            // Then the largest whole-month count from `base` that does not
            // overshoot d2. The absolute-month delta is exact up to the
            // day-of-month clamp, so these loops correct by a step or two.
            const fbase = calendar.fields(cal, base);
            var months: i64 = calendar.absoluteMonth(cal, fb.year, fb.month) -
                calendar.absoluteMonth(cal, fbase.year, fbase.month);
            while (months != 0 and surpassesDays(addMonthsUnclamped(base, months), target_days, step)) months -= step;
            while (!surpassesDays(addMonthsUnclamped(base, months + step), target_days, step)) months += step;

            const anchor = addMonthsConstrain(base, months);
            const days = shared.isoDateToEpochDays(d2.year, d2.month, d2.day) -
                shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day);

            out.years = @floatFromInt(years);
            out.months = @floatFromInt(months);
            out.days = @floatFromInt(days);
            return out;
        },
    }
}

/// True once `cand` has moved past `target` in the direction `step`.
fn surpasses(cand: ISODate, target: ISODate, step: i64) bool {
    const c = compareISODate(cand, target);
    return if (step > 0) c > 0 else c < 0;
}

/// Shift `a` by `n` calendar years, holding its month *code* and day and
/// constraining both into the target year. `fa` is `a`'s decomposition.
fn addYearsConstrain(a: ISODate, fa: calendar.CalFields, n: i64) ISODate {
    const cal = a.calendar;
    const y = std.math.cast(i32, @as(i64, fa.year) + n) orelse return a;
    return calendar.toIsoFromCode(cal, y, fa.code_num, fa.code_leap, fa.day, .constrain) catch a;
}

/// Shift `a` by `n` calendar months, clamping the day into the target month.
fn addMonthsConstrain(a: ISODate, n: i64) ISODate {
    const cal = a.calendar;
    const f = calendar.fields(cal, a);
    const ym = calendar.addMonths(cal, f.year, f.month, n) catch return a;
    const dim = calendar.daysInMonth(cal, ym.year, ym.month);
    const day: i32 = @min(f.day, dim);
    return calendar.toIso(cal, ym.year, ym.month, day, .constrain) catch a;
}

/// True once epoch day `cand` has moved past `target` in the direction `step`.
fn surpassesDays(cand: i64, target: i64, step: i64) bool {
    return if (step > 0) cand > target else cand < target;
}

/// Epoch day of a whole-unit step that keeps the day-of-month *exactly*: a day
/// the target month is too short to hold rolls past its end ("Feb 31" reads as
/// Mar 3). Measuring against this unclamped position is what makes Jan 31 until
/// Feb 28 come out as 28 days rather than a whole month — a step that only
/// reaches its target by being clamped does not count as a whole unit.
fn unclampedEpochDays(cal: calendar.CalendarId, clamped: ISODate, want_day: u8) i64 {
    const got = calendar.fields(cal, clamped).day;
    const surplus: i64 = @as(i64, want_day) - @as(i64, got);
    return shared.isoDateToEpochDays(clamped.year, clamped.month, clamped.day) + @max(surplus, 0);
}

fn addMonthsUnclamped(a: ISODate, n: i64) i64 {
    const f = calendar.fields(a.calendar, a);
    return unclampedEpochDays(a.calendar, addMonthsConstrain(a, n), f.day);
}

fn addYearsUnclamped(a: ISODate, fa: calendar.CalFields, n: i64) i64 {
    return unclampedEpochDays(a.calendar, addYearsConstrain(a, fa, n), fa.day);
}

fn nativeDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const d = try requireDate(arena, this_val);
    const other = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    if (d.calendar != other.calendar) return realm_mod.throwRangeError(arena, "calendar mismatch");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // `since` is the negation of `until`, not the difference with the operands
    // swapped: both anchor their calendar walk on the receiver. Rounding runs
    // in the mirrored direction, so GetDifferenceSettings negates the mode too.
    const st = try shared.getDifferenceSettings(arena, opts, since, .date, &.{}, .day, .day);
    const from = d.*;
    const to = other;

    var result: shared.DurationFields = undefined;
    if (st.largest == st.smallest) {
        // Result is a single calendar unit: round the exact difference to that
        // unit, using `from` as the calendar anchor for month/year fractions.
        result = try roundDateDifferenceToUnit(arena, from, to, st.smallest, st.increment, st.mode);
    } else {
        result = differenceISODate(from, to, st.largest);
        // Only day-granularity rounding is supported when the result spans
        // multiple units (a larger largestUnit than smallestUnit).
        if (st.smallest == .day and st.increment != 1) {
            result.days = shared.roundNumberToIncrement(result.days, st.increment, st.mode);
        }
    }
    if (since) result = shared.negateFields(result);
    return duration.makeDuration(arena, result);
}

/// Round the exact date difference `from`→`to` to a whole (incremented) count of
/// a single calendar `unit`, returning a DurationFields carrying only that unit.
/// Month/year fractions are nominal: measured against the calendar length of the
/// month/year straddling `to` (relativeTo = `from`).
fn roundDateDifferenceToUnit(arena: std.mem.Allocator, from: ISODate, to: ISODate, unit: shared.Unit, inc: f64, mode: shared.RoundingMode) !shared.DurationFields {
    var out = shared.DurationFields{};
    const cmp = compareISODate(from, to);
    if (cmp == 0) return out;
    const sign: f64 = if (cmp < 0) 1 else -1; // from<to → positive difference
    const total: f64 = switch (unit) {
        .day => @floatFromInt(shared.isoDateToEpochDays(to.year, to.month, to.day) - shared.isoDateToEpochDays(from.year, from.month, from.day)),
        .week => blk: {
            const days = shared.isoDateToEpochDays(to.year, to.month, to.day) - shared.isoDateToEpochDays(from.year, from.month, from.day);
            break :blk @as(f64, @floatFromInt(days)) / 7.0;
        },
        .month => blk: {
            const dm = differenceISODate(from, to, .month);
            const whole: i64 = @intFromFloat(dm.months);
            const anchor = addMonthsConstrain(from, whole);
            const next = addMonthsConstrain(from, whole + @as(i64, @intFromFloat(sign)));
            const rem = shared.isoDateToEpochDays(to.year, to.month, to.day) - shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day);
            const denom = shared.isoDateToEpochDays(next.year, next.month, next.day) - shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day);
            break :blk dm.months + sign * (@as(f64, @floatFromInt(rem)) / @as(f64, @floatFromInt(denom)));
        },
        .year => blk: {
            const dy = differenceISODate(from, to, .year);
            const whole: i64 = @intFromFloat(dy.years);
            const anchor = addMonthsConstrain(from, whole * 12);
            const next = addMonthsConstrain(from, (whole + @as(i64, @intFromFloat(sign))) * 12);
            const rem = shared.isoDateToEpochDays(to.year, to.month, to.day) - shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day);
            const denom = shared.isoDateToEpochDays(next.year, next.month, next.day) - shared.isoDateToEpochDays(anchor.year, anchor.month, anchor.day);
            break :blk dy.years + sign * (@as(f64, @floatFromInt(rem)) / @as(f64, @floatFromInt(denom)));
        },
        else => unreachable,
    };
    // For the irregular-length calendar units (year/month/week), spec
    // NudgeToCalendarUnit range-checks the away-from-zero increment candidate
    // (r2 = one increment beyond the toward-zero multiple) by adding it to the
    // relativeTo date: if the resulting date is outside the representable ISO
    // range, throw. Day differences use NudgeToDayOrTime and are not checked
    // (a Duration may hold an arbitrarily large day count).
    if (unit != .day) {
        const r2_units = (@floor(@abs(total) / inc) + 1) * inc;
        const in_range = switch (unit) {
            .year => monthsOffsetYearInRange(from, sign * r2_units * 12),
            .month => monthsOffsetYearInRange(from, sign * r2_units),
            .week => epochDayOffsetInRange(from, sign * r2_units * 7),
            else => true,
        };
        if (!in_range) return realm_mod.throwRangeError(arena, "rounded date is outside the valid ISO range");
    }
    const rounded = shared.roundNumberToIncrement(total, inc, mode);
    switch (unit) {
        .year => out.years = rounded,
        .month => out.months = rounded,
        .week => out.weeks = rounded,
        .day => out.days = rounded,
        else => {},
    }
    return out;
}

/// True iff `from` shifted by `off_months` whole months stays within the
/// representable ISO year range. Computed in i64 to avoid i32 overflow when the
/// probe offset is astronomically large.
fn monthsOffsetYearInRange(from: ISODate, off_months: f64) bool {
    if (!std.math.isFinite(off_months) or @abs(off_months) > 9.0e15) return false;
    const m: i64 = @intFromFloat(off_months);
    const mtotal: i64 = @as(i64, from.month) + m;
    const y: i64 = @as(i64, from.year) + @divFloor(mtotal - 1, 12);
    return y >= -271821 and y <= 275760;
}

/// True iff `from` shifted by `off_days` days stays within the representable ISO
/// range (~±1e8 epoch days).
fn epochDayOffsetInRange(from: ISODate, off_days: f64) bool {
    if (!std.math.isFinite(off_days) or @abs(off_days) > 9.0e15) return false;
    const base: f64 = @floatFromInt(shared.isoDateToEpochDays(from.year, from.month, from.day));
    const end = base + off_days;
    return end >= -100_000_001 and end <= 100_000_001;
}

fn unitRank(u: shared.Unit) u8 {
    return switch (u) {
        .year => 0, .month => 1, .week => 2, .day => 3,
        .hour => 4, .minute => 5, .second => 6,
        .millisecond => 7, .microsecond => 8, .nanosecond => 9,
    };
}

pub fn nativeUntil(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDifference(arena, this_val, args, false);
}
pub fn nativeSince(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDifference(arena, this_val, args, true);
}

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireDate(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (shared.isTemporalObject(arg)) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (try shared.optionGet(arena, o, "calendar") != null) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (try shared.optionGet(arena, o, "timeZone") != null) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const bag = try readDateBag(arena, o, .{ .fixed_cal = cur.calendar });
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const merged = try withDateFields(arena, cur.*, bag, overflow);
    if (!merged.any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    return makeDate(arena, merged.date);
}

/// Merge the date fields present on `o` over `cur`'s own calendar fields and
/// reconstitute. Per CalendarMergeFields a supplied "month" displaces the
/// receiver's monthCode and vice versa, so only the un-supplied side falls back
/// to the base date. `any` reports whether the bag carried any date field at all
/// (callers combine it with their own field sets before raising a TypeError).
pub fn withDateFields(arena: std.mem.Allocator, cur: ISODate, bag: DateBag, overflow: shared.Overflow) !struct { date: ISODate, any: bool } {
    const cal = cur.calendar;
    const base = calendar.fields(cal, cur);
    const any = bag.hasDateField();

    var year: i32 = base.year;
    if (bag.era != null or bag.era_year != null or bag.year != null) year = try yearFromBag(arena, bag);
    const day: i32 = if (bag.day) |x| floatToI32(x) else base.day;

    var nd: ISODate = undefined;
    if (bag.month_code) |code| {
        const mc = try shared.parseMonthCode(arena, code, calendar.hasLeapMonths(cal));
        nd = calendar.toIsoFromCode(cal, year, mc.num, mc.leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
        if (bag.month) |m| {
            if (floatToI32(m) != calendar.fields(cal, nd).month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
    } else if (bag.month) |m| {
        nd = calendar.toIso(cal, year, floatToI32(m), day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
    } else {
        nd = calendar.toIsoFromCode(cal, year, base.code_num, base.code_leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
    }
    return .{ .date = nd, .any = any };
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const other = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    // Equality is on the ISO date *and* the calendar; `compare` ignores the
    // latter because it orders dates chronologically.
    return val_mod.makeBool(arena, compareISODate(d.*, other) == 0 and d.calendar == other.calendar);
}

pub fn nativeToZonedDateTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const timezone = @import("timezone.zig");
    const zoned = @import("zoned_date_time.zig");
    const pt = @import("plain_time.zig");
    const item = if (args.len > 0) args[0] else Value{};
    var zone: timezone.Zone = undefined;
    var time = shared.ISOTime{};
    if (item.bits != 0 and item.unbox() == .string) {
        zone = try timezone.toZone(arena, item.unbox().string);
    } else if (item.bits != 0 and item.unbox() == .object) {
        const o = item.toPtr().object;
        const tz_v = try shared.optionGet(arena, o, "timeZone") orelse return realm_mod.throwTypeError(arena, "missing timeZone");
        if (tz_v.bits == 0 or tz_v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
        zone = try timezone.toZone(arena, tz_v.unbox().string);
        if (try shared.optionGet(arena, o, "plainTime")) |ptv| {
            time = try pt.toTemporalTime(arena, ptv, .constrain);
        }
    } else return realm_mod.throwTypeError(arena, "toZonedDateTime requires a time zone");
    const wall = @as(i128, shared.isoDateToEpochDays(d.year, d.month, d.day)) * shared.NS_PER_DAY +
        shared.timeToNanos(time);
    // With no plainTime the result is the start of the day, which a DST jump over
    // midnight can push past 00:00; otherwise the wall time is disambiguated the
    // "compatible" way.
    const ns = try zoned.disambiguate(arena, zone.id, zone.offset_ns, wall, .compatible);
    return zoned.makeZoned(arena, .{ .ns = ns, .tz = zone.id, .offset_ns = zone.offset_ns, .calendar = d.calendar });
}

pub fn nativeToPlainDateTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const pdt = @import("plain_date_time.zig");
    const pt = @import("plain_time.zig");
    var time = shared.ISOTime{};
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        time = try pt.toTemporalTime(arena, args[0], .constrain);
    }
    return pdt.makeDateTime(arena, .{ .date = d.*, .time = time });
}

pub fn nativeToPlainYearMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const pym = @import("plain_year_month.zig");
    return pym.makeYearMonth(arena, .{ .year = d.year, .month = d.month, .day = 1 });
}

pub fn nativeToPlainMonthDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const pmd = @import("plain_month_day.zig");
    return pmd.makeMonthDay(arena, .{ .month = d.month, .day = d.day, .ref_year = 1972 });
}

pub fn nativeWithCalendar(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const cal = if (args.len > 0) args[0] else Value{};
    if (cal.bits == 0 or cal.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "withCalendar requires a calendar");
    // The ISO date is unchanged; only the lens through which it is read.
    var out = d.*;
    out.calendar = try shared.resolveCalendarArg(arena, cal);
    return makeDate(arena, out);
}

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const show = try shared.getShowCalendar(arena, opts);
    const s = try dateToString(arena, d.*, show);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeString(arena, try dateToString(arena, d.*, .auto));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireDate(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .date);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.PlainDate");
}

pub fn dateToString(arena: std.mem.Allocator, d: ISODate, show: shared.ShowCalendar) ![]const u8 {
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, d.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, d.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, d.day, 2);
    try appendCalendar(arena, &buf, show, d.calendar);
    return buf.items;
}

/// Append the `[u-ca=…]` annotation. Under `auto` it is emitted only for a
/// non-ISO calendar, which would otherwise be lost in the round-trip.
pub fn appendCalendar(arena: std.mem.Allocator, buf: *shared.Buf, show: shared.ShowCalendar, cal: calendar.CalendarId) !void {
    switch (show) {
        .never => {},
        .auto => if (cal != .iso8601) {
            try buf.appendSlice(arena, "[u-ca=");
            try buf.appendSlice(arena, cal.str());
            try buf.append(arena, ']');
        },
        .always => {
            try buf.appendSlice(arena, "[u-ca=");
            try buf.appendSlice(arena, cal.str());
            try buf.append(arena, ']');
        },
        .critical => {
            try buf.appendSlice(arena, "[!u-ca=");
            try buf.appendSlice(arena, cal.str());
            try buf.append(arena, ']');
        },
    }
}

// ------------------------------------------------------------------ getters ---

fn getYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d.*).year));
}
fn getMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d.*).month));
}
fn getDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d.*).day));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeString(arena, try shared.formatMonthCode(arena, calendar.fields(d.calendar, d.*)));
}
fn getDayOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfWeek(d.*)));
}
fn getDayOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfYear(d.*)));
}
fn getWeekOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    if (d.calendar != .iso8601) return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(shared.weekOfYear(d.*)));
}
fn getYearOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    if (d.calendar != .iso8601) return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(shared.yearOfWeek(d.*)));
}
// era / eraYear are undefined for calendars without eras (notably ISO 8601), but
// the getters must still exist (with correct branding) on the prototype.
fn getEra(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const era = calendar.fields(d.calendar, d.*).era orelse return Value{};
    return val_mod.makeString(arena, era);
}
fn getEraYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const ey = calendar.fields(d.calendar, d.*).era_year orelse return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(ey));
}
fn getDaysInWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, 7);
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const f = calendar.fields(d.calendar, d.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInMonth(d.calendar, f.year, f.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const f = calendar.fields(d.calendar, d.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInYear(d.calendar, f.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const f = calendar.fields(d.calendar, d.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.monthsInYear(d.calendar, f.year)));
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const f = calendar.fields(d.calendar, d.*);
    return val_mod.makeBool(arena, calendar.inLeapYear(d.calendar, f.year));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeString(arena, d.calendar.str());
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethodLen(arena, proto, "with", nativeWith, 1);
    try intrinsics.setMethodLen(arena, proto, "add", nativeAdd, 1);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDateTime", nativeToPlainDateTime);
    try intrinsics.setMethod(arena, proto, "toPlainYearMonth", nativeToPlainYearMonth);
    try intrinsics.setMethod(arena, proto, "toPlainMonthDay", nativeToPlainMonthDay);
    try intrinsics.setMethod(arena, proto, "withCalendar", nativeWithCalendar);
    try intrinsics.setMethod(arena, proto, "toZonedDateTime", nativeToZonedDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "year", getYear);
    try intrinsics.defineGetter(arena, proto, "month", getMonth);
    try intrinsics.defineGetter(arena, proto, "day", getDay);
    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
    try intrinsics.defineGetter(arena, proto, "dayOfWeek", getDayOfWeek);
    try intrinsics.defineGetter(arena, proto, "dayOfYear", getDayOfYear);
    try intrinsics.defineGetter(arena, proto, "weekOfYear", getWeekOfYear);
    try intrinsics.defineGetter(arena, proto, "yearOfWeek", getYearOfWeek);
    try intrinsics.defineGetter(arena, proto, "era", getEra);
    try intrinsics.defineGetter(arena, proto, "eraYear", getEraYear);
    try intrinsics.defineGetter(arena, proto, "daysInWeek", getDaysInWeek);
    try intrinsics.defineGetter(arena, proto, "daysInMonth", getDaysInMonth);
    try intrinsics.defineGetter(arena, proto, "daysInYear", getDaysInYear);
    try intrinsics.defineGetter(arena, proto, "monthsInYear", getMonthsInYear);
    try intrinsics.defineGetter(arena, proto, "inLeapYear", getInLeapYear);
    try intrinsics.defineGetter(arena, proto, "calendarId", getCalendarId);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 3), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
}
