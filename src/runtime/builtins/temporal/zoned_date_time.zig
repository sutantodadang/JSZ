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

pub fn makeZoned(arena: std.mem.Allocator, z: ZonedDT) !Value {
    if (!isValidEpochNs(z.ns)) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    const slot = try arena.create(ZonedDT);
    slot.* = z;
    // A named zone's offset is a function of the instant, so never trust a
    // caller-supplied one: recompute it here and the slot can never go stale
    // across a DST boundary. (A fixed-offset identifier keeps what it was given.)
    slot.offset_ns = zoneOffsetAt(z.tz, z.offset_ns, z.ns);
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, proto_obj)
    else
        try JsObject.create(arena, proto_obj);
    obj.internal_kind = .temporal_zoned_date_time;
    obj.internal_slot = slot;
    return val_mod.makeObject(arena, obj);
}

fn installInto(arena: std.mem.Allocator, this_val: Value, z: ZonedDT) !Value {
    if (!isValidEpochNs(z.ns)) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    const slot = try arena.create(ZonedDT);
    slot.* = z;
    slot.offset_ns = zoneOffsetAt(z.tz, z.offset_ns, z.ns);
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
    // A Temporal.ZonedDateTime stands in for its own [[TimeZone]]
    // (ToTemporalTimeZoneIdentifier).
    if (getZoned(v)) |z| {
        if (epoch_ns) |ns| return timezone.toZoneAtInstant(arena, z.tz, ns);
        return timezone.toZone(arena, z.tz);
    }
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

fn getOffsetOption(arena: std.mem.Allocator, opts: ?*JsObject, default: OffsetOption) !OffsetOption {
    const s = (try shared.readStringOption(arena, opts, "offset")) orelse return default;
    if (std.mem.eql(u8, s, "prefer")) return .prefer;
    if (std.mem.eql(u8, s, "use")) return .use;
    if (std.mem.eql(u8, s, "ignore")) return .ignore;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return realm_mod.throwRangeError(arena, "invalid offset option");
}

pub const Disambiguation = enum { compatible, earlier, later, reject };

/// GetTemporalDisambiguationOption: ToString + membership check, "compatible"
/// default. Read (and validated) even when the result is unused, because the
/// exact sequence of option reads is observable.
pub fn getDisambiguationOption(arena: std.mem.Allocator, opts: ?*JsObject) !Disambiguation {
    const s = (try shared.readStringOption(arena, opts, "disambiguation")) orelse return .compatible;
    if (std.mem.eql(u8, s, "compatible")) return .compatible;
    if (std.mem.eql(u8, s, "earlier")) return .earlier;
    if (std.mem.eql(u8, s, "later")) return .later;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return realm_mod.throwRangeError(arena, "invalid disambiguation option");
}

/// Read the three ZonedDateTime.from options in their observable order
/// (disambiguation, offset, offset-fallback "reject", then overflow). All three
/// are always read and validated, including when the argument is already a
/// ZonedDateTime.
fn readFromOptions(arena: std.mem.Allocator, opts: ?*JsObject) !void {
    _ = try getDisambiguationOption(arena, opts);
    _ = try getOffsetOption(arena, opts, .reject);
    _ = try shared.getOverflow(arena, opts);
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
    // The `:` separator must be used consistently: either every HH/MM/SS group
    // is colon-separated or none is. Record the first choice and enforce it.
    var colon: ?bool = null;
    if (i < s.len) {
        if (s[i] == ':') {
            colon = true;
            i += 1;
        } else colon = false;
        m = od(s, i) orelse return realm_mod.throwRangeError(arena, "invalid offset string");
        i += 2;
        if (i < s.len and s[i] != '.' and s[i] != ',') {
            const has_colon = s[i] == ':';
            if (has_colon != colon.?) return realm_mod.throwRangeError(arena, "inconsistent offset separators");
            if (has_colon) i += 1;
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
                if (k == 0 or k > 9) return realm_mod.throwRangeError(arena, "invalid offset string");
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
pub fn toTemporalZoned(arena: std.mem.Allocator, v: Value, opts: ?*JsObject) !ZonedDT {
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
    // ToTemporalZonedDateTime reads the calendar first (ToTemporalCalendarIdentifier;
    // ISO strings ok), then does a single PrepareCalendarFields sweep over the
    // remaining fields — day, hour, microsecond, millisecond, minute, month,
    // monthCode, nanosecond, offset, second, timeZone, year — in that
    // alphabetical, observable order.
    const cal = if (try shared.optionGet(arena, o, "calendar")) |cv| try shared.resolveCalendarArg(arena, cv) else .iso8601;
    const bag = try plain_date.readDateBag(arena, o, .{ .time = true, .zoned = true, .fixed_cal = cal });

    // timeZone is required (a present-but-undefined value reads as absent).
    const tz_v = bag.time_zone orelse return realm_mod.throwTypeError(arena, "missing timeZone");
    const zone = try toTimeZone(arena, tz_v, null);

    // An offset given as a field is an "option"-behaviour offset; absent is "wall".
    var so = StringOffset{ .behaviour = .wall };
    if (bag.offset) |os| so = .{ .behaviour = .option, .ns = try parseOffsetValue(arena, os) };

    // Options are read after every field, in observable order, and the overflow
    // they carry governs regulation of the already-read wall-clock fields.
    const dis = try getDisambiguationOption(arena, opts);
    const offset_opt = try getOffsetOption(arena, opts, .reject);
    const overflow = try shared.getOverflow(arena, opts);

    var date = try plain_date.dateFromBag(arena, bag, overflow);
    date.calendar = cal;
    const time = try timeFromBag(arena, bag, overflow);
    const dt = ISODateTime{ .date = date, .time = time };
    const ns = try interpretOffset(arena, zone.id, dt, zone.offset_ns, so, offset_opt, dis);
    return .{ .ns = ns, .tz = zone.id, .offset_ns = zoneOffsetAt(zone.id, zone.offset_ns, ns), .calendar = cal };
}

/// Regulate the time fields already read into a property bag into an ISOTime.
fn timeFromBag(arena: std.mem.Allocator, bag: plain_date.DateBag, overflow: shared.Overflow) !ISOTime {
    const h = bag.hour orelse 0;
    const min = bag.minute orelse 0;
    const s = bag.second orelse 0;
    const ms = bag.millisecond orelse 0;
    const us = bag.microsecond orelse 0;
    const ns = bag.nanosecond orelse 0;
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


/// The zone's UTC offset at an exact instant. A fixed-offset identifier has no
/// tzdata entry and never varies, so `fixed` stands in for it.
pub fn zoneOffsetAt(tz: []const u8, fixed: i128, ns: i128) i128 {
    const def = tzdata.lookupDef(tz) orelse return fixed;
    const sec: i64 = @intCast(@divFloor(ns, shared.NS_PER_SECOND));
    return @as(i128, tzdata.offsetAt(def, sec) orelse def.std_offset_sec) * shared.NS_PER_SECOND;
}

/// GetPossibleEpochNanoseconds: the instants a wall-clock time maps to, earliest
/// first. A wall time inside a spring-forward gap has none; one inside a
/// fall-back repetition has two. The candidate offsets are those in force a day
/// either side of the wall time, which brackets any single transition.
fn possibleInstants(tz: []const u8, fixed: i128, wall: i128) [2]?i128 {
    var out: [2]?i128 = .{ null, null };
    if (tzdata.lookupDef(tz) == null) {
        out[0] = wall - fixed;
        return out;
    }
    const day = shared.NS_PER_DAY;
    const before = zoneOffsetAt(tz, fixed, wall - day);
    const after = zoneOffsetAt(tz, fixed, wall + day);
    var n: usize = 0;
    // The larger offset yields the earlier instant, so order the probes by it.
    const hi = @max(before, after);
    const lo = @min(before, after);
    for ([_]i128{ hi, lo }) |o| {
        if (o == lo and hi == lo and n > 0) continue;
        const t = wall - o;
        if (zoneOffsetAt(tz, fixed, t) == o) {
            out[n] = t;
            n += 1;
        }
    }
    return out;
}

fn instantCount(p: [2]?i128) usize {
    return @as(usize, @intFromBool(p[0] != null)) + @as(usize, @intFromBool(p[1] != null));
}

/// DisambiguatePossibleEpochNanoseconds: resolve a wall time that is ambiguous
/// (a fall-back repetition, two instants) or nonexistent (a spring-forward gap,
/// zero instants) according to the `dis` policy.
pub fn disambiguate(arena: std.mem.Allocator, tz: []const u8, fixed: i128, wall: i128, dis: Disambiguation) !i128 {
    const p = possibleInstants(tz, fixed, wall);
    const cnt = instantCount(p);
    if (cnt == 1) return p[0].?;
    if (cnt == 2) return switch (dis) {
        .earlier, .compatible => p[0].?,
        .later => p[1].?,
        .reject => realm_mod.throwRangeError(arena, "wall-clock time is ambiguous"),
    };
    // In a gap (cnt == 0): shift the wall time out of the gap by its width, then
    // take the earliest (earlier) or latest (compatible/later) real instant.
    if (dis == .reject) return realm_mod.throwRangeError(arena, "wall-clock time does not exist");
    const before = zoneOffsetAt(tz, fixed, wall - shared.NS_PER_DAY);
    const after = zoneOffsetAt(tz, fixed, wall + shared.NS_PER_DAY);
    const gap = after - before;
    if (dis == .earlier) {
        const p2 = possibleInstants(tz, fixed, wall - gap);
        return p2[0] orelse (wall - gap - after);
    }
    const p2 = possibleInstants(tz, fixed, wall + gap);
    if (p2[1]) |t| return t;
    return p2[0] orelse (wall + gap - before);
}

/// InterpretISODateTimeOffset.
fn interpretOffset(arena: std.mem.Allocator, tz: []const u8, dt: ISODateTime, zone_offset: i128, so: StringOffset, opt: OffsetOption, dis: Disambiguation) !i128 {
    const wall = wallNs(dt);
    switch (so.behaviour) {
        // No offset in the source: purely a wall-clock time.
        .wall => return disambiguate(arena, tz, zone_offset, wall, dis),
        // A `Z` designator: the instant is exact, taken verbatim with no
        // reconciliation against the zone's own offset.
        .exact => return wall - so.ns,
        .option => {
            if (opt == .use) return wall - so.ns;
            if (opt == .ignore) return disambiguate(arena, tz, zone_offset, wall, dis);
            // "prefer" and "reject" both honour an offset that really occurs at
            // this wall time; they differ only when none does.
            for (possibleInstants(tz, zone_offset, wall)) |maybe_t| {
                const t = maybe_t orelse continue;
                const cand = zoneOffsetAt(tz, zone_offset, t);
                if (cand == so.ns) return t;
                if (so.match_minutes and roundOffsetToMinutes(cand) == so.ns) return t;
            }
            if (opt == .reject) return realm_mod.throwRangeError(arena, "offset does not match time zone");
            return disambiguate(arena, tz, zone_offset, wall, dis);
        },
    }
}

fn zonedFromString(arena: std.mem.Allocator, s0: []const u8, opts: ?*JsObject) !ZonedDT {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    // A single [tz] bracket is mandatory; validate all annotations in one pass.
    const bracket = try extractAnnotations(arena, s);
    const zone = try timezone.toZone(arena, bracket);
    // ZonedDateTime accepts a `Z` UTC designator (unlike the plain types).
    const dt = shared.parseISODateTimeOpts(s, .{ .validate_calendar = true, .reject_utc = false }) catch return realm_mod.throwRangeError(arena, "invalid ZonedDateTime string");
    // The parsed wall-clock datetime must itself be representable.
    if (!shared.isoDateTimeWithinLimits(dt.date, dt.time)) return realm_mod.throwRangeError(arena, "ZonedDateTime wall-clock time out of range");
    const str_off = extractStringOffset(arena, s) catch |e| return e;
    // Options are read after the string is parsed, in observable order:
    // disambiguation, offset, overflow.
    const dis = try getDisambiguationOption(arena, opts);
    const offset_opt = try getOffsetOption(arena, opts, .reject);
    _ = try shared.getOverflow(arena, opts);
    const ns = try interpretOffset(arena, zone.id, dt, zone.offset_ns, str_off, offset_opt, dis);
    // The resulting instant must be a valid epoch nanoseconds value.
    if (ns < -shared.NS_LIMIT or ns > shared.NS_LIMIT) return realm_mod.throwRangeError(arena, "ZonedDateTime out of range");
    return .{ .ns = ns, .tz = zone.id, .offset_ns = zoneOffsetAt(zone.id, zone.offset_ns, ns), .calendar = dt.date.calendar };
}

/// Scan every `[...]` annotation on a ZonedDateTime string: require exactly one
/// time-zone annotation (bracket with no '='), reject a second one, and reject a
/// non-ISO calendar annotation. Returns the time-zone annotation's inner id.
fn extractAnnotations(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var tz: ?[]const u8 = null;
    var saw_calendar = false;
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
            // Only the first calendar annotation is meaningful; later ones are
            // ignored outright, unknown value and all.
            if (!saw_calendar) {
                saw_calendar = true;
                if (calendar.canonicalize(inner[5..]) == null) return realm_mod.throwRangeError(arena, "unsupported calendar");
            }
        }
    }
    return tz orelse realm_mod.throwRangeError(arena, "ZonedDateTime string requires a time zone");
}

/// How a ZonedDateTime string carries its UTC offset, mirroring the spec's
/// offsetBehaviour: `wall` (no offset — use the zone), `exact` (a `Z` designator
/// — take the instant verbatim, no zone-match check), or `option` (a numeric
/// ±HH:MM offset — reconcile it with the zone per the offset option).
const OffsetBehaviour = enum { wall, exact, option };
const StringOffset = struct {
    behaviour: OffsetBehaviour,
    ns: i128 = 0,
    /// `match-minutes` (ParseISODateTime): an offset written with only hours and
    /// minutes also matches a zone offset that rounds to it, so
    /// `-00:45[Africa/Monrovia]` accepts the zone's real -00:44:30.
    match_minutes: bool = false,
};

/// True when an offset token carries no seconds — `±HH` or `±HH:MM` in either
/// the extended or the basic spelling.
fn offsetIsMinutePrecision(tok: []const u8) bool {
    var digits: usize = 0;
    for (tok[1..]) |c| {
        if (c >= '0' and c <= '9') digits += 1;
    }
    return digits <= 4;
}

/// RoundNumberToIncrement(ns, 60e9, half-expand) — the minute an offset rounds to.
fn roundOffsetToMinutes(ns: i128) i128 {
    const minute = shared.NS_PER_MINUTE;
    const half = @divTrunc(minute, 2);
    return if (ns >= 0)
        @divFloor(ns + half, minute) * minute
    else
        -(@divFloor(-ns + half, minute) * minute);
}

/// Extract the trailing UTC offset (ns) and its behaviour from a datetime string.
fn extractStringOffset(arena: std.mem.Allocator, s: []const u8) !StringOffset {
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '[')) |b| end = b;
    const body = s[0..end];
    const t_idx = std.mem.indexOfAny(u8, body, "Tt") orelse return .{ .behaviour = .wall };
    var i = t_idx + 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == 'Z' or c == 'z') return .{ .behaviour = .exact };
        if (c == '+' or c == '-') return .{
            .behaviour = .option,
            .ns = try parseOffsetValue(arena, body[i..]),
            // Sub-minute precision in the source means an exact match is required.
            .match_minutes = offsetIsMinutePrecision(body[i..]),
        };
    }
    return .{ .behaviour = .wall };
}

