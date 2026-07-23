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
const plain_time = @import("plain_time.zig");

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
    // The constructor's argument goes through ToBigInt (string/boolean accepted).
    const big = try shared.toBigInt(arena, arg);
    const ns = shared.bigIntToI128(big) orelse return realm_mod.throwRangeError(arena, "Instant out of range");
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "Instant out of range");
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, ns);
    return makeInstant(arena, ns);
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (getInstant(v)) |ins| return makeInstant(arena, ins.*);
    // Fast path: a ZonedDateTime carries the epoch nanoseconds directly.
    const zdt = @import("zoned_date_time.zig");
    if (zdt.getZoned(v)) |z| return makeInstant(arena, z.ns);
    if (v.bits != 0 and v.unbox() == .string) {
        const ns = try parseInstantString(arena, v.unbox().string);
        return makeInstant(arena, ns);
    }
    // ToTemporalInstant: a non-Temporal object is coerced with ToPrimitive(string)
    // and the result parsed as an ISO string (so an ordinary object becomes
    // "[object Object]" → RangeError, but an Instant-like object with a useful
    // toString parses). Any non-string value is a TypeError.
    if (v.bits != 0 and v.unbox() == .object) {
        const s = try shared.toPrimitiveRequireString(arena, v);
        return makeInstant(arena, try parseInstantString(arena, s));
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.Instant");
}

/// Parse an ISO datetime with a mandatory UTC designator or numeric offset into
/// epoch nanoseconds.
fn parseInstantString(arena: std.mem.Allocator, s0: []const u8) !i128 {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    // Find the offset: 'Z'/'z' or a +/- after the time. We parse the datetime and
    // separately extract the offset.
    const dt = shared.parseISODateTimeOpts(s, .{ .validate_calendar = false, .reject_utc = false }) catch return realm_mod.throwRangeError(arena, "invalid Instant string");
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
    // Sub-second offset fraction (up to 9 digits → nanoseconds). Needed to
    // represent boundary offsets like "-23:59:59.999999999".
    var frac_ns: i128 = 0;
    if (idx < s.len and (s[idx] == '.' or s[idx] == ',')) {
        idx += 1;
        var scale: i128 = 100_000_000; // first digit = 100ms in ns
        while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') : (idx += 1) {
            frac_ns += @as(i128, s[idx] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    // A UTC offset's components have the same bounds as a clock: an out-of-range
    // hour/minute/second (e.g. "-24:00") makes the whole string invalid.
    if (h > 23 or m > 59 or sec > 59) return null;
    return sign * (h * shared.NS_PER_HOUR + m * shared.NS_PER_MINUTE + sec * shared.NS_PER_SECOND + frac_ns);
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
    // ToNumber throws a TypeError for BigInt and Symbol (before any range check).
    if (v.bits != 0 and (v.unbox() == .bigint or v.unbox() == .symbol))
        return realm_mod.throwTypeError(arena, "cannot convert to a Number");
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
    const zdt = @import("zoned_date_time.zig");
    if (zdt.getZoned(v)) |z| return z.ns;
    // ToTemporalInstant: any other value is coerced to a primitive with the
    // string hint and must be a String (ToPrimitiveAndRequireString), then
    // parsed — an object like {} yields "[object Object]" and a RangeError, a
    // bare number yields a TypeError before parsing.
    const str = try shared.toPrimitiveRequireString(arena, v);
    return try parseInstantString(arena, str);
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
    const st = try shared.getDifferenceSettings(arena, opts, since, .time, &.{}, .nanosecond, .second);

    const diff = other - ins.*;
    const inc_ns = shared.unitLengthNanos(st.smallest).? * @as(i128, @intFromFloat(st.increment));
    const rounded = shared.roundI128ToIncrement(diff, inc_ns, st.mode);
    const balanced = balanceTime(rounded, st.largest);
    return duration.makeDuration(arena, if (since) shared.negateFields(balanced) else balanced);
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
    if (unitRank(smallest.?) < unitRank(.hour)) return realm_mod.throwRangeError(arena, "smallestUnit must be hour..nanosecond");
    // An Instant rounds within a day, so the increment's maximum is that unit's
    // count per day (inclusive): e.g. hours→24, minutes→1440, ns→86400·10⁹.
    const unit_ns = shared.unitLengthNanos(smallest.?).?;
    const per_day: f64 = @floatFromInt(@divTrunc(shared.NS_PER_DAY, unit_ns));
    try shared.validateRoundingIncrement(arena, inc, per_day, true);
    const inc_ns = unit_ns * @as(i128, @intFromFloat(inc));
    // Rounding modes apply as if the epoch were positive, so "trunc"/"floor" go
    // towards the Big Bang (−∞), not towards the epoch.
    const rounded = shared.roundI128ToIncrementAsIfPositive(ins.*, inc_ns, mode);
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
    // All options are read before any algorithmic validation: fractionalSecond-
    // Digits, roundingMode, smallestUnit, then timeZone. The "smallestUnit is
    // hour" rejection happens only after timeZone has been read, so the unit is
    // read raw here and validated afterwards.
    const digits = try shared.getFractionalDigits(arena, opts);
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const unit = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    const tz_v: ?Value = if (opts) |o| try shared.optionGet(arena, o, "timeZone") else null;
    const prec = try shared.secondsPrecisionFromUnit(arena, unit, digits);
    // Rounding is on the epoch nanoseconds, so a carry past midnight moves the
    // date for free. The modes read as if the instant were positive.
    const ns = shared.roundI128ToIncrementAsIfPositive(ins.*, prec.increment, mode);
    if (tz_v) |v| {
        if (v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
        const timezone = @import("timezone.zig");
        const zone = try timezone.toZoneAtInstant(arena, v.unbox().string, ns);
        const s = try instantToStringPrec(arena, ns + zone.offset_ns, prec);
        var buf = shared.Buf{};
        try buf.appendSlice(arena, s[0 .. s.len - 1]); // drop the "Z"
        try buf.appendSlice(arena, try timezone.formatOffset(arena, zone.offset_ns));
        return val_mod.makeString(arena, buf.items);
    }
    return val_mod.makeString(arena, try instantToStringPrec(arena, ns, prec));
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
    return instantToStringPrec(arena, ns, .{ .digits = digits });
}

fn instantToStringPrec(arena: std.mem.Allocator, ns: i128, prec: shared.SecondsPrecision) ![]const u8 {
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
    try buf.appendSlice(arena, try plain_time.timeToStringPrec(arena, tr.time, prec));
    try buf.append(arena, 'Z');
    return buf.items;
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethodLen(arena, proto, "add", nativeAdd, 1);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
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
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "Instant"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.Instant"), .{ .writable = false, .enumerable = false, .configurable = true });
}
