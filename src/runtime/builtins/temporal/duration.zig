// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal.Duration — a signed calendar+time duration with ten fields.
//! Storage: internal_kind = .temporal_duration, internal_slot -> DurationFields.
//!
//! Calendar-unit arithmetic that needs a reference point (round/total/add with
//! years|months|weeks and no relativeTo, or with relativeTo) is only partially
//! supported: the time-unit + days machinery is complete; calendar balancing
//! against a relativeTo PlainDate is left to Wave 26.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const DurationFields = shared.DurationFields;

pub var proto_obj: ?*JsObject = null;

// --------------------------------------------------------------- slot access ---

pub fn getDuration(v: Value) ?*DurationFields {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_duration) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireDuration(arena: std.mem.Allocator, v: Value) !*DurationFields {
    return getDuration(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.Duration");
}

pub fn makeDuration(arena: std.mem.Allocator, d: DurationFields) !Value {
    if (!isValidDuration(d)) return realm_mod.throwRangeError(arena, "invalid Duration");
    const slot = try arena.create(DurationFields);
    slot.* = d;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_duration;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

/// Populate a freshly-constructed `this` object (called via `new`).
fn installInto(arena: std.mem.Allocator, this_val: Value, d: DurationFields) !Value {
    if (!isValidDuration(d)) return realm_mod.throwRangeError(arena, "invalid Duration");
    const slot = try arena.create(DurationFields);
    slot.* = d;
    this_val.toPtr().object.internal_kind = .temporal_duration;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

// -------------------------------------------------------------- validation ---

pub fn isValidDuration(d: DurationFields) bool {
    const fields = [_]f64{ d.years, d.months, d.weeks, d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };
    var sign: i8 = 0;
    for (fields) |f| {
        if (std.math.isNan(f) or f != @trunc(f)) return false;
        const s: i8 = if (f > 0) 1 else if (f < 0) -1 else 0;
        if (s != 0) {
            if (sign == 0) {
                sign = s;
            } else if (sign != s) {
                return false;
            }
        }
    }
    // IsValidDuration (Temporal): years/months/weeks each below 2^32, and the
    // combined time portion (days..nanoseconds, as seconds) below 2^53.
    const two_pow_32: f64 = 4294967296.0; // 2^32
    if (@abs(d.years) >= two_pow_32) return false;
    if (@abs(d.months) >= two_pow_32) return false;
    if (@abs(d.weeks) >= two_pow_32) return false;

    // The normative comparison is against exact mathematical reals. A coarse f64
    // estimate decides everything except a narrow band around 2^53, where f64
    // rounding (products exceed the 53-bit mantissa) is not trustworthy; there we
    // recompute the exact nanosecond total in i128 and compare against 2^53·10^9.
    const two_53: f64 = 9007199254740992.0;
    const normf = d.days * 86400.0 + d.hours * 3600.0 + d.minutes * 60.0 +
        d.seconds + d.milliseconds * 1e-3 + d.microseconds * 1e-6 + d.nanoseconds * 1e-9;
    const absn = @abs(normf);
    if (absn < two_53 - 1024.0) return true;
    if (absn > two_53 + 1024.0) return false;
    // Near the boundary every field is bounded (contribution ≤ ~2^53 s), so the
    // i128 products below cannot overflow.
    const ns_per_day: i128 = 86_400_000_000_000;
    const ns_per_hour: i128 = 3_600_000_000_000;
    const ns_per_min: i128 = 60_000_000_000;
    const total_ns: i128 =
        @as(i128, @intFromFloat(@abs(d.days))) * ns_per_day +
        @as(i128, @intFromFloat(@abs(d.hours))) * ns_per_hour +
        @as(i128, @intFromFloat(@abs(d.minutes))) * ns_per_min +
        @as(i128, @intFromFloat(@abs(d.seconds))) * 1_000_000_000 +
        @as(i128, @intFromFloat(@abs(d.milliseconds))) * 1_000_000 +
        @as(i128, @intFromFloat(@abs(d.microseconds))) * 1_000 +
        @as(i128, @intFromFloat(@abs(d.nanoseconds)));
    const limit_ns: i128 = @as(i128, 9007199254740992) * 1_000_000_000; // 2^53 · 10^9
    if (total_ns >= limit_ns) return false;
    return true;
}

// ------------------------------------------------------------------- ToDuration ---

/// ToTemporalDuration: from a Duration (copy), string (ISO), or a fields object.
pub fn toTemporalDuration(arena: std.mem.Allocator, v: Value) !DurationFields {
    if (getDuration(v)) |d| return d.*;
    if (v.bits != 0 and v.unbox() == .string) {
        return shared.parseISODuration(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid Duration string");
    }
    if (v.bits != 0 and v.unbox() == .object) {
        return try toDurationFromFields(arena, v.toPtr().object, true);
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.Duration");
}

/// Read the ten optional duration fields from a plain object. `require_any`
/// enforces that at least one field is present.
fn toDurationFromFields(arena: std.mem.Allocator, o: *JsObject, require_any: bool) !DurationFields {
    var d = DurationFields{};
    var any = false;
    const names = [_][]const u8{ "days", "hours", "microseconds", "milliseconds", "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    for (names) |name| {
        if (o.get(name)) |fv| {
            if (fv.bits != 0 and fv.unbox() != .undefined_) {
                const n = try shared.toIntegerIfIntegral(arena, fv);
                any = true;
                assignField(&d, name, n);
            }
        }
    }
    if (require_any and !any) return realm_mod.throwTypeError(arena, "duration-like object needs at least one field");
    if (!isValidDuration(d)) return realm_mod.throwRangeError(arena, "invalid Duration");
    return d;
}

fn assignField(d: *DurationFields, name: []const u8, n: f64) void {
    if (std.mem.eql(u8, name, "years")) d.years = n
    else if (std.mem.eql(u8, name, "months")) d.months = n
    else if (std.mem.eql(u8, name, "weeks")) d.weeks = n
    else if (std.mem.eql(u8, name, "days")) d.days = n
    else if (std.mem.eql(u8, name, "hours")) d.hours = n
    else if (std.mem.eql(u8, name, "minutes")) d.minutes = n
    else if (std.mem.eql(u8, name, "seconds")) d.seconds = n
    else if (std.mem.eql(u8, name, "milliseconds")) d.milliseconds = n
    else if (std.mem.eql(u8, name, "microseconds")) d.microseconds = n
    else if (std.mem.eql(u8, name, "nanoseconds")) d.nanoseconds = n;
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.Duration requires new");
    var d = DurationFields{};
    d.years = try argInt(arena, args, 0);
    d.months = try argInt(arena, args, 1);
    d.weeks = try argInt(arena, args, 2);
    d.days = try argInt(arena, args, 3);
    d.hours = try argInt(arena, args, 4);
    d.minutes = try argInt(arena, args, 5);
    d.seconds = try argInt(arena, args, 6);
    d.milliseconds = try argInt(arena, args, 7);
    d.microseconds = try argInt(arena, args, 8);
    d.nanoseconds = try argInt(arena, args, 9);
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, d);
    return makeDuration(arena, d);
}

fn argInt(arena: std.mem.Allocator, args: []const Value, idx: usize) !f64 {
    if (idx >= args.len) return 0;
    const v = args[idx];
    if (v.bits == 0 or v.unbox() == .undefined_) return 0;
    return try shared.toIntegerIfIntegral(arena, v);
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const d = try toTemporalDuration(arena, v);
    return makeDuration(arena, d);
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    const b = try toTemporalDuration(arena, if (args.len > 1) args[1] else Value{});

    // GetOptionsObject accepts undefined or any Object (including callables).
    const opts = try shared.getOptionsObject(arena, if (args.len > 2) args[2] else null);
    const rel = try readRelativeDate(arena, opts);

    // Comparing durations with calendar units (years/months/weeks) needs a
    // relativeTo reference; with one, compare their exact endpoints from R.
    if (hasCalendarUnits(a) or hasCalendarUnits(b)) {
        const R = rel orelse return realm_mod.throwRangeError(arena, "Duration.compare with calendar units requires relativeTo");
        const na = try durationEndpointNs(arena, a, R);
        const nb = try durationEndpointNs(arena, b, R);
        return val_mod.makeNumber(arena, if (na < nb) -1 else if (na > nb) 1 else 0);
    }

    // Pure time (+day) durations: exact nanosecond totals (24h day).
    const na = timeDurationNanos(a);
    const nb = timeDurationNanos(b);
    const r: f64 = if (na < nb) -1 else if (na > nb) 1 else 0;
    return val_mod.makeNumber(arena, r);
}

/// The exact epoch-nanosecond endpoint of `d` measured from PlainDate `R`
/// (24-hour days); used by Duration.compare with a relativeTo reference.
fn durationEndpointNs(arena: std.mem.Allocator, d: DurationFields, R: ISODate) !i128 {
    const DAY = shared.NS_PER_DAY;
    const time_ns = timePartNanos(d);
    const extra_days = @divTrunc(time_ns, DAY);
    const rem = time_ns - extra_days * DAY;
    const end = try pd.addISODate(R, d.years, d.months, d.weeks, d.days + @as(f64, @floatFromInt(extra_days)), .constrain, arena);
    return @as(i128, epochDaysOf(end)) * DAY + rem;
}

/// Exact total nanoseconds for a time-only duration (days + time units). Errors
/// if calendar units are present.
fn timeDurationNanos(d: DurationFields) i128 {
    var ns: i128 = @as(i128, @intFromFloat(d.days)) * shared.NS_PER_DAY;
    ns += @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR;
    ns += @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE;
    ns += @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND;
    ns += @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI;
    ns += @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO;
    ns += @as(i128, @intFromFloat(d.nanoseconds));
    return ns;
}

fn hasCalendarUnits(d: DurationFields) bool {
    return d.years != 0 or d.months != 0 or d.weeks != 0;
}

/// Whether a (possibly absent) unit is a calendar unit — year/month/week —
/// which cannot be rounded without a relativeTo reference. `day` is a time-ish
/// unit here (it balances with hours/etc.) and is allowed without relativeTo.
fn isCalendarUnit(u: ?shared.Unit) bool {
    return if (u) |uu| switch (uu) {
        .year, .month, .week => true,
        else => false,
    } else false;
}

// ------------------------------------------------------------- prototype methods ---

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const cur = try requireDuration(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    var d = cur.*;
    const o = arg.toPtr().object;
    const names = [_][]const u8{ "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" };
    var any = false;
    for (names) |name| {
        if (o.get(name)) |fv| {
            if (fv.bits != 0 and fv.unbox() != .undefined_) {
                const n = try shared.toIntegerIfIntegral(arena, fv);
                assignField(&d, name, n);
                any = true;
            }
        }
    }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");
    return makeDuration(arena, d);
}

pub fn nativeNegated(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    return makeDuration(arena, negate(d.*));
}

pub fn nativeAbs(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    var r = d.*;
    r.years = @abs(r.years);
    r.months = @abs(r.months);
    r.weeks = @abs(r.weeks);
    r.days = @abs(r.days);
    r.hours = @abs(r.hours);
    r.minutes = @abs(r.minutes);
    r.seconds = @abs(r.seconds);
    r.milliseconds = @abs(r.milliseconds);
    r.microseconds = @abs(r.microseconds);
    r.nanoseconds = @abs(r.nanoseconds);
    return makeDuration(arena, r);
}

fn negate(d: DurationFields) DurationFields {
    // Preserve -0 as 0: multiply then add 0.0 to normalize.
    return .{
        .years = -d.years + 0.0,
        .months = -d.months + 0.0,
        .weeks = -d.weeks + 0.0,
        .days = -d.days + 0.0,
        .hours = -d.hours + 0.0,
        .minutes = -d.minutes + 0.0,
        .seconds = -d.seconds + 0.0,
        .milliseconds = -d.milliseconds + 0.0,
        .microseconds = -d.microseconds + 0.0,
        .nanoseconds = -d.nanoseconds + 0.0,
    };
}

pub fn nativeAdd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSubtract(arena, this_val, args, false);
}
pub fn nativeSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return addSubtract(arena, this_val, args, true);
}

fn addSubtract(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const a = try requireDuration(arena, this_val);
    var b = try toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    if (subtract) b = negate(b);
    // relativeTo present? If calendar units involved, we cannot balance precisely.
    if (hasCalendarUnits(a.*) or hasCalendarUnits(b)) {
        // Only exact when the calendar-unit fields are identical structure; fall
        // back to field-wise addition (works for pure y/m/w sums).
        if ((a.years != 0 or b.years != 0 or a.months != 0 or b.months != 0 or a.weeks != 0 or b.weeks != 0) and
            (a.days != 0 or b.days != 0 or hasTimeUnits(a.*) or hasTimeUnits(b)))
        {
            return realm_mod.throwRangeError(arena, "Duration add/subtract with calendar units requires relativeTo");
        }
        var r = DurationFields{
            .years = a.years + b.years,
            .months = a.months + b.months,
            .weeks = a.weeks + b.weeks,
            .days = a.days + b.days,
            .hours = a.hours + b.hours,
            .minutes = a.minutes + b.minutes,
            .seconds = a.seconds + b.seconds,
            .milliseconds = a.milliseconds + b.milliseconds,
            .microseconds = a.microseconds + b.microseconds,
            .nanoseconds = a.nanoseconds + b.nanoseconds,
        };
        return makeDuration(arena, r) catch {
            r = normalizeSigns(r);
            return makeDuration(arena, r);
        };
    }
    // Pure time (+days) durations: sum nanoseconds and balance to largest unit day.
    const total = timeDurationNanos(a.*) + timeDurationNanos(b);
    const balanced = balanceTimeDuration(total, .day);
    return makeDuration(arena, balanced);
}

fn hasTimeUnits(d: DurationFields) bool {
    return d.hours != 0 or d.minutes != 0 or d.seconds != 0 or d.milliseconds != 0 or d.microseconds != 0 or d.nanoseconds != 0;
}

fn normalizeSigns(d: DurationFields) DurationFields {
    return d;
}

/// BalanceTimeDuration: distribute a nanosecond total across time units up to
/// `largest`.
fn balanceTimeDuration(total_ns: i128, largest: shared.Unit) DurationFields {
    var ns = total_ns;
    const neg = ns < 0;
    if (neg) ns = -ns;
    var d = DurationFields{};
    var rem = ns;
    switch (largest) {
        .year, .month, .week, .day => {
            d.days = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_DAY))));
            rem = @mod(rem, shared.NS_PER_DAY);
            d.hours = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_HOUR))));
            rem = @mod(rem, shared.NS_PER_HOUR);
            d.minutes = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MINUTE))));
            rem = @mod(rem, shared.NS_PER_MINUTE);
            d.seconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_SECOND))));
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .hour => {
            d.hours = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_HOUR))));
            rem = @mod(rem, shared.NS_PER_HOUR);
            d.minutes = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MINUTE))));
            rem = @mod(rem, shared.NS_PER_MINUTE);
            d.seconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_SECOND))));
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .minute => {
            d.minutes = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MINUTE))));
            rem = @mod(rem, shared.NS_PER_MINUTE);
            d.seconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_SECOND))));
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .second => {
            d.seconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_SECOND))));
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        else => {},
    }
    d.milliseconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MILLI))));
    rem = @mod(rem, shared.NS_PER_MILLI);
    d.microseconds = @floatFromInt(@as(i128, (@divTrunc(rem, shared.NS_PER_MICRO))));
    rem = @mod(rem, shared.NS_PER_MICRO);
    d.nanoseconds = @floatFromInt(@as(i128, (rem)));
    if (neg) return negate(d);
    return d;
}