// ------------------------------------------------------------- static methods ---

pub fn nativeFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    // An already-constructed ZonedDateTime is copied, but the options are still
    // read and validated (disambiguation, offset, overflow).
    if (getZoned(v)) |z| {
        try readFromOptions(arena, opts);
        return makeZoned(arena, z.*);
    }
    // A string is parsed before its options are read; a property bag reads its
    // fields then options. Both paths read/validate the options inside
    // toTemporalZoned, so `from` does not read them again.
    const z = try toTemporalZoned(arena, v, opts);
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
    const d = localDT(z).date;
    if (d.calendar != .iso8601) return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(shared.weekOfYear(d)));
}
fn getYearOfWeek(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const d = localDT(z).date;
    if (d.calendar != .iso8601) return Value{};
    return val_mod.makeNumber(arena, @floatFromInt(yearOfWeek(d)));
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
    _ = tzdata.lookupDef(z.tz) orelse return val_mod.makeNumber(arena, 24);
    // The day's length is the gap between its own start and the next day's, both
    // resolved through the zone — that is what makes a transition day 23h or 25h.
    return val_mod.makeNumber(arena, shared.divToF64(try dayLength(arena, z), shared.NS_PER_HOUR));
}

/// The ZonedDateTime's local day as [start, end) instants, and its length.
const DaySpan = struct { start: i128, end: i128, len: i128 };

