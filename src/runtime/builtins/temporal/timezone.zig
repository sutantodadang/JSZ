// SPDX-License-Identifier: Apache-2.0
//! Wave 27: time-zone identifier machinery for Temporal.ZonedDateTime.
//!
//! This test262 corpus targets the current Temporal proposal, in which
//! `Temporal.TimeZone` and `Temporal.Calendar` are NO LONGER objects — time
//! zones and calendars are plain string identifiers. (The staging suite even
//! asserts `!("TimeZone" in Temporal)`.) So there is no exotic TimeZone type
//! here; instead we parse/normalize identifier strings and compute UTC offsets.
//!
//! Supported zones: "UTC", fixed numeric offsets ("+01:00", "-08:00", …) at
//! minute precision, and named IANA zones (with DST rules) via embedded tzdata.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const realm_mod = @import("../../realm.zig");
const shared = @import("shared.zig");
const tzdata = @import("tzdata.zig");

/// Result of resolving a time-zone identifier: its normalized id and its UTC
/// offset in nanoseconds at the queried instant (may differ per instant for
/// named IANA zones with DST).
pub const Zone = struct {
    id: []const u8,
    offset_ns: i128,
};

/// Case-insensitive ASCII equality.
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Parse an offset *identifier* (minute precision only): `± HH (:? MM)?` that
/// consumes the entire slice. Returns the offset in ns and writes the
/// normalized "±HH:MM" form into `out` (must be >= 7 bytes). Sub-minute or
/// trailing garbage → null.
fn parseOffsetIdentifier(s: []const u8, out: *[7]u8) ?i128 {
    if (s.len < 3) return null;
    // Time-zone identifiers are ASCII only: the Unicode minus sign U+2212 is NOT
    // accepted here (unlike an ISO datetime's own offset field).
    const sign: i128 = switch (s[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    var i: usize = 1;
    if (i + 2 > s.len) return null;
    const h = twoDigit(s, i) orelse return null;
    i += 2;
    var m: i128 = 0;
    if (i < s.len) {
        if (s[i] == ':') i += 1;
        if (i + 2 > s.len) return null;
        m = twoDigit(s, i) orelse return null;
        i += 2;
    }
    if (i != s.len) return null; // sub-minute (":SS" / ".fff") or junk
    if (h > 23 or m > 59) return null;
    _ = std.fmt.bufPrint(out, "{c}{d:0>2}:{d:0>2}", .{ if (sign < 0) @as(u8, '-') else '+', @as(u64, @intCast(h)), @as(u64, @intCast(m)) }) catch return null;
    return sign * (h * shared.NS_PER_HOUR + m * shared.NS_PER_MINUTE);
}

fn twoDigit(s: []const u8, i: usize) ?i128 {
    if (i + 2 > s.len) return null;
    if (s[i] < '0' or s[i] > '9' or s[i + 1] < '0' or s[i + 1] > '9') return null;
    return @as(i128, s[i] - '0') * 10 + (s[i + 1] - '0');
}

/// Extract the time-zone annotation `[...]` from a datetime string. The
/// time-zone annotation is the first bracket whose content (minus an optional
/// leading '!') contains no '=' (calendar/other annotations are `[key=value]`).
/// Returns the inner id slice or null.
fn extractBracket(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '[') continue;
        const start = i + 1;
        var j = start;
        while (j < s.len and s[j] != ']') : (j += 1) {}
        if (j >= s.len) return null;
        var inner = s[start..j];
        if (inner.len > 0 and inner[0] == '!') inner = inner[1..];
        if (std.mem.indexOfScalar(u8, inner, '=') == null) return inner;
        i = j;
    }
    return null;
}

/// Resolve a time-zone identifier string (from a ctor arg or property bag) into
/// a Zone. Throws RangeError on an invalid string.
///
/// Accepts: "UTC" (any case), a bare offset identifier ("+01:00", "-08", …), a
/// named IANA zone ("America/New_York", …), or a datetime string carrying a
/// `[tz]` bracket / trailing offset / `Z`.
///
/// For IANA zones the offset depends on the instant; use `toZoneAtInstant` when
/// the epoch nanoseconds are known. This variant returns the standard (non-DST)
/// offset for IANA zones.
pub fn toZone(arena: std.mem.Allocator, s0: []const u8) !Zone {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    if (s.len == 0) return realm_mod.throwRangeError(arena, "invalid time zone");

    // 1. Direct "UTC".
    if (eqIgnoreCase(s, "UTC")) return .{ .id = "UTC", .offset_ns = 0 };

    // 2. Direct IANA zone name.
    if (tzdata.isKnownZone(s)) {
        const def = tzdata.lookupDef(s) orelse unreachable;
        return .{ .id = def.name, .offset_ns = @as(i128, def.std_offset_sec) * shared.NS_PER_SECOND };
    }

    // 3. Direct offset identifier.
    var buf: [7]u8 = undefined;
    if (parseOffsetIdentifier(s, &buf)) |ns| {
        return .{ .id = try arena.dupe(u8, buf[0..6]), .offset_ns = ns };
    }

    // 4. A datetime string. The whole datetime must still be valid (e.g. a
    //    negative-zero extended year is rejected even when a [tz] bracket is
    //    present); then the identifier comes from the [tz] bracket if present,
    //    else from the trailing offset / Z designator.
    _ = shared.parseISODateTimeOpts(s, false) catch return realm_mod.throwRangeError(arena, "invalid time zone string");
    if (extractBracket(s)) |inner| {
        if (eqIgnoreCase(inner, "UTC")) return .{ .id = "UTC", .offset_ns = 0 };
        if (tzdata.isKnownZone(inner)) {
            const def = tzdata.lookupDef(inner) orelse unreachable;
            return .{ .id = def.name, .offset_ns = @as(i128, def.std_offset_sec) * shared.NS_PER_SECOND };
        }
        if (parseOffsetIdentifier(inner, &buf)) |ns| {
            return .{ .id = try arena.dupe(u8, buf[0..6]), .offset_ns = ns };
        }
        return realm_mod.throwRangeError(arena, "invalid time zone annotation");
    }
    // No bracket: must be a datetime with a Z or minute-precision offset.
    return zoneFromDateTimeOffset(arena, s);
}