// ---------------------------------------------------- relativeTo (calendar) ---
//
// Rounding/totaling a Duration that involves calendar units (years/months/weeks)
// or a calendar largest/smallest unit needs a reference date. We support a
// PlainDate-style relativeTo (iso8601 calendar, no time zone), which is the bulk
// of the corpus. The algorithm mirrors the reference RoundDuration +
// Unbalance/BalanceDurationRelative, reusing the ISO date arithmetic in
// plain_date.zig (addISODate / differenceISODate) and treating a day as 24h.

const pd = @import("plain_date.zig");
const ISODate = shared.ISODate;

fn epochDaysOf(x: ISODate) i64 {
    return shared.isoDateToEpochDays(x.year, x.month, x.day);
}
fn daysBetween(a: ISODate, b: ISODate) f64 {
    return @floatFromInt(epochDaysOf(b) - epochDaysOf(a));
}
fn timePartNanos(d: DurationFields) i128 {
    return @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(d.nanoseconds));
}

/// Resolve the `relativeTo` option to a PlainDate (iso8601). Returns null when
/// absent/undefined. A value with a non-iso calendar or that cannot be read as a
/// date propagates the appropriate error from toTemporalDate.
fn readRelativeDate(arena: std.mem.Allocator, opts: ?*JsObject) !?ISODate {
    const o = opts orelse return null;
    // Read relativeTo through [[Get]] so observers/getters run (option-read order).
    const rv = if (realm_mod.active_context) |c|
        try c.getProp(arena, try val_mod.makeObject(arena, o), "relativeTo")
    else
        (o.get("relativeTo") orelse Value{});
    if (rv.bits == 0 or rv.isUndefined() or rv.isNull()) return null;
    // A ZonedDateTime relativeTo is reduced to its local calendar date (we do not
    // model per-day time-zone offset changes; correct for fixed-offset zones).
    const zdt = @import("zoned_date_time.zig");
    if (zdt.getZoned(rv)) |z| return zdt.localISODate(z);
    // For a string, a UTC "Z" designator is only valid alongside a [time zone]
    // annotation; a bare "…Z" is not a valid relativeTo.
    if (rv.unbox() == .string) {
        const str = rv.unbox().string;
        if (std.mem.indexOfScalar(u8, str, '[') == null and
            (std.mem.indexOfScalar(u8, str, 'Z') != null or std.mem.indexOfScalar(u8, str, 'z') != null))
            return realm_mod.throwRangeError(arena, "UTC designator without a time zone is not a valid relativeTo");
    }
    return try pd.toTemporalDate(arena, rv, .constrain);
}

