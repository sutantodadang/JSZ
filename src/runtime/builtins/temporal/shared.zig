// SPDX-License-Identifier: Apache-2.0
//! Wave 25: Temporal shared machinery — ISO calendar math, ISO 8601 string
//! parsing (date/time/datetime/duration/instant), rounding, option reading, and
//! BigInt<->i128 helpers. All Temporal value types (Instant, Duration, PlainDate,
//! PlainTime, PlainDateTime) build on these.
//!
//! The ISO calendar is the only calendar implemented here; `calendarId` is always
//! "iso8601". Proleptic Gregorian date<->epoch-day conversion uses Howard
//! Hinnant's algorithms (days_from_civil / civil_from_days).
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const coercion = @import("../coercion.zig");

// ---------------------------------------------------------------- records ---

/// ISO calendar date. month/day are 1-based. year is the signed ISO year.
pub const ISODate = struct {
    year: i32,
    month: u8, // 1..12
    day: u8, // 1..31
};

/// Wall-clock time with nanosecond resolution.
pub const ISOTime = struct {
    hour: u8 = 0, // 0..23
    minute: u8 = 0, // 0..59
    second: u8 = 0, // 0..59
    millisecond: u16 = 0, // 0..999
    microsecond: u16 = 0, // 0..999
    nanosecond: u16 = 0, // 0..999
};

pub const ISODateTime = struct {
    date: ISODate,
    time: ISOTime,
};

/// A Temporal.Duration's ten fields, kept as f64 (they are integers in range but
/// arithmetic balances through fractional intermediates).
pub const DurationFields = struct {
    years: f64 = 0,
    months: f64 = 0,
    weeks: f64 = 0,
    days: f64 = 0,
    hours: f64 = 0,
    minutes: f64 = 0,
    seconds: f64 = 0,
    milliseconds: f64 = 0,
    microseconds: f64 = 0,
    nanoseconds: f64 = 0,

    pub fn isZero(self: DurationFields) bool {
        return self.years == 0 and self.months == 0 and self.weeks == 0 and
            self.days == 0 and self.hours == 0 and self.minutes == 0 and
            self.seconds == 0 and self.milliseconds == 0 and
            self.microseconds == 0 and self.nanoseconds == 0;
    }

    /// DurationSign: +1/-1/0 from the first non-zero field (all must share sign
    /// for a valid duration, which is enforced at construction).
    pub fn sign(self: DurationFields) i8 {
        const fields = [_]f64{ self.years, self.months, self.weeks, self.days, self.hours, self.minutes, self.seconds, self.milliseconds, self.microseconds, self.nanoseconds };
        for (fields) |f| {
            if (f > 0) return 1;
            if (f < 0) return -1;
        }
        return 0;
    }
};

// ------------------------------------------------------------ calendar math ---

pub fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

pub fn isoDaysInMonth(year: i32, month: i32) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

pub fn daysInYear(year: i32) u16 {
    return if (isLeapYear(year)) 366 else 365;
}

