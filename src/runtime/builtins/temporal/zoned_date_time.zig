// SPDX-License-Identifier: Apache-2.0
//! Wave 27: Temporal.ZonedDateTime — an exact instant (epoch nanoseconds) paired
//! with a time-zone identifier and (ISO) calendar. In the current Temporal
//! proposal the time zone and calendar are string identifiers, not objects.
//!
//! Storage: internal_kind = .temporal_zoned_date_time, internal_slot -> ZonedDT.
//! Fixed-offset zones ("UTC", "±HH:MM") always have 24h days and no transitions.
//! Named IANA zones ("America/New_York", …) resolve DST-aware offsets via the
//! embedded tzdata: getTimeZoneTransition finds their DST transitions and
//! hoursInDay yields 23h/25h on spring-forward / fall-back days.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const calendar = @import("calendar.zig");
const timezone = @import("timezone.zig");
const tzdata = @import("tzdata.zig");
const duration = @import("duration.zig");
const instant = @import("instant.zig");
const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const plain_date_time = @import("plain_date_time.zig");
const ISODate = shared.ISODate;
const ISOTime = shared.ISOTime;
const ISODateTime = shared.ISODateTime;

pub var proto_obj: ?*JsObject = null;
pub var ctor_obj: ?*JsObject = null;

const MAX_NS: i128 = 8_640_000_000_000_000_000_000;

pub const ZonedDT = struct {
    ns: i128,
    tz: []const u8,
    offset_ns: i128,
    calendar: shared.calendar_mod.CalendarId = .iso8601,
};

pub fn getZoned(v: Value) ?*ZonedDT {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const obj = v.toPtr().object;
    if (obj.internal_kind != .temporal_zoned_date_time) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn requireZoned(arena: std.mem.Allocator, v: Value) !*ZonedDT {
    return getZoned(v) orelse realm_mod.throwTypeError(arena, "not a Temporal.ZonedDateTime");
}

fn isValidEpochNs(ns: i128) bool {
    return ns >= -MAX_NS and ns <= MAX_NS;
}

pub fn makeZoned(arena: std.mem.Allocator, z0: ZonedDT) !Value {
    const z = withResolvedOffset(z0);
    if (!isValidEpochNs(z.ns)) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    const slot = try arena.create(ZonedDT);
    slot.* = z;
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_zoned_date_time;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

/// The stored offset is a cache of "what offset is this zone at, at this
/// instant" — it must be re-derived whenever the instant moves, or arithmetic
/// across a DST boundary keeps reading the old side's offset.
fn withResolvedOffset(z: ZonedDT) ZonedDT {
    if (!isValidEpochNs(z.ns)) return z;
    var out = z;
    out.offset_ns = timezone.offsetAtInstant(z.tz, z.ns);
    return out;
}

fn installInto(arena: std.mem.Allocator, this_val: Value, z0: ZonedDT) !Value {
    const z = withResolvedOffset(z0);
    if (!isValidEpochNs(z.ns)) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    const slot = try arena.create(ZonedDT);
    slot.* = z;
    this_val.toPtr().object.internal_kind = .temporal_zoned_date_time;
    this_val.toPtr().object.internal_slot = slot;
    return this_val;
}

/// Local (wall-clock) datetime = instant + zone offset.
fn localDT(z: *const ZonedDT) ISODateTime {
    const total = z.ns + z.offset_ns;
    const days: i64 = @intCast(@divFloor(total, shared.NS_PER_DAY));
    const tod = total - @as(i128, days) * shared.NS_PER_DAY;
    const tr = shared.nanosToTime(tod);
    var date = shared.epochDaysToISODate(days + tr.days);
    // Carry the calendar onto the projected wall-clock date so everything
    // derived from it (getters, toPlainDate/toPlainDateTime) keeps the lens.
    date.calendar = z.calendar;
    return .{ .date = date, .time = tr.time };
}

/// The local (wall-clock) ISO date of a ZonedDateTime — used as a PlainDate-style
/// relativeTo reference by Duration rounding.
pub fn localISODate(z: *const ZonedDT) shared.ISODate {
    return localDT(z).date;
}

/// The local (wall-clock) ISO date+time of a ZonedDateTime. Used by the
/// ToTemporalTime/ToTemporalDate/... conversions, which extract the wall-clock
/// components when handed a ZonedDateTime argument.
pub fn localISODateTime(z: *const ZonedDT) ISODateTime {
    return localDT(z);
}

/// Wall nanoseconds (epoch days*NS_PER_DAY + time) for a local datetime.
fn wallNs(dt: ISODateTime) i128 {
    return @as(i128, shared.isoDateToEpochDays(dt.date.year, dt.date.month, dt.date.day)) * shared.NS_PER_DAY +
        shared.timeToNanos(dt.time);
}

// ---------------------------------------------------- time-zone identifier ---

/// Read a time-zone-like value into a Zone. Only string identifiers are
/// accepted (non-strings throw TypeError, matching the spec).
/// When `epoch_ns` is provided, uses `toZoneAtInstant` for DST-aware lookup.
fn toTimeZone(arena: std.mem.Allocator, v: Value, epoch_ns: ?i128) !timezone.Zone {
    if (v.bits == 0) return realm_mod.throwTypeError(arena, "time zone must be a string");
    switch (v.unbox()) {
        .string => |s| {
            if (epoch_ns) |ns| {
                return timezone.toZoneAtInstant(arena, s, ns);
            }
            return timezone.toZone(arena, s);
        },
        .undefined_, .null_, .boolean, .number, .bigint, .symbol => return realm_mod.throwTypeError(arena, "time zone must be a string"),
        else => return realm_mod.throwTypeError(arena, "time zone must be a string"),
    }
}

/// The constructor's calendar argument: a bare identifier String only
/// (CanonicalizeCalendar), unlike the property-bag form which also accepts an
/// ISO temporal string.
fn resolveCtorCalendar(arena: std.mem.Allocator, v: Value) !calendar.CalendarId {
    if (v.bits == 0 or v.unbox() == .undefined_) return .iso8601;
    if (v.unbox() != .string) return realm_mod.throwTypeError(arena, "calendar must be a string");
    return calendar.canonicalize(v.unbox().string) orelse
        realm_mod.throwRangeError(arena, "unsupported calendar");
}

// -------------------------------------------------------------- constructor ---

pub fn nativeCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!realm_mod.active_constructing) return realm_mod.throwTypeError(arena, "Temporal.ZonedDateTime requires new");
    const ns_arg = if (args.len > 0) args[0] else Value{};
    if (ns_arg.bits == 0 or ns_arg.unbox() != .bigint) return realm_mod.throwTypeError(arena, "epochNanoseconds must be a BigInt");
    const ns = shared.bigIntToI128(ns_arg) orelse return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    if (!isValidEpochNs(ns)) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    const zone = try toTimeZone(arena, if (args.len > 1) args[1] else Value{}, ns);
    const cal = if (args.len > 2) try resolveCtorCalendar(arena, args[2]) else .iso8601;
    const z = ZonedDT{ .ns = ns, .tz = zone.id, .offset_ns = zone.offset_ns, .calendar = cal };
    if (this_val.bits != 0 and this_val.unbox() == .object) return installInto(arena, this_val, z);
    return makeZoned(arena, z);
}