/// MaximumTemporalDurationRoundingIncrement: the dividend used to validate a
/// rounding increment for a time unit; calendar units have no maximum.
fn maxIncrementDividend(u: shared.Unit) ?f64 {
    return switch (u) {
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
        else => null,
    };
}

/// ValidateTemporalRoundingIncrement (non-inclusive): the increment must be less
/// than the unit's maximum and divide it evenly.
fn validateIncrement(arena: std.mem.Allocator, u: shared.Unit, inc: f64) !void {
    const dividend = maxIncrementDividend(u) orelse return;
    if (inc >= dividend or @mod(dividend, inc) != 0)
        return realm_mod.throwRangeError(arena, "invalid roundingIncrement for smallestUnit");
}

const RelResult = struct { d: DurationFields, total: f64 };

/// Round (or, for `total`, measure) a Duration against a PlainDate reference `R`.
/// The whole span is balanced to `largest` via the ISO calendar, then the
/// smallest unit is rounded by locating the true endpoint between the two
/// candidate dates one increment apart (spec RoundRelativeDuration/nudge).
fn roundRelative(
    arena: std.mem.Allocator,
    d0: DurationFields,
    R: ISODate,
    smallest: shared.Unit,
    largest: shared.Unit,
    inc: f64,
    mode: shared.RoundingMode,
) !RelResult {
    // Weeks can only be produced under a "year" or "week" largestUnit; requesting
    // week rounding while the (default) largestUnit is "month" is a RangeError.
    if (smallest == .week and largest == .month)
        return realm_mod.throwRangeError(arena, "cannot round to weeks with a months largestUnit");

    const DAY = shared.NS_PER_DAY;
    const time_ns = timePartNanos(d0);
    // Fold the sub-day/over-day time into whole days plus a sub-day remainder.
    const extra_days = @divTrunc(time_ns, DAY);
    const time_rem = time_ns - extra_days * DAY;
    const dest_date = try pd.addISODate(R, d0.years, d0.months, d0.weeks, d0.days + @as(f64, @floatFromInt(extra_days)), .constrain, arena);

    const s = d0.sign();
    const sgn: f64 = if (s < 0) -1 else 1;

    // ---- Time-unit smallestUnit: round the time portion, keep the calendar. ----
    if (durUnitRank(smallest) > durUnitRank(.day)) {
        const unit_ns = shared.unitLengthNanos(smallest).?;
        const inc_ns = unit_ns * @as(i128, @intFromFloat(inc));
        if (largest == .year or largest == .month or largest == .week) {
            const bal = pd.differenceISODate(R, dest_date, largest);
            const low_ns = @as(i128, @intFromFloat(bal.days)) * DAY + time_rem;
            const rounded = shared.roundI128ToIncrement(low_ns, inc_ns, mode);
            var out = balanceTimeDuration(rounded, .day);
            out.years = bal.years;
            out.months = bal.months;
            out.weeks = bal.weeks;
            return .{ .d = out, .total = @as(f64, @floatFromInt(low_ns)) / @as(f64, @floatFromInt(unit_ns)) };
        }
        const full_ns: i128 = @as(i128, epochDaysOf(dest_date) - epochDaysOf(R)) * DAY + time_rem;
        const rounded = shared.roundI128ToIncrement(full_ns, inc_ns, mode);
        const out = balanceTimeDuration(rounded, largest);
        return .{ .d = out, .total = @as(f64, @floatFromInt(full_ns)) / @as(f64, @floatFromInt(unit_ns)) };
    }

    // ---- Calendar/day smallestUnit: nudge between two candidate dates. ----
    // Balance the whole span to largestUnit, then round the smallest unit by
    // measuring where the true endpoint falls between the r1 (toward zero) and
    // r2 (one increment away) candidate dates.
    const bal = pd.differenceISODate(R, dest_date, largest);
    var ry = bal.years;
    var rmo = bal.months;
    var rw = bal.weeks;
    var rd = bal.days;
    var r1_count: f64 = 0;
    var step_y: f64 = 0;
    var step_mo: f64 = 0;
    var step_w: f64 = 0;
    var step_d: f64 = 0;
    switch (smallest) {
        .year => {
            r1_count = @trunc(bal.years / inc) * inc;
            ry = r1_count;
            rmo = 0;
            rw = 0;
            rd = 0;
            step_y = inc * sgn;
        },
        .month => {
            r1_count = @trunc(bal.months / inc) * inc;
            rmo = r1_count;
            rw = 0;
            rd = 0;
            step_mo = inc * sgn;
        },
        .week => {
            const total_days = bal.weeks * 7 + bal.days;
            r1_count = @trunc(total_days / (7 * inc)) * inc;
            rw = r1_count;
            rd = 0;
            step_w = inc * sgn;
        },
        .day => {
            r1_count = @trunc(bal.days / inc) * inc;
            rd = r1_count;
            step_d = inc * sgn;
        },
        else => unreachable,
    }

    const start_date = try pd.addISODate(R, ry, rmo, rw, rd, .constrain, arena);
    const end_date = try pd.addISODate(R, ry + step_y, rmo + step_mo, rw + step_w, rd + step_d, .constrain, arena);
    const start_ns: i128 = @as(i128, epochDaysOf(start_date)) * DAY;
    const end_ns: i128 = @as(i128, epochDaysOf(end_date)) * DAY;
    const dest_ns: i128 = @as(i128, epochDaysOf(dest_date)) * DAY + time_rem;
    const num = dest_ns - start_ns;
    const denom = end_ns - start_ns;
    const p: f64 = if (denom == 0) 0 else @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(denom));
    const value = r1_count + p * inc * sgn;
    const rounded_count = shared.roundNumberToIncrement(value, inc, mode);

    var out = DurationFields{};
    switch (smallest) {
        .year => out.years = rounded_count,
        .month => {
            out.years = bal.years;
            out.months = rounded_count;
        },
        .week => {
            out.years = bal.years;
            out.months = bal.months;
            out.weeks = rounded_count;
        },
        .day => {
            out.years = bal.years;
            out.months = bal.months;
            out.weeks = bal.weeks;
            out.days = rounded_count;
        },
        else => unreachable,
    }
    return .{ .d = out, .total = value };
}