/// Days since the Unix epoch (1970-01-01) for a proleptic-Gregorian y/m/d.
pub fn isoDateToEpochDays(year: i32, month: i32, day: i32) i64 {
    const y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Inverse of isoDateToEpochDays.
pub fn epochDaysToISODate(z0: i64) ISODate {
    const z = z0 + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// ISO day of week: 1 = Monday .. 7 = Sunday.
pub fn dayOfWeek(date: ISODate) u8 {
    const days = isoDateToEpochDays(date.year, date.month, date.day);
    // 1970-01-01 was a Thursday (ISO 4).
    const dow = @mod(days + 3, 7); // 0 = Monday
    const d: i64 = if (dow < 0) dow + 7 else dow;
    return @intCast(d + 1);
}

pub fn dayOfYear(date: ISODate) u16 {
    const start = isoDateToEpochDays(date.year, 1, 1);
    const cur = isoDateToEpochDays(date.year, date.month, date.day);
    return @intCast(cur - start + 1);
}

/// ISO 8601 week-of-year (weeks start Monday; week 1 contains the first Thursday).
/// Returns the week number and the associated year-of-week may differ; we return
/// just the week number as most tests check `.weekOfYear`.
pub fn weekOfYear(date: ISODate) u16 {
    const dow = dayOfWeek(date); // 1..7
    const doy: i32 = dayOfYear(date);
    // Week number per ISO 8601.
    var week = @divFloor(doy - @as(i32, dow) + 10, 7);
    if (week < 1) {
        // Belongs to the last week of the previous year.
        const prev_year = date.year - 1;
        week = weeksInISOYear(prev_year);
    } else if (week > weeksInISOYear(date.year)) {
        week = 1;
    }
    return @intCast(week);
}

fn weeksInISOYear(year: i32) i32 {
    const jan1 = dayOfWeek(.{ .year = year, .month = 1, .day = 1 });
    if (jan1 == 4) return 53;
    if (jan1 == 3 and isLeapYear(year)) return 53;
    return 52;
}

/// Balance an ISO date by adding a (possibly large, possibly negative) day count.
pub fn balanceISODate(year: i32, month: i32, day: i32) ISODate {
    // Normalize month into a real date first, then add day offset via epoch days.
    var y = year;
    var m = month;
    // Balance months into [1,12].
    y += @intCast(@divFloor(m - 1, 12));
    m = @intCast(@mod(m - 1, 12) + 1);
    const base = isoDateToEpochDays(y, m, 1);
    return epochDaysToISODate(base + (day - 1));
}

/// Clamp/constrain a y/m/d to a real date (overflow: "constrain"). month and day
/// are clamped into range.
pub fn regulateISODateConstrain(year: i32, month: i32, day: i32) ISODate {
    const m: u8 = @intCast(std.math.clamp(month, 1, 12));
    const dim = isoDaysInMonth(year, m);
    const d: u8 = @intCast(std.math.clamp(day, 1, dim));
    return .{ .year = year, .month = m, .day = d };
}

/// Validate an ISO date is in range (overflow: "reject"). Returns error on invalid.
pub fn isValidISODate(year: i32, month: i32, day: i32) bool {
    if (month < 1 or month > 12) return false;
    if (day < 1 or day > isoDaysInMonth(year, @intCast(month))) return false;
    return true;
}

pub fn isValidISOTime(t: ISOTime) bool {
    return t.hour < 24 and t.minute < 60 and t.second < 60 and
        t.millisecond < 1000 and t.microsecond < 1000 and t.nanosecond < 1000;
}

// ------------------------------------------------------- time <-> nanoseconds ---

pub const NS_PER_DAY: i128 = 86_400_000_000_000;
pub const NS_PER_HOUR: i128 = 3_600_000_000_000;
pub const NS_PER_MINUTE: i128 = 60_000_000_000;
pub const NS_PER_SECOND: i128 = 1_000_000_000;
pub const NS_PER_MILLI: i128 = 1_000_000;
pub const NS_PER_MICRO: i128 = 1_000;

/// Nanoseconds since midnight for a wall-clock time.
pub fn timeToNanos(t: ISOTime) i128 {
    return @as(i128, t.hour) * NS_PER_HOUR +
        @as(i128, t.minute) * NS_PER_MINUTE +
        @as(i128, t.second) * NS_PER_SECOND +
        @as(i128, t.millisecond) * NS_PER_MILLI +
        @as(i128, t.microsecond) * NS_PER_MICRO +
        @as(i128, t.nanosecond);
}

/// Decompose a nanosecond-of-day count (may be >= NS_PER_DAY or negative) into
/// day-overflow + wall-clock time.
pub fn nanosToTime(total: i128) struct { days: i64, time: ISOTime } {
    const days: i128 = @divFloor(total, NS_PER_DAY);
    var ns = total - days * NS_PER_DAY; // [0, NS_PER_DAY)
    const hour: u8 = @intCast(@divTrunc(ns, NS_PER_HOUR));
    ns -= @as(i128, hour) * NS_PER_HOUR;
    const minute: u8 = @intCast(@divTrunc(ns, NS_PER_MINUTE));
    ns -= @as(i128, minute) * NS_PER_MINUTE;
    const second: u8 = @intCast(@divTrunc(ns, NS_PER_SECOND));
    ns -= @as(i128, second) * NS_PER_SECOND;
    const milli: u16 = @intCast(@divTrunc(ns, NS_PER_MILLI));
    ns -= @as(i128, milli) * NS_PER_MILLI;
    const micro: u16 = @intCast(@divTrunc(ns, NS_PER_MICRO));
    ns -= @as(i128, micro) * NS_PER_MICRO;
    const nano: u16 = @intCast(ns);
    return .{ .days = @intCast(days), .time = .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = milli,
        .microsecond = micro,
        .nanosecond = nano,
    } };
}

// ------------------------------------------------------------- BigInt <-> i128 ---

/// Read a BigInt Value into an i128. Returns null if not a BigInt or out of range.
pub fn bigIntToI128(v: Value) ?i128 {
    if (v.bits == 0 or v.unbox() != .bigint) return null;
    const c = v.toPtr().bigint.toConst();
    return c.toInt(i128) catch null;
}

/// Box an i128 as a BigInt Value.
pub fn i128ToBigInt(arena: std.mem.Allocator, n: i128) !Value {
    var limbs_buf: [4]std.math.big.Limb = undefined;
    var m = std.math.big.int.Mutable.init(&limbs_buf, 0);
    m.set(n);
    return val_mod.makeBigInt(arena, m.toConst());
}

// --------------------------------------------------------------- ISO parsing ---

pub const ParseError = error{Invalid};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn eof(p: *Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *Parser) ?u8 {
        if (p.i >= p.s.len) return null;
        return p.s[p.i];
    }
    fn digitsN(p: *Parser, n: usize) ?i64 {
        if (p.i + n > p.s.len) return null;
        var v: i64 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const c = p.s[p.i + k];
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        p.i += n;
        return v;
    }
    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.i += 1;
            return true;
        }
        return false;
    }
};

