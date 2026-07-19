// SPDX-License-Identifier: Apache-2.0
//! Wave 27: Minimal IANA time-zone database for Temporal intl402 conformance.
//!
//! Provides UTC offset lookup for named IANA zones via embedded DST rules and
//! transition data. Covers the zones used in test262 intl402/Temporal tests.
//!
//! Each zone has either a fixed offset (no DST) or a rule that describes its
//! DST transitions. Transitions are computed on the fly from the rule formula.

const std = @import("std");

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

const DstRule = struct {
    start_month: u8,   // Transition to DST
    start_weekday: u8, // Sunday=0
    start_occurrence: i8, // positive = Nth, negative = last
    start_hour: u8,
    end_month: u8,      // Transition back to standard
    end_weekday: u8,
    end_occurrence: i8,
    end_hour: u8,
};

fn applyRule(r: *const DstRule, year: i32, std_offset_sec: i32, dst_save_sec: i32, start_out: *i64, end_out: *i64) void {
    // DST start transition
    const start_day: u8 = if (r.start_occurrence > 0)
        nthWeekday(year, r.start_month, @as(u8, @intCast(r.start_occurrence)), r.start_weekday)
    else
        lastWeekday(year, r.start_month, r.start_weekday);
    // Transition at local standard time (wall clock jumps forward).
    start_out.* = transTime(year, r.start_month, start_day, r.start_hour, 0, 0) - @as(i64, std_offset_sec);

    // DST end transition
    const end_day: u8 = if (r.end_occurrence > 0)
        nthWeekday(year, r.end_month, @as(u8, @intCast(r.end_occurrence)), r.end_weekday)
    else
        lastWeekday(year, r.end_month, r.end_weekday);
    // Transition at local DST time (wall clock falls back).
    end_out.* = transTime(year, r.end_month, end_day, r.end_hour, 0, 0) - @as(i64, std_offset_sec + dst_save_sec);
}

// ── Zone definition ─────────────────────────────────────────────────────────

pub const ZoneDef = struct {
    name: []const u8,
    std_offset_sec: i32, // Standard time offset from UTC (seconds, positive east)
    dst_save_sec: i32,   // Additional offset during DST (usually 3600)
    dst_rule: ?DstRule,
};

