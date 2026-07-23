// SPDX-License-Identifier: Apache-2.0
//! Wave 30: Temporal.PlainYearMonth — an ISO calendar year+month with no day.
//! Storage: internal_kind = .temporal_plain_year_month, internal_slot -> ISODate
//! whose [[Day]] is the ISO reference day: 1 for iso8601, and for other
//! calendars the ISO date of the first day of the calendar month.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const calendar = @import("calendar.zig");
const duration = @import("duration.zig");
const plain_date = @import("plain_date.zig");
const ISODate = shared.ISODate;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

pub fn getYearMonth(v: Value) ?*ISODate {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_plain_year_month) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireYM(arena: std.mem.Allocator, v: Value) !*ISODate {
    return getYearMonth(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.PlainYearMonth");
}

/// ISOYearMonthWithinLimits: the year-month must lie within the same overall
/// range as PlainDate, with a one-month margin at each end (checked against a
/// representative day).
fn checkLimits(arena: std.mem.Allocator, d: ISODate) !void {
    if (d.year < -271821 or d.year > 275760) return realm_mod.throwRangeError(arena, "PlainYearMonth out of range");
    if (d.year == -271821 and d.month < 4) return realm_mod.throwRangeError(arena, "PlainYearMonth out of range");
    if (d.year == 275760 and d.month > 9) return realm_mod.throwRangeError(arena, "PlainYearMonth out of range");
}

pub fn makeYearMonth(arena: std.mem.Allocator, d0: ISODate) !Value {
    const d = d0;
    if (!shared.isValidISODate(d.year, d.month, d.day)) return realm_mod.throwRangeError(arena, "invalid PlainYearMonth");
    try checkLimits(arena, d);
    const slot = try arena.create(ISODate);
    slot.* = d;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_plain_year_month;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, d: ISODate) !Value {
    if (!shared.isValidISODate(d.year, d.month, d.day)) return realm_mod.throwRangeError(arena, "invalid PlainYearMonth");
    try checkLimits(arena, d);
    const slot = try arena.create(ISODate);
    slot.* = d;
    this_val.toPtr().object.internal_kind = .temporal_plain_year_month;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.PlainYearMonth requires new");
    const y = try shared.toIntegerWithTruncation(arena, if (args.len > 0) args[0] else Value{});
    const m = try shared.toIntegerWithTruncation(arena, if (args.len > 1) args[1] else Value{});
    // args[2] is calendar; constructor → CanonicalizeCalendar (bare id only).
    // The constructor's year/month are ISO regardless of the calendar.
    const cal = if (args.len > 2) try shared.resolveCalendarArgCanonical(arena, args[2]) else .iso8601;
    // args[3] is referenceISODay (default 1).
    var ref_day: f64 = 1;
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        ref_day = try shared.toIntegerWithTruncation(arena, args[3]);
    }
    const yi = floatToI32(y);
    const mi = floatToI32(m);
    const di = floatToI32(ref_day);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid year-month");
    const date = ISODate{ .year = yi, .month = @intCast(mi), .day = @intCast(di), .calendar = cal };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, date);
    return makeYearMonth(arena, date);
}

fn floatToI32(f: f64) i32 {
    if (f > 2147483647) return 2147483647;
    if (f < -2147483648) return -2147483648;
    return @intFromFloat(f);
}

// ---------------------------------------------------------------- conversion ---