/// Parse an ISO date (with optional bracket annotations) from a full string that
/// must be a date-only representation. Accepts "YYYY-MM-DD", "YYYYMMDD",
/// expanded "±YYYYYY-MM-DD", and datetime forms (time part ignored). Bracket
/// suffixes like "[u-ca=iso8601]" are tolerated.
pub fn parseISODateTime(s0: []const u8) ParseError!ISODateTime {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    var p = Parser{ .s = s };

    // Year: optional sign for expanded (6-digit) year, else 4-digit.
    var year: i64 = undefined;
    if (p.peek() == '+' or p.peek() == '-') {
        const neg = p.s[p.i] == '-';
        p.i += 1;
        year = p.digitsN(6) orelse return error.Invalid;
        if (neg) year = -year;
        if (neg and year == 0) return error.Invalid; // -000000 not allowed
    } else {
        year = p.digitsN(4) orelse return error.Invalid;
    }

    const had_dash = p.eat('-');
    const month = p.digitsN(2) orelse return error.Invalid;
    if (had_dash) {
        if (!p.eat('-')) return error.Invalid;
    }
    const day = p.digitsN(2) orelse return error.Invalid;

    var time = ISOTime{};
    // Optional time part: 'T'/'t'/' ' then time.
    if (p.peek()) |c| {
        if (c == 'T' or c == 't' or c == ' ') {
            p.i += 1;
            time = try parseTimeInner(&p);
            // Optional offset / Z — tolerated but ignored for plain types.
            skipOffset(&p);
        }
    }
    skipAnnotations(&p);
    if (!p.eof()) return error.Invalid;

    if (year < -271821 or year > 275760) return error.Invalid;
    if (!isValidISODate(@intCast(year), @intCast(month), @intCast(day))) return error.Invalid;
    if (!isValidISOTime(time)) return error.Invalid;
    return .{ .date = .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) }, .time = time };
}

/// Parse a time-only string "HH:MM:SS.sss" / "HHMMSS" / "HH". Also accepts a full
/// datetime and extracts the time. Returns the ISOTime.
pub fn parseISOTime(s0: []const u8) ParseError!ISOTime {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    var p = Parser{ .s = s };
    // Try full datetime first if it looks like a date (has a '-' in first 6, or
    // 8 leading digits followed by 'T').
    if (looksLikeDate(s)) {
        const dt = try parseISODateTime(s);
        return dt.time;
    }
    const t = try parseTimeInner(&p);
    skipOffset(&p);
    skipAnnotations(&p);
    if (!p.eof()) return error.Invalid;
    if (!isValidISOTime(t)) return error.Invalid;
    return t;
}

fn looksLikeDate(s: []const u8) bool {
    // A leading 4-digit year followed by '-' or two more digits then a date sep.
    if (s.len < 8) return false;
    var digits: usize = 0;
    var idx: usize = 0;
    if (s[0] == '+' or s[0] == '-') idx = 1;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') : (idx += 1) digits += 1;
    // date year is 4 (or 6 expanded); a bare time "12:30" has only 2 leading digits.
    return digits >= 4 and (idx < s.len and (s[idx] == '-' or s[idx] == 'T' or s[idx] == 't'));
}

