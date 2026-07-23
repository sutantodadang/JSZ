// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.PlainDateTime — an ISO date + wall-clock time (no zone).
//! Storage: internal_kind = .temporal_plain_date_time, internal_slot ->
//! ISODateTime.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const duration = @import("duration.zig");
const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const calendar = @import("calendar.zig");
const ISODate = shared.ISODate;
const ISOTime = shared.ISOTime;
const ISODateTime = shared.ISODateTime;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

pub fn getDateTime(v: Value) ?*ISODateTime {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_plain_date_time) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireDT(arena: std.mem.Allocator, v: Value) !*ISODateTime {
    return getDateTime(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.PlainDateTime");
}

pub fn makeDateTime(arena: std.mem.Allocator, dt: ISODateTime) !Value {
    if (!shared.isValidISODate(dt.date.year, dt.date.month, dt.date.day)) return realm_mod.throwRangeError(arena, "invalid PlainDateTime");
    if (!shared.isoDateTimeWithinLimits(dt.date, dt.time)) return realm_mod.throwRangeError(arena, "PlainDateTime out of range");
    const slot = try arena.create(ISODateTime);
    slot.* = dt;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_plain_date_time;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, dt: ISODateTime) !Value {
    if (!shared.isValidISODate(dt.date.year, dt.date.month, dt.date.day)) return realm_mod.throwRangeError(arena, "invalid PlainDateTime");
    if (!shared.isoDateTimeWithinLimits(dt.date, dt.time)) return realm_mod.throwRangeError(arena, "PlainDateTime out of range");
    const slot = try arena.create(ISODateTime);
    slot.* = dt;
    this_val.toPtr().object.internal_kind = .temporal_plain_date_time;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.PlainDateTime requires new");
    const y = try shared.toIntegerWithTruncation(arena, if (args.len > 0) args[0] else Value{});
    const mo = try shared.toIntegerWithTruncation(arena, if (args.len > 1) args[1] else Value{});
    const d = try shared.toIntegerWithTruncation(arena, if (args.len > 2) args[2] else Value{});
    const h = try argIntTrunc(arena, args, 3);
    const min = try argIntTrunc(arena, args, 4);
    const s = try argIntTrunc(arena, args, 5);
    const ms = try argIntTrunc(arena, args, 6);
    const us = try argIntTrunc(arena, args, 7);
    const ns = try argIntTrunc(arena, args, 8);
    // Constructor calendar → CanonicalizeCalendar (bare identifier only). The
    // constructor's year/month/day are always ISO, whatever the calendar.
    var cal: calendar.CalendarId = .iso8601;
    if (args.len > 9 and args[9].bits != 0 and args[9].unbox() != .undefined_) {
        // The constructor's calendar argument must be a String primitive; any
        // other type (null, number, object, …) is a TypeError before the
        // identifier is canonicalized.
        if (args[9].unbox() != .string) return realm_mod.throwTypeError(arena, "calendar must be a string");
        cal = calendar.canonicalize(args[9].unbox().string) orelse return realm_mod.throwRangeError(arena, "unsupported calendar");
    }
    const yi = f2i(y);
    const mi = f2i(mo);
    const di = f2i(d);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid date");
    if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999 or
        h < 0 or min < 0 or s < 0 or ms < 0 or us < 0 or ns < 0)
        return realm_mod.throwRangeError(arena, "time field out of range");
    const dt = ISODateTime{
        .date = .{ .year = yi, .month = @intCast(mi), .day = @intCast(di), .calendar = cal },
        .time = .{
            .hour = @intFromFloat(h),
            .minute = @intFromFloat(min),
            .second = @intFromFloat(s),
            .millisecond = @intFromFloat(ms),
            .microsecond = @intFromFloat(us),
            .nanosecond = @intFromFloat(ns),
        },
    };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, dt);
    return makeDateTime(arena, dt);
}

fn argIntTrunc(arena: std.mem.Allocator, args: []const Value, idx: usize) !f64 {
    if (idx >= args.len) return 0;
    const v = args[idx];
    if (v.bits == 0 or v.unbox() == .undefined_) return 0;
    return try shared.toIntegerWithTruncation(arena, v);
}

fn f2i(f: f64) i32 {
    if (f > 2147483647) return 2147483647;
    if (f < -2147483648) return -2147483648;
    return @intFromFloat(f);
}

// ---------------------------------------------------------------- ToDateTime ---

