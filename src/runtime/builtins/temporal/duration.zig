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

pub fn makeDuration(arena: std.mem.Allocator, d0: DurationFields) !Value {
    const d = shared.normalizeZeroFields(d0);
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
fn installInto(arena: std.mem.Allocator, this_val: Value, d0: DurationFields) !Value {
    const d = shared.normalizeZeroFields(d0);
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

    // The normative comparison is against exact mathematical reals, and an f64
    // estimate of the nanosecond total is not trustworthy anywhere near the
    // limit (the intermediate products blow past the 53-bit mantissa). So sum
    // exactly: every field is an integer-valued f64, hence exactly an integer,
    // and any single field whose magnitude alone dwarfs the limit short-circuits
    // before its conversion could overflow.
    const limit_ns: i256 = @as(i256, 9007199254740992) * 1_000_000_000; // 2^53 · 10^9
    const scales = [_]i256{ 86_400_000_000_000, 3_600_000_000_000, 60_000_000_000, 1_000_000_000, 1_000_000, 1_000, 1 };
    const times = [_]f64{ d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };
    var total_ns: i256 = 0;
    for (times, scales) |f, scale| {
        const mag = @abs(f);
        if (mag >= 1.0e30) return false; // 10^30 ns ≫ 2^53 s on its own
        total_ns += @as(i256, @intFromFloat(mag)) * scale;
        if (total_ns >= limit_ns) return false;
    }
    return true;
}

// ------------------------------------------------------------------- ToDuration ---

/// ToTemporalDuration: from a Duration (copy), string (ISO), or a fields object.
pub fn toTemporalDuration(arena: std.mem.Allocator, v: Value) !DurationFields {
    if (getDuration(v)) |d| return d.*;
    if (v.bits != 0 and v.unbox() == .string) {
        const d = shared.parseISODuration(v.unbox().string) catch return realm_mod.throwRangeError(arena, "invalid Duration string");
        // A parsed digit run may overflow to a non-finite / out-of-range value
        // (e.g. "PT" + "1"×1000 + "S"); IsValidDuration rejects those.
        if (!isValidDuration(d)) return realm_mod.throwRangeError(arena, "invalid Duration string");
        return d;
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
        if (try shared.optionGet(arena, o, name)) |fv| {
            const n = try shared.toIntegerIfIntegral(arena, fv);
            any = true;
            assignField(&d, name, n);
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

    // Two durations with identical field values compare equal without needing a
    // relativeTo, even when calendar units are present (spec step 5).
    if (a.years == b.years and a.months == b.months and a.weeks == b.weeks and
        a.days == b.days and a.hours == b.hours and a.minutes == b.minutes and
        a.seconds == b.seconds and a.milliseconds == b.milliseconds and
        a.microseconds == b.microseconds and a.nanoseconds == b.nanoseconds)
    {
        return val_mod.makeNumber(arena, 0);
    }

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
    // ToTemporalPartialDurationRecord reads every field through [[Get]] (so
    // getters/Proxy traps run) in alphabetical order, and requires at least one.
    const names = [_][]const u8{ "days", "hours", "microseconds", "milliseconds", "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    var any = false;
    for (names) |name| {
        if (try shared.optionGet(arena, o, name)) |fv| {
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
    // add/subtract take no relativeTo, so any nonzero calendar unit (years,
    // months, weeks) in either operand is unbalanceable and throws (spec
    // AddDurations: DefaultTemporalLargestUnit of a calendar unit with an
    // undefined relativeTo is a RangeError).
    if (hasCalendarUnits(a.*) or hasCalendarUnits(b))
        return realm_mod.throwRangeError(arena, "Duration add/subtract with calendar units requires relativeTo");
    // Pure time (+days) durations: sum nanoseconds and balance up to the larger
    // of the two operands' default largest units (LargerOfTwoTemporalUnits), so
    // e.g. blank + "-PT24H" stays 24 hours rather than collapsing to 1 day.
    const total = timeDurationNanos(a.*) + timeDurationNanos(b);
    const largest = largerUnit(defaultLargestUnit(a.*), defaultLargestUnit(b));
    const balanced = balanceTimeDuration(total, largest);
    return makeDuration(arena, balanced);
}

/// BalanceTimeDuration: distribute a nanosecond total across time units up to
/// `largest`.
fn balanceTimeDuration(total_ns: i128, largest: shared.Unit) DurationFields {
    var ns = total_ns;
    const neg = ns < 0;
    if (neg) ns = -ns;
    var d = DurationFields{};
    var rem = ns;
    // Open each unit only when `largest` is that unit or coarser (rank ≤ its
    // rank), so e.g. largestUnit "microseconds" keeps the whole amount in
    // microseconds instead of rolling up into milliseconds. A calendar largest
    // unit (year/month/week) still caps time balancing at days.
    const r = durUnitRank(largest);
    if (r <= durUnitRank(.day)) {
        d.days = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_DAY)));
        rem = @mod(rem, shared.NS_PER_DAY);
    }
    if (r <= durUnitRank(.hour)) {
        d.hours = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_HOUR)));
        rem = @mod(rem, shared.NS_PER_HOUR);
    }
    if (r <= durUnitRank(.minute)) {
        d.minutes = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MINUTE)));
        rem = @mod(rem, shared.NS_PER_MINUTE);
    }
    if (r <= durUnitRank(.second)) {
        d.seconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_SECOND)));
        rem = @mod(rem, shared.NS_PER_SECOND);
    }
    if (r <= durUnitRank(.millisecond)) {
        d.milliseconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MILLI)));
        rem = @mod(rem, shared.NS_PER_MILLI);
    }
    if (r <= durUnitRank(.microsecond)) {
        d.microseconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MICRO)));
        rem = @mod(rem, shared.NS_PER_MICRO);
    }
    d.nanoseconds = @floatFromInt(@as(i128, rem));
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
    const rv = (try shared.optionGet(arena, o, "relativeTo")) orelse Value{};
    // ToRelativeTemporalObject: undefined (or absent) means "no relativeTo";
    // any other primitive that is not a String is a TypeError (only strings and
    // objects convert), so null/boolean/number/bigint/symbol throw here.
    if (rv.bits == 0 or rv.isUndefined()) return null;
    switch (rv.unbox()) {
        .null_, .boolean, .number, .bigint, .symbol => return realm_mod.throwTypeError(arena, "relativeTo must be a string or object"),
        else => {},
    }
    // A ZonedDateTime relativeTo is reduced to its local calendar date (we do not
    // model per-day time-zone offset changes; correct for fixed-offset zones).
    const zdt = @import("zoned_date_time.zig");
    if (zdt.getZoned(rv)) |z| return zdt.localISODate(z);
    // For a string, a UTC "Z" designator makes it a zoned relativeTo, which is
    // only valid alongside a [time zone] annotation. We reduce a zoned reference
    // to its local calendar date (fixed-offset accurate); a bare "…Z" without a
    // time-zone annotation is not a valid relativeTo.
    if (rv.unbox() == .string) {
        const str = rv.unbox().string;
        const bracket_start = std.mem.indexOfScalar(u8, str, '[');
        const before_brackets = if (bracket_start) |b| str[0..b] else str;
        const has_utc = std.mem.indexOfScalar(u8, before_brackets, 'Z') != null or
            std.mem.indexOfScalar(u8, before_brackets, 'z') != null;
        // A string with a time-zone annotation (or a bare `Z`) is a *zoned*
        // relativeTo: route it through ToTemporalZonedDateTime so the offset is
        // validated against the zone and the instant is range-checked. A bare
        // `Z` with no `[tz]` annotation is not a valid relativeTo.
        if (hasTimeZoneAnnotation(str)) {
            const z = try zdt.toTemporalZoned(arena, rv, null);
            return zdt.localISODate(&z);
        }
        if (has_utc)
            return realm_mod.throwRangeError(arena, "UTC designator without a time zone is not a valid relativeTo");
    }
    // A Temporal.PlainDate / PlainDateTime relativeTo uses its internal ISO date
    // directly — its property-bag fields must NOT be observed.
    if (pd.getDate(rv)) |dd| return dd.*;
    if (@import("plain_date_time.zig").getDateTime(rv)) |dt| return dt.date;
    // A property bag is read as a full ZonedDateTime-shaped bag (time, offset
    // and timeZone included) even though only the date is kept: which fields are
    // touched is observable.
    if (rv.unbox() == .object) {
        const bag = try pd.readDateBag(arena, rv.toPtr().object, .{ .time = true, .zoned = true });
        // A bag naming a time zone is a *zoned* relativeTo, so its time zone and
        // offset have to be validated even though only the date survives.
        if (bag.time_zone != null) {
            const z = try zdt.toTemporalZoned(arena, rv, null);
            return zdt.localISODate(&z);
        }
        return try pd.dateFromBag(arena, bag, .constrain);
    }
    return try pd.toTemporalDate(arena, rv, .constrain);
}