fn parseTimeInner(p: *Parser) ParseError!ISOTime {
    var t = ISOTime{};
    const hour = p.digitsN(2) orelse return error.Invalid;
    t.hour = @intCast(hour);
    var had_colon = false;
    if (p.eat(':')) had_colon = true;
    // minute optional
    if (p.peek()) |c| {
        if (c >= '0' and c <= '9') {
            const minute = p.digitsN(2) orelse return error.Invalid;
            t.minute = @intCast(minute);
            if (had_colon) {
                if (p.eat(':')) {
                    const second = p.digitsN(2) orelse return error.Invalid;
                    t.second = @intCast(second);
                    try parseFraction(p, &t);
                }
            } else {
                // Compact form: seconds may follow directly.
                if (p.peek()) |c2| {
                    if (c2 >= '0' and c2 <= '9') {
                        const second = p.digitsN(2) orelse return error.Invalid;
                        t.second = @intCast(second);
                        try parseFraction(p, &t);
                    }
                }
            }
        }
    }
    return t;
}

fn parseFraction(p: *Parser, t: *ISOTime) ParseError!void {
    if (p.peek() == '.' or p.peek() == ',') {
        p.i += 1;
        var frac: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
        var k: usize = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            if (k < 9) frac[k] = c;
            k += 1;
            p.i += 1;
        }
        if (k == 0) return error.Invalid;
        const nanos = std.fmt.parseInt(u32, &frac, 10) catch return error.Invalid;
        t.millisecond = @intCast(nanos / 1_000_000);
        t.microsecond = @intCast((nanos / 1000) % 1000);
        t.nanosecond = @intCast(nanos % 1000);
    }
}

fn skipOffset(p: *Parser) void {
    if (p.peek()) |c| {
        if (c == 'Z' or c == 'z') {
            p.i += 1;
            return;
        }
        if (c == '+' or c == '-') {
            const save = p.i;
            p.i += 1;
            const h = p.digitsN(2) orelse {
                p.i = save;
                return;
            };
            _ = h;
            // Minutes: "±HH", "±HH:MM" and compact "±HHMM" are all valid, as is
            // a further "±HH:MM:SS(.fff)" / "±HHMMSS(.fff)". Consume greedily.
            const had_colon = p.eat(':');
            if (isDigit(p.peek())) {
                _ = p.digitsN(2);
                // Seconds (with matching separator style).
                const sep = if (had_colon) p.eat(':') else !had_colon;
                if (sep and isDigit(p.peek())) {
                    _ = p.digitsN(2);
                    var t = ISOTime{};
                    parseFraction(p, &t) catch {};
                }
            }
        }
    }
}

fn isDigit(c: ?u8) bool {
    const ch = c orelse return false;
    return ch >= '0' and ch <= '9';
}

fn skipAnnotations(p: *Parser) void {
    while (p.peek() == '[') {
        while (p.peek()) |c| {
            p.i += 1;
            if (c == ']') break;
        }
    }
}