pub fn toTemporalDateTime(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODateTime {
    const dt = try toTemporalDateTimeUnchecked(arena, v, overflow);
    if (!shared.isoDateTimeWithinLimits(dt.date, dt.time)) return realm_mod.throwRangeError(arena, "PlainDateTime out of range");
    return dt;
}

fn toTemporalDateTimeUnchecked(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODateTime {
    if (getDateTime(v)) |dt| return dt.*;
    if (v.bits != 0 and v.unbox() == .object) {
        if (plain_date.getDate(v)) |d| return .{ .date = d.*, .time = .{} };
        // A ZonedDateTime yields its wall-clock date+time.
        const zdt = @import("zoned_date_time.zig");
        if (zdt.getZoned(v)) |z| return zdt.localISODateTime(z);
        return try dtFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        return shared.parseISODateTime(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainDateTime string");
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainDateTime");
}

/// ToTemporalDateTime with an options object: the field bag is read before the
/// overflow option (both are observable).
pub fn toTemporalDateTimeOpts(arena: std.mem.Allocator, v: Value, opts_v: ?Value) !ISODateTime {
    if (v.bits != 0 and v.unbox() == .object and getDateTime(v) == null) {
        const zdt = @import("zoned_date_time.zig");
        if (plain_date.getDate(v) == null and zdt.getZoned(v) == null) {
            const bag = try plain_date.readDateBag(arena, v.toPtr().object, .{ .time = true });
            const opts = try shared.getOptionsObject(arena, opts_v);
            const overflow = try shared.getOverflow(arena, opts);
            return dtFromBag(arena, bag, overflow);
        }
    }
    const dt = try toTemporalDateTime(arena, v, .constrain);
    _ = try shared.getOverflow(arena, try shared.getOptionsObject(arena, opts_v));
    return dt;
}

fn dtFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODateTime {
    // The date half is exactly PlainDate's field set (calendar, era/eraYear or
    // year, month or monthCode, day); the time fields are all optional.
    const bag = try plain_date.readDateBag(arena, o, .{ .time = true });
    return dtFromBag(arena, bag, overflow);
}

pub fn dtFromBag(arena: std.mem.Allocator, bag: plain_date.DateBag, overflow: shared.Overflow) !ISODateTime {
    const date = try plain_date.dateFromBag(arena, bag, overflow);
    const time = try timeFromBag(arena, bag, overflow, .{});
    return .{ .date = date, .time = time };
}

/// Build an ISOTime from whichever time fields the bag carries, falling back to
/// `base` (all zeroes for `from`, the receiver's own time for `with`).
pub fn timeFromBag(arena: std.mem.Allocator, bag: plain_date.DateBag, overflow: shared.Overflow, base: ISOTime) !ISOTime {
    const h: f64 = bag.hour orelse @as(f64, @floatFromInt(base.hour));
    const min: f64 = bag.minute orelse @as(f64, @floatFromInt(base.minute));
    const s: f64 = bag.second orelse @as(f64, @floatFromInt(base.second));
    const ms: f64 = bag.millisecond orelse @as(f64, @floatFromInt(base.millisecond));
    const us: f64 = bag.microsecond orelse @as(f64, @floatFromInt(base.microsecond));
    const ns: f64 = bag.nanosecond orelse @as(f64, @floatFromInt(base.nanosecond));
    if (overflow == .reject) {
        if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999 or
            h < 0 or min < 0 or s < 0 or ms < 0 or us < 0 or ns < 0)
            return realm_mod.throwRangeError(arena, "time field out of range");
    }
    return .{
        .hour = @intFromFloat(std.math.clamp(h, 0, 23)),
        .minute = @intFromFloat(std.math.clamp(min, 0, 59)),
        .second = @intFromFloat(std.math.clamp(s, 0, 59)),
        .millisecond = @intFromFloat(std.math.clamp(ms, 0, 999)),
        .microsecond = @intFromFloat(std.math.clamp(us, 0, 999)),
        .nanosecond = @intFromFloat(std.math.clamp(ns, 0, 999)),
    };
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    return makeDateTime(arena, try toTemporalDateTimeOpts(arena, v, if (args.len > 1) args[1] else null));
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalDateTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const b = try toTemporalDateTime(arena, if (args.len > 1) args[1] else Value{}, .constrain);
    const c = compareDT(a, b);
    return val_mod.makeNumber(arena, @floatFromInt(c));
}

fn compareDT(a: ISODateTime, b: ISODateTime) i8 {
    const dc = plain_date.compareISODate(a.date, b.date);
    if (dc != 0) return dc;
    const ta = shared.timeToNanos(a.time);
    const tb = shared.timeToNanos(b.time);
    return if (ta < tb) -1 else if (ta > tb) 1 else 0;
}

// ------------------------------------------------------------- arithmetic ---

fn addSub(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const dt = try requireDT(arena, this_val);
    var dur = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    if (subtract) {
        dur = negate(dur);
    }
    // Add time part first (carry days), then date part.
    const time_ns = shared.timeToNanos(dt.time) + durTimeNanos(dur);
    const tr = shared.nanosToTime(time_ns);
    const new_date = try plain_date.addISODate(dt.date, dur.years, dur.months, dur.weeks, dur.days + @as(f64, @floatFromInt(tr.days)), overflow, arena);
    return makeDateTime(arena, .{ .date = new_date, .time = tr.time });
}

fn negate(d: shared.DurationFields) shared.DurationFields {
    return .{
        .years = -d.years, .months = -d.months, .weeks = -d.weeks, .days = -d.days,
        .hours = -d.hours, .minutes = -d.minutes, .seconds = -d.seconds,
        .milliseconds = -d.milliseconds, .microseconds = -d.microseconds, .nanoseconds = -d.nanoseconds,
    };
}

fn durTimeNanos(d: shared.DurationFields) i128 {
    return @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(d.nanoseconds));
}

pub fn nativeAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSub(arena, this_val, args, false);
}
pub fn nativeSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSub(arena, this_val, args, true);
}

