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
    // CreateTemporalMonthDay validates the reference ISO date against the full
    // PlainDate range (the boundary reference year alone is not enough).
    if (!shared.isoDateWithinLimits(.{ .year = md.ref_year, .month = md.month, .day = md.day }))
        return realm_mod.throwRangeError(arena, "PlainMonthDay reference date out of range");
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
    if (!shared.isoDateWithinLimits(.{ .year = md.ref_year, .month = md.month, .day = md.day }))
        return realm_mod.throwRangeError(arena, "PlainMonthDay reference date out of range");
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

/// ToTemporalMonthDay with an options object: the field bag is read before the
/// overflow option (both are observable).
pub fn toTemporalMonthDayOpts(arena: std.mem.Allocator, v: Value, opts_v: ?Value) !ISOMonthDay {
    if (v.bits != 0 and v.unbox() == .object and getMonthDay(v) == null) {
        const bag = try plain_date.readDateBag(arena, v.toPtr().object, .{});
        const opts = try shared.getOptionsObject(arena, opts_v);
        const overflow = try shared.getOverflow(arena, opts);
        return monthDayFromBag(arena, bag, overflow);
    }
    const md = try toTemporalMonthDay(arena, v, .constrain);
    _ = try shared.getOverflow(arena, try shared.getOptionsObject(arena, opts_v));
    return md;
}

fn monthDayFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISOMonthDay {
    const bag = try plain_date.readDateBag(arena, o, .{});
    return monthDayFromBag(arena, bag, overflow);
}

fn monthDayFromBag(arena: std.mem.Allocator, bag: plain_date.DateBag, overflow: shared.Overflow) !ISOMonthDay {
    const cal = bag.calendar;
    const day = floatToI32(bag.day orelse return realm_mod.throwTypeError(arena, "missing day"));

    const has_month = bag.month != null;
    const has_code = bag.month_code != null;
    var code = shared.MonthCode{ .num = 0 };
    if (bag.month_code) |mc| {
        code = try shared.parseMonthCode(arena, mc, calendar.hasLeapMonths(cal));
    } else if (bag.month) |mv| {
        const m = floatToI32(mv);
        if (m < 1 or m > 255) return realm_mod.throwRangeError(arena, "month out of range");
        code = .{ .num = @intCast(m) };
    } else {
        return realm_mod.throwTypeError(arena, "missing month or monthCode");
    }

    // A year (directly or via era/eraYear) pins the month/day to a specific
    // year, which both validates the year's range and — for a numeric month —
    // resolves which month code it names.
    const has_year = bag.year != null or bag.era != null;
    var resolved_day = day;
    if (has_year) {
        const cal_year = try plain_date.yearFromBag(arena, bag);
        const iso = if (has_code)
            calendar.toIsoFromCode(cal, cal_year, code.num, code.leap, day, overflow) catch
                return realm_mod.throwRangeError(arena, "month-day out of range")
        else
            calendar.toIso(cal, cal_year, code.num, day, overflow) catch
                return realm_mod.throwRangeError(arena, "month-day out of range");
        const f = calendar.fields(cal, iso);
        if (has_month and has_code) {
            if (floatToI32(bag.month.?) != f.month) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        // The year only picks the month code and constrains the day; the stored
        // reference date is still the canonical one near 1972.
        code = .{ .num = f.code_num, .leap = f.code_leap };
        resolved_day = f.day;
    }

    // month and monthCode, when both present, must name the same month.
    if (has_month and has_code) {
        if (floatToI32(bag.month.?) != code.num or code.leap) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
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
    return makeMonthDay(arena, try toTemporalMonthDayOpts(arena, v, if (args.len > 1) args[1] else null));
}

// ------------------------------------------------------------- methods ---

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireMD(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (shared.isTemporalObject(arg)) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (try shared.optionGet(arena, o, "calendar") != null) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (try shared.optionGet(arena, o, "timeZone") != null) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const cal = cur.calendar;
    // PrepareCalendarFields reads the partial fields (day, month, monthCode, year)
    // alphabetically, coerced and validated, *before* the options object is
    // consulted — so an out-of-range partial field is a RangeError even when the
    // options argument would itself be a TypeError.
    const bag = try plain_date.readDateBag(arena, o, .{ .fixed_cal = cal });
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const any = bag.day != null or bag.month != null or bag.month_code != null or
        bag.year != null or bag.era != null or bag.era_year != null;
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    // Merge over the receiver's own calendar fields, then recompute the ISO
    // reference date for the resulting month code + day.
    const base = calendar.fields(cal, .{ .year = cur.ref_year, .month = cur.month, .day = cur.day, .calendar = cal });
    var code = shared.MonthCode{ .num = base.code_num, .leap = base.code_leap };
    if (bag.month_code) |mc| code = try shared.parseMonthCode(arena, mc, calendar.hasLeapMonths(cal));
    if (bag.month) |mv| {
        const m = floatToI32(mv); // readDateBag already rejected month < 1
        if (bag.month_code != null) {
            if (m != code.num or code.leap) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        } else {
            code = .{ .num = @intCast(m) };
        }
    }
    const day: i32 = if (bag.day) |dv| floatToI32(dv) else base.day;
    const iso = calendar.monthDayReference(cal, code.num, code.leap, day, overflow) catch
        return realm_mod.throwRangeError(arena, "month-day out of range");
    return makeMonthDay(arena, .{ .month = iso.month, .day = iso.day, .ref_year = iso.year, .calendar = cal });
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
    const cal = md.calendar;
    // Only the year fields are read: the month and day come from the receiver.
    const bag = try plain_date.readDateBag(arena, o, .{ .day = false, .month = false, .fixed_cal = cal });
    const ref = ISODate{ .year = md.ref_year, .month = md.month, .day = md.day, .calendar = cal };
    const f = calendar.fields(cal, ref);
    const cal_year = try plain_date.yearFromBag(arena, bag);
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
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainMonthDay"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainMonthDay"), .{ .writable = false, .enumerable = false, .configurable = true });
}
