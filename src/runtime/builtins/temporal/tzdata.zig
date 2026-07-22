// SPDX-License-Identifier: Apache-2.0
//! Wave 27: Minimal IANA time-zone database for Temporal intl402 conformance.
//!
//! Provides UTC offset lookup for named IANA zones via embedded DST rules and
//! transition data. Covers the zones used in test262 intl402/Temporal tests.
//!
//! Each zone has either a fixed offset (no DST) or a rule that describes its
//! DST transitions. Transitions are computed on the fly from the rule formula.

const std = @import("std");
const gen = @import("tzdata_zones.zig");

// ── helpers ─────────────────────────────────────────────────────────────────

/// Is `year` a leap year in the Gregorian/ISO calendar?
fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

/// Days from 1970-01-01 to the start of `year` (proleptic Gregorian).
fn daysToYear(year: i32) i64 {
    var y = @as(i64, year) - 1;
    // Days in full 400-year cycles
    const cycles = @divFloor(y, 400);
    y = @mod(y, 400);
    // Days in remaining years (each 400y cycle = 146097 days)
    return cycles * 146097 + y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + 1;
}

/// Days from 1970-01-01 to `(year, month, day)`.
fn toDays(year: i32, month: u8, day: u8) i64 {
    const MONTH_DAYS = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var d = daysToYear(year);
    for (0..(month - 1)) |m| d += MONTH_DAYS[m];
    if (month > 2 and isLeap(year)) d += 1;
    return d + @as(i64, day) - 1 - daysToYear(1970);
}

/// Nth weekday of month. `n` counting from 1 (1=first, 5=last).
/// Sunday=0, Monday=1, ..., Saturday=6.
/// Returns day-of-month (1-based).
fn nthWeekday(year: i32, month: u8, n: u8, weekday: u8) u8 {
    // Day of week of the 1st of the month (1970-01-01 = Thursday = 4).
    const first_dow = @mod(@as(i32, @intCast(toDays(year, month, 1))) + 4, 7);
    // Offset from first to the target weekday:
    const offset = (weekday + 7 - @as(u8, @intCast(first_dow))) % 7;
    const first_occurrence: u8 = 1 + offset;
    if (n <= 4) return first_occurrence + (n - 1) * 7;
    // Last occurrence: back up to the last full week.
    const month_len: u8 = switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    var last = first_occurrence;
    while (last + 7 <= month_len) last += 7;
    return last;
}

/// Last weekday of month.
fn lastWeekday(year: i32, month: u8, weekday: u8) u8 {
    const month_len: u8 = switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    const last_dow = @mod(@as(i32, @intCast(toDays(year, month, month_len))) + 4, 7);
    const diff = @rem(@as(i8, @intCast(weekday)) - @as(i8, @intCast(last_dow)) + 7, 7);
    return month_len - @as(u8, @intCast(@mod(-diff, 7)));
}