fn unitRank(u: shared.Unit) u8 {
    return switch (u) {
        .year => 0, .month => 1, .week => 2, .day => 3,
        .hour => 4, .minute => 5, .second => 6,
        .millisecond => 7, .microsecond => 8, .nanosecond => 9,
    };
}

fn difference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const dt = try requireDT(arena, this_val);
    const other = try toTemporalDateTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    if (dt.date.calendar != other.date.calendar) return realm_mod.throwRangeError(arena, "calendar mismatch");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // `since` negates `until` rather than swapping the operands: both anchor
    // their calendar walk on the receiver, and calendar arithmetic is not
    // symmetric. Rounding runs mirrored, so the mode comes back negated.
    const st = try shared.getDifferenceSettings(arena, opts, since, .datetime, &.{}, .nanosecond, .day);
    const from = dt.*;
    const to = other;

    var result: shared.DurationFields = undefined;
    // Rank 0 is `year`, so "day or larger" is a *lower* rank.
    if (unitRank(st.largest) <= unitRank(.day)) {
        // Calendar+time difference with day/week/month/year largest unit.
        result = differenceDateTime(from, to, st.largest);
    } else {
        // Pure time balancing (largest is hour or smaller): convert everything.
        const total_ns = (shared.isoDateToEpochDays(to.date.year, to.date.month, to.date.day) -
            shared.isoDateToEpochDays(from.date.year, from.date.month, from.date.day)) * shared.NS_PER_DAY +
            (shared.timeToNanos(to.time) - shared.timeToNanos(from.time));
        result = balanceTime(total_ns, st.largest);
    }
    // Rounding: only for time-unit / day smallestUnit (approximate).
    const dest_wall = @as(i128, shared.isoDateToEpochDays(to.date.year, to.date.month, to.date.day)) *
        shared.NS_PER_DAY + shared.timeToNanos(to.time);
    result = try roundRelative(arena, from, dest_wall, result, st.smallest, st.increment, st.mode, st.largest);
    if (since) result = shared.negateFields(result);
    return duration.makeDuration(arena, result);
}