// ---------------------------------------------------------------- ToZoned ---

const OffsetOption = enum { prefer, use, ignore, reject };

const Disambiguation = enum { compatible, earlier, later, reject };

fn getDisambiguation(arena: std.mem.Allocator, opts: ?*JsObject) !Disambiguation {
    const s = (try shared.readStringOption(arena, opts, "disambiguation")) orelse return .compatible;
    if (std.mem.eql(u8, s, "compatible")) return .compatible;
    if (std.mem.eql(u8, s, "earlier")) return .earlier;
    if (std.mem.eql(u8, s, "later")) return .later;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return realm_mod.throwRangeError(arena, "invalid disambiguation option");
}

/// DisambiguatePossibleEpochNanoseconds: pick the instant a wall-clock time
/// names in `tz`. A fall-back overlap offers two; a spring-forward gap offers
/// none, and the wall time is shifted by the size of the gap in the direction
/// the option asks for ("compatible" means later for a gap, earlier for an
/// overlap).
fn disambiguate(arena: std.mem.Allocator, tz: []const u8, wall: i128, mode: Disambiguation) !i128 {
    const p = timezone.possibleInstants(tz, wall);
    if (p.n == 1) return p.first;
    if (p.n > 1) return switch (mode) {
        .earlier, .compatible => p.first,
        .later => p.second,
        .reject => realm_mod.throwRangeError(arena, "wall-clock time is ambiguous in this time zone"),
    };
    if (mode == .reject) return realm_mod.throwRangeError(arena, "wall-clock time does not exist in this time zone");
    // Gap: the offsets a day either side bracket it, and their difference is the
    // gap width.
    const before = timezone.offsetAtInstant(tz, wall - shared.NS_PER_DAY);
    const after = timezone.offsetAtInstant(tz, wall + shared.NS_PER_DAY);
    const gap = after - before;
    const shifted = if (mode == .earlier) wall - gap else wall + gap;
    const q = timezone.possibleInstants(tz, shifted);
    if (q.n == 0) return realm_mod.throwRangeError(arena, "wall-clock time does not exist in this time zone");
    if (mode == .earlier) return q.first;
    return if (q.n > 1) q.second else q.first;
}

fn getOffsetOption(arena: std.mem.Allocator, opts: ?*JsObject, default: OffsetOption) !OffsetOption {
    const s = (try shared.readStringOption(arena, opts, "offset")) orelse return default;
    if (std.mem.eql(u8, s, "prefer")) return .prefer;
    if (std.mem.eql(u8, s, "use")) return .use;
    if (std.mem.eql(u8, s, "ignore")) return .ignore;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return realm_mod.throwRangeError(arena, "invalid offset option");
}

/// Parse an offset *value* string (sub-minute allowed): "±HH:MM(:SS(.fff))" /
/// "Z". Returns ns.
fn parseOffsetValue(arena: std.mem.Allocator, s: []const u8) !i128 {
    if (s.len == 1 and (s[0] == 'Z' or s[0] == 'z')) return 0;
    if (s.len < 3 or (s[0] != '+' and s[0] != '-')) return realm_mod.throwRangeError(arena, "invalid offset string");
    const sign: i128 = if (s[0] == '-') -1 else 1;
    var i: usize = 1;
    const h = od(s, i) orelse return realm_mod.throwRangeError(arena, "invalid offset string");
    i += 2;
    var m: i128 = 0;
    var sec: i128 = 0;
    var sub: i128 = 0;
    if (i < s.len) {
        if (s[i] == ':') i += 1;
        m = od(s, i) orelse return realm_mod.throwRangeError(arena, "invalid offset string");
        i += 2;
        if (i < s.len) {
            if (s[i] == ':') i += 1;
            sec = od(s, i) orelse return realm_mod.throwRangeError(arena, "invalid offset string");
            i += 2;
            if (i < s.len and (s[i] == '.' or s[i] == ',')) {
                i += 1;
                var frac: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
                var k: usize = 0;
                while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                    if (k < 9) frac[k] = s[i];
                    k += 1;
                }
                if (k == 0) return realm_mod.throwRangeError(arena, "invalid offset string");
                sub = std.fmt.parseInt(i128, &frac, 10) catch 0;
            }
        }
    }
    if (i != s.len) return realm_mod.throwRangeError(arena, "invalid offset string");
    if (h > 23 or m > 59 or sec > 59) return realm_mod.throwRangeError(arena, "invalid offset string");
    return sign * (h * shared.NS_PER_HOUR + m * shared.NS_PER_MINUTE + sec * shared.NS_PER_SECOND + sub);
}

fn od(s: []const u8, i: usize) ?i128 {
    if (i + 2 > s.len) return null;
    if (s[i] < '0' or s[i] > '9' or s[i + 1] < '0' or s[i + 1] > '9') return null;
    return @as(i128, s[i] - '0') * 10 + (s[i + 1] - '0');
}

/// Convert a value to a ZonedDateTime (used by from/compare/equals/since/until).
fn toTemporalZoned(arena: std.mem.Allocator, v: Value, opts: ?*JsObject) !ZonedDT {
    if (getZoned(v)) |z| return z.*;
    if (v.bits != 0 and v.unbox() == .object) {
        return try zonedFromFields(arena, v.toPtr().object, opts);
    }
    if (v.bits != 0 and v.unbox() == .string) {
        return try zonedFromString(arena, v.unbox().string, opts);
    }
    return realm_mod.throwTypeError(arena, "cannot convert to Temporal.ZonedDateTime");
}