/// Resolve a time-zone identifier at a given instant (epoch nanoseconds).
/// Returns the correct UTC offset (DST-aware) for named IANA zones.
pub fn toZoneAtInstant(arena: std.mem.Allocator, s0: []const u8, epoch_ns: i128) !Zone {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    if (s.len == 0) return realm_mod.throwRangeError(arena, "invalid time zone");

    // 1. Direct "UTC".
    if (eqIgnoreCase(s, "UTC")) return .{ .id = "UTC", .offset_ns = 0 };

    // 2. Direct IANA zone name → compute offset at instant.
    if (tzdata.isKnownZone(s)) {
        const def = tzdata.lookupDef(s) orelse unreachable;
        const unix_sec: i64 = @intCast(@divFloor(epoch_ns, shared.NS_PER_SECOND));
        const offset_sec = tzdata.offsetAt(def, unix_sec) orelse def.std_offset_sec;
        return .{ .id = def.name, .offset_ns = @as(i128, offset_sec) * shared.NS_PER_SECOND };
    }

    // 3. Direct offset identifier.
    var buf: [7]u8 = undefined;
    if (parseOffsetIdentifier(s, &buf)) |ns| {
        return .{ .id = try arena.dupe(u8, buf[0..6]), .offset_ns = ns };
    }

    // 4. Datetime string.
    _ = shared.parseISODateTimeOpts(s, false) catch return realm_mod.throwRangeError(arena, "invalid time zone string");
    if (extractBracket(s)) |inner| {
        if (eqIgnoreCase(inner, "UTC")) return .{ .id = "UTC", .offset_ns = 0 };
        if (tzdata.isKnownZone(inner)) {
            const def = tzdata.lookupDef(inner) orelse unreachable;
            const unix_sec: i64 = @intCast(@divFloor(epoch_ns, shared.NS_PER_SECOND));
            const offset_sec = tzdata.offsetAt(def, unix_sec) orelse def.std_offset_sec;
            return .{ .id = def.name, .offset_ns = @as(i128, offset_sec) * shared.NS_PER_SECOND };
        }
        if (parseOffsetIdentifier(inner, &buf)) |ns| {
            return .{ .id = try arena.dupe(u8, buf[0..6]), .offset_ns = ns };
        }
        return realm_mod.throwRangeError(arena, "invalid time zone annotation");
    }
    return zoneFromDateTimeOffset(arena, s);
}

/// For a bracket-less datetime string, derive the zone from its trailing offset.
fn zoneFromDateTimeOffset(arena: std.mem.Allocator, s: []const u8) !Zone {
    // The string must parse as an ISO datetime (validates the date/time part).
    _ = shared.parseISODateTimeOpts(s, false) catch return realm_mod.throwRangeError(arena, "invalid time zone string");
    // Find the offset portion after the 'T'.
    const t_idx = std.mem.indexOfAny(u8, s, "Tt") orelse return realm_mod.throwRangeError(arena, "invalid time zone string");
    var i = t_idx + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 'Z' or c == 'z') {
            if (i + 1 == s.len) return .{ .id = "UTC", .offset_ns = 0 };
            return realm_mod.throwRangeError(arena, "invalid time zone string");
        }
        if (c == '+' or c == '-') {
            var buf: [7]u8 = undefined;
            const ns = parseOffsetIdentifier(s[i..], &buf) orelse return realm_mod.throwRangeError(arena, "sub-minute offset is not a valid time zone");
            return .{ .id = try arena.dupe(u8, buf[0..6]), .offset_ns = ns };
        }
    }
    return realm_mod.throwRangeError(arena, "bare date-time is not a time zone");
}

/// Format a fixed UTC offset (ns) as "±HH:MM" (or "±HH:MM:SS(.fff)" if the
/// offset carries sub-minute precision — not produced by our zones but handled
/// for completeness).
pub fn formatOffset(arena: std.mem.Allocator, offset_ns: i128) ![]const u8 {
    const neg = offset_ns < 0;
    var rem: i128 = if (neg) -offset_ns else offset_ns;
    const h: u64 = @intCast(@divTrunc(rem, shared.NS_PER_HOUR));
    rem = @mod(rem, shared.NS_PER_HOUR);
    const m: u64 = @intCast(@divTrunc(rem, shared.NS_PER_MINUTE));
    rem = @mod(rem, shared.NS_PER_MINUTE);
    const sec: u64 = @intCast(@divTrunc(rem, shared.NS_PER_SECOND));
    const sub: u64 = @intCast(@mod(rem, shared.NS_PER_SECOND));
    var buf = shared.Buf{};
    try buf.append(arena, if (neg) '-' else '+');
    try shared.appendPadded(arena, &buf, @intCast(h), 2);
    try buf.append(arena, ':');
    try shared.appendPadded(arena, &buf, @intCast(m), 2);
    if (sec != 0 or sub != 0) {
        try buf.append(arena, ':');
        try shared.appendPadded(arena, &buf, @intCast(sec), 2);
        if (sub != 0) {
            var frac: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{sub}) catch unreachable;
            var end: usize = 9;
            while (end > 0 and frac[end - 1] == '0') : (end -= 1) {}
            try buf.append(arena, '.');
            try buf.appendSlice(arena, frac[0..end]);
        }
    }
    return buf.items;
}