/// DifferenceISODateTime with a calendar largest unit (day..year).
fn differenceDateTime(dt1: ISODateTime, dt2: ISODateTime, largest: shared.Unit) shared.DurationFields {
    var ns_diff = shared.timeToNanos(dt2.time) - shared.timeToNanos(dt1.time);
    var d1 = dt1.date;
    const d2 = dt2.date;
    const date_sign = plain_date.compareISODate(d1, d2); // -1 if d1 earlier
    // Borrow a day so time-diff sign agrees with date-diff sign.
    if (ns_diff < 0 and date_sign < 0) {
        d1 = shared.balanceISODate(d1.year, d1.month, @as(i32, d1.day) + 1);
        d1.calendar = d2.calendar;
        ns_diff += shared.NS_PER_DAY;
    } else if (ns_diff > 0 and date_sign > 0) {
        d1 = shared.balanceISODate(d1.year, d1.month, @as(i32, d1.day) - 1);
        d1.calendar = d2.calendar;
        ns_diff -= shared.NS_PER_DAY;
    }
    var date_dur = plain_date.differenceISODate(d1, d2, largest);
    const time_dur = balanceTime(ns_diff, .hour);
    date_dur.hours = time_dur.hours;
    date_dur.minutes = time_dur.minutes;
    date_dur.seconds = time_dur.seconds;
    date_dur.milliseconds = time_dur.milliseconds;
    date_dur.microseconds = time_dur.microseconds;
    date_dur.nanoseconds = time_dur.nanoseconds;
    return date_dur;
}

/// Balance a signed nanosecond count into time units down from `largest`
/// (largest is hour or smaller; day handled by callers).
fn balanceTime(total_ns: i128, largest: shared.Unit) shared.DurationFields {
    const neg = total_ns < 0;
    var rem: i128 = if (neg) -total_ns else total_ns;
    var d = shared.DurationFields{};
    if (unitRank(largest) <= unitRank(.hour)) {
        d.hours = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_HOUR))));
        rem = @mod(rem, shared.NS_PER_HOUR);
    }
    if (unitRank(largest) <= unitRank(.minute)) {
        d.minutes = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MINUTE))));
        rem = @mod(rem, shared.NS_PER_MINUTE);
    }
    if (unitRank(largest) <= unitRank(.second)) {
        d.seconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_SECOND))));
        rem = @mod(rem, shared.NS_PER_SECOND);
    }
    if (unitRank(largest) <= unitRank(.millisecond)) {
        d.milliseconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MILLI))));
        rem = @mod(rem, shared.NS_PER_MILLI);
    }
    if (unitRank(largest) <= unitRank(.microsecond)) {
        d.microseconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MICRO))));
        rem = @mod(rem, shared.NS_PER_MICRO);
    }
    d.nanoseconds = @floatFromInt(@as(i128, (rem)));
    if (neg) return negate(d);
    return d;
}

/// RoundRelativeDuration for a date+time difference measured from `from`.
/// `dest_wall` is the target's wall-clock nanosecond position (epoch days ×
/// NS_PER_DAY + time of day) — the same scale `wallNanos(from)` produces.
///
/// A calendar `smallest` cannot be rounded on a nanosecond total: a year is not
/// a fixed length. So the spec brackets the answer between the two candidate
/// multiples of the increment, converts each back into a real date, and rounds
/// the *fraction* of the way `dest` lies between them.
pub fn roundRelative(
    arena: std.mem.Allocator,
    from: ISODateTime,
    dest_wall: i128,
    dur: shared.DurationFields,
    smallest: shared.Unit,
    inc: f64,
    mode: shared.RoundingMode,
    largest: shared.Unit,
) !shared.DurationFields {
    if (unitRank(smallest) >= unitRank(.hour)) {
        var res = roundTimeOnly(dur, smallest, inc, mode, largest);
        // When the time rounding spilled into an extra day and `largest` is a
        // calendar unit, that day can complete a month/year: re-anchor the date
        // part from `from` so the overflow bubbles up (BubbleRelativeDuration).
        if (unitRank(largest) < unitRank(.day)) {
            const end = try plain_date.addISODate(from.date, res.years, res.months, res.weeks, res.days, .constrain, arena);
            const rebal = plain_date.differenceISODate(from.date, end, largest);
            res.years = rebal.years;
            res.months = rebal.months;
            res.weeks = rebal.weeks;
            res.days = rebal.days;
        }
        return res;
    }
    if (dur.sign() == 0) return dur;
    const sign: f64 = @floatFromInt(dur.sign());

    // Everything coarser than `smallest` is carried through untouched; the unit
    // itself is re-derived and everything finer is dropped.
    var base = shared.DurationFields{};
    switch (smallest) {
        .month => base.years = dur.years,
        .week => {
            base.years = dur.years;
            base.months = dur.months;
        },
        .day => {
            base.years = dur.years;
            base.months = dur.months;
            base.weeks = dur.weeks;
        },
        else => {},
    }
    const unit_val: f64 = switch (smallest) {
        .year => dur.years,
        .month => dur.months,
        .week => dur.weeks,
        .day => dur.days,
        else => unreachable,
    };
    const q = @trunc(@abs(unit_val) / inc) * inc * sign;
    const q2 = q + inc * sign;

    const time_ns = shared.timeToNanos(from.time);
    const p1 = try candidateWall(arena, from.date, base, smallest, q, time_ns);
    const p2 = try candidateWall(arena, from.date, base, smallest, q2, time_ns);

    var total = q;
    if (p2 != p1) {
        const progress = shared.divToF64(dest_wall - p1, p2 - p1);
        total = q + progress * inc * sign;
    }
    var out = base;
    const rounded = shared.roundNumberToIncrement(total, inc, mode);
    switch (smallest) {
        .year => out.years = rounded,
        .month => {
            out.months = rounded;
            // A rounded month count reaching a full year (12, ISO) bubbles into
            // years, but only when `largest` is year (BubbleRelativeDuration).
            if (largest == .year) {
                const extra = @divTrunc(rounded, 12);
                if (extra != 0) {
                    out.years += extra;
                    out.months -= extra * 12;
                }
            }
        },
        .week => out.weeks = rounded,
        .day => out.days = rounded,
        else => {},
    }
    return out;
}