fn zonedFromFields(arena: std.mem.Allocator, o: *JsObject, opts: ?*JsObject) !ZonedDT {
    // ToTemporalZonedDateTime validates the calendar (ToTemporalCalendarIdentifier;
    // ISO strings ok) BEFORE requiring the timeZone field, so an invalid calendar
    // throws RangeError even when timeZone is absent.
    const cal = if (o.get("calendar")) |cv| try shared.resolveCalendarArg(arena, cv) else .iso8601;
    // timeZone is required.
    const tz_v = o.get("timeZone") orelse return realm_mod.throwTypeError(arena, "missing timeZone");
    if (tz_v.bits != 0 and tz_v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "missing timeZone");
    const zone = try toTimeZone(arena, tz_v, null);
    const disamb = try getDisambiguation(arena, opts);
    const offset_opt = try getOffsetOption(arena, opts, .reject);
    const overflow = try shared.getOverflow(arena, opts);

    // Read the wall-clock datetime from the property bag (reuse PlainDateTime).
    const dt = try readDateTimeFields(arena, o, overflow, cal);

    // offset property.
    var provided: ?i128 = null;
    if (o.get("offset")) |ov| {
        if (ov.bits != 0 and ov.unbox() != .undefined_) {
            if (ov.unbox() != .string) return realm_mod.throwTypeError(arena, "offset must be a string");
            provided = try parseOffsetValue(arena, ov.unbox().string);
        }
    }
    const ns = try interpretOffset(arena, dt, zone.id, provided, offset_opt, disamb);
    return .{ .ns = ns, .tz = zone.id, .offset_ns = timezone.offsetAtInstant(zone.id, ns), .calendar = cal };
}

/// Read the required/optional date+time fields from a property bag into an
/// ISODateTime (mirrors PlainDateTime's field reading, inlined so ZonedDateTime
/// can require timeZone separately).
fn readDateTimeFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow, cal: calendar.CalendarId) !ISODateTime {
    // The date half is exactly PlainDate's field set, read in `cal`'s space.
    var date = try plain_date.dateFromFields(arena, o, overflow);
    date.calendar = cal;
    const time = try readTimeFields(arena, o, overflow);
    return .{ .date = date, .time = time };
}

fn readTimeFields(arena: std.mem.Allocator, o: *JsObject, overflow: shared.Overflow) !ISOTime {
    var h: f64 = 0;
    var min: f64 = 0;
    var s: f64 = 0;
    var ms: f64 = 0;
    var us: f64 = 0;
    var ns: f64 = 0;
    if (try readField(arena, o, "hour")) |x| h = x;
    if (try readField(arena, o, "minute")) |x| min = x;
    if (try readField(arena, o, "second")) |x| s = x;
    if (try readField(arena, o, "millisecond")) |x| ms = x;
    if (try readField(arena, o, "microsecond")) |x| us = x;
    if (try readField(arena, o, "nanosecond")) |x| ns = x;
    if (overflow == .reject) {
        if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999 or
            h < 0 or min < 0 or s < 0 or ms < 0 or us < 0 or ns < 0)
            return realm_mod.throwRangeError(arena, "time field out of range");
    }
    return .{
        .hour = @intFromFloat(std.math.clamp(h, 0, 23)),
        .minute = @intFromFloat(std.math.clamp(min, 0, 59)),
        .second = @intFromFloat(std.math.clamp(s, 0, 59)),
        .millisecond = @intFromFloat(std.math.clamp(ms, 0, 999)),
        .microsecond = @intFromFloat(std.math.clamp(us, 0, 999)),
        .nanosecond = @intFromFloat(std.math.clamp(ns, 0, 999)),
    };
}

fn readField(arena: std.mem.Allocator, o: *JsObject, name: []const u8) !?f64 {
    const v = o.get(name) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try shared.toIntegerWithTruncation(arena, v);
}

fn f2i(f: f64) i32 {
    if (f > 2147483647) return 2147483647;
    if (f < -2147483648) return -2147483648;
    return @intFromFloat(f);
}

/// InterpretISODateTimeOffset for a fixed-offset zone.
/// InterpretISODateTimeOffset: turn a wall-clock reading plus an optionally
/// supplied UTC offset into an instant.
fn interpretOffset(
    arena: std.mem.Allocator,
    dt: ISODateTime,
    tz: []const u8,
    provided: ?i128,
    opt: OffsetOption,
    disamb: Disambiguation,
) !i128 {
    const wall = wallNs(dt);
    if (provided == null or opt == .ignore) return disambiguate(arena, tz, wall, disamb);
    if (opt == .use) return wall - provided.?;

    // "prefer"/"reject": honour the supplied offset if the zone actually was at
    // it. A minute-precision offset also matches an offset that only differs
    // below the minute (spec match-minutes).
    const want = provided.?;
    const minute_precision = @mod(want, shared.NS_PER_MINUTE) == 0;
    const p = timezone.possibleInstants(tz, wall);
    var i: u8 = 0;
    while (i < p.n) : (i += 1) {
        const cand = if (i == 0) p.first else p.second;
        const cand_off = wall - cand;
        if (cand_off == want) return cand;
        if (minute_precision and shared.roundI128ToIncrement(cand_off, shared.NS_PER_MINUTE, .half_expand) == want) return cand;
    }
    if (opt == .reject) return realm_mod.throwRangeError(arena, "offset does not match time zone");
    return disambiguate(arena, tz, wall, disamb);
}

fn zonedFromString(arena: std.mem.Allocator, s0: []const u8, opts: ?*JsObject) !ZonedDT {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    // A single [tz] bracket is mandatory; validate all annotations in one pass.
    const bracket = try extractAnnotations(arena, s);
    const zone = try timezone.toZone(arena, bracket);
    // ZonedDateTime accepts a `Z` UTC designator (unlike the plain types).
    const dt = shared.parseISODateTimeOpts(s, .{ .validate_calendar = true, .reject_utc = false }) catch return realm_mod.throwRangeError(arena, "invalid ZonedDateTime string");
    const str_off = extractStringOffset(arena, s) catch |e| return e;
    const disamb = try getDisambiguation(arena, opts);
    var offset_opt = try getOffsetOption(arena, opts, .reject);
    // A `Z` designator states the instant outright (spec offsetBehaviour
    // "exact"), so the offset option does not get a say.
    if (hasUtcDesignator(s)) offset_opt = .use;
    const ns = try interpretOffset(arena, dt, zone.id, str_off, offset_opt, disamb);
    return .{ .ns = ns, .tz = zone.id, .offset_ns = timezone.offsetAtInstant(zone.id, ns), .calendar = dt.date.calendar };
}

