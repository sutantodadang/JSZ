// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.PlainTime — a wall-clock time (no date, no zone) with
//! nanosecond resolution. Storage: internal_kind = .temporal_plain_time,
//! internal_slot -> ISOTime.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const duration = @import("duration.zig");
const ISOTime = shared.ISOTime;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

pub fn getTime(v: Value) ?*ISOTime {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_plain_time) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireTime(arena: std.mem.Allocator, v: Value) !*ISOTime {
    return getTime(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.PlainTime");
}

pub fn makeTime(arena: std.mem.Allocator, t: ISOTime) !Value {
    const slot = try arena.create(ISOTime);
    slot.* = t;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_plain_time;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, t: ISOTime) !Value {
    const slot = try arena.create(ISOTime);
    slot.* = t;
    this_val.toPtr().object.internal_kind = .temporal_plain_time;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.PlainTime requires new");
    const h = try argInt(arena, args, 0);
    const min = try argInt(arena, args, 1);
    const s = try argInt(arena, args, 2);
    const ms = try argInt(arena, args, 3);
    const us = try argInt(arena, args, 4);
    const ns = try argInt(arena, args, 5);
    // Constructor rejects out-of-range (overflow: reject).
    if (h < 0 or h > 23 or min < 0 or min > 59 or s < 0 or s > 59 or
        ms < 0 or ms > 999 or us < 0 or us > 999 or ns < 0 or ns > 999)
        return realm_mod.throwRangeError(arena, "PlainTime field out of range");
    const t = ISOTime{
        .hour = @intFromFloat(h),
        .minute = @intFromFloat(min),
        .second = @intFromFloat(s),
        .millisecond = @intFromFloat(ms),
        .microsecond = @intFromFloat(us),
        .nanosecond = @intFromFloat(ns),
    };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, t);
    return makeTime(arena, t);
}

fn argInt(arena: std.mem.Allocator, args: []const Value, idx: usize) !f64 {
    if (idx >= args.len) return 0;
    const v = args[idx];
    if (v.bits == 0 or v.unbox() == .undefined_) return 0;
    return try shared.toIntegerWithTruncation(arena, v);
}

// ---------------------------------------------------------------- ToTime ---