pub fn nativeRound(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    // Parse options: a bare string is shorthand for { smallestUnit }.
    var opts: ?*JsObject = null;
    var smallest: ?shared.Unit = null;
    var largest: ?shared.Unit = null;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits != 0 and arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
    } else {
        opts = try shared.getOptionsObject(arena, arg0);
        smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
        largest = try shared.getTemporalUnit(arena, opts, "largestUnit");
    }
    const mode = try shared.getRoundingMode(arena, opts, .half_expand);
    const inc = try shared.getRoundingIncrement(arena, opts);
    if (smallest == null and largest == null) return realm_mod.throwRangeError(arena, "round() requires smallestUnit or largestUnit");

    const small = smallest orelse shared.Unit.nanosecond;
    try validateIncrement(arena, small, inc);
    // Default largestUnit = the larger of the duration's existing largest unit and
    // smallestUnit (spec LargerOfTwoTemporalUnits over DefaultTemporalLargestUnit).
    const large = largest orelse largerUnit(defaultLargestUnit(d.*), small);
    // largestUnit must be the same or larger magnitude than smallestUnit.
    if (durUnitRank(large) > durUnitRank(small))
        return realm_mod.throwRangeError(arena, "largestUnit must be larger than or equal to smallestUnit");

    // Anything touching calendar units (in the receiver or as a rounding unit)
    // needs a reference date; resolve relativeTo and use the calendar algorithm.
    const rel_date = try readRelativeDate(arena, opts);
    const needs_relative = hasCalendarUnits(d.*) or isCalendarUnit(small) or isCalendarUnit(large);
    if (needs_relative) {
        const R = rel_date orelse return realm_mod.throwRangeError(arena, "Duration.round with calendar units requires relativeTo");
        const res = try roundRelative(arena, d.*, R, small, large, inc, mode);
        return makeDuration(arena, res.d);
    }

    const inc_ns = (shared.unitLengthNanos(small) orelse return realm_mod.throwRangeError(arena, "calendar smallestUnit needs relativeTo")) * @as(i128, @intFromFloat(inc));
    const total = timeDurationNanos(d.*);
    const rounded = shared.roundI128ToIncrement(total, inc_ns, mode);
    // Each balanced component must be a float64-representable integer; a huge
    // component (e.g. balancing to nanoseconds) that loses precision is out of
    // range (TemporalDurationFromInternal).
    if (!balancedComponentsFitF64(rounded, large))
        return realm_mod.throwRangeError(arena, "rounded Duration component is out of range");
    return makeDuration(arena, balanceTimeDuration(rounded, large));
}