/// Does the datetime portion (before any annotation) end in a `Z`/`z` UTC
/// designator?
fn hasUtcDesignator(s: []const u8) bool {
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '[')) |b| end = b;
    const body = s[0..end];
    return body.len > 0 and (body[body.len - 1] == 'Z' or body[body.len - 1] == 'z');
}

/// Scan every `[...]` annotation on a ZonedDateTime string: require exactly one
/// time-zone annotation (bracket with no '='), reject a second one, and reject a
/// non-ISO calendar annotation. Returns the time-zone annotation's inner id.
fn extractAnnotations(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var tz: ?[]const u8 = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '[') continue;
        const start = i + 1;
        var j = start;
        while (j < s.len and s[j] != ']') : (j += 1) {}
        if (j >= s.len) return realm_mod.throwRangeError(arena, "unterminated annotation");
        var inner = s[start..j];
        i = j;
        if (inner.len > 0 and inner[0] == '!') inner = inner[1..];
        if (std.mem.indexOfScalar(u8, inner, '=') == null) {
            // A time-zone annotation.
            if (tz != null) return realm_mod.throwRangeError(arena, "more than one time zone annotation");
            tz = inner;
        } else if (std.mem.startsWith(u8, inner, "u-ca=")) {
            if (calendar.canonicalize(inner[5..]) == null) return realm_mod.throwRangeError(arena, "unsupported calendar");
        }
    }
    return tz orelse realm_mod.throwRangeError(arena, "ZonedDateTime string requires a time zone");
}

/// Extract the trailing UTC offset (ns) from a datetime string, or null if none.
fn extractStringOffset(arena: std.mem.Allocator, s: []const u8) !?i128 {
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '[')) |b| end = b;
    const body = s[0..end];
    const t_idx = std.mem.indexOfAny(u8, body, "Tt") orelse return null;
    var i = t_idx + 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == 'Z' or c == 'z') return 0;
        if (c == '+' or c == '-') return try parseOffsetValue(arena, body[i..]);
    }
    return null;
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // If v is already a ZonedDateTime, still read options (overflow/offset/disambiguation).
    // A string argument is parsed before the options bag is consulted.
    const parse_first = shared.isStringArg(v);
    if (getZoned(v) == null and !parse_first) {
        _ = try shared.getOverflow(arena, opts);
        _ = try getOffsetOption(arena, opts, .reject);
    }
    const z = try toTemporalZoned(arena, v, opts);
    if (parse_first) {
        _ = try shared.getOverflow(arena, opts);
        _ = try getOffsetOption(arena, opts, .reject);
    }
    return makeZoned(arena, z);
}

pub fn nativeCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = try toTemporalZoned(arena, if (args.len > 0) args[0] else Value{}, null);
    const b = try toTemporalZoned(arena, if (args.len > 1) args[1] else Value{}, null);
    const r: f64 = if (a.ns < b.ns) -1 else if (a.ns > b.ns) 1 else 0;
    return val_mod.makeNumber(arena, r);
}

// ---------------------------------------------------------------- getters ---

fn getYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d).year));
}
fn getMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d).month));
}
fn getDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeNumber(arena, @floatFromInt(calendar.fields(d.calendar, d).day));
}
fn getMonthCode(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeString(arena, try shared.formatMonthCode(arena, calendar.fields(d.calendar, d)));
}
fn getHour(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.hour));
}
fn getMinute(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.minute));
}
fn getSecond(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.second));
}
fn getMilli(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.millisecond));
}
fn getMicro(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.microsecond));
}
fn getNano(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(localDT(z).time.nanosecond));
}
fn getEpochMilliseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(@as(i128, @divFloor(z.ns, shared.NS_PER_MILLI))));
}
fn getEpochNanoseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return shared.i128ToBigInt(arena, z.ns);
}
fn getOffsetNanoseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(z.offset_ns));
}
fn getOffset(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeString(arena, try timezone.formatOffset(arena, z.offset_ns));
}
fn getTimeZoneId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeString(arena, z.tz);
}
fn getCalendarId(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeString(arena, z.calendar.str());
}
fn getDayOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfWeek(localDT(z).date)));
}
fn getDayOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.dayOfYear(localDT(z).date)));
}
fn getWeekOfYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(shared.weekOfYear(localDT(z).date)));
}
fn getYearOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, @floatFromInt(yearOfWeek(localDT(z).date)));
}
fn getEra(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    const era = calendar.fields(d.calendar, d).era orelse return Value{};
    return val_mod.makeString(arena, era);
}
fn getEraYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    const ey = calendar.fields(d.calendar, d).era_year orelse return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(ey));
}
fn getDaysInWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = try requireZoned(arena, this_val);
    return val_mod.makeNumber(arena, 7);
}
fn getDaysInMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    const f = calendar.fields(d.calendar, d);
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInMonth(d.calendar, f.year, f.month)));
}
fn getDaysInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeNumber(arena, @floatFromInt(calendar.daysInYear(d.calendar, calendar.fields(d.calendar, d).year)));
}
fn getMonthsInYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeNumber(arena, @floatFromInt(calendar.monthsInYear(d.calendar, calendar.fields(d.calendar, d).year)));
}
fn getInLeapYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    return val_mod.makeBool(arena, calendar.inLeapYear(d.calendar, calendar.fields(d.calendar, d).year));
}
fn getHoursInDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    // Fixed-offset / unknown zones: every day is 24h. Named IANA zones with DST
    // may have 23h/25h days around a transition.
    const def = tzdata.lookupDef(z.tz) orelse return val_mod.makeNumber(arena, 24);
    if (def.dst_rule == null) return val_mod.makeNumber(arena, 24);

    // The day's length is the gap between this day's start and the next day's,
    // both resolved as wall-clock midnights in the zone.
    const today = localDT(z).date;
    const start = try disambiguate(arena, z.tz, wallNs(.{ .date = today, .time = .{} }), .compatible);
    const tomorrow = shared.balanceISODate(today.year, today.month, @as(i32, today.day) + 1);
    const end = try disambiguate(arena, z.tz, wallNs(.{ .date = tomorrow, .time = .{} }), .compatible);
    return val_mod.makeNumber(arena, @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(shared.NS_PER_HOUR)));
}

/// ISO week-numbering year for a date.
fn yearOfWeek(date: ISODate) i32 {
    const wk = shared.weekOfYear(date);
    // If week 52/53 but we're in early January -> previous year; week 1 but late
    // December -> next year.
    if (date.month == 1 and wk >= 52) return date.year - 1;
    if (date.month == 12 and wk == 1) return date.year + 1;
    return date.year;
}

