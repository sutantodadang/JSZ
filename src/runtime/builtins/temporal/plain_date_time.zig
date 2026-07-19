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
    if (dt.date.year < -271821 or dt.date.year > 275760) return realm_mod.throwRangeError(arena, "PlainDateTime year out of range");
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
    if (args.len > 9 and args[9].bits != 0 and args[9].unbox() != .undefined_) {
        const cal = try shared.valueToString(arena, args[9]);
        if (!plainDateIsIso(cal)) return realm_mod.throwRangeError(arena, "only iso8601 calendar supported");
    }
    const yi = f2i(y);
    const mi = f2i(mo);
    const di = f2i(d);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid date");
    if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999 or
        h < 0 or min < 0 or s < 0 or ms < 0 or us < 0 or ns < 0)
        return realm_mod.throwRangeError(arena, "time field out of range");
    const dt = ISODateTime{
        .date = .{ .year = yi, .month = @intCast(mi), .day = @intCast(di) },
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

fn plainDateIsIso(s: []const u8) bool {
    if (s.len != 7) return false;
    const lower = "iso8601";
    for (s, 0..) |c, i| {
        if (std.ascii.toLower(c) != lower[i]) return false;
    }
    return true;
}

// ---------------------------------------------------------------- ToDateTime ---

pub fn toTemporalDateTime(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISODateTime {
    if (getDateTime(v)) |dt| return dt.*;
    if (v.bits != 0 and v.unbox() == .object) {
        if (plain_date.getDate(v)) |d| return .{ .date = d.*, .time = .{} };
        return try dtFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        return shared.parseISODateTime(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainDateTime string");
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainDateTime");
}

fn dtFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODateTime {
    if (o.get("calendar")) |cv| {
        if (cv.bits != 0 and cv.unbox() != .undefined_) {
            const cal = try shared.valueToString(arena, cv);
            if (!plainDateIsIso(cal)) return realm_mod.throwRangeError(arena, "only iso8601 calendar supported");
        }
    }
    // Date fields (required: year, day, month|monthCode).
    const year_v = o.get("year");
    const day_v = o.get("day");
    if (year_v == null or year_v.?.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing year");
    if (day_v == null or day_v.?.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing day");
    var month: f64 = undefined;
    const month_v = o.get("month");
    const mc_v = o.get("monthCode");
    if (month_v != null and month_v.?.unbox() != .undefined_) {
        month = try shared.toIntegerWithTruncation(arena, month_v.?);
    } else if (mc_v != null and mc_v.?.unbox() != .undefined_) {
        const code = try shared.valueToString(arena, mc_v.?);
        if (code.len < 3 or code[0] != 'M') return realm_mod.throwRangeError(arena, "invalid monthCode");
        month = @floatFromInt(std.fmt.parseInt(u8, code[1..3], 10) catch return realm_mod.throwRangeError(arena, "invalid monthCode"));
    } else return realm_mod.throwTypeError(arena, "missing month or monthCode");
    const year = try shared.toIntegerWithTruncation(arena, year_v.?);
    const day = try shared.toIntegerWithTruncation(arena, day_v.?);

    var date: ISODate = undefined;
    if (overflow == .reject) {
        if (!shared.isValidISODate(f2i(year), f2i(month), f2i(day))) return realm_mod.throwRangeError(arena, "date out of range");
        date = .{ .year = f2i(year), .month = @intCast(f2i(month)), .day = @intCast(f2i(day)) };
    } else {
        date = shared.regulateISODateConstrain(f2i(year), f2i(month), f2i(day));
    }
    // Time fields (all optional, default 0).
    const time = try readTimeFields(arena, o, overflow);
    return .{ .date = date, .time = time };
}

fn readTimeFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISOTime {
    var h: f64 = 0;
    var min: f64 = 0;
    var s: f64 = 0;
    var ms: f64 = 0;
    var us: f64 = 0;
    var ns: f64 = 0;
    if (try readField(arena, o, "hour")) |x| h = x;
    if (try readField(arena, o, "minute")) |x| min = x;
    if (try readField(arena, o, "second")) |x| s = x;
    if (try readField(arena, o, "millisecond")) |x| ms = x;
    if (try readField(arena, o, "microsecond")) |x| us = x;
    if (try readField(arena, o, "nanosecond")) |x| ns = x;
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
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const dt = try toTemporalDateTime(arena, v, overflow);
    return makeDateTime(arena, dt);
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
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    var smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    var largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    if (smallest == null) smallest = .nanosecond;
    if (largest == null) largest = if (unitRank(smallest.?) < unitRank(.day)) smallest.? else .day;
    if (unitRank(largest.?) > unitRank(smallest.?)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const inc = try shared.getRoundingIncrement(arena, opts);

    const from = if (since) other else dt.*;
    const to = if (since) dt.* else other;

    var result: shared.DurationFields = undefined;
    if (unitRank(largest.?) >= unitRank(.day)) {
        // Calendar+time difference with day/week/month/year largest unit.
        result = differenceDateTime(from, to, largest.?);
    } else {
        // Pure time balancing (largest is hour or smaller): convert everything.
        const total_ns = (shared.isoDateToEpochDays(to.date.year, to.date.month, to.date.day) -
            shared.isoDateToEpochDays(from.date.year, from.date.month, from.date.day)) * shared.NS_PER_DAY +
            (shared.timeToNanos(to.time) - shared.timeToNanos(from.time));
        result = balanceTime(total_ns, largest.?);
    }
    // Rounding: only for time-unit / day smallestUnit (approximate).
    result = roundResult(result, smallest.?, inc, mode, largest.?);
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
        ns_diff += shared.NS_PER_DAY;
    } else if (ns_diff > 0 and date_sign > 0) {
        d1 = shared.balanceISODate(d1.year, d1.month, @as(i32, d1.day) - 1);
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

/// Approximate rounding of a difference to `smallest`+increment for time units.
fn roundResult(result: shared.DurationFields, smallest: shared.Unit, inc: f64, mode: shared.RoundingMode, largest: shared.Unit) shared.DurationFields {
    if (unitRank(smallest) < unitRank(.hour)) return result; // date-unit rounding unsupported
    // Only round when the whole duration is pure time (no calendar fields) so a
    // nanosecond total is meaningful.
    if (result.years != 0 or result.months != 0 or result.weeks != 0 or result.days != 0) return result;
    const total = durTimeNanos(result);
    const per = shared.unitLengthNanos(smallest) orelse return result;
    const inc_ns = per * @as(i128, @intFromFloat(inc));
    const rounded = shared.roundI128ToIncrement(total, inc_ns, mode);
    return balanceTime(rounded, largest);
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
    if (getDateTime(arg) != null or plain_date.getDate(arg) != null or plain_time.getTime(arg) != null)
        return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (o.get("calendar") != null and o.get("calendar").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (o.get("timeZone") != null and o.get("timeZone").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);

    var year: f64 = @floatFromInt(cur.date.year);
    var month: f64 = @floatFromInt(cur.date.month);
    var day: f64 = @floatFromInt(cur.date.day);
    var h: f64 = @floatFromInt(cur.time.hour);
    var min: f64 = @floatFromInt(cur.time.minute);
    var s: f64 = @floatFromInt(cur.time.second);
    var ms: f64 = @floatFromInt(cur.time.millisecond);
    var us: f64 = @floatFromInt(cur.time.microsecond);
    var ns: f64 = @floatFromInt(cur.time.nanosecond);
    var any = false;
    if (try readField(arena, o, "year")) |x| { year = x; any = true; }
    if (o.get("monthCode")) |mc| {
        if (mc.bits != 0 and mc.unbox() != .undefined_) {
            const code = try shared.valueToString(arena, mc);
            if (code.len < 3 or code[0] != 'M') return realm_mod.throwRangeError(arena, "invalid monthCode");
            month = @floatFromInt(std.fmt.parseInt(u8, code[1..3], 10) catch return realm_mod.throwRangeError(arena, "invalid monthCode"));
            any = true;
        }
    }
    if (try readField(arena, o, "month")) |x| { month = x; any = true; }
    if (try readField(arena, o, "day")) |x| { day = x; any = true; }
    if (try readField(arena, o, "hour")) |x| { h = x; any = true; }
    if (try readField(arena, o, "minute")) |x| { min = x; any = true; }
    if (try readField(arena, o, "second")) |x| { s = x; any = true; }
    if (try readField(arena, o, "millisecond")) |x| { ms = x; any = true; }
    if (try readField(arena, o, "microsecond")) |x| { us = x; any = true; }
    if (try readField(arena, o, "nanosecond")) |x| { ns = x; any = true; }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");

    var date: ISODate = undefined;
    if (overflow == .reject) {
        if (!shared.isValidISODate(f2i(year), f2i(month), f2i(day))) return realm_mod.throwRangeError(arena, "date out of range");
        date = .{ .year = f2i(year), .month = @intCast(f2i(month)), .day = @intCast(f2i(day)) };
        if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999)
            return realm_mod.throwRangeError(arena, "time out of range");
    } else {
        date = shared.regulateISODateConstrain(f2i(year), f2i(month), f2i(day));
    }
    const time = ISOTime{
        .hour = @intFromFloat(std.math.clamp(h, 0, 23)),
        .minute = @intFromFloat(std.math.clamp(min, 0, 59)),
        .second = @intFromFloat(std.math.clamp(s, 0, 59)),
        .millisecond = @intFromFloat(std.math.clamp(ms, 0, 999)),
        .microsecond = @intFromFloat(std.math.clamp(us, 0, 999)),
        .nanosecond = @intFromFloat(std.math.clamp(ns, 0, 999)),
    };
    return makeDateTime(arena, .{ .date = date, .time = time });
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
    if (arg0.bits != 0 and arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
    } else {
        opts = try shared.getOptionsObject(arena, arg0);
        smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    }
    if (smallest == null) return realm_mod.throwRangeError(arena, "round() requires smallestUnit");
    if (unitRank(smallest.?) < unitRank(.day)) return realm_mod.throwRangeError(arena, "smallestUnit must be day..nanosecond");
    const mode = try shared.getRoundingMode(arena, opts, .half_expand);
    const inc = try shared.getRoundingIncrement(arena, opts);

    if (smallest.? == .day) {
        // Round to nearest day.
        const day_ns = shared.timeToNanos(dt.time);
        const rounded = shared.roundI128ToIncrement(day_ns, shared.NS_PER_DAY, mode);
        const carry_days: i32 = @intCast(@divTrunc(rounded, shared.NS_PER_DAY));
        const new_date = shared.balanceISODate(dt.date.year, dt.date.month, @as(i32, dt.date.day) + carry_days);
        return makeDateTime(arena, .{ .date = new_date, .time = .{} });
    }
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    const total = shared.timeToNanos(dt.time);
    const rounded = shared.roundI128ToIncrement(total, inc_ns, mode);
    const tr = shared.nanosToTime(rounded);
    const new_date = shared.balanceISODate(dt.date.year, dt.date.month, @as(i32, dt.date.day) + @as(i32, @intCast(tr.days)));
    return makeDateTime(arena, .{ .date = new_date, .time = tr.time });
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    const other = try toTemporalDateTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    return val_mod.makeBool(arena, compareDT(dt.*, other) == 0);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return plain_date.makeDate(arena, dt.date);
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
    const digits = try shared.getFractionalDigits(arena, opts);
    const show = try shared.getShowCalendar(arena, opts);
    const s = try dtToString(arena, dt.*, digits, show);
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
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, dt.date.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, dt.date.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, dt.date.day, 2);
    try buf.append(arena, 'T');
    try shared.appendPadded(arena, &buf, dt.time.hour, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, dt.time.minute, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, dt.time.second, 2);
    try shared.appendFraction(arena, &buf, dt.time, digits);
    try plain_date.appendCalendar(arena, &buf, show);
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getY(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.date.year));
}
fn getMo(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.date.month));
}
fn getD(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(dt.date.day));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    var b: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "M{d:0>2}", .{dt.date.month}) catch unreachable;
    return val_mod.makeString(arena, try arena.dupe(u8, s));
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
fn getDaysInWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, 7);
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.isoDaysInMonth(dt.date.year, dt.date.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.daysInYear(dt.date.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDT(arena, this_val);
    return val_mod.makeNumber(arena, 12);
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dt = try requireDT(arena, this_val);
    return val_mod.makeBool(arena, shared.isLeapYear(dt.date.year));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDT(arena, this_val);
    return val_mod.makeString(arena, "iso8601");
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethod(arena, proto, "with", nativeWith);
    try intrinsics.setMethod(arena, proto, "withPlainTime", nativeWithPlainTime);
    try intrinsics.setMethod(arena, proto, "add", nativeAdd);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDate", nativeToPlainDate);
    try intrinsics.setMethod(arena, proto, "toPlainTime", nativeToPlainTime);
    try intrinsics.setMethod(arena, proto, "toZonedDateTime", nativeToZonedDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
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
    try intrinsics.defineGetter(arena, proto, "daysInWeek", getDaysInWeek);
    try intrinsics.defineGetter(arena, proto, "daysInMonth", getDaysInMonth);
    try intrinsics.defineGetter(arena, proto, "daysInYear", getDaysInYear);
    try intrinsics.defineGetter(arena, proto, "monthsInYear", getMonthsInYear);
    try intrinsics.defineGetter(arena, proto, "inLeapYear", getInLeapYear);
    try intrinsics.defineGetter(arena, proto, "calendarId", getCalendarId);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 3), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
}