/// Parse an ISO 8601 duration string: [+-]PnYnMnWnDTnHnMnS with an optional
/// fraction on the smallest present time unit.
pub fn parseISODuration(s0: []const u8) ParseError!DurationFields {
    const s = std.mem.trim(u8, s0, " \t\n\r");
    if (s.len == 0) return error.Invalid;
    var p = Parser{ .s = s };
    var factor: f64 = 1;
    if (p.peek() == '+') {
        p.i += 1;
    } else if (p.peek() == '-') {
        factor = -1;
        p.i += 1;
    }
    if (!(p.eat('P') or p.eat('p'))) return error.Invalid;

    var out = DurationFields{};
    // Date portion.
    var any = false;
    var last_ok = true;
    _ = &last_ok;
    // years/months/weeks/days
    while (p.peek()) |c| {
        if (c == 'T' or c == 't') break;
        if (!(c >= '0' and c <= '9')) return error.Invalid;
        const start = p.i;
        while (p.peek()) |d| {
            if (d < '0' or d > '9') break;
            p.i += 1;
        }
        const numstr = p.s[start..p.i];
        const num = std.fmt.parseFloat(f64, numstr) catch return error.Invalid;
        const unit = p.peek() orelse return error.Invalid;
        p.i += 1;
        switch (unit) {
            'Y', 'y' => out.years = num,
            'M', 'm' => out.months = num,
            'W', 'w' => out.weeks = num,
            'D', 'd' => out.days = num,
            else => return error.Invalid,
        }
        any = true;
    }
    // Time portion.
    if (p.eat('T') or p.eat('t')) {
        var saw_time = false;
        while (p.peek()) |c| {
            if (!(c >= '0' and c <= '9')) return error.Invalid;
            const start = p.i;
            while (p.peek()) |d| {
                if (d < '0' or d > '9') break;
                p.i += 1;
            }
            var frac: f64 = 0;
            var has_frac = false;
            if (p.peek() == '.' or p.peek() == ',') {
                p.i += 1;
                const fstart = p.i;
                while (p.peek()) |d| {
                    if (d < '0' or d > '9') break;
                    p.i += 1;
                }
                if (p.i == fstart) return error.Invalid;
                const fstr = p.s[fstart..p.i];
                frac = std.fmt.parseFloat(f64, fstr) catch return error.Invalid;
                frac = frac / std.math.pow(f64, 10, @floatFromInt(fstr.len));
                has_frac = true;
            }
            const whole = std.fmt.parseFloat(f64, sliceInt(p.s, start)) catch return error.Invalid;
            const num = whole + frac;
            const unit = p.peek() orelse return error.Invalid;
            p.i += 1;
            switch (unit) {
                'H', 'h' => {
                    // Whole hours in the field; any fraction cascades into m/s/….
                    out.hours = whole;
                    if (has_frac) cascadeFraction(&out, 'H', frac);
                },
                'M', 'm' => {
                    out.minutes = whole;
                    if (has_frac) cascadeFraction(&out, 'M', frac);
                },
                'S', 's' => {
                    // Fractional seconds -> ms/us/ns.
                    const total_ns = num * 1e9;
                    out.seconds = @trunc(num);
                    const sub = total_ns - out.seconds * 1e9;
                    out.milliseconds = @trunc(sub / 1e6);
                    out.microseconds = @trunc((sub - out.milliseconds * 1e6) / 1e3);
                    out.nanoseconds = @round(sub - out.milliseconds * 1e6 - out.microseconds * 1e3);
                },
                else => return error.Invalid,
            }
            saw_time = true;
            any = true;
        }
        if (!saw_time) return error.Invalid;
    }
    if (!any) return error.Invalid;
    if (!p.eof()) return error.Invalid;

    if (factor < 0) {
        out.years = -out.years;
        out.months = -out.months;
        out.weeks = -out.weeks;
        out.days = -out.days;
        out.hours = -out.hours;
        out.minutes = -out.minutes;
        out.seconds = -out.seconds;
        out.milliseconds = -out.milliseconds;
        out.microseconds = -out.microseconds;
        out.nanoseconds = -out.nanoseconds;
    }
    return out;
}

fn sliceInt(s: []const u8, start: usize) []const u8 {
    var i = start;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    return s[start..i];
}

fn cascadeFraction(out: *DurationFields, unit: u8, frac: f64) void {
    if (unit == 'H' or unit == 'h') {
        const rem_min = frac * 60.0;
        out.minutes = @trunc(rem_min);
        const rem_sec = (rem_min - out.minutes) * 60.0;
        out.seconds = @trunc(rem_sec);
        var sub_ns = (rem_sec - out.seconds) * 1e9;
        out.milliseconds = @trunc(sub_ns / 1e6);
        sub_ns -= out.milliseconds * 1e6;
        out.microseconds = @trunc(sub_ns / 1e3);
        sub_ns -= out.microseconds * 1e3;
        out.nanoseconds = @round(sub_ns);
    } else if (unit == 'M' or unit == 'm') {
        const rem_sec = frac * 60.0;
        out.seconds = @trunc(rem_sec);
        var sub_ns = (rem_sec - out.seconds) * 1e9;
        out.milliseconds = @trunc(sub_ns / 1e6);
        sub_ns -= out.milliseconds * 1e6;
        out.microseconds = @trunc(sub_ns / 1e3);
        sub_ns -= out.microseconds * 1e3;
        out.nanoseconds = @round(sub_ns);
    }
}

// ------------------------------------------------------------------ rounding ---

pub const RoundingMode = enum {
    ceil,
    floor,
    expand,
    trunc,
    half_ceil,
    half_floor,
    half_expand,
    half_trunc,
    half_even,
};