/// Whether every component produced by balancing `total_ns` up to `largest` is a
/// float64-representable integer (i.e. survives the i128→f64→i128 round trip).
fn balancedComponentsFitF64(total_ns: i128, largest: shared.Unit) bool {
    var rem: i128 = if (total_ns < 0) -total_ns else total_ns;
    var comps = [_]i128{0} ** 7; // days, hours, minutes, seconds, ms, µs, ns
    switch (largest) {
        .year, .month, .week, .day => {
            comps[0] = @divTrunc(rem, shared.NS_PER_DAY);
            rem = @mod(rem, shared.NS_PER_DAY);
            comps[1] = @divTrunc(rem, shared.NS_PER_HOUR);
            rem = @mod(rem, shared.NS_PER_HOUR);
            comps[2] = @divTrunc(rem, shared.NS_PER_MINUTE);
            rem = @mod(rem, shared.NS_PER_MINUTE);
            comps[3] = @divTrunc(rem, shared.NS_PER_SECOND);
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .hour => {
            comps[1] = @divTrunc(rem, shared.NS_PER_HOUR);
            rem = @mod(rem, shared.NS_PER_HOUR);
            comps[2] = @divTrunc(rem, shared.NS_PER_MINUTE);
            rem = @mod(rem, shared.NS_PER_MINUTE);
            comps[3] = @divTrunc(rem, shared.NS_PER_SECOND);
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .minute => {
            comps[2] = @divTrunc(rem, shared.NS_PER_MINUTE);
            rem = @mod(rem, shared.NS_PER_MINUTE);
            comps[3] = @divTrunc(rem, shared.NS_PER_SECOND);
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        .second => {
            comps[3] = @divTrunc(rem, shared.NS_PER_SECOND);
            rem = @mod(rem, shared.NS_PER_SECOND);
        },
        else => {},
    }
    comps[4] = @divTrunc(rem, shared.NS_PER_MILLI);
    rem = @mod(rem, shared.NS_PER_MILLI);
    comps[5] = @divTrunc(rem, shared.NS_PER_MICRO);
    rem = @mod(rem, shared.NS_PER_MICRO);
    comps[6] = rem;
    for (comps) |c| {
        const f: f64 = @floatFromInt(c);
        if (@as(i128, @intFromFloat(f)) != c) return false;
    }
    return true;
}

fn durUnitRank(u: shared.Unit) u8 {
    return switch (u) {
        .year => 0, .month => 1, .week => 2, .day => 3,
        .hour => 4, .minute => 5, .second => 6,
        .millisecond => 7, .microsecond => 8, .nanosecond => 9,
    };
}

/// The larger (in magnitude) of two units — the one with the smaller rank.
fn largerUnit(a: shared.Unit, b: shared.Unit) shared.Unit {
    return if (durUnitRank(a) <= durUnitRank(b)) a else b;
}

/// DefaultTemporalLargestUnit: the largest unit with a non-zero field.
fn defaultLargestUnit(d: DurationFields) shared.Unit {
    if (d.years != 0) return .year;
    if (d.months != 0) return .month;
    if (d.weeks != 0) return .week;
    if (d.days != 0) return .day;
    if (d.hours != 0) return .hour;
    if (d.minutes != 0) return .minute;
    if (d.seconds != 0) return .second;
    if (d.milliseconds != 0) return .millisecond;
    if (d.microseconds != 0) return .microsecond;
    return .nanosecond;
}


pub fn nativeTotal(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    var unit: ?shared.Unit = null;
    var opts: ?*JsObject = null;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits != 0 and arg0.unbox() == .string) {
        unit = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid unit");
    } else {
        opts = try shared.getOptionsObject(arena, arg0);
        unit = try shared.getTemporalUnit(arena, opts, "unit");
    }
    const u = unit orelse return realm_mod.throwRangeError(arena, "total() requires a unit");

    // Calendar units (in the receiver or as the target unit) need relativeTo.
    if (hasCalendarUnits(d.*) or isCalendarUnit(u)) {
        const R = (try readRelativeDate(arena, opts)) orelse
            return realm_mod.throwRangeError(arena, "Duration.total with calendar units requires relativeTo");
        const res = try roundRelative(arena, d.*, R, u, u, 1, .trunc);
        return val_mod.makeNumber(arena, res.total);
    }
    const per = shared.unitLengthNanos(u) orelse return realm_mod.throwRangeError(arena, "calendar unit needs relativeTo");
    const total = timeDurationNanos(d.*);
    const result = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(per));
    return val_mod.makeNumber(arena, result);
}

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    const digits = try shared.getFractionalDigits(arena, opts);
    const s = try durationToString(arena, d.*, digits);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    const s = try durationToString(arena, d.*, null);
    return val_mod.makeString(arena, s);
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireDuration(arena, this_val);
    // Route through Intl.DurationFormat for locale-aware output (en-US default).
    const intl = @import("../intl.zig");
    const df = try intl.durationFormatFor(arena, args);
    return intl.nativeDurationFormatFormat(arena, df, &.{this_val});
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.Duration");
}