/// Wall position of `from` + (`base` plus `n` of `unit`), keeping the time of day.
fn candidateWall(arena: std.mem.Allocator, from: ISODate, base: shared.DurationFields, unit: shared.Unit, n: f64, time_ns: i128) !i128 {
    var d = base;
    switch (unit) {
        .year => d.years = n,
        .month => d.months = n,
        .week => d.weeks = n,
        .day => d.days = n,
        else => {},
    }
    const shifted = try plain_date.addISODate(from, d.years, d.months, d.weeks, d.days, .constrain, arena);
    return @as(i128, shared.isoDateToEpochDays(shifted.year, shifted.month, shifted.day)) * shared.NS_PER_DAY + time_ns;
}

/// NudgeToDayOrTime: `smallest` is a time unit, so the time portion rounds on a
/// plain nanosecond total. Calendar fields ride along unless `largest` is itself
/// a time unit, in which case the days fold into the total too.
fn roundTimeOnly(dur: shared.DurationFields, smallest: shared.Unit, inc: f64, mode: shared.RoundingMode, largest: shared.Unit) shared.DurationFields {
    const per = shared.unitLengthNanos(smallest) orelse return dur;
    const inc_ns = per * @as(i128, @intFromFloat(inc));
    if (unitRank(largest) >= unitRank(.hour)) {
        const total = @as(i128, @intFromFloat(dur.days)) * shared.NS_PER_DAY + durTimeNanos(dur);
        return balanceTime(shared.roundI128ToIncrement(total, inc_ns, mode), largest);
    }
    const rounded = shared.roundI128ToIncrement(durTimeNanos(dur), inc_ns, mode);
    // Rounding the time can spill into a whole extra day.
    const extra_days = @divTrunc(rounded, shared.NS_PER_DAY);
    var out = balanceTime(rounded - extra_days * shared.NS_PER_DAY, .hour);
    out.years = dur.years;
    out.months = dur.months;
    out.weeks = dur.weeks;
    out.days = dur.days + @as(f64, @floatFromInt(extra_days));
    return out;
}

pub fn nativeUntil(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, false);
}
pub fn nativeSince(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, true);
}

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireDT(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (shared.isTemporalObject(arg)) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (try shared.optionGet(arena, o, "calendar") != null) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (try shared.optionGet(arena, o, "timeZone") != null) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const bag = try plain_date.readDateBag(arena, o, .{ .time = true, .fixed_cal = cur.date.calendar });
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    if (!bag.hasDateField() and !bag.hasTimeField()) return realm_mod.throwTypeError(arena, "with() needs at least one field");

    // Date fields go through the shared calendar-aware merge; time fields fall
    // back to the receiver's own wall-clock components.
    const merged = try plain_date.withDateFields(arena, cur.date, bag, overflow);
    const time = try timeFromBag(arena, bag, overflow, cur.time);
    return makeDateTime(arena, .{ .date = merged.date, .time = time });
}

pub fn nativeWithPlainTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    var time = ISOTime{};
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        time = try plain_time.toTemporalTime(arena, args[0], .constrain);
    }
    return makeDateTime(arena, .{ .date = dt.date, .time = time });
}