fn lookupZoneDef(name: []const u8) ?*const ZoneDef {
    for (&ZONES) |*z| {
        if (eqIgnoreCase(name, z.name)) return z;
    }
    return null;
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
    if (def.dst_rule == null) return def.std_offset_sec;

    const rule = &def.dst_rule.?;
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
    if (def.dst_rule == null) return null;
    const rule = &def.dst_rule.?;
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

// ── Zone list ───────────────────────────────────────────────────────────────
// DST rules:
//   US (2007+):  2nd Sun Mar 2:00 → 1st Sun Nov 2:00  (northern)
//   EU:          Last Sun Mar 1:00 UTC → Last Sun Oct 1:00 UTC  (northern)
//   AU (Sydney): 1st Sun Oct 2:00 → 1st Sun Apr 3:00 AEDT  (southern)
//   NZ:          Last Sun Sep 2:00 → 1st Sun Apr 3:00 NZDT  (southern)

const ZONES = [_]ZoneDef{
    // ── No DST ──────────────────────────────────────────
    .{ .name = "UTC", .std_offset_sec = 0, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Tokyo", .std_offset_sec = 9 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Shanghai", .std_offset_sec = 8 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Hong_Kong", .std_offset_sec = 8 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Seoul", .std_offset_sec = 9 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Singapore", .std_offset_sec = 8 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Kolkata", .std_offset_sec = 5 * 3600 + 1800, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Asia/Dubai", .std_offset_sec = 4 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Europe/Moscow", .std_offset_sec = 3 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Africa/Cairo", .std_offset_sec = 2 * 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "Africa/Lagos", .std_offset_sec = 3600, .dst_save_sec = 0, .dst_rule = null },
    .{ .name = "America/Argentina/Buenos_Aires", .std_offset_sec = -3 * 3600, .dst_save_sec = 0, .dst_rule = null },

    // ── US zones (2007+ rules) ──────────────────────────
    .{
        .name = "America/New_York",
        .std_offset_sec = -5 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Chicago",
        .std_offset_sec = -6 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Denver",
        .std_offset_sec = -7 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Los_Angeles",
        .std_offset_sec = -8 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Phoenix",
        .std_offset_sec = -7 * 3600,
        .dst_save_sec = 0,
        .dst_rule = null,
    },
    .{
        .name = "America/Anchorage",
        .std_offset_sec = -9 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },

    // ── EU zones (last Sun Mar / last Sun Oct) ──────────
    .{
        .name = "Europe/London",
        .std_offset_sec = 0,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Paris",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Berlin",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Rome",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Madrid",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Amsterdam",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Stockholm",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Prague",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Warsaw",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Budapest",
        .std_offset_sec = 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Helsinki",
        .std_offset_sec = 2 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = -1, .start_hour = 1,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 1,
        },
    },
    .{
        .name = "Europe/Istanbul",
        .std_offset_sec = 3 * 3600,
        .dst_save_sec = 0,
        .dst_rule = null,
    },

    // ── Australia (southern hemisphere) ──────────────────
    .{
        .name = "Australia/Sydney",
        .std_offset_sec = 10 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 10, .start_weekday = 0, .start_occurrence = 1, .start_hour = 2,
            .end_month = 4, .end_weekday = 0, .end_occurrence = 1, .end_hour = 3,
        },
    },
    .{
        .name = "Australia/Melbourne",
        .std_offset_sec = 10 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 10, .start_weekday = 0, .start_occurrence = 1, .start_hour = 2,
            .end_month = 4, .end_weekday = 0, .end_occurrence = 1, .end_hour = 3,
        },
    },
    .{
        .name = "Australia/Brisbane",
        .std_offset_sec = 10 * 3600,
        .dst_save_sec = 0,
        .dst_rule = null,
    },
    .{
        .name = "Australia/Perth",
        .std_offset_sec = 8 * 3600,
        .dst_save_sec = 0,
        .dst_rule = null,
    },
    .{
        .name = "Australia/Adelaide",
        .std_offset_sec = 9 * 3600 + 1800,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 10, .start_weekday = 0, .start_occurrence = 1, .start_hour = 2,
            .end_month = 4, .end_weekday = 0, .end_occurrence = 1, .end_hour = 3,
        },
    },
    .{
        .name = "Australia/Darwin",
        .std_offset_sec = 9 * 3600 + 1800,
        .dst_save_sec = 0,
        .dst_rule = null,
    },

    // ── Pacific ─────────────────────────────────────────
    .{
        .name = "Pacific/Auckland",
        .std_offset_sec = 12 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 9, .start_weekday = 0, .start_occurrence = -1, .start_hour = 2,
            .end_month = 4, .end_weekday = 0, .end_occurrence = 1, .end_hour = 3,
        },
    },
    .{
        .name = "Pacific/Fiji",
        .std_offset_sec = 12 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 11, .start_weekday = 0, .start_occurrence = 1, .start_hour = 2,
            .end_month = 1, .end_weekday = 0, .end_occurrence = 2, .end_hour = 3,
        },
    },
    .{
        .name = "Pacific/Honolulu",
        .std_offset_sec = -10 * 3600,
        .dst_save_sec = 0,
        .dst_rule = null,
    },

    // ── Americas (non-US) ───────────────────────────────
    .{
        .name = "America/Toronto",
        .std_offset_sec = -5 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Vancouver",
        .std_offset_sec = -8 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 3, .start_weekday = 0, .start_occurrence = 2, .start_hour = 2,
            .end_month = 11, .end_weekday = 0, .end_occurrence = 1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Mexico_City",
        .std_offset_sec = -6 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 4, .start_weekday = 0, .start_occurrence = 1, .start_hour = 2,
            .end_month = 10, .end_weekday = 0, .end_occurrence = -1, .end_hour = 2,
        },
    },
    .{
        .name = "America/Sao_Paulo",
        .std_offset_sec = -3 * 3600,
        .dst_save_sec = 3600,
        .dst_rule = .{
            .start_month = 11, .start_weekday = 0, .start_occurrence = 1, .start_hour = 0,
            .end_month = 2, .end_weekday = 0, .end_occurrence = 3, .end_hour = 0,
        },
    },
};

/// Check if `name` is a known IANA zone. Case-insensitive.
pub fn isKnownZone(name: []const u8) bool {
    return lookupZoneDef(name) != null;
}