pub fn roundingModeFromString(s: []const u8) ?RoundingMode {
    const map = .{
        .{ "ceil", RoundingMode.ceil },
        .{ "floor", RoundingMode.floor },
        .{ "expand", RoundingMode.expand },
        .{ "trunc", RoundingMode.trunc },
        .{ "halfCeil", RoundingMode.half_ceil },
        .{ "halfFloor", RoundingMode.half_floor },
        .{ "halfExpand", RoundingMode.half_expand },
        .{ "halfTrunc", RoundingMode.half_trunc },
        .{ "halfEven", RoundingMode.half_even },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return null;
}

/// Round `x` to the nearest multiple of `increment` using the given mode.
pub fn roundNumberToIncrement(x: f64, increment: f64, mode: RoundingMode) f64 {
    if (increment == 0) return x;
    const quotient = x / increment;
    const rounded = applyRounding(quotient, mode);
    return rounded * increment;
}

/// i128 rounding (nanosecond precision): round `x` to a multiple of `increment`.
pub fn roundI128ToIncrement(x: i128, increment: i128, mode: RoundingMode) i128 {
    if (increment == 0) return x;
    const q = @divTrunc(x, increment);
    const r = x - q * increment; // remainder, same sign as x
    if (r == 0) return x;
    const neg = (x < 0);
    const abs_r = if (r < 0) -r else r;
    const twice = abs_r * 2;
    var round_up: bool = undefined;
    switch (mode) {
        .ceil => round_up = !neg,
        .floor => round_up = neg,
        .expand => round_up = true,
        .trunc => round_up = false,
        .half_ceil => round_up = if (twice == increment) !neg else (twice > increment),
        .half_floor => round_up = if (twice == increment) neg else (twice > increment),
        .half_expand => round_up = twice >= increment,
        .half_trunc => round_up = twice > increment,
        .half_even => {
            if (twice > increment) {
                round_up = true;
            } else if (twice < increment) {
                round_up = false;
            } else {
                const q_abs = if (q < 0) -q else q;
                round_up = (@mod(q_abs, 2) == 1);
            }
        },
    }
    var result_q = q;
    if (round_up) {
        result_q += if (neg) -1 else 1;
    }
    return result_q * increment;
}

fn applyRounding(q: f64, mode: RoundingMode) f64 {
    const fl = @floor(q);
    const frac = q - fl;
    switch (mode) {
        .ceil => return @ceil(q),
        .floor => return fl,
        .expand => return if (q < 0) @floor(q) else @ceil(q),
        .trunc => return @trunc(q),
        .half_ceil => return if (frac == 0.5) @ceil(q) else @round(q),
        .half_floor => return if (frac == 0.5) fl else roundHalfDown(q),
        .half_expand => return roundHalfExpand(q),
        .half_trunc => return if (frac == 0.5) @trunc(q) else roundHalfExpand(q),
        .half_even => {
            if (frac < 0.5) return fl;
            if (frac > 0.5) return fl + 1;
            const even = @mod(fl, 2) == 0;
            return if (even) fl else fl + 1;
        },
    }
}

fn roundHalfExpand(q: f64) f64 {
    if (q < 0) return -@round(-q);
    return @round(q);
}
fn roundHalfDown(q: f64) f64 {
    const fl = @floor(q);
    const frac = q - fl;
    if (frac > 0.5) return fl + 1;
    return fl;
}

pub fn negateRoundingMode(mode: RoundingMode) RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .half_ceil => .half_floor,
        .half_floor => .half_ceil,
        else => mode,
    };
}

// --------------------------------------------------------------- unit tables ---

pub const Unit = enum {
    year,
    month,
    week,
    day,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
    nanosecond,
};

pub fn unitFromString(s: []const u8) ?Unit {
    const map = .{
        .{ "year", Unit.year },        .{ "years", Unit.year },
        .{ "month", Unit.month },      .{ "months", Unit.month },
        .{ "week", Unit.week },        .{ "weeks", Unit.week },
        .{ "day", Unit.day },          .{ "days", Unit.day },
        .{ "hour", Unit.hour },        .{ "hours", Unit.hour },
        .{ "minute", Unit.minute },    .{ "minutes", Unit.minute },
        .{ "second", Unit.second },    .{ "seconds", Unit.second },
        .{ "millisecond", Unit.millisecond }, .{ "milliseconds", Unit.millisecond },
        .{ "microsecond", Unit.microsecond }, .{ "microseconds", Unit.microsecond },
        .{ "nanosecond", Unit.nanosecond },   .{ "nanoseconds", Unit.nanosecond },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, s, pair[0])) return pair[1];
    }
    return null;
}