pub fn toTemporalTime(arena: std.mem.Allocator, v: Value, overflow: shared.Overflow) !ISOTime {
    if (getTime(v)) |t| return t.*;
    if (v.bits != 0 and v.unbox() == .object) {
        // A PlainDateTime carries a time; extract it.
        const pdt = @import("plain_date_time.zig");
        if (pdt.getDateTime(v)) |dt| return dt.time;
        // A ZonedDateTime yields its wall-clock time.
        const zdt = @import("zoned_date_time.zig");
        if (zdt.getZoned(v)) |z| return zdt.localISODateTime(z).time;
        return try timeFromFields(arena, v.toPtr().object, overflow);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        const t = shared.parseISOTime(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid PlainTime string");
        return t;
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.PlainTime");
}

fn timeFromFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISOTime {
    var got = false;
    var h: f64 = 0;
    var min: f64 = 0;
    var s: f64 = 0;
    var ms: f64 = 0;
    var us: f64 = 0;
    var ns: f64 = 0;
    if (try readField(arena, o, "hour")) |x| {
        h = x;
        got = true;
    }
    if (try readField(arena, o, "minute")) |x| {
        min = x;
        got = true;
    }
    if (try readField(arena, o, "second")) |x| {
        s = x;
        got = true;
    }
    if (try readField(arena, o, "millisecond")) |x| {
        ms = x;
        got = true;
    }
    if (try readField(arena, o, "microsecond")) |x| {
        us = x;
        got = true;
    }
    if (try readField(arena, o, "nanosecond")) |x| {
        ns = x;
        got = true;
    }
    if (!got) return realm_mod.throwTypeError(arena, "time-like object needs at least one field");
    return regulateTime(arena, h, min, s, ms, us, ns, overflow);
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

fn regulateTime(arena: std.mem.Allocator, h: f64, min: f64, s: f64, ms: f64, us: f64, ns: f64, overflow: shared.Overflow) !ISOTime {
    if (overflow == .reject) {
        if (h < 0 or h > 23 or min < 0 or min > 59 or s < 0 or s > 59 or
            ms < 0 or ms > 999 or us < 0 or us > 999 or ns < 0 or ns > 999)
            return realm_mod.throwRangeError(arena, "PlainTime field out of range");
    }
    return ISOTime{
        .hour = @intFromFloat(std.math.clamp(h, 0, 23)),
        .minute = @intFromFloat(std.math.clamp(min, 0, 59)),
        .second = @intFromFloat(std.math.clamp(s, 0, 59)),
        .millisecond = @intFromFloat(std.math.clamp(ms, 0, 999)),
        .microsecond = @intFromFloat(std.math.clamp(us, 0, 999)),
        .nanosecond = @intFromFloat(std.math.clamp(ns, 0, 999)),
    };
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    const t = try toTemporalTime(arena, v, overflow);
    return makeTime(arena, t);
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const b = try toTemporalTime(arena, if (args.len > 1) args[1] else Value{}, .constrain);
    const na = shared.timeToNanos(a);
    const nb = shared.timeToNanos(b);
    const r: f64 = if (na < nb) -1 else if (na > nb) 1 else 0;
    return val_mod.makeNumber(arena, r);
}

// ------------------------------------------------------------ prototype methods ---

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireTime(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    const o = arg.toPtr().object;
    // Reject calendar/date fields per spec (with a Temporal type is a TypeError).
    if (getTime(arg) != null) return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    var h: f64 = @floatFromInt(cur.hour);
    var min: f64 = @floatFromInt(cur.minute);
    var s: f64 = @floatFromInt(cur.second);
    var ms: f64 = @floatFromInt(cur.millisecond);
    var us: f64 = @floatFromInt(cur.microsecond);
    var ns: f64 = @floatFromInt(cur.nanosecond);
    var any = false;
    if (try readField(arena, o, "hour")) |x| { h = x; any = true; }
    if (try readField(arena, o, "minute")) |x| { min = x; any = true; }
    if (try readField(arena, o, "second")) |x| { s = x; any = true; }
    if (try readField(arena, o, "millisecond")) |x| { ms = x; any = true; }
    if (try readField(arena, o, "microsecond")) |x| { us = x; any = true; }
    if (try readField(arena, o, "nanosecond")) |x| { ns = x; any = true; }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    const t = try regulateTime(arena, h, min, s, ms, us, ns, overflow);
    return makeTime(arena, t);
}

pub fn nativeAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSubtract(arena, this_val, args, false);
}
pub fn nativeSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSubtract(arena, this_val, args, true);
}

fn addSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const t = try requireTime(arena, this_val);
    const d = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    var delta = durationTimeNanos(d);
    if (subtract) delta = -delta;
    var total = shared.timeToNanos(t.*) + delta;
    // Wrap into [0, NS_PER_DAY).
    total = @mod(total, shared.NS_PER_DAY);
    const r = shared.nanosToTime(total);
    return makeTime(arena, r.time);
}

fn durationTimeNanos(d: shared.DurationFields) i128 {
    return @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(d.nanoseconds));
}

pub fn nativeUntil(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, false);
}
pub fn nativeSince(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, true);
}

fn difference(arena: std.mem.Allocator, this_val: Value, args: []const Value, since: bool) !Value {
    const t = try requireTime(arena, this_val);
    const other = try toTemporalTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    var smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    var largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    if (smallest == null) smallest = .nanosecond;
    if (largest == null) largest = .hour;
    if (!isTimeUnit(smallest.?) or !isTimeUnit(largest.?)) return realm_mod.throwRangeError(arena, "PlainTime difference units must be hour..nanosecond");
    if (unitRank(largest.?) > unitRank(smallest.?)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const inc = try shared.getRoundingIncrement(arena, opts);

    // until(other) = other - this; since(other) = this - other. Rounding the
    // signed difference with the original mode already points the right way.
    const diff = if (since)
        shared.timeToNanos(t.*) - shared.timeToNanos(other)
    else
        shared.timeToNanos(other) - shared.timeToNanos(t.*);
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    const rounded = shared.roundI128ToIncrement(diff, inc_ns, mode);
    return duration.makeDuration(arena, balanceTime(rounded, largest.?));
}

fn negateDur(d: shared.DurationFields) shared.DurationFields {
    var r = d;
    r.hours = -r.hours;
    r.minutes = -r.minutes;
    r.seconds = -r.seconds;
    r.milliseconds = -r.milliseconds;
    r.microseconds = -r.microseconds;
    r.nanoseconds = -r.nanoseconds;
    return r;
}

fn isTimeUnit(u: shared.Unit) bool {
    return switch (u) {
        .hour, .minute, .second, .millisecond, .microsecond, .nanosecond => true,
        else => false,
    };
}

/// Balance a signed nanosecond total into a time-unit Duration up to `largest`.
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
    if (neg) return negateDur(d);
    return d;
}

