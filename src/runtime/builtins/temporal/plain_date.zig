// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.PlainDate — an ISO calendar date (year/month/day, no time
//! or zone). Storage: internal_kind = .temporal_plain_date, internal_slot ->
//! ISODate. The only calendar is "iso8601".
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const duration = @import("duration.zig");
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
    // args[3] is calendar; only "iso8601" supported.
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        const cal = try shared.valueToString(arena, args[3]);
        if (!isIsoCalendar(cal)) return realm_mod.throwRangeError(arena, "only the iso8601 calendar is supported");
    }
    if (y != @trunc(y) or m != @trunc(m) or d != @trunc(d)) return realm_mod.throwRangeError(arena, "non-integer date field");
    const yi: i32 = floatToI32(y);
    const mi: i32 = floatToI32(m);
    const di: i32 = floatToI32(d);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid date");
    const date = ISODate{ .year = yi, .month = @intCast(mi), .day = @intCast(di) };
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
        return try dateFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        const dt = shared.parseISODateTime(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainDate string");
        return dt.date;
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainDate");
}

fn dateFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODate {
    // Read calendar (must be iso8601 if present).
    if (o.get("calendar")) |cv| {
        if (cv.bits != 0 and cv.unbox() != .undefined_) {
            // A Temporal object supplied as the calendar contributes its
            // [[Calendar]] internal slot (always iso8601 here); otherwise coerce
            // to a string and require iso8601.
            if (!isTemporalCalendarObject(cv)) {
                const cal = try shared.valueToString(arena, cv);
                if (!isIsoCalendar(cal)) return realm_mod.throwRangeError(arena, "only iso8601 calendar supported");
            }
        }
    }
    const year_v = o.get("year");
    const month_v = o.get("month");
    const monthcode_v = o.get("monthCode");
    const day_v = o.get("day");
    if (day_v == null or (day_v.?.bits != 0 and day_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing day");
    if (year_v == null or (year_v.?.bits != 0 and year_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing year");
    var month: f64 = undefined;
    if (month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_) {
        month = try shared.toIntegerWithTruncation(arena, month_v.?);
    } else if (monthcode_v != null and monthcode_v.?.bits != 0 and monthcode_v.?.unbox() != .undefined_) {
        if (monthcode_v.?.unbox() != .string) return realm_mod.throwTypeError(arena, "monthCode must be a string");
        month = @floatFromInt(try monthFromCode(arena, monthcode_v.?.unbox().string));
    } else {
        return realm_mod.throwTypeError(arena, "missing month or monthCode");
    }
    const year = try shared.toIntegerWithTruncation(arena, year_v.?);
    const day = try shared.toIntegerWithTruncation(arena, day_v.?);
    return try regulateDate(arena, floatToI32(year), floatToI32(month), floatToI32(day), overflow);
}

fn monthFromCode(arena: std.mem.Allocator, code: []const u8) !u8 {
    if (code.len < 3 or code[0] != 'M') return realm_mod.throwRangeError(arena, "invalid monthCode");
    const n = std.fmt.parseInt(u8, code[1..3], 10) catch return realm_mod.throwRangeError(arena, "invalid monthCode");
    if (n < 1 or n > 12) return realm_mod.throwRangeError(arena, "invalid monthCode");
    return n;
}

fn regulateDate(arena: std.mem.Allocator, year: i32, month: i32, day: i32, overflow: shared.Overflow) !ISODate {
    if (overflow == .reject) {
        if (!shared.isValidISODate(year, month, day)) return realm_mod.throwRangeError(arena, "date out of range");
        return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
    }
    return shared.regulateISODateConstrain(year, month, day);
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const d = try toTemporalDate(arena, v, overflow);
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
    // Add years and months first (constrain/reject day), then weeks+days.
    const mtotal: i128 = @as(i128, date.month) + @as(i128, @intFromFloat(months)) + @as(i128, @intFromFloat(years)) * 12;
    const y: i128 = @as(i128, date.year) + @divFloor(mtotal - 1, 12);
    const m: i128 = @mod(mtotal - 1, 12) + 1;
    if (y > 300000 or y < -300000) return realm_mod.throwRangeError(arena, "date out of range");
    const yi: i32 = @intCast(y);
    const mi: i32 = @intCast(m);
    const dim = shared.isoDaysInMonth(yi, mi);
    var day: i64 = date.day;
    if (overflow == .reject) {
        if (day > dim) return realm_mod.throwRangeError(arena, "day out of range for month");
    } else {
        if (day > dim) day = dim;
    }
    const extra: i128 = @as(i128, @intFromFloat(days)) + @as(i128, @intFromFloat(weeks)) * 7;
    const target: i128 = @as(i128, shared.isoDateToEpochDays(yi, mi, 1)) + (day - 1) + extra;
    // Valid epoch-day window for the Temporal year range (~±1e8 days).
    if (target > 400_000_000 or target < -400_000_000) return realm_mod.throwRangeError(arena, "date out of range");
    return shared.epochDaysToISODate(@intCast(target));
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
            // year / month: order earlier→later, compute, then re-sign.
            const sign: i8 = cmp; // -1 if d1<d2, +1 if d1>d2
            const a = if (sign < 0) d1 else d2;
            const b = if (sign < 0) d2 else d1;
            var total_months: i64 = (@as(i64, b.year) - a.year) * 12 + (@as(i64, b.month) - a.month);
            var cand = addMonthsConstrain(a, total_months);
            if (compareISODate(cand, b) > 0) {
                total_months -= 1;
                cand = addMonthsConstrain(a, total_months);
            }
            const days = shared.isoDateToEpochDays(b.year, b.month, b.day) - shared.isoDateToEpochDays(cand.year, cand.month, cand.day);
            var years: i64 = 0;
            var months: i64 = total_months;
            if (largest == .year) {
                years = @divTrunc(total_months, 12);
                months = total_months - years * 12;
            }
            const dir: f64 = if (sign < 0) 1 else -1;
            out.years = @as(f64, @floatFromInt(years)) * dir;
            out.months = @as(f64, @floatFromInt(months)) * dir;
            out.days = @as(f64, @floatFromInt(days)) * dir;
            return out;
        },
    }
}

fn addMonthsConstrain(a: ISODate, n: i64) ISODate {
    const mtotal: i64 = @as(i64, a.month) + n;
    const y: i64 = @as(i64, a.year) + @divFloor(mtotal - 1, 12);
    const m: i64 = @mod(mtotal - 1, 12) + 1;
    const dim = shared.isoDaysInMonth(@intCast(y), @intCast(m));
    const day: i64 = @min(a.day, dim);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(day) };
}

fn nativeDifference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const d = try requireDate(arena, this_val);
    const other = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    var smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    var largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    if (smallest == null) smallest = .day;
    if (largest == null) largest = .day;
    // Only date units allowed.
    if (unitRank(smallest.?) > unitRank(.day) or unitRank(largest.?) > unitRank(.day))
        return realm_mod.throwRangeError(arena, "PlainDate difference units must be year..day");
    if (unitRank(largest.?) > unitRank(smallest.?)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const inc = try shared.getRoundingIncrement(arena, opts);

    const from = if (since) other else d.*;
    const to = if (since) d.* else other;
    var result = differenceISODate(from, to, largest.?);
    // Rounding for day/week smallestUnit with increment; year/month rounding
    // needs relativeTo-style re-balancing which we approximate for day.
    if (smallest.? == .day and inc != 1) {
        const days_rounded = shared.roundNumberToIncrement(result.days, inc, mode);
        result.days = days_rounded;
    }
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
    var year: f64 = @floatFromInt(cur.year);
    var month: f64 = @floatFromInt(cur.month);
    var day: f64 = @floatFromInt(cur.day);
    var any = false;
    if (try readField(arena, o, "year")) |x| { year = x; any = true; }
    if (o.get("monthCode")) |mc| {
        if (mc.bits != 0 and mc.unbox() != .undefined_) {
            month = @floatFromInt(try monthFromCode(arena, try shared.valueToString(arena, mc)));
            any = true;
        }
    }
    if (try readField(arena, o, "month")) |x| { month = x; any = true; }
    if (try readField(arena, o, "day")) |x| { day = x; any = true; }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    const nd = try regulateDate(arena, floatToI32(year), floatToI32(month), floatToI32(day), overflow);
    return makeDate(arena, nd);
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    const other = try toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    return val_mod.makeBool(arena, compareISODate(d.*, other) == 0);
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
    try appendCalendar(arena, &buf, show);
    return buf.items;
}

pub fn appendCalendar(arena: std.mem.Allocator, buf: *shared.Buf, show: shared.ShowCalendar) !void {
    switch (show) {
        .never, .auto => {},
        .always => try buf.appendSlice(arena, "[u-ca=iso8601]"),
        .critical => try buf.appendSlice(arena, "[!u-ca=iso8601]"),
    }
}

// ------------------------------------------------------------------ getters ---

fn getYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(d.year));
}
fn getMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(d.month));
}
fn getDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(d.day));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "M{d:0>2}", .{d.month}) catch unreachable;
    return val_mod.makeString(arena, try arena.dupe(u8, s));
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
fn getDaysInWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, 7);
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.isoDaysInMonth(d.year, d.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.daysInYear(d.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDate(arena, this_val);
    return val_mod.makeNumber(arena, 12);
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDate(arena, this_val);
    return val_mod.makeBool(arena, shared.isLeapYear(d.year));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireDate(arena, this_val);
    return val_mod.makeString(arena, "iso8601");
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethod(arena, proto, "with", nativeWith);
    try intrinsics.setMethod(arena, proto, "add", nativeAdd);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDateTime", nativeToPlainDateTime);
    try intrinsics.setMethod(arena, proto, "toZonedDateTime", nativeToZonedDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "year", getYear);
    try intrinsics.defineGetter(arena, proto, "month", getMonth);
    try intrinsics.defineGetter(arena, proto, "day", getDay);
    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
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
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 3), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainDate"), .{ .writable = false, .enumerable = false, .configurable = true });
}
