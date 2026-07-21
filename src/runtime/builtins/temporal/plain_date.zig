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
    if (d.year < -271821 or d.year > 275760) return realm_mod.throwRangeError(arena, "PlainDate year out of range");
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
        const name = try shared.valueToString(arena, args[3]);
        cal = calendar.canonicalize(name) orelse return realm_mod.throwRangeError(arena, "unsupported calendar");
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

/// CalendarDateFromFields: read {calendar, era/eraYear|year, month|monthCode,
/// day} off a property bag. Shared with PlainDateTime and ZonedDateTime, whose
/// date portion uses exactly these fields.
pub fn dateFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODate {
    const cal = if (o.get("calendar")) |cv| try shared.resolveCalendarArg(arena, cv) else .iso8601;
    const day_v = o.get("day");
    if (day_v == null or (day_v.?.bits != 0 and day_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing day");
    const day = try shared.toIntegerWithTruncation(arena, day_v.?);
    const cal_year = try readCalendarYear(arena, o, cal);
    return try monthFieldsToIso(arena, o, cal, cal_year, floatToI32(day), overflow);
}

/// Resolve the calendar-space year from either a "year" field or an
/// {era, eraYear} pair. Exactly one of the two forms must be present.
pub fn readCalendarYear(arena: std.mem.Allocator, o: *JsObject, cal: calendar.CalendarId) !i32 {
    const year_v = o.get("year");
    const has_year = year_v != null and year_v.?.bits != 0 and year_v.?.unbox() != .undefined_;
    // A calendar without eras has no era/eraYear fields, so any such properties
    // on the bag are ignored; an era-bearing calendar needs both or neither.
    const era_v = if (calendar.hasEras(cal)) o.get("era") else null;
    const era_year_v = if (calendar.hasEras(cal)) o.get("eraYear") else null;
    const has_era = era_v != null and era_v.?.bits != 0 and era_v.?.unbox() != .undefined_;
    const has_era_year = era_year_v != null and era_year_v.?.bits != 0 and era_year_v.?.unbox() != .undefined_;
    if (has_era != has_era_year) return realm_mod.throwTypeError(arena, "era and eraYear must be provided together");
    if (has_era) {
        const era = try shared.valueToString(arena, era_v.?);
        const era_year = try shared.toIntegerWithTruncation(arena, era_year_v.?);
        const from_era = calendar.yearFromEra(cal, era, floatToI32(era_year)) orelse
            return realm_mod.throwRangeError(arena, "invalid era for this calendar");
        // When both forms are given they must agree.
        if (has_year) {
            const y = floatToI32(try shared.toIntegerWithTruncation(arena, year_v.?));
            if (y != from_era) return realm_mod.throwRangeError(arena, "year and era/eraYear disagree");
        }
        return from_era;
    }
    if (!has_year) return realm_mod.throwTypeError(arena, "missing year");
    return floatToI32(try shared.toIntegerWithTruncation(arena, year_v.?));
}

/// Apply whichever of "month" / "monthCode" is present to produce an ISO date.
fn monthFieldsToIso(arena: std.mem.Allocator, o: *JsObject, cal: calendar.CalendarId, cal_year: i32, day: i32, overflow: shared.Overflow) !ISODate {
    const month_v = o.get("month");
    const monthcode_v = o.get("monthCode");
    const has_month = month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_;
    const has_code = monthcode_v != null and monthcode_v.?.bits != 0 and monthcode_v.?.unbox() != .undefined_;
    if (has_code) {
        if (monthcode_v.?.unbox() != .string) return realm_mod.throwTypeError(arena, "monthCode must be a string");
        const mc = try shared.parseMonthCode(arena, monthcode_v.?.unbox().string, calendar.hasLeapMonths(cal));
        const iso = calendar.toIsoFromCode(cal, cal_year, mc.num, mc.leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
        // A "month" given alongside "monthCode" must name the same month.
        if (has_month) {
            const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
            if (m != calendar.fields(cal, iso).month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        return iso;
    }
    if (!has_month) return realm_mod.throwTypeError(arena, "missing month or monthCode");
    const month = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
    return calendar.toIso(cal, cal_year, month, day, overflow) catch
        realm_mod.throwRangeError(arena, "date out of range");
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // A string argument is parsed before the options bag is consulted.
    const parse_first = shared.isStringArg(v);
    const overflow = if (parse_first) .constrain else try shared.getOverflow(arena, opts);
    const d = try toTemporalDate(arena, v, overflow);
    if (parse_first) _ = try shared.getOverflow(arena, opts);
    return makeDate(arena, d);
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
    // Years and months are *calendar* units: shift them in the calendar's own
    // field space (constrain/reject the day there), then add weeks+days as a
    // plain epoch-day offset.
    const cal = date.calendar;
    const f = calendar.fields(cal, date);
    const y0: i128 = @as(i128, f.year) + @as(i128, @intFromFloat(years));
    if (y0 > 300_000 or y0 < -300_000) return realm_mod.throwRangeError(arena, "date out of range");
    const ym = calendar.addMonths(cal, @intCast(y0), f.month, @intFromFloat(months)) catch
        return realm_mod.throwRangeError(arena, "date out of range");

    const dim = calendar.daysInMonth(cal, ym.year, ym.month);
    var day: i64 = f.day;
    if (overflow == .reject) {
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
            var years: i64 = 0;
            var base = d1;
            if (largest == .year) {
                years = @as(i64, fb.year) - @as(i64, fa.year);
                while (years != 0 and yearStepSurpasses(cal, fa, years, fb, step)) years -= step;
                while (!yearStepSurpasses(cal, fa, years + step, fb, step)) years += step;
                base = addYearsConstrain(d1, fa, years);
            }

            // Then the largest whole-month count from `base` that does not
            // overshoot d2. The absolute-month delta is exact up to the
            // day-of-month clamp, so these loops correct by a step or two.
            const fbase = calendar.fields(cal, base);
            var months: i64 = calendar.absoluteMonth(cal, fb.year, fb.month) -
                calendar.absoluteMonth(cal, fbase.year, fbase.month);
            while (months != 0 and monthStepSurpasses(cal, fbase, months, fb, step)) months -= step;
            while (!monthStepSurpasses(cal, fbase, months + step, fb, step)) months += step;

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

/// Spec ISODateSurpasses: the month/year walk compares the *unclamped* day, so
/// "the 30th of a 29-day month" counts as past that month's end rather than
/// landing on it. Without this, Jan 31 until Feb 28 would read as one whole
/// month instead of 28 days.
fn tripleSurpasses(y: i64, m: i64, day: i64, target: calendar.CalFields, step: i64) bool {
    const c: i8 = if (y != target.year)
        (if (y > target.year) 1 else -1)
    else if (m != target.month)
        (if (m > target.month) 1 else -1)
    else if (day != target.day)
        (if (day > target.day) 1 else -1)
    else
        0;
    return if (step > 0) c > 0 else c < 0;
}

/// Does shifting `fa` by `n` calendar years (month code held fixed) overshoot
/// `fb`?
fn yearStepSurpasses(cal: calendar.CalendarId, fa: calendar.CalFields, n: i64, fb: calendar.CalFields, step: i64) bool {
    const y = std.math.cast(i32, @as(i64, fa.year) + n) orelse return true;
    // Resolve the month *code* to its ordinal in the destination year; a leap
    // month's ordinal shifts between leap and common years.
    const anchor = calendar.toIsoFromCode(cal, y, fa.code_num, fa.code_leap, 1, .constrain) catch return true;
    const af = calendar.fields(cal, anchor);
    return tripleSurpasses(af.year, af.month, fa.day, fb, step);
}

/// Does shifting `fbase` by `n` calendar months overshoot `fb`?
fn monthStepSurpasses(cal: calendar.CalendarId, fbase: calendar.CalFields, n: i64, fb: calendar.CalFields, step: i64) bool {
    const ym = calendar.addMonths(cal, fbase.year, fbase.month, n) catch return true;
    return tripleSurpasses(ym.year, ym.month, fbase.day, fb, step);
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

fn nativeDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const d = try requireDate(arena, this_val);
    const other = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // `since` is the negation of `until`, not the difference with the operands
    // swapped: both anchor their calendar walk on the receiver. Rounding runs
    // in the mirrored direction, so the mode is negated too.
    const o = try shared.getDiffOptions(arena, opts, since);
    const smallest = o.smallest orelse .day;
    // largestUnit defaults to "auto" = the larger of "day" and smallestUnit.
    const largest = o.largest orelse if (unitRank(smallest) < unitRank(.day)) smallest else .day;
    // Only date units allowed.
    if (unitRank(smallest) > unitRank(.day) or unitRank(largest) > unitRank(.day))
        return realm_mod.throwRangeError(arena, "PlainDate difference units must be year..day");
    if (unitRank(largest) > unitRank(smallest)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");

    const from = d.*;
    const to = other;
    var result = differenceISODate(from, to, largest);
    if (smallest != .day or o.inc != 1) {
        const dest_ns: i128 = @as(i128, shared.isoDateToEpochDays(to.year, to.month, to.day) -
            shared.isoDateToEpochDays(from.year, from.month, from.day)) * shared.NS_PER_DAY;
        const rr = try duration.roundRelativeBalanced(
            arena,
            result,
            from,
            dest_ns,
            smallest,
            largest,
            o.inc,
            o.mode,
            if (dest_ns < 0) -1 else 1,
        );
        result = rr.d;
    }
    if (since) result = shared.negateFields(result);
    return duration.makeDuration(arena, result);
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
    if (getDate(arg) != null) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (o.get("calendar") != null and o.get("calendar").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (o.get("timeZone") != null and o.get("timeZone").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const merged = try withDateFields(arena, cur.*, o, overflow);
    if (!merged.any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    return makeDate(arena, merged.date);
}

/// Merge the date fields present on `o` over `cur`'s own calendar fields and
/// reconstitute. Per CalendarMergeFields a supplied "month" displaces the
/// receiver's monthCode and vice versa, so only the un-supplied side falls back
/// to the base date. `any` reports whether the bag carried any date field at all
/// (callers combine it with their own field sets before raising a TypeError).
pub fn withDateFields(arena: std.mem.Allocator, cur: ISODate, o: *JsObject, overflow: shared.Overflow) !struct { date: ISODate, any: bool } {
    const cal = cur.calendar;
    const base = calendar.fields(cal, cur);
    var year: i32 = base.year;
    var day: i32 = base.day;
    var any = false;

    // Era fields only exist on calendars that number years by era.
    const era_v = if (calendar.hasEras(cal)) o.get("era") else null;
    const era_year_v = if (calendar.hasEras(cal)) o.get("eraYear") else null;
    const has_era = era_v != null and era_v.?.bits != 0 and era_v.?.unbox() != .undefined_;
    const has_era_year = era_year_v != null and era_year_v.?.bits != 0 and era_year_v.?.unbox() != .undefined_;
    if (has_era != has_era_year) return realm_mod.throwTypeError(arena, "era and eraYear must be provided together");
    if (has_era) {
        const era = try shared.valueToString(arena, era_v.?);
        const ey = floatToI32(try shared.toIntegerWithTruncation(arena, era_year_v.?));
        year = calendar.yearFromEra(cal, era, ey) orelse return realm_mod.throwRangeError(arena, "invalid era for this calendar");
        any = true;
    }
    if (try readField(arena, o, "year")) |x| {
        year = floatToI32(x);
        any = true;
    }
    if (try readField(arena, o, "day")) |x| {
        day = floatToI32(x);
        any = true;
    }

    const month_v = o.get("month");
    const monthcode_v = o.get("monthCode");
    const has_month = month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_;
    const has_code = monthcode_v != null and monthcode_v.?.bits != 0 and monthcode_v.?.unbox() != .undefined_;
    if (has_month or has_code) any = true;

    var nd: ISODate = undefined;
    if (has_code) {
        if (monthcode_v.?.unbox() != .string) return realm_mod.throwTypeError(arena, "monthCode must be a string");
        const mc = try shared.parseMonthCode(arena, monthcode_v.?.unbox().string, calendar.hasLeapMonths(cal));
        nd = calendar.toIsoFromCode(cal, year, mc.num, mc.leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
        if (has_month) {
            const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
            if (m != calendar.fields(cal, nd).month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
    } else if (has_month) {
        const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
        nd = calendar.toIso(cal, year, m, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
    } else {
        nd = calendar.toIsoFromCode(cal, year, base.code_num, base.code_leap, day, overflow) catch
            return realm_mod.throwRangeError(arena, "date out of range");
    }
    return .{ .date = nd, .any = any };
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
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
        const tz_v = o.get("timeZone") orelse return realm_mod.throwTypeError(arena, "missing timeZone");
        if (tz_v.bits == 0 or tz_v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
        zone = try timezone.toZone(arena, tz_v.unbox().string);
        if (o.get("plainTime")) |ptv| {
            if (ptv.bits != 0 and ptv.unbox() != .undefined_) {
                time = try pt.toTemporalTime(arena, ptv, .constrain);
            }
        }
    } else return realm_mod.throwTypeError(arena, "toZonedDateTime requires a time zone");
    const wall = @as(i128, shared.isoDateToEpochDays(d.year, d.month, d.day)) * shared.NS_PER_DAY +
        shared.timeToNanos(time);
    return zoned.makeZoned(arena, .{ .ns = wall - zone.offset_ns, .tz = zone.id, .offset_ns = zone.offset_ns });
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
    return val_mod.makeNumber(arena, @floatFromInt(shared.weekOfYear(d.*)));
}
fn getYearOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
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
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 3), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
}