// ---------------------------------------------------------------- toX ---

pub fn nativeToInstant(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return instant.makeInstant(arena, z.ns);
}
pub fn nativeToPlainDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return plain_date.makeDate(arena, localDT(z).date);
}
pub fn nativeToPlainTime(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return plain_time.makeTime(arena, localDT(z).time);
}
pub fn nativeToPlainDateTime(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    return plain_date_time.makeDateTime(arena, localDT(z));
}

// ---------------------------------------------------------------- withX ---

pub fn nativeWithTimeZone(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const zone = try toTimeZone(arena, if (args.len > 0) args[0] else Value{}, z.ns);
    return makeZoned(arena, .{ .ns = z.ns, .tz = zone.id, .offset_ns = zone.offset_ns, .calendar = z.calendar });
}

pub fn nativeWithCalendar(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .string) return realm_mod.throwTypeError(arena, "calendar must be a string");
    // The instant and zone are unchanged; only the lens through which the
    // wall-clock date is read.
    var out = z.*;
    out.calendar = try shared.resolveCalendarArg(arena, v);
    return makeZoned(arena, out);
}

pub fn nativeWithPlainTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    var time = ISOTime{};
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        time = try plain_time.toTemporalTime(arena, args[0], .constrain);
    }
    const cur = localDT(z);
    const ns = try disambiguate(arena, z.tz, wallNs(.{ .date = cur.date, .time = time }), .compatible);
    return makeZoned(arena, .{ .ns = ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    if (getZoned(arg) != null or plain_date.getDate(arg) != null or plain_time.getTime(arg) != null or plain_date_time.getDateTime(arg) != null)
        return realm_mod.throwTypeError(arena, "with() argument must be a plain object");
    const o = arg.toPtr().object;
    if (o.get("calendar")) |c| if (c.bits != 0 and c.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (o.get("timeZone")) |c| if (c.bits != 0 and c.unbox() != .undefined_) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const disamb = try getDisambiguation(arena, opts);
    const offset_opt = try getOffsetOption(arena, opts, .prefer);
    const overflow = try shared.getOverflow(arena, opts);

    const cur = localDT(z);
    const merged = try plain_date.withDateFields(arena, cur.date, o, overflow);
    var h: f64 = @floatFromInt(cur.time.hour);
    var min: f64 = @floatFromInt(cur.time.minute);
    var s: f64 = @floatFromInt(cur.time.second);
    var ms: f64 = @floatFromInt(cur.time.millisecond);
    var us: f64 = @floatFromInt(cur.time.microsecond);
    var ns: f64 = @floatFromInt(cur.time.nanosecond);
    var any = merged.any;
    if (try readField(arena, o, "hour")) |x| { h = x; any = true; }
    if (try readField(arena, o, "minute")) |x| { min = x; any = true; }
    if (try readField(arena, o, "second")) |x| { s = x; any = true; }
    if (try readField(arena, o, "millisecond")) |x| { ms = x; any = true; }
    if (try readField(arena, o, "microsecond")) |x| { us = x; any = true; }
    if (try readField(arena, o, "nanosecond")) |x| { ns = x; any = true; }
    var provided: ?i128 = null;
    if (o.get("offset")) |ov| {
        if (ov.bits != 0 and ov.unbox() != .undefined_) {
            if (ov.unbox() != .string) return realm_mod.throwTypeError(arena, "offset must be a string");
            provided = try parseOffsetValue(arena, ov.unbox().string);
            any = true;
        }
    }
    if (!any) return realm_mod.throwTypeError(arena, "with() needs at least one field");

    const date = merged.date;
    if (overflow == .reject) {
        if (h > 23 or min > 59 or s > 59 or ms > 999 or us > 999 or ns > 999)
            return realm_mod.throwRangeError(arena, "time out of range");
    }
    const time = ISOTime{
        .hour = @intFromFloat(std.math.clamp(h, 0, 23)),
        .minute = @intFromFloat(std.math.clamp(min, 0, 59)),
        .second = @intFromFloat(std.math.clamp(s, 0, 59)),
        .millisecond = @intFromFloat(std.math.clamp(ms, 0, 999)),
        .microsecond = @intFromFloat(std.math.clamp(us, 0, 999)),
        .nanosecond = @intFromFloat(std.math.clamp(ns, 0, 999)),
    };
    const new_ns = try interpretOffset(arena, .{ .date = date, .time = time }, z.tz, provided, offset_opt, disamb);
    return makeZoned(arena, .{ .ns = new_ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

// ---------------------------------------------------------------- arithmetic ---

fn durTimeNanos(d: shared.DurationFields) i128 {
    return @as(i128, @intFromFloat(d.hours)) * shared.NS_PER_HOUR +
        @as(i128, @intFromFloat(d.minutes)) * shared.NS_PER_MINUTE +
        @as(i128, @intFromFloat(d.seconds)) * shared.NS_PER_SECOND +
        @as(i128, @intFromFloat(d.milliseconds)) * shared.NS_PER_MILLI +
        @as(i128, @intFromFloat(d.microseconds)) * shared.NS_PER_MICRO +
        @as(i128, @intFromFloat(d.nanoseconds));
}

fn addSub(arena: std.mem.Allocator, this_val: Value, args: []const Value, subtract: bool) !Value {
    const z = try requireZoned(arena, this_val);
    var dur = try duration.toTemporalDuration(arena, if (args.len > 0) args[0] else Value{});
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const overflow = try shared.getOverflow(arena, opts);
    if (subtract) dur = negate(dur);
    // AddZonedDateTime for a fixed-offset zone: add the date part to the wall
    // date, re-anchor to an instant, then add the exact time part in ns.
    const cur = localDT(z);
    var new_ns = z.ns;
    if (dur.years != 0 or dur.months != 0 or dur.weeks != 0 or dur.days != 0) {
        const new_date = try plain_date.addISODate(cur.date, dur.years, dur.months, dur.weeks, dur.days, overflow, arena);
        new_ns = try disambiguate(arena, z.tz, wallNs(.{ .date = new_date, .time = cur.time }), .compatible);
    }
    new_ns += durTimeNanos(dur);
    return makeZoned(arena, .{ .ns = new_ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

fn negate(d: shared.DurationFields) shared.DurationFields {
    return .{
        .years = -d.years, .months = -d.months, .weeks = -d.weeks, .days = -d.days,
        .hours = -d.hours, .minutes = -d.minutes, .seconds = -d.seconds,
        .milliseconds = -d.milliseconds, .microseconds = -d.microseconds, .nanoseconds = -d.nanoseconds,
    };
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
    const z = try requireZoned(arena, this_val);
    const other = try toTemporalZoned(arena, if (args.len > 0) args[0] else Value{}, null);
    if (!std.mem.eql(u8, z.tz, other.tz)) {
        // Difference across different zones with calendar units is not
        // representable without a common zone; only allow time-based largestUnit.
    }
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // `since` negates `until` rather than swapping the operands: both anchor
    // their calendar walk on the receiver, and calendar arithmetic is not
    // symmetric. Rounding runs mirrored, so the mode is negated too.
    const o = try shared.getDiffOptions(arena, opts, since);
    const smallest = o.smallest orelse .nanosecond;
    const largest = o.largest orelse if (unitRank(smallest) < unitRank(.hour)) smallest else .hour;
    if (unitRank(largest) > unitRank(smallest)) return realm_mod.throwRangeError(arena, "largestUnit must be >= smallestUnit");
    try shared.validateIncrement(arena, smallest, o.inc);

    const from = z.*;
    const to = other;

    var result: shared.DurationFields = undefined;
    // Rank 0 is `year`, so "day or larger" is a *lower* rank.
    if (unitRank(largest) <= unitRank(.day)) {
        result = differenceZoned(from, to, largest);
        if (smallest != .nanosecond or o.inc != 1) {
            // Round against the receiver's *local* calendar date. Candidate
            // dates are measured on the wall clock, which is exact for a fixed
            // offset and off by the offset shift only across a DST boundary.
            const lfrom = localDT(&from);
            const lto = localDT(&to);
            const dest_ns: i128 = @as(i128, shared.isoDateToEpochDays(lto.date.year, lto.date.month, lto.date.day) -
                shared.isoDateToEpochDays(lfrom.date.year, lfrom.date.month, lfrom.date.day)) * shared.NS_PER_DAY +
                (shared.timeToNanos(lto.time) - shared.timeToNanos(lfrom.time));
            const rr = try duration.roundRelativeBalanced(
                arena,
                result,
                lfrom.date,
                dest_ns,
                smallest,
                largest,
                o.inc,
                o.mode,
                if (dest_ns < 0) -1 else 1,
            );
            result = rr.d;
        }
    } else {
        result = balanceTime(to.ns - from.ns, largest);
        result = roundResult(result, smallest, o.inc, o.mode, largest);
    }
    if (since) result = shared.negateFields(result);
    result.years = nz(result.years);
    result.months = nz(result.months);
    result.weeks = nz(result.weeks);
    result.days = nz(result.days);
    result.hours = nz(result.hours);
    result.minutes = nz(result.minutes);
    result.seconds = nz(result.seconds);
    result.milliseconds = nz(result.milliseconds);
    result.microseconds = nz(result.microseconds);
    result.nanoseconds = nz(result.nanoseconds);
    return duration.makeDuration(arena, result);
}

/// Difference between two same-zone ZonedDateTimes with a calendar largest unit.
fn differenceZoned(a: ZonedDT, b: ZonedDT, largest: shared.Unit) shared.DurationFields {
    const la = localDT(&a);
    const lb = localDT(&b);
    var ns_diff = shared.timeToNanos(lb.time) - shared.timeToNanos(la.time);
    var d1 = la.date;
    const d2 = lb.date;
    const date_sign = plain_date.compareISODate(d1, d2);
    if (ns_diff < 0 and date_sign < 0) {
        d1 = shared.balanceISODate(d1.year, d1.month, @as(i32, d1.day) + 1);
        d1.calendar = d2.calendar;
        ns_diff += shared.NS_PER_DAY;
    } else if (ns_diff > 0 and date_sign > 0) {
        d1 = shared.balanceISODate(d1.year, d1.month, @as(i32, d1.day) - 1);
        d1.calendar = d2.calendar;
        ns_diff -= shared.NS_PER_DAY;
    }
    var date_dur = plain_date.differenceISODate(d1, d2, largest);
    const time_dur = balanceTime(ns_diff, .hour);
    date_dur.hours = time_dur.hours;
    date_dur.minutes = time_dur.minutes;
    date_dur.seconds = time_dur.seconds;
    date_dur.milliseconds = time_dur.milliseconds;
    date_dur.microseconds = time_dur.microseconds;
    date_dur.nanoseconds = time_dur.nanoseconds;
    return date_dur;
}

fn balanceTime(total_ns: i128, largest: shared.Unit) shared.DurationFields {
    const neg = total_ns < 0;
    var rem: i128 = if (neg) -total_ns else total_ns;
    var d = shared.DurationFields{};
    if (unitRank(largest) <= unitRank(.hour)) {
        d.hours = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_HOUR)));
        rem = @mod(rem, shared.NS_PER_HOUR);
    }
    if (unitRank(largest) <= unitRank(.minute)) {
        d.minutes = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MINUTE)));
        rem = @mod(rem, shared.NS_PER_MINUTE);
    }
    if (unitRank(largest) <= unitRank(.second)) {
        d.seconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_SECOND)));
        rem = @mod(rem, shared.NS_PER_SECOND);
    }
    if (unitRank(largest) <= unitRank(.millisecond)) {
        d.milliseconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MILLI)));
        rem = @mod(rem, shared.NS_PER_MILLI);
    }
    if (unitRank(largest) <= unitRank(.microsecond)) {
        d.microseconds = @floatFromInt(@as(i128, @divTrunc(rem, shared.NS_PER_MICRO)));
        rem = @mod(rem, shared.NS_PER_MICRO);
    }
    d.nanoseconds = @floatFromInt(@as(i128, rem));
    if (neg) {
        // Negate each field but keep +0 (avoid -0, which SameValue distinguishes).
        d.hours = nz(-d.hours);
        d.minutes = nz(-d.minutes);
        d.seconds = nz(-d.seconds);
        d.milliseconds = nz(-d.milliseconds);
        d.microseconds = nz(-d.microseconds);
        d.nanoseconds = nz(-d.nanoseconds);
    }
    return d;
}