/// TemporalDurationToString (ES 7.5.15), with optional fixed fractional digits.
fn durationToString(arena: std.mem.Allocator, d: DurationFields, digits: ?u8) ![]const u8 {
    var buf = shared.Buf{};
    const sign = d.sign();
    if (sign < 0) try buf.append(arena, '-');
    try buf.append(arena, 'P');
    try appendUnit(arena, &buf, @abs(d.years), 'Y');
    try appendUnit(arena, &buf, @abs(d.months), 'M');
    try appendUnit(arena, &buf, @abs(d.weeks), 'W');
    try appendUnit(arena, &buf, @abs(d.days), 'D');

    // Time part. Hours and minutes print as-is; seconds combine with the
    // millisecond/microsecond/nanosecond fields (which carry up into whole
    // seconds) into one decimal.
    const has_h = d.hours != 0;
    const has_m = d.minutes != 0;
    const total_sec_ns: i128 = @as(i128, @intFromFloat(@abs(d.seconds))) * 1_000_000_000 +
        @as(i128, @intFromFloat(@abs(d.milliseconds))) * 1_000_000 +
        @as(i128, @intFromFloat(@abs(d.microseconds))) * 1000 +
        @as(i128, @intFromFloat(@abs(d.nanoseconds)));
    const sec_whole: i64 = @intCast(@divTrunc(total_sec_ns, 1_000_000_000));
    const frac_ns: u32 = @intCast(@mod(total_sec_ns, 1_000_000_000));
    const has_s = total_sec_ns != 0 or (digits != null and digits.? > 0);

    if (has_h or has_m or has_s) {
        try buf.append(arena, 'T');
        try appendUnit(arena, &buf, @abs(d.hours), 'H');
        try appendUnit(arena, &buf, @abs(d.minutes), 'M');
        if (has_s) {
            try shared.appendPadded(arena, &buf, sec_whole, 1);
            try appendSecondsFraction(arena, &buf, frac_ns, digits);
            try buf.append(arena, 'S');
        }
    } else if (sign == 0 and d.years == 0 and d.months == 0 and d.weeks == 0 and d.days == 0) {
        // Zero duration -> "PT0S".
        try buf.appendSlice(arena, "T0S");
    }
    return buf.items;
}