/// Nanoseconds per unit for time units (year/month/week/day return null — they
/// need calendar/relativeTo context).
pub fn unitLengthNanos(u: Unit) ?i128 {
    return switch (u) {
        .day => NS_PER_DAY,
        .hour => NS_PER_HOUR,
        .minute => NS_PER_MINUTE,
        .second => NS_PER_SECOND,
        .millisecond => NS_PER_MILLI,
        .microsecond => NS_PER_MICRO,
        .nanosecond => 1,
        else => null,
    };
}

// -------------------------------------------------------------- option reading ---

/// Resolve the options argument: undefined -> null (empty), object -> itself,
/// anything else -> TypeError. Per GetOptionsObject, *any* Object is accepted —
/// including callables (functions), which carry no option properties here and so
/// resolve to an empty options set.
pub fn getOptionsObject(arena: std.mem.Allocator, v: ?Value) !?*JsObject {
    const val = v orelse return null;
    if (val.bits == 0 or val.unbox() == .undefined_) return null;
    switch (val.unbox()) {
        .object => return val.toPtr().object,
        .function, .bc_function, .native_function => return null,
        else => return realm_mod.throwTypeError(arena, "options must be an object or undefined"),
    }
}

/// Coerce a Value to a string (ES ToString), returning an arena slice.
pub fn valueToString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    switch (v.unbox()) {
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .null_ => return "null",
        .undefined_ => return "undefined",
        .symbol => return realm_mod.throwTypeError(arena, "Cannot convert a Symbol value to a string"),
        .bigint => |b| return try val_mod.bigIntToString(arena, b),
        else => {
            if (try coercion.toPrimitive(arena, v, .string)) |prim| {
                if (prim.bits != 0 and prim.unbox() == .string) return prim.toPtr().string;
                if (prim.bits != 0 and prim.unbox() == .number) return try val_mod.formatNumber(arena, prim.unbox().number);
                if (prim.bits != 0 and prim.unbox() == .boolean) return if (prim.unbox().boolean) "true" else "false";
                if (prim.bits != 0 and prim.unbox() == .bigint) return try val_mod.bigIntToString(arena, prim.toPtr().bigint);
            }
            return "[object Object]";
        },
    }
}

/// Read a string-valued option; returns null if the property is absent/undefined.
/// Throws if present but coerces to a value not in `allowed` (when allowed given).
pub fn readStringOption(arena: std.mem.Allocator, opts: ?*JsObject, key: []const u8) !?[]const u8 {
    const o = opts orelse return null;
    const v = o.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try valueToString(arena, v);
}

/// Read the "overflow" option: "constrain" (default) or "reject".
pub const Overflow = enum { constrain, reject };
pub fn getOverflow(arena: std.mem.Allocator, opts: ?*JsObject) !Overflow {
    const s = (try readStringOption(arena, opts, "overflow")) orelse return .constrain;
    if (std.mem.eql(u8, s, "constrain")) return .constrain;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return realm_mod.throwRangeError(arena, "invalid overflow value");
}

/// Read the "disambiguation"/generic rounding mode option.
pub fn getRoundingMode(arena: std.mem.Allocator, opts: ?*JsObject, default: RoundingMode) !RoundingMode {
    const s = (try readStringOption(arena, opts, "roundingMode")) orelse return default;
    return roundingModeFromString(s) orelse realm_mod.throwRangeError(arena, "invalid roundingMode");
}

pub fn getRoundingIncrement(arena: std.mem.Allocator, opts: ?*JsObject) !f64 {
    const o = opts orelse return 1;
    const v = o.get("roundingIncrement") orelse return 1;
    if (v.bits == 0 or v.unbox() == .undefined_) return 1;
    const n = try realm_mod.toNumberValue(arena, v);
    if (!std.math.isFinite(n)) return realm_mod.throwRangeError(arena, "roundingIncrement must be finite");
    const t = @trunc(n);
    if (t < 1 or t > 1_000_000_000) return realm_mod.throwRangeError(arena, "roundingIncrement out of range");
    return t;
}

/// Read a required or optional temporal unit option (e.g. "smallestUnit").
pub fn getTemporalUnit(arena: std.mem.Allocator, opts: ?*JsObject, key: []const u8) !?Unit {
    const s = (try readStringOption(arena, opts, key)) orelse return null;
    if (std.mem.eql(u8, s, "auto")) return null;
    return unitFromString(s) orelse realm_mod.throwRangeError(arena, "invalid temporal unit");
}