fn daySpan(arena: std.mem.Allocator, z: *const ZonedDT) !DaySpan {
    const date = localDT(z).date;
    const start = try startOfDay(arena, z.tz, z.offset_ns, date);
    const next = shared.balanceISODate(date.year, date.month, @as(i32, date.day) + 1);
    const end = try startOfDay(arena, z.tz, z.offset_ns, next);
    return .{ .start = start, .end = end, .len = end - start };
}

fn dayLength(arena: std.mem.Allocator, z: *const ZonedDT) !i128 {
    return (try daySpan(arena, z)).len;
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
    if (v.bits == 0 or v.unbox() == .undefined_) return realm_mod.throwTypeError(arena, "withCalendar requires a calendar");
    // The instant and zone are unchanged; only the lens through which the
    // wall-clock date is read. A calendar-bearing Temporal object contributes
    // its own [[Calendar]] (ToTemporalCalendarIdentifier fast path).
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
    // With no argument the result is the start of the day, which in a zone whose
    // midnight is skipped is *not* simply wall-midnight (GetStartOfDay).
    const ns = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_)
        try disambiguate(arena, z.tz, z.offset_ns, wallNs(.{ .date = cur.date, .time = time }), .compatible)
    else
        try startOfDay(arena, z.tz, z.offset_ns, cur.date);
    return makeZoned(arena, .{ .ns = ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

/// TimeZoneEquals: two identifiers name the same zone when they canonicalize to
/// the same primary name — "Asia/Calcutta" and "Asia/Kolkata" are one zone.
fn timeZoneEquals(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const ca = tzdata.canonicalName(a) orelse return false;
    const cb = tzdata.canonicalName(b) orelse return false;
    return std.mem.eql(u8, ca, cb);
}

pub fn nativeWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    if (arg.bits == 0 or arg.unbox() != .object) return realm_mod.throwTypeError(arena, "with() requires an object");
    // Any Temporal date/time object (including PlainYearMonth/PlainMonthDay) is
    // rejected — with() takes a plain fields bag (RejectTemporalLikeObject).
    switch (arg.toPtr().object.internal_kind) {
        .temporal_zoned_date_time, .temporal_plain_date, .temporal_plain_time, .temporal_plain_date_time, .temporal_plain_year_month, .temporal_plain_month_day => return realm_mod.throwTypeError(arena, "with() argument must be a plain object"),
        else => {},
    }
    const o = arg.toPtr().object;
    if (try shared.optionGet(arena, o, "calendar") != null) return realm_mod.throwTypeError(arena, "with() may not set calendar");
    if (try shared.optionGet(arena, o, "timeZone") != null) return realm_mod.throwTypeError(arena, "with() may not set timeZone");
    // The bag is read in full before any option is consulted; the "offset"
    // field lands in its alphabetical slot among the rest. timeZone is NOT read
    // here — it was already rejected above (RejectObjectWithCalendarOrTimeZone).
    const bag = try plain_date.readDateBag(arena, o, .{ .time = true, .zoned = true, .skip_time_zone = true, .fixed_cal = z.calendar });
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);
    const dis = try getDisambiguationOption(arena, opts);
    const offset_opt = try getOffsetOption(arena, opts, .prefer);
    const overflow = try shared.getOverflow(arena, opts);

    const so: StringOffset = if (bag.offset) |os| .{ .behaviour = .option, .ns = try parseOffsetValue(arena, os) } else .{ .behaviour = .wall };
    if (!bag.hasDateField() and !bag.hasTimeField() and bag.offset == null)
        return realm_mod.throwTypeError(arena, "with() needs at least one field");

    const cur = localDT(z);
    const merged = try plain_date.withDateFields(arena, cur.date, bag, overflow);
    const time = try plain_date_time.timeFromBag(arena, bag, overflow, cur.time);
    const new_ns = try interpretOffset(arena, z.tz, .{ .date = merged.date, .time = time }, z.offset_ns, so, offset_opt, dis);
    return makeZoned(arena, .{ .ns = new_ns, .tz = z.tz, .offset_ns = zoneOffsetAt(z.tz, z.offset_ns, new_ns), .calendar = z.calendar });
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
        new_ns = try disambiguate(arena, z.tz, z.offset_ns, wallNs(.{ .date = new_date, .time = cur.time }), .compatible);
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
    if (z.calendar != other.calendar) return realm_mod.throwRangeError(arena, "calendar mismatch");
    const opts = try shared.getOptionsObject(arena, if (args.len > 1) args[1] else null);

    // `since` negates `until` rather than swapping the operands: both anchor
    // their calendar walk on the receiver, and calendar arithmetic is not
    // symmetric. Rounding runs mirrored, so the mode comes back negated.
    const st = try shared.getDifferenceSettings(arena, opts, since, .datetime, &.{}, .nanosecond, .hour);
    if (unitRank(st.largest) <= unitRank(.day)) {
        // A date-unit difference is measured in local wall-clock terms, which
        // only exists if both instants share a zone.
        if (!timeZoneEquals(z.tz, other.tz))
            return realm_mod.throwRangeError(arena, "time zone mismatch in date-unit difference");
    }
    const from = z.*;
    const to = other;

    var result: shared.DurationFields = undefined;
    // Rank 0 is `year`, so "day or larger" is a *lower* rank.
    if (unitRank(st.largest) <= unitRank(.day)) {
        result = try differenceZoned(arena, from, to, st.largest);
    } else {
        result = balanceTime(to.ns - from.ns, st.largest);
    }
    const lto = localDT(&to);
    const dest_wall = @as(i128, shared.isoDateToEpochDays(lto.date.year, lto.date.month, lto.date.day)) *
        shared.NS_PER_DAY + shared.timeToNanos(lto.time);
    result = try plain_date_time.roundRelative(arena, localDT(&from), dest_wall, result, st.smallest, st.increment, st.mode, st.largest);
    if (since) result = shared.negateFields(result);
    return duration.makeDuration(arena, result);
}