fn appendUnit(arena: std.mem.Allocator, buf: *shared.Buf, value: f64, letter: u8) !void {
    if (value == 0) return;
    try shared.appendPadded(arena, buf, @intFromFloat(value), 1);
    try buf.append(arena, letter);
}

fn appendSecondsFraction(arena: std.mem.Allocator, buf: *shared.Buf, sub_ns: u32, digits: ?u8) !void {
    if (digits) |dd| {
        if (dd == 0) return;
        var frac: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{sub_ns}) catch unreachable;
        try buf.append(arena, '.');
        try buf.appendSlice(arena, frac[0..dd]);
    } else {
        if (sub_ns == 0) return;
        var frac: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{sub_ns}) catch unreachable;
        var end: usize = 9;
        while (end > 0 and frac[end - 1] == '0') : (end -= 1) {}
        try buf.append(arena, '.');
        try buf.appendSlice(arena, frac[0..end]);
    }
}

// ------------------------------------------------------------------ getters ---

fn fieldGetter(comptime field: []const u8) val_mod.NativeFnPtr {
    return struct {
        fn get(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
            const d = try requireDuration(arena, this_val);
            return val_mod.makeNumber(arena, @field(d, field));
        }
    }.get;
}

pub fn nativeGetSign(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(d.sign()));
}