pub fn toTemporalYearMonth(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODate {
    if (getYearMonth(v)) |d| return d.*;
    if (v.bits != 0 and v.unbox() == .object) {
        return try yearMonthFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        return shared.parseISOYearMonth(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainYearMonth string");
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainYearMonth");
}

/// ToTemporalYearMonth with an options object: the field bag is read before the
/// overflow option (both are observable).
pub fn toTemporalYearMonthOpts(arena: std.mem.Allocator, v: Value, opts_v: ?Value) !ISODate {
    if (v.bits != 0 and v.unbox() == .object and getYearMonth(v) == null) {
        const bag = try plain_date.readDateBag(arena, v.toPtr().object, .{ .day = false });
        const opts = try shared.getOptionsObject(arena, opts_v);
        const overflow = try shared.getOverflow(arena, opts);
        const cal_year = try plain_date.yearFromBag(arena, bag);
        return resolveMonth(arena, bag, bag.calendar, cal_year, overflow);
    }
    const ym = try toTemporalYearMonth(arena, v, .constrain);
    _ = try shared.getOverflow(arena, try shared.getOptionsObject(arena, opts_v));
    return ym;
}

fn yearMonthFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODate {
    // PlainYearMonth's field list has no "day", so the bag must not read one.
    const bag = try plain_date.readDateBag(arena, o, .{ .day = false });
    const cal_year = try plain_date.yearFromBag(arena, bag);
    // The stored ISO date is the first day of the calendar month.
    return resolveMonth(arena, bag, bag.calendar, cal_year, overflow);
}

/// Turn whichever of "month" / "monthCode" is present into the ISO date of the
/// first day of that calendar month.
fn resolveMonth(arena: std.mem.Allocator, bag: plain_date.DateBag, cal: calendar.CalendarId, cal_year: i32, overflow: shared.Overflow) !ISODate {
    if (bag.month_code) |code| {
        const mc = try shared.parseMonthCode(arena, code, calendar.hasLeapMonths(cal));
        const iso = calendar.toIsoFromCode(cal, cal_year, mc.num, mc.leap, 1, overflow) catch
            return realm_mod.throwRangeError(arena, "year-month out of range");
        if (bag.month) |m| {
            if (floatToI32(m) != calendar.fields(cal, iso).month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        return iso;
    }
    const month = floatToI32(bag.month orelse return realm_mod.throwTypeError(arena, "missing month or monthCode"));
    // A month below 1 is always out of range; the upper bound is constrained or
    // rejected per the overflow option.
    if (month < 1) return realm_mod.throwRangeError(arena, "month out of range");
    return calendar.toIso(cal, cal_year, month, 1, overflow) catch
        realm_mod.throwRangeError(arena, "month out of range");
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    return makeYearMonth(arena, try toTemporalYearMonthOpts(arena, v, if (args.len > 1) args[1] else null));
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalYearMonth(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const b = try toTemporalYearMonth(arena, if (args.len > 1) args[1] else Value{}, .constrain);
    return val_mod.makeNumber(arena, @floatFromInt(compareYM(a, b)));
}

/// Compare year-months ignoring reference day.
fn compareYM(a: ISODate, b: ISODate) i8 {
    if (a.year != b.year) return if (a.year < b.year) -1 else 1;
    if (a.month != b.month) return if (a.month < b.month) -1 else 1;
    return 0;
}

// ------------------------------------------------------------- arithmetic ---

fn nativeAddSub(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const ym = try requireYM(arena, this_val);
    var dur = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    if (subtract) {
        dur.years = -dur.years;
        dur.months = -dur.months;
        dur.weeks = -dur.weeks;
        dur.days = -dur.days;
        dur.hours = -dur.hours;
        dur.minutes = -dur.minutes;
        dur.seconds = -dur.seconds;
        dur.milliseconds = -dur.milliseconds;
        dur.microseconds = -dur.microseconds;
        dur.nanoseconds = -dur.nanoseconds;
    }
    // Balance time units down into whole days.
    const time_ns = @as(i128, @intFromFloat(dur.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(dur.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(dur.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(dur.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(dur.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(dur.nanoseconds));
    const extra_days: f64 = @floatFromInt(@as(i128, (@divTrunc(time_ns, shared.NS_PER_DAY))));
    const total_days = dur.days + extra_days;
    // AddDurationToYearMonth: anchor to the first of the month for a
    // non-negative duration, else the last day, so day-level overflow lands the
    // result in the intended month.
    const sign = shared.DurationFields.sign(.{
        .years = dur.years,
        .months = dur.months,
        .weeks = dur.weeks,
        .days = total_days,
    });
    const cal = ym.calendar;
    const f = calendar.fields(cal, ym.*);
    // The stored ISO date is already day 1 of the calendar month, which is the
    // anchor a non-negative duration wants. A *calendar* month rarely starts on
    // an ISO 1st, so the last-day anchor has to be built in calendar space too.
    const anchor: ISODate = if (sign < 0)
        calendar.toIso(cal, f.year, f.month, calendar.daysInMonth(cal, f.year, f.month), .constrain) catch ym.*
    else
        ym.*;
    const result = try plain_date.addISODateDayOverflow(anchor, dur.years, dur.months, dur.weeks, total_days, overflow, .constrain, arena);
    // Renormalize onto the first day of the resulting *calendar* month.
    const rf = calendar.fields(cal, result);
    const first = calendar.toIso(cal, rf.year, rf.month, 1, .constrain) catch
        return realm_mod.throwRangeError(arena, "year-month out of range");
    return makeYearMonth(arena, first);
}

pub fn nativeAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeAddSub(arena, this_val, args, false);
}
pub fn nativeSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeAddSub(arena, this_val, args, true);
}

fn nativeDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const ym = try requireYM(arena, this_val);
    const other = try toTemporalYearMonth(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    if (ym.calendar != other.calendar) return realm_mod.throwRangeError(arena, "calendar mismatch");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // `since` negates `until` rather than swapping the operands, and both keep
    // the receiver's calendar: rebuilding these as bare literals would silently
    // measure a non-ISO year-month difference in the ISO calendar.
    const st = try shared.getDifferenceSettings(arena, opts, since, .date, &.{ .week, .day }, .month, .year);
    const smallest: ?shared.Unit = st.smallest;
    const largest: ?shared.Unit = st.largest;
    const mode = st.mode;
    const inc = st.increment;
    var result = plain_date.differenceISODate(ym.*, other, largest.?);
    result.weeks = 0;
    result.days = 0;

    // differenceISODate already split years/months using the calendar's own
    // months-per-year, so only re-derive the split when rounding disturbs it.
    // The total-months form assumes 12 months per year and is reached only for
    // year-granularity or multi-month increments.
    if (inc != 1 or smallest.? == .year) {
        var total_months = result.years * 12.0 + result.months;
        const round_increment: f64 = if (smallest.? == .year) inc * 12.0 else inc;
        total_months = shared.roundNumberToIncrement(total_months, round_increment, mode);
        result.years = 0;
        result.months = 0;
        if (largest.? == .year) {
            result.years = @trunc(total_months / 12.0);
            result.months = total_months - result.years * 12.0;
        } else {
            result.months = total_months;
        }
    } else if (largest.? == .month) {
        result.months = result.years * 12.0 + result.months;
        result.years = 0;
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
    const cur = try requireYM(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (shared.isTemporalObject(arg)) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (try shared.optionGet(arena, o, "calendar") != null) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (try shared.optionGet(arena, o, "timeZone") != null) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const cal = cur.calendar;
    const base = calendar.fields(cal, cur.*);
    // Merge over the receiver's own calendar fields. The bag carries the
    // receiver's calendar: `with` may not change it. It is read in full before
    // the options object, which is observable.
    const bag = try plain_date.readDateBag(arena, o, .{ .day = false, .fixed_cal = cal });
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const any = bag.era != null or bag.era_year != null or bag.month != null or
        bag.month_code != null or bag.year != null;
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    var year: i32 = base.year;
    if (bag.era != null or bag.era_year != null or bag.year != null) year = try plain_date.yearFromBag(arena, bag);
    if (bag.month == null and bag.month_code == null) {
        const iso = calendar.toIsoFromCode(cal, year, base.code_num, base.code_leap, 1, overflow) catch
            return realm_mod.throwRangeError(arena, "year-month out of range");
        return makeYearMonth(arena, iso);
    }
    return makeYearMonth(arena, try resolveMonth(arena, bag, cal, year, overflow));
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = (try shared.optionGet(arena, o, name)) orelse return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const other = try toTemporalYearMonth(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    // Compare the full ISO date (including reference day) plus the calendar.
    return val_mod.makeBool(arena, ym.year == other.year and ym.month == other.month and
        ym.day == other.day and ym.calendar == other.calendar);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "toPlainDate requires an object with a day");
    const o = arg.toPtr().object;
    const day_v = try shared.optionGet(arena, o, "day") orelse return realm_mod.throwTypeError(arena, "missing day");
    if (day_v.bits != 0 and day_v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing day");
    const day = try shared.toIntegerWithTruncation(arena, day_v);
    const di = floatToI32(day);
    // `day` numbers a day of the *calendar* month, which for a non-ISO calendar
    // is not the ISO day-of-month at all.
    const cal = ym.calendar;
    const f = calendar.fields(cal, ym.*);
    const iso = calendar.toIso(cal, f.year, f.month, di, .constrain) catch
        return realm_mod.throwRangeError(arena, "invalid day for PlainDate");
    return plain_date.makeDate(arena, iso);
}

// ------------------------------------------------------------------ strings ---

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const show = try shared.getShowCalendar(arena, opts);
    return val_mod.makeString(arena, try yearMonthToString(arena, ym.*, show));
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeString(arena, try yearMonthToString(arena, ym.*, .auto));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireYM(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .year_month);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.PlainYearMonth");
}

fn yearMonthToString(arena: std.mem.Allocator, ym: ISODate, show: shared.ShowCalendar) ![]const u8 {
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, ym.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, ym.month, 2);
    // When the calendar is shown — either because it was asked for, or because
    // it is non-ISO and would otherwise be lost — the ISO reference day is
    // emitted too, so the string round-trips back to the same month.
    const shows_calendar = show == .always or show == .critical or
        (show == .auto and ym.calendar != .iso8601);
    if (shows_calendar) {
        try buf.append(arena, '-');
        try shared.appendPadded(arena, &buf, ym.day, 2);
    }
    try plain_date.appendCalendar(arena, &buf, show, ym.calendar);
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(ym.calendar, ym.*).year));
}
fn getMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(ym.calendar, ym.*).month));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeString(arena, try shared.formatMonthCode(arena, calendar.fields(ym.calendar, ym.*)));
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const f = calendar.fields(ym.calendar, ym.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInMonth(ym.calendar, f.year, f.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const f = calendar.fields(ym.calendar, ym.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInYear(ym.calendar, f.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const f = calendar.fields(ym.calendar, ym.*);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.monthsInYear(ym.calendar, f.year)));
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const f = calendar.fields(ym.calendar, ym.*);
    return val_mod.makeBool(arena, calendar.inLeapYear(ym.calendar, f.year));
}
fn getEra(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const era = calendar.fields(ym.calendar, ym.*).era orelse return Value{};
    return val_mod.makeString(arena, era);
}
fn getEraYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const ey = calendar.fields(ym.calendar, ym.*).era_year orelse return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(ey));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeString(arena, ym.calendar.str());
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
    try intrinsics.setMethodLen(arena, proto, "toPlainDate", nativeToPlainDate, 1);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "year", getYear);
    try intrinsics.defineGetter(arena, proto, "month", getMonth);
    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
    try intrinsics.defineGetter(arena, proto, "daysInMonth", getDaysInMonth);
    try intrinsics.defineGetter(arena, proto, "daysInYear", getDaysInYear);
    try intrinsics.defineGetter(arena, proto, "monthsInYear", getMonthsInYear);
    try intrinsics.defineGetter(arena, proto, "inLeapYear", getInLeapYear);
    try intrinsics.defineGetter(arena, proto, "era", getEra);
    try intrinsics.defineGetter(arena, proto, "eraYear", getEraYear);
    try intrinsics.defineGetter(arena, proto, "calendarId", getCalendarId);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainYearMonth"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainYearMonth"), .{ .writable = false, .enumerable = false, .configurable = true });
}