/// True if the string carries an RFC 9557 time-zone annotation — a `[...]`
/// bracket whose contents are not a `key=value` pair (i.e. a bare zone id such
/// as `[UTC]` or `[-07:00]`), as opposed to a `[u-ca=…]` calendar annotation.
fn hasTimeZoneAnnotation(str: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, str, i, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, str, open + 1, ']') orelse return false;
        const inner = str[open + 1 .. close];
        if (std.mem.indexOfScalar(u8, inner, '=') == null) return true;
        i = close + 1;
    }
    return false;
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
            return .{ .d = out, .total = shared.divToF64(low_ns, unit_ns) };
        }
        const full_ns: i128 = @as(i128, epochDaysOf(dest_date) - epochDaysOf(R)) * DAY + time_rem;
        const rounded = shared.roundI128ToIncrement(full_ns, inc_ns, mode);
        const out = balanceTimeDuration(rounded, largest);
        return .{ .d = out, .total = shared.divToF64(full_ns, unit_ns) };
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
    // total = r1 + progress × increment × sign, where progress = num/denom.
    const p: f64 = if (denom == 0) 0 else @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(denom));
    const value = r1_count + p * inc * sgn;
    const rounded_count = shared.roundNumberToIncrement(value, inc, mode);

    var out = DurationFields{};
    switch (smallest) {
        .year => out.years = rounded_count,
        .month => {
            out.years = bal.years;
            out.months = rounded_count;
            // A rounded month count that reaches a full year (12, ISO) bubbles
            // into the years field, but only when `largest` is year — otherwise
            // months remain the top unit (BubbleRelativeDuration).
            if (largest == .year) {
                const extra = @divTrunc(rounded_count, 12);
                if (extra != 0) {
                    out.years += extra;
                    out.months -= extra * 12;
                }
            }
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
    var given = false; // at least one of smallestUnit/largestUnit was supplied
    var rel_date: ?shared.ISODate = null;
    var mode: shared.RoundingMode = .half_expand;
    var inc: f64 = 1;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits == 0 or arg0.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "round() requires an options argument");
    if (arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
        given = true;
    } else {
        // Alphabetical, and every read happens before any validation.
        opts = try shared.getOptionsObject(arena, arg0);
        switch (try shared.getTemporalUnitOption(arena, opts, "largestUnit")) {
            .absent => {},
            .auto => given = true,
            .unit => |u| {
                largest = u;
                given = true;
            },
        }
        rel_date = try readRelativeDate(arena, opts);
        inc = try shared.getRoundingIncrement(arena, opts);
        mode = try shared.getRoundingMode(arena, opts, .half_expand);
        switch (try shared.getTemporalUnitOption(arena, opts, "smallestUnit")) {
            .absent, .auto => {},
            .unit => |u| {
                smallest = u;
                given = true;
            },
        }
    }
    if (!given) return realm_mod.throwRangeError(arena, "round() requires smallestUnit or largestUnit");

    const small = smallest orelse shared.Unit.nanosecond;
    try validateIncrement(arena, small, inc);
    // Default largestUnit = the larger of the duration's existing largest unit and
    // smallestUnit (spec LargerOfTwoTemporalUnits over DefaultTemporalLargestUnit).
    const large = largest orelse largerUnit(defaultLargestUnit(d.*), small);
    // largestUnit must be the same or larger magnitude than smallestUnit.
    if (durUnitRank(large) > durUnitRank(small))
        return realm_mod.throwRangeError(arena, "largestUnit must be larger than or equal to smallestUnit");
    // Rounding a date unit (year/month/week/day) to an increment > 1 cannot also
    // balance up to a larger unit: the increment and the balancing target must be
    // the same unit (e.g. rounding days to 30 while balancing to weeks is invalid).
    if (inc > 1 and durUnitRank(small) <= durUnitRank(.day) and durUnitRank(large) != durUnitRank(small))
        return realm_mod.throwRangeError(arena, "cannot round to an increment of date units greater than 1 while balancing to a larger unit");

    // Anything touching calendar units (in the receiver or as a rounding unit)
    // needs a reference date; resolve relativeTo and use the calendar algorithm.
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
    var rel_date: ?shared.ISODate = null;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits == 0 or arg0.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "total() requires a unit argument");
    if (arg0.unbox() == .string) {
        unit = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid unit");
    } else {
        // "relativeTo" sorts before "unit", and both are read before validation.
        opts = try shared.getOptionsObject(arena, arg0);
        rel_date = try readRelativeDate(arena, opts);
        unit = try shared.getTemporalUnit(arena, opts, "unit");
    }
    const u = unit orelse return realm_mod.throwRangeError(arena, "total() requires a unit");

    // Calendar units (in the receiver or as the target unit) need relativeTo.
    if (hasCalendarUnits(d.*) or isCalendarUnit(u)) {
        const R = rel_date orelse
            return realm_mod.throwRangeError(arena, "Duration.total with calendar units requires relativeTo");
        const res = try roundRelative(arena, d.*, R, u, u, 1, .trunc);
        return val_mod.makeNumber(arena, res.total);
    }
    const per = shared.unitLengthNanos(u) orelse return realm_mod.throwRangeError(arena, "calendar unit needs relativeTo");
    const total = timeDurationNanos(d.*);
    const result = shared.divToF64(total, per);
    return val_mod.makeNumber(arena, result);
}

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const d = try requireDuration(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    // Option read order is fixed by the spec: digits, then mode, then unit.
    const digits = try shared.getFractionalDigits(arena, opts);
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const prec = try shared.getSecondsStringPrecision(arena, opts, digits);
    // A Duration has no clock to truncate to, so unlike the time types it
    // accepts only second..nanosecond.
    if (prec.minute) return realm_mod.throwRangeError(arena, "smallestUnit must be one of second, millisecond, microsecond, nanosecond");
    const s = try durationToStringPrec(arena, d.*, prec, mode);
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
    return durationToStringPrec(arena, d, .{ .digits = digits }, .trunc);
}