// -------------------------------------------------------- ToIntegerWithTrunc ---

/// ToIntegerWithTruncation: ToNumber then truncate; NaN/Infinity throw RangeError.
pub fn toIntegerWithTruncation(arena: std.mem.Allocator, v: Value) !f64 {
    const n = try realm_mod.toNumberValue(arena, v);
    if (std.math.isNan(n) or std.math.isInf(n)) return realm_mod.throwRangeError(arena, "value must be a finite integer");
    return @trunc(n);
}

/// ToIntegerIfIntegral: ToNumber; must be an integer (else RangeError).
pub fn toIntegerIfIntegral(arena: std.mem.Allocator, v: Value) !f64 {
    const n = try realm_mod.toNumberValue(arena, v);
    if (!std.math.isFinite(n) or n != @trunc(n)) return realm_mod.throwRangeError(arena, "value must be an integer");
    return n;
}

// ------------------------------------------------------------ string builders ---

/// A growable byte buffer alias (Zig 0.15 unmanaged ArrayList; allocator passed
/// per call).
pub const Buf = std.ArrayList(u8);

/// Append a zero-padded integer of at least `width` digits.
pub fn appendPadded(a: std.mem.Allocator, buf: *Buf, value: i64, width: usize) !void {
    var tmp: [24]u8 = undefined;
    const neg = value < 0;
    const av: u64 = if (neg) @intCast(-value) else @intCast(value);
    const s = std.fmt.bufPrint(&tmp, "{d}", .{av}) catch unreachable;
    if (neg) try buf.append(a, '-');
    var pad = width;
    while (pad > s.len) : (pad -= 1) try buf.append(a, '0');
    try buf.appendSlice(a, s);
}

/// Format a signed year: 4 digits normally; ±6 digits with sign when outside
/// [0, 9999].
pub fn appendISOYear(a: std.mem.Allocator, buf: *Buf, year: i32) !void {
    if (year < 0 or year > 9999) {
        try buf.append(a, if (year < 0) '-' else '+');
        try appendPadded(a, buf, @abs(year), 6);
    } else {
        try appendPadded(a, buf, year, 4);
    }
}

/// Append the fractional-second portion for a toString, honoring a fixed digit
/// count (fractionalDigits) or "auto" (trim trailing zeros; omit if all zero).
pub fn appendFraction(a: std.mem.Allocator, buf: *Buf, t: ISOTime, digits: ?u8) !void {
    const total_ns: u32 = @as(u32, t.millisecond) * 1_000_000 + @as(u32, t.microsecond) * 1000 + t.nanosecond;
    if (digits) |d| {
        if (d == 0) return;
        var frac: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{total_ns}) catch unreachable;
        try buf.append(a, '.');
        try buf.appendSlice(a, frac[0..d]);
    } else {
        if (total_ns == 0) return;
        var frac: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{total_ns}) catch unreachable;
        var end: usize = 9;
        while (end > 0 and frac[end - 1] == '0') : (end -= 1) {}
        try buf.append(a, '.');
        try buf.appendSlice(a, frac[0..end]);
    }
}

/// "auto" | "always" | "never" | "critical" for calendarName; we only need the
/// three behaviors relevant to ISO output.
pub const ShowCalendar = enum { auto, always, never, critical };
pub fn getShowCalendar(arena: std.mem.Allocator, opts: ?*JsObject) !ShowCalendar {
    const s = (try readStringOption(arena, opts, "calendarName")) orelse return .auto;
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "never")) return .never;
    if (std.mem.eql(u8, s, "critical")) return .critical;
    return realm_mod.throwRangeError(arena, "invalid calendarName");
}

/// Parse fractionalSecondDigits option: null = auto, else 0..9.
pub fn getFractionalDigits(arena: std.mem.Allocator, opts: ?*JsObject) !?u8 {
    const o = opts orelse return null;
    const v = o.get("fractionalSecondDigits") orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    if (v.unbox() == .string) {
        if (std.mem.eql(u8, v.unbox().string, "auto")) return null;
        return realm_mod.throwRangeError(arena, "invalid fractionalSecondDigits");
    }
    const n = try realm_mod.toNumberValue(arena, v);
    if (std.math.isNan(n)) return realm_mod.throwRangeError(arena, "invalid fractionalSecondDigits");
    const t = @floor(n);
    if (t < 0 or t > 9) return realm_mod.throwRangeError(arena, "fractionalSecondDigits out of range");
    return @intFromFloat(t);
}
