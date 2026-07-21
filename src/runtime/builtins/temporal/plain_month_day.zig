// SPDX-License-Identifier: Apache-2.0
//! Wave 30: Temporal.PlainMonthDay — an ISO calendar month+day with no year.
//! Storage: internal_kind = .temporal_plain_month_day, internal_slot ->
//! ISOMonthDay { month, day, ref_year }. The ISO reference year is 1972 (a leap
//! year) by default; for other calendars it is the latest date on or before
//! 1972-12-31 whose calendar month code and day match.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const calendar = @import("calendar.zig");
const ISODate = shared.ISODate;
const plain_date = @import("plain_date.zig");
const ISOMonthDay = shared.ISOMonthDay;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

pub fn getMonthDay(v: Value) ?*ISOMonthDay {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_plain_month_day) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireMD(arena: std.mem.Allocator, v: Value) !*ISOMonthDay {
    return getMonthDay(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.PlainMonthDay");
}

pub fn makeMonthDay(arena: std.mem.Allocator, md: ISOMonthDay) !Value {
    if (!shared.isValidISODate(md.ref_year, md.month, md.day)) return realm_mod.throwRangeError(arena, "invalid PlainMonthDay");
    if (md.ref_year < -271821 or md.ref_year > 275760) return realm_mod.throwRangeError(arena, "PlainMonthDay reference year out of range");
    const slot = try arena.create(ISOMonthDay);
    slot.* = md;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_plain_month_day;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, md: ISOMonthDay) !Value {
    if (!shared.isValidISODate(md.ref_year, md.month, md.day)) return realm_mod.throwRangeError(arena, "invalid PlainMonthDay");
    const slot = try arena.create(ISOMonthDay);
    slot.* = md;
    this_val.toPtr().object.internal_kind = .temporal_plain_month_day;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.PlainMonthDay requires new");
    const m = try shared.toIntegerWithTruncation(arena, if (args.len > 0) args[0] else Value{});
    const d = try shared.toIntegerWithTruncation(arena, if (args.len > 1) args[1] else Value{});
    // Constructor → CanonicalizeCalendar (bare identifier only). The
    // constructor's month/day and reference year are ISO, whatever the calendar.
    const cal = if (args.len > 2) try shared.resolveCalendarArgCanonical(arena, args[2]) else .iso8601;
    var ref_year: f64 = 1972;
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        ref_year = try shared.toIntegerWithTruncation(arena, args[3]);
    }
    const mi = floatToI32(m);
    const di = floatToI32(d);
    const yi = floatToI32(ref_year);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid month-day");
    const md = ISOMonthDay{ .month = @intCast(mi), .day = @intCast(di), .ref_year = yi, .calendar = cal };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, md);
    return makeMonthDay(arena, md);
}

fn floatToI32(f: f64) i32 {
    if (f > 2147483647) return 2147483647;
    if (f < -2147483648) return -2147483648;
    return @intFromFloat(f);
}

// ---------------------------------------------------------------- conversion ---