/// Map -0 to +0 (Temporal Duration fields never carry a negative zero).
fn nz(x: f64) f64 {
    return if (x == 0) 0 else x;
}

fn roundResult(result: shared.DurationFields, smallest: shared.Unit, inc: f64, mode: shared.RoundingMode, largest: shared.Unit) shared.DurationFields {
    if (unitRank(smallest) < unitRank(.hour)) return result;
    if (result.years != 0 or result.months != 0 or result.weeks != 0 or result.days != 0) return result;
    const total = durTimeNanos(result);
    const per = shared.unitLengthNanos(smallest) orelse return result;
    const inc_ns = per * @as(i128, @intFromFloat(inc));
    const rounded = shared.roundI128ToIncrement(total, inc_ns, mode);
    return balanceTime(rounded, largest);
}

pub fn nativeUntil(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, false);
}
pub fn nativeSince(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return difference(arena, this_val, args, true);
}

pub fn nativeEquals(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const other = try toTemporalZoned(arena, if (args.len > 0) args[0] else Value{}, null);
    // Equality is on the instant, the zone *and* the calendar.
    return val_mod.makeBool(arena, z.ns == other.ns and std.mem.eql(u8, z.tz, other.tz) and
        z.calendar == other.calendar);
}

// ---------------------------------------------------------------- round ---