/// DifferenceZonedDateTime with a calendar largest unit. The date part is
/// measured on the wall clock, but the leftover time is the *exact* gap to the
/// target instant: on a 23- or 25-hour DST day the two disagree, and only the
/// exact gap is real elapsed time. Re-anchoring can overshoot, so the end date
/// is walked back a day at a time until the leftover time stops pointing the
/// wrong way.
fn differenceZoned(arena: std.mem.Allocator, a: ZonedDT, b: ZonedDT, largest: shared.Unit) !shared.DurationFields {
    if (a.ns == b.ns) return .{};
    const sign: i32 = if (b.ns > a.ns) 1 else -1;
    const la = localDT(&a);
    const lb = localDT(&b);

    const max_correction: i32 = if (sign == 1) 2 else 1;
    var correction: i32 = 0;
    const time_diff = shared.timeToNanos(lb.time) - shared.timeToNanos(la.time);
    // A time-of-day difference pointing against the overall direction already
    // costs a day, so start there rather than discovering it a round later.
    if ((time_diff > 0 and sign < 0) or (time_diff < 0 and sign > 0)) correction = 1;

    while (correction <= max_correction) : (correction += 1) {
        var inter_date = shared.balanceISODate(lb.date.year, lb.date.month, @as(i32, lb.date.day) - correction * sign);
        inter_date.calendar = lb.date.calendar;
        const inter_ns = try disambiguate(arena, a.tz, a.offset_ns, wallNs(.{ .date = inter_date, .time = la.time }), .compatible);
        const rem = b.ns - inter_ns;
        const rem_sign: i32 = if (rem > 0) 1 else if (rem < 0) -1 else 0;
        if (rem_sign == -sign) continue;
        var date_dur = plain_date.differenceISODate(la.date, inter_date, largest);
        const time_dur = balanceTime(rem, .hour);
        date_dur.hours = time_dur.hours;
        date_dur.minutes = time_dur.minutes;
        date_dur.seconds = time_dur.seconds;
        date_dur.milliseconds = time_dur.milliseconds;
        date_dur.microseconds = time_dur.microseconds;
        date_dur.nanoseconds = time_dur.nanoseconds;
        return date_dur;
    }
    return .{};
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
    return val_mod.makeBool(arena, z.ns == other.ns and timeZoneEquals(z.tz, other.tz) and
        z.calendar == other.calendar);
}