fn durationToStringPrec(arena: std.mem.Allocator, d: DurationFields, prec: shared.SecondsPrecision, mode: shared.RoundingMode) ![]const u8 {
    const digits = prec.digits;
    const sign = d.sign();

    // Fields print verbatim; only the sub-second units (ms/µs/ns) fold up into a
    // fractional seconds value, and the seconds field itself may be arbitrarily
    // large (it is NOT balanced into minutes for display).
    var out = d;
    var sec_ns: i128 = @as(i128, @intFromFloat(@abs(d.seconds))) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(@abs(d.milliseconds))) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(@abs(d.microseconds))) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(@abs(d.nanoseconds)));

    // When a rounding increment is in force, the whole time part is rounded to it
    // and the carry may cross unit boundaries up through days (but never into
    // weeks/months/years). Otherwise the values are emitted as stored.
    if (prec.increment > 1) {
        const time_ns: i128 = @as(i128, @intFromFloat(@abs(d.hours))) * shared.NS_PER_HOUR +
            @as(i128, @intFromFloat(@abs(d.minutes))) * shared.NS_PER_MINUTE + sec_ns;
        const rounded = shared.roundI128ToIncrement(if (sign < 0) -time_ns else time_ns, prec.increment, mode);
        const mag_ns: i128 = if (rounded < 0) -rounded else rounded;
        // Balance up to the duration's own largest unit (a calendar unit caps the
        // time balance at days), so 59.9s→60s stays "60S" while 1h59m59.9s→"2H".
        const bt = balanceTimeDuration(mag_ns, defaultLargestUnit(d));
        out.days = d.days + (if (sign < 0) -bt.days else bt.days);
        out.hours = if (sign < 0) -bt.hours else bt.hours;
        out.minutes = if (sign < 0) -bt.minutes else bt.minutes;
        out.seconds = if (sign < 0) -bt.seconds else bt.seconds;
        out.milliseconds = 0;
        out.microseconds = 0;
        out.nanoseconds = 0;
        if (!isValidDuration(out)) return realm_mod.throwRangeError(arena, "rounded Duration is out of range");
        sec_ns = mag_ns - @as(i128, @intFromFloat(@abs(bt.days))) * shared.NS_PER_DAY -
            @as(i128, @intFromFloat(@abs(bt.hours))) * shared.NS_PER_HOUR -
            @as(i128, @intFromFloat(@abs(bt.minutes))) * shared.NS_PER_MINUTE;
    }

    var buf = shared.Buf{};
    if (sign < 0) try buf.append(arena, '-');
    try buf.append(arena, 'P');
    try appendUnit(arena, &buf, @abs(out.years), 'Y');
    try appendUnit(arena, &buf, @abs(out.months), 'M');
    try appendUnit(arena, &buf, @abs(out.weeks), 'W');
    try appendUnit(arena, &buf, @abs(out.days), 'D');

    const has_h = out.hours != 0;
    const has_m = out.minutes != 0;
    const sec_whole: i64 = @intCast(@divTrunc(sec_ns, 1_000_000_000));
    const frac_ns: u32 = @intCast(@mod(sec_ns, 1_000_000_000));
    // The seconds component is emitted when it is nonzero or when the precision
    // was explicitly requested (any fractionalSecondDigits, including 0).
    const has_s = !prec.minute and (sec_ns != 0 or digits != null);

    if (has_h or has_m or has_s) {
        try buf.append(arena, 'T');
        try appendUnit(arena, &buf, @abs(out.hours), 'H');
        try appendUnit(arena, &buf, @abs(out.minutes), 'M');
        if (has_s) {
            try shared.appendPadded(arena, &buf, sec_whole, 1);
            try appendSecondsFraction(arena, &buf, frac_ns, digits);
            try buf.append(arena, 'S');
        }
    } else if (sign == 0 and out.years == 0 and out.months == 0 and out.weeks == 0 and out.days == 0) {
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

    try intrinsics.setMethodLen(arena, proto, "with", nativeWith, 1);
    try intrinsics.setMethod(arena, proto, "negated", nativeNegated);
    try intrinsics.setMethod(arena, proto, "abs", nativeAbs);
    try intrinsics.setMethodLen(arena, proto, "add", nativeAdd, 1);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "total", nativeTotal);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
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
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "Duration"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    // Store ctor for the Temporal namespace to expose.
    ctor_obj = ctor;
}

pub var ctor_obj: ?*JsObject = null;

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.Duration"), .{ .writable = false, .enumerable = false, .configurable = true });
}
