// SPDX-License-Identifier: Apache-2.0
//! Wave 30: Temporal.PlainMonthDay — an ISO calendar month+day with no year.
//! Storage: internal_kind = .temporal_plain_month_day, internal_slot ->
//! ISOMonthDay { month, day, ref_year }. The ISO reference year is 1972 (a leap
//! year) by default. The only calendar is "iso8601".
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
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
    // Constructor → CanonicalizeCalendar (bare identifier only).
    if (args.len > 2) try shared.validateCalendarArgCanonical(arena, args[2]);
    var ref_year: f64 = 1972;
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_) {
        ref_year = try shared.toIntegerWithTruncation(arena, args[3]);
    }
    const mi = floatToI32(m);
    const di = floatToI32(d);
    const yi = floatToI32(ref_year);
    if (!shared.isValidISODate(yi, mi, di)) return realm_mod.throwRangeError(arena, "invalid month-day");
    const md = ISOMonthDay{ .month = @intCast(mi), .day = @intCast(di), .ref_year = yi };
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
    if (o.get("calendar")) |cv| try shared.validateCalendarArg(arena, cv);
    const day_v = o.get("day");
    const month_v = o.get("month");
    const mc = try shared.readMonthCode(arena, o.get("monthCode"));
    const year_v = o.get("year");
    if (day_v == null or (day_v.?.bits != 0 and day_v.?.unbox() == .undefined_)) return realm_mod.throwTypeError(arena, "missing day");
    var month: f64 = undefined;
    var has_monthcode = false;
    if (mc) |code| {
        month = @floatFromInt(code);
        has_monthcode = true;
    } else if (month_v != null and month_v.?.bits != 0 and month_v.?.unbox() != .undefined_) {
        month = try shared.toIntegerWithTruncation(arena, month_v.?);
    } else {
        return realm_mod.throwTypeError(arena, "missing month or monthCode");
    }
    const day = try shared.toIntegerWithTruncation(arena, day_v.?);
    // If a year is supplied (with a numeric month, not monthCode) the day is
    // regulated against that year; otherwise validate against the leap-safe
    // reference year 1972.
    var year: i32 = 1972;
    if (!has_monthcode and year_v != null and year_v.?.bits != 0 and year_v.?.unbox() != .undefined_) {
        year = floatToI32(try shared.toIntegerWithTruncation(arena, year_v.?));
    }
    const mi = floatToI32(month);
    const di = floatToI32(day);
    if (overflow == .reject) {
        if (!shared.isValidISODate(year, mi, di)) return realm_mod.throwRangeError(arena, "month-day out of range");
        return .{ .month = @intCast(mi), .day = @intCast(di), .ref_year = 1972 };
    }
    const reg = shared.regulateISODateConstrain(year, mi, di);
    return .{ .month = reg.month, .day = reg.day, .ref_year = 1972 };
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
    var month: f64 = @floatFromInt(cur.month);
    var day: f64 = @floatFromInt(cur.day);
    var any = false;
    var mc_month: ?i32 = null;
    if (try shared.readMonthCode(arena, o.get("monthCode"))) |code| {
        mc_month = code;
        month = @floatFromInt(code);
        any = true;
    }
    if (try readField(arena, o, "month")) |x| {
        // month and monthCode, when both present, must denote the same month.
        if (mc_month) |mc| {
            if (floatToI32(x) != mc) return realm_mod.throwRangeError(arena, "month and monthCode disagree");
        }
        month = x;
        any = true;
    }
    if (try readField(arena, o, "day")) |x| { day = x; any = true; }
    if (o.get("year") != null and o.get("year").?.bits != 0 and o.get("year").?.unbox() != .undefined_) any = true;
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    const mi = floatToI32(month);
    const di = floatToI32(day);
    if (overflow == .reject) {
        if (!shared.isValidISODate(1972, mi, di)) return realm_mod.throwRangeError(arena, "month-day out of range");
        return makeMonthDay(arena, .{ .month = @intCast(mi), .day = @intCast(di), .ref_year = 1972 });
    }
    const reg = shared.regulateISODateConstrain(1972, mi, di);
    return makeMonthDay(arena, .{ .month = reg.month, .day = reg.day, .ref_year = 1972 });
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const other = try toTemporalMonthDay(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    return val_mod.makeBool(arena, md.month == other.month and md.day == other.day and md.ref_year == other.ref_year);
}

pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "toPlainDate requires an object with a year");
    const o = arg.toPtr().object;
    const year_v = o.get("year") orelse return realm_mod.throwTypeError(arena, "missing year");
    if (year_v.bits != 0 and year_v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing year");
    const year = try shared.toIntegerWithTruncation(arena, year_v);
    const yi = floatToI32(year);
    // Constrain the day to the target year's month length (leap-day handling).
    const reg = shared.regulateISODateConstrain(yi, md.month, md.day);
    return plain_date.makeDate(arena, reg);
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
    // The reference year is emitted only when the calendar annotation shows.
    switch (show) {
        .never, .auto => {},
        .always, .critical => {
            try shared.appendISOYear(arena, &buf, md.ref_year);
            try buf.append(arena, '-');
        },
    }
    try shared.appendPadded(arena, &buf, md.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, md.day, 2);
    switch (show) {
        .never, .auto => {},
        .always => try buf.appendSlice(arena, "[u-ca=iso8601]"),
        .critical => try buf.appendSlice(arena, "[!u-ca=iso8601]"),
    }
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "M{d:0>2}", .{md.month}) catch unreachable;
    return val_mod.makeString(arena, try arena.dupe(u8, s));
}
fn getDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const md = try requireMD(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(md.day));
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireMD(arena, this_val);
    return val_mod.makeString(arena, "iso8601");
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethod(arena, proto, "with", nativeWith);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDate", nativeToPlainDate);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
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