pub fn nativeRound(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    var opts: ?*JsObject = null;
    var smallest: ?shared.Unit = null;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits == 0 or arg0.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "round() requires an options argument");
    var inc: f64 = 1;
    var mode: shared.RoundingMode = .half_expand;
    if (arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
    } else {
        opts = try shared.getOptionsObject(arena, arg0);
        inc = try shared.getRoundingIncrement(arena, opts);
        mode = try shared.getRoundingMode(arena, opts, .half_expand);
        smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    }
    if (smallest == null) return realm_mod.throwRangeError(arena, "round() requires smallestUnit");
    if (unitRank(smallest.?) < unitRank(.day)) return realm_mod.throwRangeError(arena, "smallestUnit must be day..nanosecond");
    // ValidateTemporalRoundingIncrement: day allows only 1 (inclusive maximum),
    // time units divide their next-coarser unit (non-inclusive).
    if (smallest.? == .day)
        try shared.validateRoundingIncrement(arena, inc, 1, true)
    else if (shared.maximumRoundingIncrement(smallest.?)) |maxv|
        try shared.validateRoundingIncrement(arena, inc, maxv, false);

    if (smallest.? == .day) {
        // Round to nearest day.
        const day_ns = shared.timeToNanos(dt.time);
        const rounded = shared.roundI128ToIncrement(day_ns, shared.NS_PER_DAY, mode);
        const carry_days: i32 = @intCast(@divTrunc(rounded, shared.NS_PER_DAY));
        var new_date = shared.balanceISODate(dt.date.year, dt.date.month, @as(i32, dt.date.day) + carry_days);
        new_date.calendar = dt.date.calendar;
        return makeDateTime(arena, .{ .date = new_date, .time = .{} });
    }
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    const total = shared.timeToNanos(dt.time);
    const rounded = shared.roundI128ToIncrement(total, inc_ns, mode);
    const tr = shared.nanosToTime(rounded);
    var new_date = shared.balanceISODate(dt.date.year, dt.date.month, @as(i32, dt.date.day) + @as(i32, @intCast(tr.days)));
    new_date.calendar = dt.date.calendar;
    return makeDateTime(arena, .{ .date = new_date, .time = tr.time });
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const other = try toTemporalDateTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    // Equality is on the ISO date-time *and* the calendar; `compare` ignores the
    // latter because it orders date-times chronologically.
    return val_mod.makeBool(arena, compareDT(dt.*, other) == 0 and dt.date.calendar == other.date.calendar);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return plain_date.makeDate(arena, dt.date);
}

pub fn nativeWithCalendar(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const cal = if (args.len > 0) args[0] else Value{};
    if (cal.bits == 0 or cal.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "withCalendar requires a calendar");
    // The ISO date+time is unchanged; only the lens through which it is read.
    var out = dt.*;
    out.date.calendar = try shared.resolveCalendarArg(arena, cal);
    return makeDateTime(arena, out);
}

pub fn nativeToZonedDateTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const timezone = @import("timezone.zig");
    const zoned = @import("zoned_date_time.zig");
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
    const zone = try timezone.toZone(arena, v.unbox().string);
    // disambiguation option is validated but irrelevant for fixed-offset zones.
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    _ = try getDisambiguation(arena, opts);
    const wall = @as(i128, shared.isoDateToEpochDays(dt.date.year, dt.date.month, dt.date.day)) * shared.NS_PER_DAY +
        shared.timeToNanos(dt.time);
    return zoned.makeZoned(arena, .{ .ns = wall - zone.offset_ns, .tz = zone.id, .offset_ns = zone.offset_ns });
}

fn getDisambiguation(arena: std.mem.Allocator, opts: ?*JsObject) !void {
    const s = (try shared.readStringOption(arena, opts, "disambiguation")) orelse return;
    if (std.mem.eql(u8, s, "compatible") or std.mem.eql(u8, s, "earlier") or
        std.mem.eql(u8, s, "later") or std.mem.eql(u8, s, "reject")) return;
    return realm_mod.throwRangeError(arena, "invalid disambiguation");
}

