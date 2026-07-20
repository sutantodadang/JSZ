// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.Instant — an absolute point in time as i128 nanoseconds
//! since the Unix epoch. Storage: internal_kind = .temporal_instant,
//! internal_slot -> i128.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const duration = @import("duration.zig");

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

/// Maximum |epoch nanoseconds| for a valid Instant: 8.64e21 (100 million days).
const MAX_NS: i128 = 8_640_000_000_000_000_000_000;

pub fn getInstant(v: Value) ?*i128 {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_instant) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireInstant(arena: std.mem.Allocator, v: Value) !*i128 {
    return getInstant(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.Instant");
}

fn isValidEpochNs(ns: i128) bool {
    return ns >= -MAX_NS and ns <= MAX_NS;
}

pub fn makeInstant(arena: std.mem.Allocator, ns: i128) !Value {
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "Instant out of range");
    const slot = try arena.create(i128);
    slot.* = ns;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_instant;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, ns: i128) !Value {
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "Instant out of range");
    const slot = try arena.create(i128);
    slot.* = ns;
    this_val.toPtr().object.internal_kind = .temporal_instant;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.Instant requires new");
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .bigint) return realm_mod.throwTypeError(arena, "epochNanoseconds must be a BigInt");
    const ns = shared.bigIntToI128(arg) orelse return realm_mod.throwRangeError(arena, "Instant out of range");
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "Instant out of range");
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, ns);
    return makeInstant(arena, ns);
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (getInstant(v)) |ins| return makeInstant(arena, ins.*);
    if (v.bits != 0 and v.unbox() == .string) {
        const ns = try parseInstantString(arena, v.unbox().string);
        return makeInstant(arena, ns);
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.Instant");
}

/// Parse an ISO datetime with a mandatory UTC designator or numeric offset into
/// epoch nanoseconds.
fn parseInstantString(arena: std.mem.Allocator, s0: []const u8) !i128 {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    // Find the offset: 'Z'/'z' or a +/- after the time. We parse the datetime and
    // separately extract the offset.
    const dt = shared.parseISODateTimeOpts(s, false) catch return realm_mod.throwRangeError(arena, "invalid Instant string");
    const offset_ns = extractOffsetNs(s) orelse return realm_mod.throwRangeError(arena, "Instant string requires a UTC offset or Z");
    const days = shared.isoDateToEpochDays(dt.date.year, dt.date.month, dt.date.day);
    var ns: i128 = @as(i128, days) * shared.NS_PER_DAY + shared.timeToNanos(dt.time);
    ns -= offset_ns;
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "Instant out of range");
    return ns;
}

/// Extract the trailing UTC offset (in ns) from an ISO string. Returns null if
/// no offset/Z present.
fn extractOffsetNs(s: []const u8) ?i128 {
    // Strip bracket annotations first.
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '[')) |b| end = b;
    const body = s[0..end];
    if (body.len == 0) return null;
    const last = body[body.len - 1];
    if (last == 'Z' or last == 'z') return 0;
    // Look for the offset sign after the 'T'.
    const t_idx = std.mem.indexOfAny(u8, body, "Tt") orelse return null;
    var i = t_idx + 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '+' or c == '-') {
            return parseOffset(body[i..]);
        }
    }
    return null;
}

fn parseOffset(s: []const u8) ?i128 {
    if (s.len < 3) return null;
    const sign: i128 = if (s[0] == '-') -1 else 1;
    var idx: usize = 1;
    const h = twoDigits(s, idx) orelse return null;
    idx += 2;
    var m: i128 = 0;
    var sec: i128 = 0;
    if (idx < s.len and s[idx] == ':') idx += 1;
    if (idx + 1 < s.len and s[idx] >= '0' and s[idx] <= '9') {
        m = twoDigits(s, idx) orelse 0;
        idx += 2;
    }
    if (idx < s.len and s[idx] == ':') idx += 1;
    if (idx + 1 < s.len and s[idx] >= '0' and s[idx] <= '9') {
        sec = twoDigits(s, idx) orelse 0;
        idx += 2;
    }
    return sign * (h * shared.NS_PER_HOUR + m * shared.NS_PER_MINUTE + sec * shared.NS_PER_SECOND);
}