pub fn toTemporalMonthDay(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISOMonthDay {
    if (getMonthDay(v)) |md| return md.*;
    if (v.bits != 0 and v.unbox() == .object) {
        return try monthDayFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        return shared.parseISOMonthDay(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainMonthDay string");
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainMonthDay");
}

fn monthDayFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISOMonthDay {
    const cal = if (o.get("calendar")) |cv| try shared.resolveCalendarArg(arena, cv) else .iso8601;
    const day_v = o.get("day");
    if (day_v == null or (day_v.?.bits != 0 and day_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing day");
    const day = floatToI32(try shared.toIntegerWithTruncation(arena, day_v.?));

    const month_v = o.get("month");
    const mc_v = o.get("monthCode");
    const has_month = month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_;
    const has_code = mc_v != null and mc_v.?.bits != 0 and mc_v.?.unbox() != .undefined_;
    var code = shared.MonthCode{ .num = 0 };
    if (has_code) {
        if (mc_v.?.unbox() != .string) return realm_mod.throwTypeError(arena, "monthCode must be a string");
        code = try shared.parseMonthCode(arena, mc_v.?.unbox().string, calendar.hasLeapMonths(cal));
    } else if (has_month) {
        const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
        if (m < 1 or m > 255) return realm_mod.throwRangeError(arena, "month out of range");
        code = .{ .num = @intCast(m) };
    } else {
        return realm_mod.throwTypeError(arena, "missing month or monthCode");
    }

    // A year (directly or via era/eraYear) pins the month/day to a specific
    // year, which both validates the year's range and — for a numeric month —
    // resolves which month code it names.
    const year_v = o.get("year");
    const has_year = (year_v != null and year_v.?.bits != 0 and year_v.?.unbox() != .undefined_) or
        (calendar.hasEras(cal) and o.get("era") != null and o.get("era").?.bits != 0 and o.get("era").?.unbox() != .undefined_);
    var resolved_day = day;
    if (has_year) {
        const cal_year = try plain_date.readCalendarYear(arena, o, cal);
        const iso = if (has_code)
            calendar.toIsoFromCode(cal, cal_year, code.num, code.leap, day, overflow) catch
                return realm_mod.throwRangeError(arena, "month-day out of range")
        else
            calendar.toIso(cal, cal_year, code.num, day, overflow) catch
                return realm_mod.throwRangeError(arena, "month-day out of range");
        const f = calendar.fields(cal, iso);
        if (has_month and has_code) {
            const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
            if (m != f.month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        // The year only picks the month code and constrains the day; the stored
        // reference date is still the canonical one near 1972.
        code = .{ .num = f.code_num, .leap = f.code_leap };
        resolved_day = f.day;
    }

    // month and monthCode, when both present, must name the same month.
    if (has_month and has_code) {
        const m = floatToI32(try shared.toIntegerWithTruncation(arena, month_v.?));
        if (m != code.num or code.leap) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
    }
    // A day already constrained against a supplied year must not be constrained
    // a second time here, so the reference lookup is exact in that case.
    const ref_overflow: shared.Overflow = if (has_year) .reject else overflow;
    const iso = calendar.monthDayReference(cal, code.num, code.leap, resolved_day, ref_overflow) catch
        return realm_mod.throwRangeError(arena, "month-day out of range");
    return .{ .month = iso.month, .day = iso.day, .ref_year = iso.year, .calendar = cal };
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const md = try toTemporalMonthDay(arena, v, overflow);
    return makeMonthDay(arena, md);
}

// ------------------------------------------------------------- methods ---

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireMD(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (getMonthDay(arg) != null) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (o.get("calendar") != null and o.get("calendar").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (o.get("timeZone") != null and o.get("timeZone").?.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    // Merge over the receiver's own calendar fields, then recompute the ISO
    // reference date for the resulting month code + day.
    const cal = cur.calendar;
    const base = calendar.fields(cal, .{ .year = cur.ref_year, .month = cur.month, .day = cur.day, .calendar = cal });
    var code = shared.MonthCode{ .num = base.code_num, .leap = base.code_leap };
    var day: i32 = base.day;
    var any = false;
    var mc_month: ?i32 = null;
    const mc_v = o.get("monthCode");
    if (mc_v != null and mc_v.?.bits != 0 and mc_v.?.unbox() != .undefined_) {
        if (mc_v.?.unbox() != .string) return realm_mod.throwTypeError(arena, "monthCode must be a string");
        code = try shared.parseMonthCode(arena, mc_v.?.unbox().string, calendar.hasLeapMonths(cal));
        mc_month = code.num;
        any = true;
    }
    if (try readField(arena, o, "month")) |x| {
        // month and monthCode, when both present, must denote the same month.
        if (mc_month) |mc| {
            if (floatToI32(x) != mc) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        } else {
            const m = floatToI32(x);
            if (m < 1 or m > 255) return realm_mod.throwRangeError(arena, "month out of range");
            code = .{ .num = @intCast(m) };
        }
        any = true;
    }
    if (try readField(arena, o, "day")) |x| {
        day = floatToI32(x);
        any = true;
    }
    if (o.get("year") != null and o.get("year").?.bits != 0 and o.get("year").?.unbox() != .undefined_) any = true;
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    const iso = calendar.monthDayReference(cal, code.num, code.leap, day, overflow) catch
        return realm_mod.throwRangeError(arena, "month-day out of range");
    return makeMonthDay(arena, .{ .month = iso.month, .day = iso.day, .ref_year = iso.year, .calendar = cal });
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const other = try toTemporalMonthDay(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    // Equality is on the full ISO reference date *and* the calendar.
    return val_mod.makeBool(arena, md.month == other.month and md.day == other.day and
        md.ref_year == other.ref_year and md.calendar == other.calendar);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "toPlainDate requires an object with a year");
    const o = arg.toPtr().object;
    const year_v = o.get("year") orelse return realm_mod.throwTypeError(arena, "missing year");
    if (year_v.bits != 0 and year_v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing year");
    const cal = md.calendar;
    const ref = ISODate{ .year = md.ref_year, .month = md.month, .day = md.day, .calendar = cal };
    const f = calendar.fields(cal, ref);
    const cal_year = try plain_date.readCalendarYear(arena, o, cal);
    // Constrain the day to the target year's month length (leap-day handling).
    const iso = calendar.toIsoFromCode(cal, cal_year, f.code_num, f.code_leap, f.day, .constrain) catch
        return realm_mod.throwRangeError(arena, "date out of range");
    return plain_date.makeDate(arena, iso);
}

// ------------------------------------------------------------------ strings ---

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const show = try shared.getShowCalendar(arena, opts);
    return val_mod.makeString(arena, try monthDayToString(arena, md.*, show));
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    return val_mod.makeString(arena, try monthDayToString(arena, md.*, .auto));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireMD(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .month_day);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.PlainMonthDay");
}

fn monthDayToString(arena: std.mem.Allocator, md: ISOMonthDay, show: shared.ShowCalendar) ![]const u8 {
    var buf = shared.Buf{};
    // The reference year is emitted only when the calendar annotation shows —
    // which includes a non-ISO calendar under `auto`, since it would otherwise
    // be lost in the round-trip.
    const shows_calendar = show == .always or show == .critical or
        (show == .auto and md.calendar != .iso8601);
    if (shows_calendar) {
        try shared.appendISOYear(arena, &buf, md.ref_year);
        try buf.append(arena, '-');
    }
    try shared.appendPadded(arena, &buf, md.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, md.day, 2);
    try plain_date.appendCalendar(arena, &buf, show, md.calendar);
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const ref = ISODate{ .year = md.ref_year, .month = md.month, .day = md.day, .calendar = md.calendar };
    return val_mod.makeString(arena, try shared.formatMonthCode(arena, calendar.fields(md.calendar, ref)));
}
fn getDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const ref = ISODate{ .year = md.ref_year, .month = md.month, .day = md.day, .calendar = md.calendar };
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(md.calendar, ref).day));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    return val_mod.makeString(arena, md.calendar.str());
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethodLen(arena, proto, "with", nativeWith, 1);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethodLen(arena, proto, "toPlainDate", nativeToPlainDate, 1);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
    try intrinsics.defineGetter(arena, proto, "day", getDay);
    try intrinsics.defineGetter(arena, proto, "calendarId", getCalendarId);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainMonthDay"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainMonthDay"), .{ .writable = false, .enumerable = false, .configurable = true });
}