/// Lower rank = larger unit.
fn unitRank(u: shared.Unit) u8 {
    return switch (u) {
        .year => 0,
        .month => 1,
        .week => 2,
        .day => 3,
        .hour => 4,
        .minute => 5,
        .second => 6,
        .millisecond => 7,
        .microsecond => 8,
        .nanosecond => 9,
    };
}

pub fn nativeRound(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const t = try requireTime(arena, this_val);
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
    if (!isTimeUnit(smallest.?) and smallest.? != .day) return realm_mod.throwRangeError(arena, "invalid smallestUnit for PlainTime");
    if (smallest.? == .day) return realm_mod.throwRangeError(arena, "smallestUnit 'day' invalid for PlainTime");
    const mode = try shared.getRoundingMode(arena, opts, .half_expand);
    const inc = try shared.getRoundingIncrement(arena, opts);
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    var total = shared.timeToNanos(t.*);
    total = shared.roundI128ToIncrement(total, inc_ns, mode);
    total = @mod(total, shared.NS_PER_DAY);
    const r = shared.nanosToTime(total);
    return makeTime(arena, r.time);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const t = try requireTime(arena, this_val);
    const other = try toTemporalTime(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    return val_mod.makeBool(arena, shared.timeToNanos(t.*) == shared.timeToNanos(other));
}

pub fn nativeToPlainDateTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const t = try requireTime(arena, this_val);
    const pdt = @import("plain_date_time.zig");
    const pd = @import("plain_date.zig");
    const date = try pd.toTemporalDate(arena, if (args.len > 0) args[0] else Value{}, .constrain);
    return pdt.makeDateTime(arena, .{ .date = date, .time = t.* });
}

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const t = try requireTime(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const digits = try shared.getFractionalDigits(arena, opts);
    const s = try timeToString(arena, t.*, digits);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const t = try requireTime(arena, this_val);
    return val_mod.makeString(arena, try timeToString(arena, t.*, null));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireTime(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .time);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.PlainTime");
}

pub fn timeToString(arena: std.mem.Allocator, t: ISOTime, digits: ?u8) ![]const u8 {
    var buf = shared.Buf{};
    try shared.appendPadded(arena, &buf, t.hour, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, t.minute, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, t.second, 2);
    try shared.appendFraction(arena, &buf, t, digits);
    return buf.items;
}

// ------------------------------------------------------------------ getters ---

fn timeGetter(comptime field: []const u8) val_mod.NativeFnPtr {
    return struct {
        fn get(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
            const t = try requireTime(arena, this_val);
            return val_mod.makeNumber(arena, @floatFromInt(@field(t, field)));
        }
    }.get;
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
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toPlainDateTime", nativeToPlainDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "hour", timeGetter("hour"));
    try intrinsics.defineGetter(arena, proto, "minute", timeGetter("minute"));
    try intrinsics.defineGetter(arena, proto, "second", timeGetter("second"));
    try intrinsics.defineGetter(arena, proto, "millisecond", timeGetter("millisecond"));
    try intrinsics.defineGetter(arena, proto, "microsecond", timeGetter("microsecond"));
    try intrinsics.defineGetter(arena, proto, "nanosecond", timeGetter("nanosecond"));

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "PlainTime"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.PlainTime"), .{ .writable = false, .enumerable = false, .configurable = true });
}