fn twoDigits(s: []const u8, idx: usize) ?i128 {
    if (idx + 2 > s.len) return null;
    if (s[idx] < '0' or s[idx] > '9' or s[idx + 1] < '0' or s[idx + 1] > '9') return null;
    return @as(i128, s[idx] - '0') * 10 + (s[idx + 1] - '0');
}

pub fn nativeFromEpochSeconds(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Valid |epochSeconds| ≤ MAX_NS / 1e9 = 8.64e12.
    const n = try readEpochNumber(arena, args, 8.64e12);
    return makeInstant(arena, @as(i128, @intFromFloat(n)) * shared.NS_PER_SECOND);
}

pub fn nativeFromEpochMilliseconds(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = try readEpochNumber(arena, args, 8.64e15);
    return makeInstant(arena, @as(i128, @intFromFloat(n)) * shared.NS_PER_MILLI);
}

fn readEpochNumber(arena: std.mem.Allocator, args: []const Value, max_abs: f64) !f64 {
    const v = if (args.len > 0) args[0] else Value{};
    const n = try realm_mod.toNumberValue(arena, v);
    if (!std.math.isFinite(n) or n != @trunc(n)) return realm_mod.throwRangeError(arena, "epoch value must be an integer");
    if (@abs(n) > max_abs) return realm_mod.throwRangeError(arena, "Instant out of range");
    return n;
}

pub fn nativeFromEpochMicroseconds(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .bigint) return realm_mod.throwTypeError(arena, "epochMicroseconds must be a BigInt");
    const us = shared.bigIntToI128(v) orelse return realm_mod.throwRangeError(arena, "Instant out of range");
    return makeInstant(arena, us * shared.NS_PER_MICRO);
}

pub fn nativeFromEpochNanoseconds(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .bigint) return realm_mod.throwTypeError(arena, "epochNanoseconds must be a BigInt");
    const ns = shared.bigIntToI128(v) orelse return realm_mod.throwRangeError(arena, "Instant out of range");
    return makeInstant(arena, ns);
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toInstantNs(arena, if (args.len > 0) args[0] else Value{});
    const b = try toInstantNs(arena, if (args.len > 1) args[1] else Value{});
    const r: f64 = if (a < b) -1 else if (a > b) 1 else 0;
    return val_mod.makeNumber(arena, r);
}

fn toInstantNs(arena: std.mem.Allocator, v: Value) !i128 {
    if (getInstant(v)) |ins| return ins.*;
    if (v.bits != 0 and v.unbox() == .string) return try parseInstantString(arena, v.unbox().string);
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.Instant");
}

// ------------------------------------------------------------- prototype methods ---

fn addSub(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const ins = try requireInstant(arena, this_val);
    const d = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    if (d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0)
        return realm_mod.throwRangeError(arena, "Instant arithmetic does not allow calendar units");
    var delta = @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(d.nanoseconds));
    if (subtract) delta = -delta;
    return makeInstant(arena, ins.* + delta);
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
    const ins = try requireInstant(arena, this_val);
    const other = try toInstantNs(arena, if (args.len > 0) args[0] else Value{});
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    var smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    var largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    if (smallest == null) smallest = .nanosecond;
    if (largest == null) largest = .second;
    if (unitRank(smallest.?) < unitRank(.hour) or unitRank(largest.?) < unitRank(.hour))
        return realm_mod.throwRangeError(arena, "Instant difference units must be hour..nanosecond");
    if (unitRank(largest.?) > unitRank(smallest.?)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const inc = try shared.getRoundingIncrement(arena, opts);

    const diff = if (since) ins.* - other else other - ins.*;
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    const rounded = shared.roundI128ToIncrement(diff, inc_ns, mode);
    return duration.makeDuration(arena, balanceTime(rounded, largest.?));
}

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
    if (neg) {
        d.hours = -d.hours;
        d.minutes = -d.minutes;
        d.seconds = -d.seconds;
        d.milliseconds = -d.milliseconds;
        d.microseconds = -d.microseconds;
        d.nanoseconds = -d.nanoseconds;
    }
    return d;
}