/// Seconds since Unix epoch for a given transition time.
fn transTime(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    const d = toDays(year, month, day);
    return d * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

// ── DST rule types ──────────────────────────────────────────────────────────

const DstRule = gen.Rule;

fn applyRule(r: *const DstRule, year: i32, std_offset_sec: i32, dst_save_sec: i32, start_out: *i64, end_out: *i64) void {
    // DST start transition
    const start_day: u8 = if (r.start_week < 5)
        nthWeekday(year, r.start_month, r.start_week, r.start_dow)
    else
        lastWeekday(year, r.start_month, r.start_dow);
    // Transition at local standard time (wall clock jumps forward).
    start_out.* = transTime(year, r.start_month, start_day, 0, 0, 0) + r.start_sec - @as(i64, std_offset_sec);

    // DST end transition
    const end_day: u8 = if (r.end_week < 5)
        nthWeekday(year, r.end_month, r.end_week, r.end_dow)
    else
        lastWeekday(year, r.end_month, r.end_dow);
    // Transition at local DST time (wall clock falls back).
    end_out.* = transTime(year, r.end_month, end_day, 0, 0, 0) + r.end_sec - @as(i64, std_offset_sec + dst_save_sec);
}

// ── Zone definition ─────────────────────────────────────────────────────────

pub const ZoneDef = gen.Zone;

fn lookupZoneDef(name: []const u8) ?*const ZoneDef {
    // The generated table is sorted by case-folded name.
    var lo: usize = 0;
    var hi: usize = gen.zones.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (orderIgnoreCase(name, gen.zones[mid].name)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return &gen.zones[mid],
        }
    }
    return null;
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return if (lx < ly) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Look up a ZoneDef by name. Public for use in timezone.zig.
pub fn lookupDef(name: []const u8) ?*const ZoneDef {
    return lookupZoneDef(name);
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Return the UTC offset in seconds for a zone definition at Unix timestamp
/// `unix_sec`. Handles both DST and non-DST zones.
pub fn offsetAt(def: *const ZoneDef, unix_sec: i64) ?i32 {
    if (def.rule == null) return def.std_offset_sec;

    const rule = &def.rule.?;
    // Compute DST transitions for the year of the timestamp and adjacent years
    // to handle edge cases near year boundaries.
    const tyear = unixYear(unix_sec);

    // Check the 3 relevant years (prev, current, next) for transitions.
    // This covers timestamps near the transition point.
    var y = tyear - 1;
    while (y <= tyear + 1) : (y += 1) {
        var start: i64 = undefined;
        var end: i64 = undefined;
        applyRule(rule, y, def.std_offset_sec, def.dst_save_sec, &start, &end);
        if (start > end) {
            // Southern hemisphere: DST spans year boundary.
            // start = DST start (e.g. Oct), end = DST end (e.g. Apr next year)
            if (end < start) {
                // DST runs from start to end of next year.
                if (unix_sec >= start and unix_sec < end + 365 * 86400) {
                    return def.std_offset_sec + def.dst_save_sec;
                }
            }
        } else {
            // Northern hemisphere: DST within one year.
            if (start <= unix_sec and unix_sec < end) {
                return def.std_offset_sec + def.dst_save_sec;
            }
        }
    }
    return def.std_offset_sec;
}

/// Find the next or previous DST transition for a zone at Unix timestamp
/// `unix_sec`. Returns the transition time in Unix seconds, or null if none.
pub fn findTransition(def: *const ZoneDef, unix_sec: i64, direction: enum { next, previous }) ?i64 {
    if (def.rule == null) return null;
    const rule = &def.rule.?;
    const tyear = unixYear(unix_sec);
    // Scan a ±50 year window and pick the nearest transition on the requested
    // side of `unix_sec`. Each year yields a DST-start and a DST-end transition;
    // their chronological order differs between hemispheres, so we don't assume
    // ordering and simply track the closest match.
    var best: ?i64 = null;
    var y = tyear - 50;
    while (y <= tyear + 50) : (y += 1) {
        var start: i64 = undefined;
        var end: i64 = undefined;
        applyRule(rule, y, def.std_offset_sec, def.dst_save_sec, &start, &end);
        for ([_]i64{ start, end }) |t| {
            switch (direction) {
                .next => if (t > unix_sec and (best == null or t < best.?)) {
                    best = t;
                },
                .previous => if (t < unix_sec and (best == null or t > best.?)) {
                    best = t;
                },
            }
        }
    }
    return best;
}

fn unixYear(unix_sec: i64) i32 {
    // Approximate year from days since epoch.
    const days = @divFloor(unix_sec, 86400);
    var y: i32 = @intCast(@divFloor(days, 365) + 1970);
    // Correct by counting actual days.
    while (toDays(y + 1, 1, 1) <= days) y += 1;
    while (toDays(y, 1, 1) > days) y -= 1;
    return y;
}

/// The name that stands for this zone's whole link group. Time-zone equality
/// compares these, so "Asia/Calcutta" and "Asia/Kolkata" count as one zone.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    const def = lookupZoneDef(name) orelse return null;
    return gen.zones[def.canon].name;
}

/// Check if `name` is a known IANA zone. Case-insensitive.
pub fn isKnownZone(name: []const u8) bool {
    return lookupZoneDef(name) != null;
}