pub fn nativeStartOfDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const cur = localDT(z);
    const ns = try disambiguate(arena, z.tz, wallNs(.{ .date = cur.date, .time = .{} }), .compatible);
    return makeZoned(arena, .{ .ns = ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

pub fn nativeGetTimeZoneTransition(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    var dir: ?[]const u8 = null;
    if (arg.bits != 0 and arg.unbox() == .string) {
        dir = arg.unbox().string;
    } else if (arg.bits != 0 and arg.unbox() == .object) {
        const o = arg.toPtr().object;
        const dv = o.get("direction") orelse return realm_mod.throwTypeError(arena, "missing direction");
        if (dv.bits == 0 or dv.unbox() != .string) return realm_mod.throwTypeError(arena, "direction must be a string");
        dir = dv.unbox().string;
    } else if (arg.bits == 0 or arg.unbox() == .undefined_) {
        return realm_mod.throwTypeError(arena, "direction is required");
    } else {
        return realm_mod.throwTypeError(arena, "invalid direction argument");
    }
    if (!std.mem.eql(u8, dir.?, "next") and !std.mem.eql(u8, dir.?, "previous"))
        return realm_mod.throwRangeError(arena, "direction must be 'next' or 'previous'");
    // Fixed-offset / unknown zones have no transitions. Named IANA zones consult
    // the embedded tzdata for their DST transitions.
    const def = tzdata.lookupDef(z.tz) orelse return val_mod.makeNull(arena);
    const unix_sec: i64 = @intCast(@divFloor(z.ns, shared.NS_PER_SECOND));
    const trans_sec = tzdata.findTransition(def, unix_sec, if (std.mem.eql(u8, dir.?, "next")) .next else .previous) orelse
        return val_mod.makeNull(arena);
    return instant.makeInstant(arena, @as(i128, trans_sec) * shared.NS_PER_SECOND);
}

pub fn nativeRound(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    var opts: ?*JsObject = null;
    var smallest: ?shared.Unit = null;
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits == 0 or arg0.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "round() requires an argument");
    if (arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
    } else {
        opts = try shared.getOptionsObject(arena, arg0);
        smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    }
    if (smallest == null) return realm_mod.throwRangeError(arena, "round() requires smallestUnit");
    if (unitRank(smallest.?) < unitRank(.day)) return realm_mod.throwRangeError(arena, "smallestUnit must be day..nanosecond");
    const mode = try shared.getRoundingMode(arena, opts, .half_expand);
    const inc = try shared.getRoundingIncrement(arena, opts);

    const cur = localDT(z);
    const day_start_ns = try disambiguate(arena, z.tz, wallNs(.{ .date = cur.date, .time = .{} }), .compatible);
    const next = shared.balanceISODate(cur.date.year, cur.date.month, @as(i32, cur.date.day) + 1);
    // A DST day is 23 or 25 hours long, and "round to day" splits it in half.
    const day_len = (try disambiguate(arena, z.tz, wallNs(.{ .date = next, .time = .{} }), .compatible)) - day_start_ns;
    const since_start = z.ns - day_start_ns;
    var new_ns: i128 = undefined;
    if (smallest.? == .day) {
        const rounded = shared.roundI128ToIncrement(since_start, day_len, mode);
        new_ns = day_start_ns + rounded;
    } else {
        const inc_ns = shared.unitLengthNanos(smallest.?).? * @as(i128, @intFromFloat(inc));
        const rounded = shared.roundI128ToIncrement(since_start, inc_ns, mode);
        new_ns = day_start_ns + rounded;
    }
    return makeZoned(arena, .{ .ns = new_ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

// ---------------------------------------------------------------- toString ---

pub fn nativeToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const opts = try shared.getOptionsObject(arena, if (args.len > 0) args[0] else null);
    // The spec fixes this read order: calendarName, digits, offset, mode,
    // smallestUnit, timeZoneName. toString takes no roundingIncrement.
    const show_cal = try shared.getShowCalendar(arena, opts);
    const digits = try shared.getFractionalDigits(arena, opts);
    const show_off = try getShowOffset(arena, opts);
    const mode = try shared.getRoundingMode(arena, opts, .trunc);
    const prec = try shared.getSecondsStringPrecision(arena, opts, digits);
    const show_tz = try getShowTimeZoneName(arena, opts);
    // Rounding the epoch nanoseconds carries into the date for free.
    const z_ns = shared.roundI128ToIncrement(z.ns, prec.increment, mode);
    const s = try zonedToString(arena, z_ns, z.offset_ns, z.tz, z.calendar, prec, show_cal, show_off, show_tz);
    return val_mod.makeString(arena, s);
}

pub fn nativeToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const s = try zonedToString(arena, z.ns, z.offset_ns, z.tz, z.calendar, .{}, .auto, .auto, .auto);
    return val_mod.makeString(arena, s);
}

pub fn nativeToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    _ = try requireZoned(arena, this_val);
    return @import("../intl.zig").temporalToLocaleString(arena, this_val, args, .zoned);
}

pub fn nativeValueOf(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return realm_mod.throwTypeError(arena, "Called valueOf on a Temporal.ZonedDateTime");
}

const ShowOffset = enum { auto, never };
fn getShowOffset(arena: std.mem.Allocator, opts: ?*JsObject) !ShowOffset {
    const s = (try shared.readStringOption(arena, opts, "offset")) orelse return .auto;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "never")) return .never;
    return realm_mod.throwRangeError(arena, "invalid offset display option");
}