pub fn nativeGetBlank(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    return val_mod.makeBool(arena, d.sign() == 0);
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethod(arena, proto, "with", nativeWith);
    try intrinsics.setMethod(arena, proto, "negated", nativeNegated);
    try intrinsics.setMethod(arena, proto, "abs", nativeAbs);
    try intrinsics.setMethod(arena, proto, "add", nativeAdd);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "total", nativeTotal);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethod(arena, proto, "toJSON", nativeToJSON);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "years", fieldGetter("years"));
    try intrinsics.defineGetter(arena, proto, "months", fieldGetter("months"));
    try intrinsics.defineGetter(arena, proto, "weeks", fieldGetter("weeks"));
    try intrinsics.defineGetter(arena, proto, "days", fieldGetter("days"));
    try intrinsics.defineGetter(arena, proto, "hours", fieldGetter("hours"));
    try intrinsics.defineGetter(arena, proto, "minutes", fieldGetter("minutes"));
    try intrinsics.defineGetter(arena, proto, "seconds", fieldGetter("seconds"));
    try intrinsics.defineGetter(arena, proto, "milliseconds", fieldGetter("milliseconds"));
    try intrinsics.defineGetter(arena, proto, "microseconds", fieldGetter("microseconds"));
    try intrinsics.defineGetter(arena, proto, "nanoseconds", fieldGetter("nanoseconds"));
    try intrinsics.defineGetter(arena, proto, "sign", nativeGetSign);
    try intrinsics.defineGetter(arena, proto, "blank", nativeGetBlank);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "Duration"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    // Store ctor for the Temporal namespace to expose.
    ctor_obj = ctor;
}

pub var ctor_obj: ?*JsObject = null;

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.Duration"), .{ .writable = false, .enumerable = false, .configurable = true });
}