pub fn nativeUntil(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, false);
}
pub fn nativeSince(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, true);
}

pub fn nativeRound(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
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
    if (unitRank(smallest.?) < unitRank(.hour)) return realm_mod.throwRangeError(arena, "smallestUnit must be hour..nanosecond");
    const mode = try shared.getRoundingMode(arena, opts, .half_expand);
    const inc = try shared.getRoundingIncrement(arena, opts);
    const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
    const rounded = shared.roundI128ToIncrement(ins.*, inc_ns, mode);
    return makeInstant(arena, rounded);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const other = try toInstantNs(arena, if (args.len > 0) args[0] else Value{});
    return val_mod.makeBool(arena, ins.* == other);
}

// ------------------------------------------------------------------ getters ---

fn getEpochSeconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const secs = @divFloor(ins.*, shared.NS_PER_SECOND);
    return val_mod.makeNumber(arena, @floatFromInt(@as(i128, (secs))));
}
fn getEpochMilliseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const ms = @divFloor(ins.*, shared.NS_PER_MILLI);
    return val_mod.makeNumber(arena, @floatFromInt(@as(i128, (ms))));
}
fn getEpochMicroseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const us = @divFloor(ins.*, shared.NS_PER_MICRO);
    return shared.i128ToBigInt(arena, us);
}
fn getEpochNanoseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    return shared.i128ToBigInt(arena, ins.*);
}

// ------------------------------------------------------------------ toString ---

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const digits = try shared.getFractionalDigits(arena, opts);
    // timeZone option ignored (UTC).
    const s = try instantToString(arena, ins.*, digits);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    return val_mod.makeString(arena, try instantToString(arena, ins.*, null));
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireInstant(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .instant);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.Instant");
}

pub fn nativeToZonedDateTimeISO(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ins = try requireInstant(arena, this_val);
    const timezone = @import("timezone.zig");
    const zoned = @import("zoned_date_time.zig");
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
    const zone = try timezone.toZone(arena, v.unbox().string);
    return zoned.makeZoned(arena, .{ .ns = ins.*, .tz = zone.id, .offset_ns = zone.offset_ns });
}

fn instantToString(arena: std.mem.Allocator, ns: i128, digits: ?u8) ![]const u8 {
    const days: i64 = @intCast(@divFloor(ns, shared.NS_PER_DAY));
    const time_of_day: i128 = ns - @as(i128, days) * shared.NS_PER_DAY;
    const date = shared.epochDaysToISODate(days);
    const tr = shared.nanosToTime(time_of_day);
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, date.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, date.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, date.day, 2);
    try buf.append(arena, 'T');
    try shared.appendPadded(arena, &buf, tr.time.hour, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, tr.time.minute, 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, tr.time.second, 2);
    try shared.appendFraction(arena, &buf, tr.time, digits);
    try buf.append(arena, 'Z');
    return buf.items;
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethod(arena, proto, "add", nativeAdd);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);
    try intrinsics.setMethod(arena, proto, "toZonedDateTimeISO", nativeToZonedDateTimeISO);

    try intrinsics.defineGetter(arena, proto, "epochSeconds", getEpochSeconds);
    try intrinsics.defineGetter(arena, proto, "epochMilliseconds", getEpochMilliseconds);
    try intrinsics.defineGetter(arena, proto, "epochMicroseconds", getEpochMicroseconds);
    try intrinsics.defineGetter(arena, proto, "epochNanoseconds", getEpochNanoseconds);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "fromEpochSeconds", nativeFromEpochSeconds);
    try intrinsics.setMethod(arena, ctor, "fromEpochMilliseconds", nativeFromEpochMilliseconds);
    try intrinsics.setMethod(arena, ctor, "fromEpochMicroseconds", nativeFromEpochMicroseconds);
    try intrinsics.setMethod(arena, ctor, "fromEpochNanoseconds", nativeFromEpochNanoseconds);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "Instant"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.Instant"), .{ .writable = false, .enumerable = false, .configurable = true });
}