const ShowTZ = enum { auto, never, critical };
fn getShowTimeZoneName(arena: std.mem.Allocator, opts: ?*JsObject) !ShowTZ {
    const s = (try shared.readStringOption(arena, opts, "timeZoneName")) orelse return .auto;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "never")) return .never;
    if (std.mem.eql(u8, s, "critical")) return .critical;
    return realm_mod.throwRangeError(arena, "invalid timeZoneName option");
}

fn zonedToString(arena: std.mem.Allocator, ns: i128, offset_ns: i128, tz: []const u8, cal: shared.calendar_mod.CalendarId, prec: shared.SecondsPrecision, show_cal: shared.ShowCalendar, show_off: ShowOffset, show_tz: ShowTZ) ![]const u8 {
    const total = ns + offset_ns;
    const days: i64 = @intCast(@divFloor(total, shared.NS_PER_DAY));
    const tod = total - @as(i128, days) * shared.NS_PER_DAY;
    const tr = shared.nanosToTime(tod);
    const date = shared.epochDaysToISODate(days + tr.days);
    var buf = shared.Buf{};
    try shared.appendISOYear(arena, &buf, date.year);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, date.month, 2);
    try buf.append(arena, '-');
    try shared.appendPadded(arena, &buf, date.day, 2);
    try buf.append(arena, 'T');
    try buf.appendSlice(arena, try plain_time.timeToStringPrec(arena, tr.time, prec));
    if (show_off == .auto) {
        try buf.appendSlice(arena, try timezone.formatOffset(arena, offset_ns));
    }
    if (show_tz != .never) {
        try buf.append(arena, '[');
        if (show_tz == .critical) try buf.append(arena, '!');
        try buf.appendSlice(arena, tz);
        try buf.append(arena, ']');
    }
    try plain_date.appendCalendar(arena, &buf, show_cal, cal);
    return buf.items;
}

// ------------------------------------------------------------- registration ---

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const proto = try JsObject.create(arena, ctx.object_proto);
    proto_obj = proto;

    try intrinsics.setMethodLen(arena, proto, "with", nativeWith, 1);
    try intrinsics.setMethod(arena, proto, "withPlainTime", nativeWithPlainTime);
    try intrinsics.setMethod(arena, proto, "withTimeZone", nativeWithTimeZone);
    try intrinsics.setMethod(arena, proto, "withCalendar", nativeWithCalendar);
    try intrinsics.setMethodLen(arena, proto, "add", nativeAdd, 1);
    try intrinsics.setMethod(arena, proto, "subtract", nativeSubtract);
    try intrinsics.setMethod(arena, proto, "until", nativeUntil);
    try intrinsics.setMethod(arena, proto, "since", nativeSince);
    try intrinsics.setMethod(arena, proto, "equals", nativeEquals);
    try intrinsics.setMethod(arena, proto, "round", nativeRound);
    try intrinsics.setMethod(arena, proto, "startOfDay", nativeStartOfDay);
    try intrinsics.setMethodLen(arena, proto, "getTimeZoneTransition", nativeGetTimeZoneTransition, 1);
    try intrinsics.setMethod(arena, proto, "toInstant", nativeToInstant);
    try intrinsics.setMethod(arena, proto, "toPlainDate", nativeToPlainDate);
    try intrinsics.setMethod(arena, proto, "toPlainTime", nativeToPlainTime);
    try intrinsics.setMethod(arena, proto, "toPlainDateTime", nativeToPlainDateTime);
    try intrinsics.setMethod(arena, proto, "toString", nativeToString);
    try intrinsics.setMethodLen(arena, proto, "toJSON", nativeToJSON, 0);
    try intrinsics.setMethod(arena, proto, "toLocaleString", nativeToLocaleString);
    try intrinsics.setMethod(arena, proto, "valueOf", nativeValueOf);

    try intrinsics.defineGetter(arena, proto, "year", getYear);
    try intrinsics.defineGetter(arena, proto, "month", getMonth);
    try intrinsics.defineGetter(arena, proto, "day", getDay);
    try intrinsics.defineGetter(arena, proto, "monthCode", getMonthCode);
    try intrinsics.defineGetter(arena, proto, "hour", getHour);
    try intrinsics.defineGetter(arena, proto, "minute", getMinute);
    try intrinsics.defineGetter(arena, proto, "second", getSecond);
    try intrinsics.defineGetter(arena, proto, "millisecond", getMilli);
    try intrinsics.defineGetter(arena, proto, "microsecond", getMicro);
    try intrinsics.defineGetter(arena, proto, "nanosecond", getNano);
    try intrinsics.defineGetter(arena, proto, "epochMilliseconds", getEpochMilliseconds);
    try intrinsics.defineGetter(arena, proto, "epochNanoseconds", getEpochNanoseconds);
    try intrinsics.defineGetter(arena, proto, "offsetNanoseconds", getOffsetNanoseconds);
    try intrinsics.defineGetter(arena, proto, "offset", getOffset);
    try intrinsics.defineGetter(arena, proto, "timeZoneId", getTimeZoneId);
    try intrinsics.defineGetter(arena, proto, "calendarId", getCalendarId);
    try intrinsics.defineGetter(arena, proto, "dayOfWeek", getDayOfWeek);
    try intrinsics.defineGetter(arena, proto, "dayOfYear", getDayOfYear);
    try intrinsics.defineGetter(arena, proto, "weekOfYear", getWeekOfYear);
    try intrinsics.defineGetter(arena, proto, "yearOfWeek", getYearOfWeek);
    try intrinsics.defineGetter(arena, proto, "era", getEra);
    try intrinsics.defineGetter(arena, proto, "eraYear", getEraYear);
    try intrinsics.defineGetter(arena, proto, "daysInWeek", getDaysInWeek);
    try intrinsics.defineGetter(arena, proto, "daysInMonth", getDaysInMonth);
    try intrinsics.defineGetter(arena, proto, "daysInYear", getDaysInYear);
    try intrinsics.defineGetter(arena, proto, "monthsInYear", getMonthsInYear);
    try intrinsics.defineGetter(arena, proto, "inLeapYear", getInLeapYear);
    try intrinsics.defineGetter(arena, proto, "hoursInDay", getHoursInDay);

    const ctor = try intrinsics.makeCtor(arena, proto, nativeCtor, ctx.function_proto);
    try intrinsics.setMethod(arena, ctor, "from", nativeFrom);
    try intrinsics.setMethod(arena, ctor, "compare", nativeCompare);
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "ZonedDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.ZonedDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
}