pub fn nativeToPlainTime(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return plain_time.makeTime(arena, dt.time);
}

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    // Options are read in alphabetical order: calendarName, fractionalSecondDigits,
    // roundingMode, then smallestUnit (via getSecondsStringPrecision).
    const show = try shared.getShowCalendar(arena, opts);
    const digits = try shared.getFractionalDigits(arena, opts);
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const prec = try shared.getSecondsStringPrecision(arena, opts, digits);
    // Rounding up past midnight carries into the date.
    const r = plain_time.roundTimeToIncrement(dt.time, prec, mode);
    var out = dt.*;
    out.time = r.time;
    if (r.days != 0) {
        const cal = out.date.calendar;
        out.date = shared.balanceISODate(out.date.year, out.date.month, @as(i32, out.date.day) + @as(i32, @intCast(r.days)));
        out.date.calendar = cal;
    }
    const s = try dtToStringPrec(arena, out, prec, show);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeString(arena, try dtToString(arena, dt.*, null, .auto));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireDT(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .datetime);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.PlainDateTime");
}

fn dtToString(arena: std.mem.Allocator, dt: ISODateTime, digits: ?u8, show: shared.ShowCalendar) ![]const u8 {
    return dtToStringPrec(arena, dt, .{ .digits = digits }, show);
}

fn dtToStringPrec(arena: std.mem.Allocator, dt: ISODateTime, prec: shared.SecondsPrecision, show: shared.ShowCalendar) ![]const u8 {
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, dt.date.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, dt.date.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, dt.date.day, 2);
    try buf.append(arena, 'T');
    try buf.appendSlice(arena, try plain_time.timeToStringPrec(arena, dt.time, prec));
    try plain_date.appendCalendar(arena, &buf, show, dt.date.calendar);
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getY(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(dt.date.calendar, dt.date).year));
}
fn getMo(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(dt.date.calendar, dt.date).month));
}
fn getD(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(dt.date.calendar, dt.date).day));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeString(arena, try shared.formatMonthCode(arena, calendar.fields(dt.date.calendar, dt.date)));
}
fn getH(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.hour));
}
fn getMin(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.minute));
}
fn getS(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.second));
}
fn getMs(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.millisecond));
}
fn getUs(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.microsecond));
}
fn getNs(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.time.nanosecond));
}
fn getDayOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfWeek(dt.date)));
}
fn getDayOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfYear(dt.date)));
}
fn getWeekOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.weekOfYear(dt.date)));
}
fn getYearOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.yearOfWeek(dt.date)));
}
fn getEra(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const era = calendar.fields(dt.date.calendar, dt.date).era orelse return Value{};
    return val_mod.makeString(arena, era);
}
fn getEraYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const ey = calendar.fields(dt.date.calendar, dt.date).era_year orelse return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(ey));
}
fn getDaysInWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, 7);
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const f = calendar.fields(dt.date.calendar, dt.date);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInMonth(dt.date.calendar, f.year, f.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const f = calendar.fields(dt.date.calendar, dt.date);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInYear(dt.date.calendar, f.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const f = calendar.fields(dt.date.calendar, dt.date);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.monthsInYear(dt.date.calendar, f.year)));
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const f = calendar.fields(dt.date.calendar, dt.date);
    return val_mod.makeBool(arena, calendar.inLeapYear(dt.date.calendar, f.year));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeString(arena, dt.date.calendar.str());
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethodLen(arena, proto, "with", nativeWith, 1);
    try intrinsics.setMethod(arena, proto, "withPlainTime", nativeWithPlainTime);
    try intrinsics.setMethodLen(arena, proto, "add", nativeAdd, 1);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDate", nativeToPlainDate);
    try intrinsics.setMethod(arena, proto, "toPlainTime", nativeToPlainTime);
    try intrinsics.setMethod(arena, proto, "withCalendar", nativeWithCalendar);
    try intrinsics.setMethod(arena, proto, "toZonedDateTime", nativeToZonedDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "year", getY);
    try intrinsics.defineGetter(arena, proto, "month", getMo);
    try intrinsics.defineGetter(arena, proto, "day", getD);
    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
    try intrinsics.defineGetter(arena, proto, "hour", getH);
    try intrinsics.defineGetter(arena, proto, "minute", getMin);
    try intrinsics.defineGetter(arena, proto, "second", getS);
    try intrinsics.defineGetter(arena, proto, "millisecond", getMs);
    try intrinsics.defineGetter(arena, proto, "microsecond", getUs);
    try intrinsics.defineGetter(arena, proto, "nanosecond", getNs);
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
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
}
