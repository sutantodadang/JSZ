// SPDX-License-Identifier: Apache-2.0
//! Wave 30: Temporal.PlainYearMonth — an ISO calendar year+month with no day.
//! Storage: internal_kind = .temporal_plain_year_month, internal_slot -> ISODate
//! whose [[Day]] is the ISO reference day (always 1 for the iso8601 calendar).
//! The only calendar is "iso8601".
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
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
    if (args.len > 2) try shared.validateCalendarArgCanonical(arena, args[2]);
    // args[3] is referenceISODay (default 1).
    var ref_day: f64 = 1;
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        ref_day = try shared.toIntegerWithTruncation(arena, args[3]);
    }
    const yi = floatToI32(y);
    const mi = floatToI32(m);
    const di = floatToI32(ref_day);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid year-month");
    const date = ISODate{ .year = yi, .month = @intCast(mi), .day = @intCast(di) };
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

fn yearMonthFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISODate {
    if (o.get("calendar")) |cv| try shared.validateCalendarArg(arena, cv);
    const year_v = o.get("year");
    const month_v = o.get("month");
    const mc = try shared.readMonthCode(arena, o.get("monthCode"));
    if (year_v == null or (year_v.?.bits != 0 and year_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing year");
    var month: f64 = undefined;
    if (month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_) {
        month = try shared.toIntegerWithTruncation(arena, month_v.?);
        // month and monthCode, when both present, must agree.
        if (mc) |code| {
            if (floatToI32(month) != code) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
    } else if (mc) |code| {
        month = @floatFromInt(code);
    } else {
        return realm_mod.throwTypeError(arena, "missing month or monthCode");
    }
    const year = try shared.toIntegerWithTruncation(arena, year_v.?);
    var mi = floatToI32(month);
    const yi = floatToI32(year);
    // A month below 1 is always out of range; the upper bound is constrained or
    // rejected per the overflow option.
    if (mi < 1) return realm_mod.throwRangeError(arena, "month out of range");
    if (mi > 12) {
        if (overflow == .reject) return realm_mod.throwRangeError(arena, "month out of range");
        mi = 12;
    }
    return .{ .year = yi, .month = @intCast(mi), .day = 1 };
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const d = try toTemporalYearMonth(arena, v, overflow);
    return makeYearMonth(arena, d);
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
    const anchor_day: u8 = if (sign < 0) shared.isoDaysInMonth(ym.year, ym.month) else 1;
    const anchor = ISODate{ .year = ym.year, .month = ym.month, .day = anchor_day };
    const result = try plain_date.addISODate(anchor, dur.years, dur.months, dur.weeks, total_days, overflow, arena);
    return makeYearMonth(arena, .{ .year = result.year, .month = result.month, .day = 1 });
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
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    var smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    var largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    if (smallest == null) smallest = .month;
    if (largest == null) largest = .year;
    // Only year/month units allowed.
    if (unitRank(smallest.?) > 1 or unitRank(largest.?) > 1)
        return realm_mod.throwRangeError(arena, "PlainYearMonth difference units must be year or month");
    if (unitRank(largest.?) > unitRank(smallest.?)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const inc = try shared.getRoundingIncrement(arena, opts);

    const a = ISODate{ .year = ym.year, .month = ym.month, .day = 1 };
    const b = ISODate{ .year = other.year, .month = other.month, .day = 1 };
    const from = if (since) b else a;
    const to = if (since) a else b;
    var result = plain_date.differenceISODate(from, to, largest.?);
    result.weeks = 0;
    result.days = 0;

    // Round the (years, months) difference to the requested smallestUnit. Work in
    // total signed months; the increment is measured in months (12 per year).
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
    if (getYearMonth(arg) != null) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (o.get("calendar") != null and o.get("calendar").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (o.get("timeZone") != null and o.get("timeZone").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    var year: f64 = @floatFromInt(cur.year);
    var month: f64 = @floatFromInt(cur.month);
    var any = false;
    var mc_month: ?i32 = null;
    if (try readField(arena, o, "year")) |x| { year = x; any = true; }
    if (try shared.readMonthCode(arena, o.get("monthCode"))) |code| {
        mc_month = code;
        month = @floatFromInt(code);
        any = true;
    }
    if (try readField(arena, o, "month")) |x| {
        if (mc_month) |mc| {
            if (floatToI32(x) != mc) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        month = x;
        any = true;
    }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    var mi = floatToI32(month);
    const yi = floatToI32(year);
    if (mi < 1) return realm_mod.throwRangeError(arena, "month out of range");
    if (mi > 12) {
        if (overflow == .reject) return realm_mod.throwRangeError(arena, "month out of range");
        mi = 12;
    }
    return makeYearMonth(arena, .{ .year = yi, .month = @intCast(mi), .day = 1 });
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const other = try toTemporalYearMonth(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    // Compare full ISO date (including reference day) plus calendar (iso only).
    return val_mod.makeBool(arena, ym.year == other.year and ym.month == other.month and ym.day == other.day);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "toPlainDate requires an object with a day");
    const o = arg.toPtr().object;
    const day_v = o.get("day") orelse return realm_mod.throwTypeError(arena, "missing day");
    if (day_v.bits != 0 and day_v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing day");
    const day = try shared.toIntegerWithTruncation(arena, day_v);
    const di = floatToI32(day);
    if (!shared.isValidISODate(ym.year, ym.month, di)) return realm_mod.throwRangeError(arena, "invalid day for PlainDate");
    return plain_date.makeDate(arena, .{ .year = ym.year, .month = ym.month, .day = @intCast(di) });
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
    // When the calendar is shown, the ISO reference day is emitted too.
    switch (show) {
        .never, .auto => {},
        .always => {
            try buf.append(arena, '-');
            try shared.appendPadded(arena, &buf, ym.day, 2);
            try buf.appendSlice(arena, "[u-ca=iso8601]");
        },
        .critical => {
            try buf.append(arena, '-');
            try shared.appendPadded(arena, &buf, ym.day, 2);
            try buf.appendSlice(arena, "[!u-ca=iso8601]");
        },
    }
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(ym.year));
}
fn getMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(ym.month));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "M{d:0>2}", .{ym.month}) catch unreachable;
    return val_mod.makeString(arena, try arena.dupe(u8, s));
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.isoDaysInMonth(ym.year, ym.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.daysInYear(ym.year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireYM(arena, this_val);
    return val_mod.makeNumber(arena, 12);
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ym = try requireYM(arena, this_val);
    return val_mod.makeBool(arena, shared.isLeapYear(ym.year));
}
fn getEra(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireYM(arena, this_val);
    return Value{}; // undefined for iso8601
}
fn getEraYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireYM(arena, this_val);
    return Value{}; // undefined for iso8601
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireYM(arena, this_val);
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
    try intrinsics.setMethod(arena, proto, "toPlainDate", nativeToPlainDate);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
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
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainYearMonth"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainYearMonth"), .{ .writable = false, .enumerable = false, .configurable = true });
}