// ---------------------------------------------------------------- round ---

pub fn nativeStartOfDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const ns = try startOfDay(arena, z.tz, z.offset_ns, localDT(z).date);
    return makeZoned(arena, .{ .ns = ns, .tz = z.tz, .offset_ns = z.offset_ns, .calendar = z.calendar });
}

/// GetStartOfDay: the earliest instant of `date` in `tz`. Midnight itself may be
/// skipped by a DST jump (1919-03-31 in America/Toronto started at 00:30), in
/// which case the day begins at the transition.
fn startOfDay(arena: std.mem.Allocator, tz: []const u8, fixed: i128, date: shared.ISODate) !i128 {
    return disambiguate(arena, tz, fixed, wallNs(.{ .date = date, .time = .{} }), .compatible);
}

pub fn nativeGetTimeZoneTransition(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const z = try requireZoned(arena, this_val);
    const arg = if (args.len > 0) args[0] else Value{};
    var dir: ?[]const u8 = null;
    if (arg.bits != 0 and arg.unbox() == .string) {
        dir = arg.unbox().string;
    } else if (arg.bits != 0 and arg.unbox() == .object) {
        const o = arg.toPtr().object;
        // GetDirectionOption: the value is coerced with ToString (a Symbol is a
        // TypeError) and must be "next"/"previous"; a missing/undefined direction
        // is a RangeError (the option is required with no default).
        const dv = try shared.optionGet(arena, o, "direction") orelse return realm_mod.throwRangeError(arena, "direction is required");
        dir = try shared.valueToString(arena, dv);
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
    var inc: f64 = 1;
    var mode: shared.RoundingMode = .half_expand;
    if (arg0.unbox() == .string) {
        smallest = shared.unitFromString(arg0.unbox().string) orelse return realm_mod.throwRangeError(arena, "invalid smallestUnit");
    } else {
        // Read order: roundingIncrement, roundingMode, smallestUnit; then validate.
        opts = try shared.getOptionsObject(arena, arg0);
        inc = try shared.getRoundingIncrement(arena, opts);
        mode = try shared.getRoundingMode(arena, opts, .half_expand);
        smallest = try shared.getTemporalUnit(arena, opts, "smallestUnit");
    }
    if (smallest == null) return realm_mod.throwRangeError(arena, "round() requires smallestUnit");
    if (unitRank(smallest.?) < unitRank(.day)) return realm_mod.throwRangeError(arena, "smallestUnit must be day..nanosecond");
    // ValidateTemporalRoundingIncrement: day allows only 1 (inclusive); a time
    // unit's increment must divide (non-inclusive) its next-coarser unit.
    if (smallest.? == .day)
        try shared.validateRoundingIncrement(arena, inc, 1, true)
    else if (shared.maximumRoundingIncrement(smallest.?)) |maxv|
        try shared.validateRoundingIncrement(arena, inc, maxv, false);

    const span = try daySpan(arena, z);
    const day_start_ns = span.start;
    const day_len = span.len;
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
    // Rounding the epoch nanoseconds carries into the date for free. Modes apply
    // as if the epoch were positive, so "trunc"/"floor" go towards the Big Bang.
    const z_ns = shared.roundI128ToIncrementAsIfPositive(z.ns, prec.increment, mode);
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
        try buf.appendSlice(arena, try timezone.formatOffsetRounded(arena, offset_ns));
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
    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ctor.defineOwnData("name", try val_mod.makeString(arena, "ZonedDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(arena, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    ctor_obj = ctor;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const proto = proto_obj orelse return;
    try proto.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.ZonedDateTime"), .{ .writable = false, .enumerable = false, .configurable = true });
}
