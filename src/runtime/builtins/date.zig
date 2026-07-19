// SPDX-License-Identifier: Apache-2.0
//! Phase 4d: Date — constructor + prototype methods.
//! Storage: internal_kind = .date, internal_slot -> DateData{ ms: i64 }.
//! All UTC. Uses std.time.timestamp() for Date.now().
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const intrinsics = @import("intrinsics.zig");
const coercion = @import("coercion.zig");
const function_proto = @import("function_proto.zig");

pub const DateData = struct {
    ms: i64,
    valid: bool = true,
};

pub var active_date_proto: ?*JsObject = null;

/// R1: install Date.prototype + constructor and bind the `Date` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const date_proto = try JsObject.create(arena, ctx.object_proto);
    try intrinsics.setMethods(arena, date_proto, .{
        .{ "getTime", nativeDateGetTime },
        .{ "valueOf", nativeDateValueOf },
        .{ "getFullYear", nativeDateGetFullYear },
        .{ "getMonth", nativeDateGetMonth },
        .{ "getDate", nativeDateGetDate },
        .{ "getDay", nativeDateGetDay },
        .{ "getHours", nativeDateGetHours },
        .{ "getMinutes", nativeDateGetMinutes },
        .{ "getSeconds", nativeDateGetSeconds },
        .{ "getMilliseconds", nativeDateGetMilliseconds },
        .{ "toISOString", nativeDateToISOString },
        .{ "toString", nativeDateToString },
        .{ "getUTCFullYear", nativeDateGetUTCFullYear },
        .{ "getUTCMonth", nativeDateGetUTCMonth },
        .{ "getUTCDate", nativeDateGetUTCDate },
        .{ "getUTCDay", nativeDateGetUTCDay },
        .{ "getUTCHours", nativeDateGetUTCHours },
        .{ "getUTCMinutes", nativeDateGetUTCMinutes },
        .{ "getUTCSeconds", nativeDateGetUTCSeconds },
        .{ "getUTCMilliseconds", nativeDateGetUTCMilliseconds },
        .{ "getTimezoneOffset", nativeDateGetTimezoneOffset },
        .{ "getYear", nativeDateGetYear },
        .{ "setFullYear", nativeDateSetFullYear },
        .{ "setMonth", nativeDateSetMonth },
        .{ "setDate", nativeDateSetDate },
        .{ "setHours", nativeDateSetHours },
        .{ "setMinutes", nativeDateSetMinutes },
        .{ "setSeconds", nativeDateSetSeconds },
        .{ "setMilliseconds", nativeDateSetMilliseconds },
        .{ "setTime", nativeDateSetTime },
        .{ "setYear", nativeDateSetYear },
        .{ "toUTCString", nativeDateToUTCString },
        .{ "toGMTString", nativeDateToGMTString },
        .{ "toDateString", nativeDateToDateString },
        .{ "toTimeString", nativeDateToTimeString },
        .{ "toJSON", nativeDateToJSON },
        .{ "setUTCFullYear", nativeDateSetFullYear },
        .{ "setUTCMonth", nativeDateSetMonth },
        .{ "setUTCDate", nativeDateSetDate },
        .{ "setUTCHours", nativeDateSetHours },
        .{ "setUTCMinutes", nativeDateSetMinutes },
        .{ "setUTCSeconds", nativeDateSetSeconds },
        .{ "setUTCMilliseconds", nativeDateSetMilliseconds },
        .{ "toLocaleString", nativeDateToLocaleString },
        .{ "toLocaleDateString", nativeDateToLocaleDateString },
        .{ "toLocaleTimeString", nativeDateToLocaleTimeString },
    });
    active_date_proto = date_proto;

    const date_ctor = try intrinsics.makeCtor(arena, date_proto, nativeDateCtor, null);
    try intrinsics.setMethod(arena, date_ctor, "now", nativeDateNow);
    try intrinsics.setMethod(arena, date_ctor, "parse", nativeDateParse);
    try intrinsics.setMethod(arena, date_ctor, "UTC", nativeDateUTC);
    // Date.UTC.length === 7 (year..ms); Date.parse.length === 1. Both bare names
    // are ambiguous in the shared length table, so pin them explicitly here.
    if (date_ctor.getOwn("UTC")) |u| {
        if (u.bits != 0 and u.unbox() == .object) {
            _ = try u.unbox().object.defineOwnData("length", try val_mod.makeNumber(arena, 7), .{ .writable = false, .enumerable = false, .configurable = true });
        }
    }
    if (date_ctor.getOwn("parse")) |pf| {
        if (pf.bits != 0 and pf.unbox() == .object) {
            _ = try pf.unbox().object.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        }
    }
    _ = try date_ctor.defineOwnData("name", try val_mod.makeString(arena, "Date"), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try date_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 7), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try date_proto.defineOwnData("constructor", try val_mod.makeObject(arena, date_ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    try ctx.defineGlobal("Date", date_ctor);
}

/// Wire Date.prototype[@@toPrimitive] once the well-known symbols exist (Symbol
/// init runs after register()). The method is { [[Writable]]: false,
/// [[Enumerable]]: false, [[Configurable]]: true } with name "[Symbol.toPrimitive]".
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const proto = active_date_proto orelse return;
    if (realm_mod.active_sym_to_primitive) |sym| {
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, nativeDateToPrimitive, "[Symbol.toPrimitive]", 1);
        try proto.setSymAttr(sym, fn_val, .{ .writable = false, .enumerable = false, .configurable = true });
    }
}

// ------------------------------------------------------------------ helpers ---

const WDAY = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MON = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn daysInMonth(month: i32, year: i32) i32 {
    return switch (month) {
        0 => 31, // Jan
        1 => if (isLeapYear(year)) 29 else 28,
        2 => 31,
        3 => 30,
        4 => 31,
        5 => 30,
        6 => 31,
        7 => 31,
        8 => 30,
        9 => 31,
        10 => 30,
        11 => 31,
        else => 30,
    };
}

fn isLeapYear(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or (@mod(y, 400) == 0);
}

/// Milliseconds since epoch -> { year, month (0-11), day (1-31), weekday (0=Sun), hour, min, sec, ms }
pub const DateFields = struct {
    year: i32,
    month: i32,
    day: i32,
    weekday: i32,
    hour: i32,
    min: i32,
    sec: i32,
    ms: i32,
};

/// Public UTC field decomposition (used by Intl.DateTimeFormat).
pub fn msToFieldsUtc(ms_epoch: i64) DateFields {
    return msToFields(ms_epoch);
}

/// Extract the epoch-millisecond value from a Date object Value, or null.
pub fn getDateMs(v: Value) ?i64 {
    const dd = getDateData(v) orelse return null;
    return dd.ms;
}

fn msToFields(ms_epoch: i64) DateFields {
    const ms_abs: i64 = @mod(ms_epoch, 1000);
    var secs: i64 = @divFloor(ms_epoch, 1000);
    const ms_part: i32 = @intCast(if (ms_abs < 0) ms_abs + 1000 else ms_abs);
    if (ms_abs < 0) secs -= 1;

    // Weekday: Jan 1 1970 was Thursday (4).
    var wday: i64 = @mod(secs, 7 * 86400);
    if (wday < 0) wday += 7 * 86400;
    const weekday: i32 = @intCast(@mod(@divFloor(wday, 86400) + 4, 7));

    // Derive year/month/day from days since epoch.
    var days: i64 = @divFloor(secs, 86400);
    var rem_secs: i64 = @mod(secs, 86400);
    if (rem_secs < 0) {
        rem_secs += 86400;
        days -= 1;
    }

    const hour: i32 = @intCast(@divFloor(rem_secs, 3600));
    const min_: i32 = @intCast(@divFloor(@mod(rem_secs, 3600), 60));
    const sec_: i32 = @intCast(@mod(rem_secs, 60));

    // Simple year computation.
    var year: i32 = 1970;
    var d = days;
    if (d >= 0) {
        while (true) {
            const yl: i64 = if (isLeapYear(year)) 366 else 365;
            if (d < yl) break;
            d -= yl;
            year += 1;
        }
    } else {
        while (d < 0) {
            year -= 1;
            d += if (isLeapYear(year)) 366 else 365;
        }
    }

    // Find month.
    var month: i32 = 0;
    while (month < 11) : (month += 1) {
        const dim = daysInMonth(month, year);
        if (d < dim) break;
        d -= dim;
    }

    return DateFields{
        .year = year,
        .month = month,
        .day = @intCast(d + 1),
        .weekday = weekday,
        .hour = hour,
        .min = min_,
        .sec = sec_,
        .ms = ms_part,
    };
}

/// Days from the epoch (1970-01-01) to Jan 1 of `y`.
fn daysToYearStart(y: i32) i64 {
    var days: i64 = 0;
    if (y >= 1970) {
        var yr: i32 = 1970;
        while (yr < y) : (yr += 1) days += if (isLeapYear(yr)) 366 else 365;
    } else {
        var yr: i32 = 1969;
        while (yr >= y) : (yr -= 1) days -= if (isLeapYear(yr)) 366 else 365;
    }
    return days;
}

/// UTC fields -> milliseconds since epoch.
fn fieldsToMs(year: i32, month: i32, day: i32, hour: i32, min_: i32, sec_: i32, ms_: i32) i64 {
    // Normalize month into [0,11], carrying into the year (i64 math avoids overflow).
    var y64: i64 = year;
    y64 += @divFloor(@as(i64, month), 12);
    const m: i32 = @intCast(@mod(@as(i64, month), 12));
    // Clamp the year far beyond the valid Date range (±271821); anything outside
    // yields an out-of-range result the caller maps to NaN. Also bounds the
    // day-accumulation loop and prevents i32 overflow on extreme inputs.
    if (y64 > 300000) y64 = 300000;
    if (y64 < -300000) y64 = -300000;
    const y: i32 = @intCast(y64);

    // Days from epoch to Jan 1 of year.
    var days: i64 = daysToYearStart(y);
    // Add days for months.
    var mo: i32 = 0;
    while (mo < m) : (mo += 1) {
        days += daysInMonth(mo, y);
    }
    days += @as(i64, day) - 1;

    return days * 86400_000 + @as(i64, hour) * 3_600_000 + @as(i64, min_) * 60_000 + @as(i64, sec_) * 1000 + ms_;
}

/// ES MakeDate(MakeDay(year, month, date), MakeTime(hour, min, sec, ms)) followed
/// by TimeClip. Non-finite inputs, or a result outside ±8.64e15 ms, yield null
/// (→ Invalid Date / NaN). All numeric args are ToInteger-truncated per spec, so
/// the day-of-month and time components may be arbitrarily large.
fn composeTime(year: f64, month: f64, date: f64, hour: f64, min: f64, sec: f64, ms: f64) ?i64 {
    inline for (.{ year, month, date, hour, min, sec, ms }) |x| {
        if (!std.math.isFinite(x)) return null;
    }
    const y = @trunc(year);
    const mo = @trunc(month);
    const ym = y + @floor(mo / 12.0);
    // Year far outside the representable Date range → definitely out of bounds.
    if (@abs(ym) > 300000) return null;
    const mn: i32 = @intFromFloat(mo - @floor(mo / 12.0) * 12.0);
    const yi: i32 = @intFromFloat(ym);
    var days: i64 = daysToYearStart(yi);
    var k: i32 = 0;
    while (k < mn) : (k += 1) days += daysInMonth(k, yi);
    const day_ms = (@as(f64, @floatFromInt(days)) + (@trunc(date) - 1.0)) * 86400000.0;
    const time_ms = ((@trunc(hour) * 3600000.0 + @trunc(min) * 60000.0) + @trunc(sec) * 1000.0) + @trunc(ms);
    return timeClip(day_ms + time_ms);
}

/// ToNumber each argument left-to-right (every side effect runs even after an
/// earlier arg already produced NaN). `out[0]` is always coerced — an absent
/// first argument is `undefined` → NaN — while later slots are coerced only when
/// the argument is present. Returns the number of slots actually filled.
fn coerceArgs(arena: std.mem.Allocator, args: []const Value, out: []f64) !usize {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (i != 0 and i >= args.len) break;
        const v: Value = if (i < args.len) args[i] else Value{};
        out[i] = try realm_mod.toNumberValue(arena, v);
    }
    return i;
}

/// Commit a composed time value to the receiver's [[DateValue]]: a null result
/// marks the date Invalid and returns NaN.
fn applyResult(arena: std.mem.Allocator, dd: *DateData, result: ?i64) !Value {
    if (result) |ms| {
        dd.ms = ms;
        dd.valid = true;
        return val_mod.makeNumber(arena, @floatFromInt(ms));
    }
    dd.valid = false;
    return val_mod.makeNumber(arena, std.math.nan(f64));
}

fn getDateData(this_val: Value) ?*DateData {
    if (this_val.bits == 0) return null;
    const inner = this_val.unbox();
    if (inner != .object) return null;
    const obj = inner.object;
    if (obj.internal_kind != .date) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

/// Like getDateData, but returns null for an Invalid Date so getters/formatters
/// fall back to their NaN / "Invalid Date" default uniformly.
fn getValidDateData(this_val: Value) ?*DateData {
    const dd = getDateData(this_val) orelse return null;
    if (!dd.valid) return null;
    return dd;
}

/// Brand check: every Date.prototype method requires a `this` with a
/// [[DateValue]] internal slot, throwing a TypeError otherwise (spec step 1 of
/// thisTimeValue / the individual methods). Returns the data even when the date
/// is Invalid — callers decide whether to surface NaN or a string for that.
fn requireDate(arena: std.mem.Allocator, this_val: Value) anyerror!*DateData {
    return getDateData(this_val) orelse realm_mod.throwTypeError(arena, "Date.prototype method called on an incompatible receiver");
}

/// Brand check + validity: throws a TypeError for a non-Date receiver, returns
/// null for a valid brand but Invalid Date (so string formatters can emit
/// "Invalid Date"), and the data otherwise.
fn brandValidDate(arena: std.mem.Allocator, this_val: Value) anyerror!?*DateData {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return null;
    return dd;
}

/// Maximum representable time value per TimeClip (ES 21.4.1.1): ±8.64e15 ms.
const MAX_TIME_MS: f64 = 8.64e15;

/// ES TimeClip: a time value outside the representable range (or non-finite)
/// becomes NaN; otherwise it is truncated toward zero to an integer millisecond.
fn timeClip(t: f64) ?i64 {
    if (!std.math.isFinite(t)) return null;
    if (@abs(t) > MAX_TIME_MS) return null;
    return @intFromFloat(@trunc(t));
}

fn createDateObject(arena: std.mem.Allocator, ms: i64, valid: bool) !Value {
    const dd = try arena.create(DateData);
    dd.* = DateData{ .ms = ms, .valid = valid };
    const proto = active_date_proto;
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    obj.internal_kind = .date;
    obj.internal_slot = dd;
    return val_mod.makeObject(arena, obj);
}

fn argToI32(args: []const Value, idx: usize, default: i32) i32 {
    if (idx >= args.len or args[idx].bits == 0) return default;
    return switch (args[idx].unbox()) {
        .number => |n| blk: {
            if (std.math.isNan(n)) break :blk default;
            const t = @trunc(n);
            if (t >= 2147483647.0) break :blk std.math.maxInt(i32);
            if (t <= -2147483648.0) break :blk std.math.minInt(i32);
            break :blk @intFromFloat(t);
        },
        else => default,
    };
}

// ------------------------------------------------------------------ ISO 8601 date-string parsing ---

fn parseDigits(s: []const u8, pos: *usize, width: usize) ?i32 {
    if (pos.* + width > s.len) return null;
    var val: i32 = 0;
    for (s[pos.* .. pos.* + width]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        val = val * 10 + @as(i32, c - '0');
    }
    pos.* += width;
    return val;
}

fn parseExpandedYear(s: []const u8, pos: *usize) ?i32 {
    if (pos.* >= s.len) return null;
    const sign: i32 = switch (s[pos.*]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    pos.* += 1;
    const digits = parseDigits(s, pos, 6) orelse return null;
    return sign * digits;
}

/// Parse the ES2015 §21.4.1.18 Date Time String Format (ISO 8601 subset) into
/// epoch milliseconds. Returns null on any parse or range failure — the
/// caller maps that to an Invalid Date / NaN. All-UTC engine: an absent
/// timezone suffix on a date-time is treated as UTC (not local time).
fn parseIsoDateString(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var pos: usize = 0;

    var year: i32 = undefined;
    if (s[0] == '+' or s[0] == '-') {
        year = parseExpandedYear(s, &pos) orelse return null;
    } else {
        year = parseDigits(s, &pos, 4) orelse return null;
    }

    var month: i32 = 1;
    var day: i32 = 1;
    if (pos < s.len and s[pos] == '-') {
        pos += 1;
        month = parseDigits(s, &pos, 2) orelse return null;
        if (pos < s.len and s[pos] == '-') {
            pos += 1;
            day = parseDigits(s, &pos, 2) orelse return null;
        }
    }
    if (month < 1 or month > 12) return null;

    var hour: i32 = 0;
    var min_: i32 = 0;
    var sec_: i32 = 0;
    var ms_: i32 = 0;
    var tz_offset_min: i32 = 0;

    if (pos < s.len and (s[pos] == 'T' or s[pos] == 't')) {
        pos += 1;
        hour = parseDigits(s, &pos, 2) orelse return null;
        if (pos >= s.len or s[pos] != ':') return null;
        pos += 1;
        min_ = parseDigits(s, &pos, 2) orelse return null;

        if (pos < s.len and s[pos] == ':') {
            pos += 1;
            sec_ = parseDigits(s, &pos, 2) orelse return null;
            if (pos < s.len and s[pos] == '.') {
                pos += 1;
                const frac_start = pos;
                while (pos < s.len and std.ascii.isDigit(s[pos])) : (pos += 1) {}
                const frac_len = pos - frac_start;
                if (frac_len == 0) return null;
                var msv: i32 = 0;
                var i: usize = 0;
                while (i < 3) : (i += 1) {
                    const d: i32 = if (i < frac_len) @as(i32, s[frac_start + i] - '0') else 0;
                    msv = msv * 10 + d;
                }
                ms_ = msv;
            }
        }

        if (pos < s.len) {
            if (s[pos] == 'Z' or s[pos] == 'z') {
                pos += 1;
            } else if (s[pos] == '+' or s[pos] == '-') {
                const sign: i32 = if (s[pos] == '-') -1 else 1;
                pos += 1;
                const oh = parseDigits(s, &pos, 2) orelse return null;
                if (pos >= s.len or s[pos] != ':') return null;
                pos += 1;
                const om = parseDigits(s, &pos, 2) orelse return null;
                if (oh > 23 or om > 59) return null;
                tz_offset_min = sign * (oh * 60 + om);
            }
        }
    }

    if (pos != s.len) return null; // trailing garbage

    if (day < 1) return null;
    const dim = daysInMonth(month - 1, year);
    if (day > dim) return null;
    if (hour == 24) {
        if (min_ != 0 or sec_ != 0 or ms_ != 0) return null;
    } else if (hour > 23) {
        return null;
    }
    if (min_ > 59) return null;
    if (sec_ > 59) return null;

    const base_ms = fieldsToMs(year, month - 1, day, hour, min_, sec_, ms_);
    return base_ms - @as(i64, tz_offset_min) * 60_000;
}

// ------------------------------------------------------------------ Date.now ---

pub fn nativeDateNow(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const ts = std.time.milliTimestamp();
    return val_mod.makeNumber(arena, @floatFromInt(ts));
}

pub fn nativeDateParse(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeNumber(arena, std.math.nan(f64));
    const v = args[0];
    var s: []const u8 = undefined;
    if (v.bits != 0 and v.unbox() == .string) {
        s = v.unbox().string;
    } else {
        const prim = try coercion.toPrimitive(arena, v, .string);
        if (prim) |p| {
            if (p.bits != 0 and p.unbox() == .string) {
                s = p.unbox().string;
            } else {
                return val_mod.makeNumber(arena, std.math.nan(f64));
            }
        } else {
            return val_mod.makeNumber(arena, std.math.nan(f64));
        }
    }
    if (parseIsoDateString(s)) |ms| {
        return val_mod.makeNumber(arena, @floatFromInt(ms));
    }
    return val_mod.makeNumber(arena, std.math.nan(f64));
}

// ------------------------------------------------------------------ Date constructor ---

/// ES Date.UTC(year [, month [, date [, hours [, minutes [, seconds [, ms ]]]]]]).
/// Every argument is ToNumber-coerced in order; the result is a TimeClip'd number
/// (NaN when out of range), never a Date object.
pub fn nativeDateUTC(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var nums: [7]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    const year = makeFullYear(nums[0]);
    const month = if (n > 1) nums[1] else 0;
    const date = if (n > 2) nums[2] else 1;
    const hours = if (n > 3) nums[3] else 0;
    const minutes = if (n > 4) nums[4] else 0;
    const seconds = if (n > 5) nums[5] else 0;
    const ms = if (n > 6) nums[6] else 0;
    if (composeTime(year, month, date, hours, minutes, seconds, ms)) |r|
        return val_mod.makeNumber(arena, @floatFromInt(r));
    return val_mod.makeNumber(arena, std.math.nan(f64));
}

/// ES MakeFullYear: a finite year in 0..99 (after ToInteger) maps to 1900+year;
/// everything else passes through unchanged (NaN stays NaN).
fn makeFullYear(year: f64) f64 {
    if (!std.math.isFinite(year)) return year;
    const yt = @trunc(year);
    if (yt >= 0 and yt <= 99) return 1900 + yt;
    return year;
}

pub fn nativeDateCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Called as a plain function (no `new`): ES 21.4.2.1 step 1 — ignore all
    // arguments and return the current time as a string. Construction always
    // passes a fresh object (with Date.prototype) as `this`; a plain call passes
    // undefined (strict) which we treat as the function form.
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        const now_val = try createDateObject(arena, std.time.milliTimestamp(), true);
        return nativeDateToString(arena, now_val, &[_]Value{});
    }
    var is_invalid = false;
    const ms: i64 = blk: {
        if (args.len == 0) {
            break :blk std.time.milliTimestamp();
        } else if (args.len == 1) {
            // new Date(value): a Date argument copies its [[DateValue]]; otherwise
            // ToPrimitive(value, default) → String parses, anything else ToNumbers.
            const v = args[0];
            if (getDateData(v)) |src| {
                is_invalid = !src.valid;
                break :blk src.ms;
            }
            var prim = v;
            if (v.bits != 0 and v.unbox() == .object) {
                prim = (try coercion.toPrimitive(arena, v, .default)) orelse v;
            }
            if (prim.bits != 0 and prim.unbox() == .string) {
                if (parseIsoDateString(prim.unbox().string)) |pms| break :blk pms;
                is_invalid = true;
                break :blk 0;
            }
            const tv = try realm_mod.toNumberValue(arena, prim);
            if (timeClip(tv)) |clamped| break :blk clamped;
            is_invalid = true;
            break :blk 0;
        } else {
            // new Date(year, month, day?, hour?, min?, sec?, ms?)
            var nums: [7]f64 = undefined;
            const n = try coerceArgs(arena, args, &nums);
            const year = makeFullYear(nums[0]);
            const month = nums[1];
            const day = if (n > 2) nums[2] else 1;
            const hour = if (n > 3) nums[3] else 0;
            const min = if (n > 4) nums[4] else 0;
            const sec = if (n > 5) nums[5] else 0;
            const ms_ = if (n > 6) nums[6] else 0;
            if (composeTime(year, month, day, hour, min, sec, ms_)) |c| break :blk c;
            is_invalid = true;
            break :blk 0;
        }
    };

    // Populate `this` object (called with new).
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const dd = try arena.create(DateData);
        dd.* = DateData{ .ms = ms, .valid = !is_invalid };
        this_val.toPtr().object.internal_kind = .date;
        this_val.toPtr().object.internal_slot = dd;
        return this_val;
    }
    return createDateObject(arena, ms, !is_invalid);
}

// ------------------------------------------------------------------ prototype methods ---

pub fn nativeDateGetTime(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @floatFromInt(dd.ms));
}

pub fn nativeDateGetFullYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.year));
}

pub fn nativeDateGetMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.month));
}

pub fn nativeDateGetDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.day));
}

pub fn nativeDateGetDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.weekday));
}

pub fn nativeDateGetHours(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.hour));
}

pub fn nativeDateGetMinutes(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.min));
}

pub fn nativeDateGetSeconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.sec));
}

pub fn nativeDateGetMilliseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.ms));
}

pub fn nativeDateValueOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDateGetTime(arena, this_val, args);
}

/// ES2015 Date.prototype[Symbol.toPrimitive]. `args[0]` is the hint string.
/// "number" -> numeric timestamp (valueOf); "string"/"default" -> date string.
pub fn nativeDateToPrimitive(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Step 1-2: this must be an Object.
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return realm_mod.throwTypeError(arena, "Date.prototype[Symbol.toPrimitive] called on non-object");
    // Steps 3-5: hint selects the OrdinaryToPrimitive order; anything other than
    // "string"/"number"/"default" is a TypeError.
    const hint: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string)
        args[0].unbox().string
    else
        "";
    const string_first = if (std.mem.eql(u8, hint, "string") or std.mem.eql(u8, hint, "default"))
        true
    else if (std.mem.eql(u8, hint, "number"))
        false
    else
        return realm_mod.throwTypeError(arena, "invalid hint for Date.prototype[Symbol.toPrimitive]");
    // Step 6: OrdinaryToPrimitive(O, tryFirst) — invokes the object's own
    // toString/valueOf (user-overridable), never the @@toPrimitive path again.
    if (try coercion.ordinaryToPrimitive(arena, this_val, string_first)) |p| return p;
    return realm_mod.throwTypeError(arena, "Cannot convert Date to primitive value");
}

pub fn nativeDateToISOString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    // toISOString on an Invalid Date is a RangeError, not the "Invalid Date" string.
    if (!dd.valid) return realm_mod.throwRangeError(arena, "Invalid time value");
    const f = msToFields(dd.ms);
    // Years outside 0..9999 use the expanded ±YYYYYY form (ES 21.4.4.36).
    if (f.year < 0 or f.year > 9999) {
        const sign: u8 = if (f.year < 0) '-' else '+';
        const s = try std.fmt.allocPrint(arena, "{c}{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            sign,
            @as(u32, @intCast(@abs(f.year))),
            @as(u8, @intCast(f.month + 1)),
            @as(u8, @intCast(f.day)),
            @as(u8, @intCast(f.hour)),
            @as(u8, @intCast(f.min)),
            @as(u8, @intCast(f.sec)),
            @as(u16, @intCast(f.ms)),
        });
        return val_mod.makeString(arena, s);
    }
    // Use unsigned casts to avoid '+' sign in Zig format specifiers.
    const s = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, @intCast(f.year)),
        @as(u8, @intCast(f.month + 1)),
        @as(u8, @intCast(f.day)),
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
        @as(u16, @intCast(f.ms)),
    });
    return val_mod.makeString(arena, s);
}

/// Format a year for the human-readable date strings: at least four digits,
/// with a leading '-' for negative (extended) years, e.g. 20 -> "0020",
/// -1 -> "-0001", 275760 -> "275760".
fn yearString(arena: std.mem.Allocator, year: i32) ![]const u8 {
    if (year < 0)
        return std.fmt.allocPrint(arena, "-{d:0>4}", .{@as(u32, @intCast(-year))});
    return std.fmt.allocPrint(arena, "{d:0>4}", .{@as(u32, @intCast(year))});
}

pub fn nativeDateToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ToDateString(tv): DateString + " " + TimeString + TimeZoneString.
    const dd = (try brandValidDate(arena, this_val)) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    const s = try std.fmt.allocPrint(arena, "{s} {s} {d:0>2} {s} {d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        WDAY[@intCast(f.weekday)],
        MON[@intCast(f.month)],
        @as(u8, @intCast(f.day)),
        try yearString(arena, f.year),
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
    });
    return val_mod.makeString(arena, s);
}

/// `Date.prototype.toLocaleString([locales[, options]])` — en-US date+time via
/// Intl.DateTimeFormat (honors component/dateStyle/timeStyle options).
pub fn nativeDateToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if ((try brandValidDate(arena, this_val)) == null) return val_mod.makeString(arena, "Invalid Date");
    return @import("intl.zig").dateToLocaleString(arena, this_val, args, .datetime);
}

/// `Date.prototype.toLocaleDateString` — date-only default.
pub fn nativeDateToLocaleDateString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if ((try brandValidDate(arena, this_val)) == null) return val_mod.makeString(arena, "Invalid Date");
    return @import("intl.zig").dateToLocaleString(arena, this_val, args, .date);
}

/// `Date.prototype.toLocaleTimeString` — time-only default.
pub fn nativeDateToLocaleTimeString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if ((try brandValidDate(arena, this_val)) == null) return val_mod.makeString(arena, "Invalid Date");
    return @import("intl.zig").dateToLocaleString(arena, this_val, args, .time);
}

// ------------------------------------------------------------------ UTC getters ---

pub fn nativeDateGetUTCFullYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.year));
}

pub fn nativeDateGetUTCMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.month));
}

pub fn nativeDateGetUTCDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.day));
}

pub fn nativeDateGetUTCDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.weekday));
}

pub fn nativeDateGetUTCHours(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.hour));
}

pub fn nativeDateGetUTCMinutes(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.min));
}

pub fn nativeDateGetUTCSeconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.sec));
}

pub fn nativeDateGetUTCMilliseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.ms));
}

// ------------------------------------------------------------------ getTimezoneOffset / getYear ---

pub fn nativeDateGetTimezoneOffset(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, 0);
}

pub fn nativeDateGetYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    if (!dd.valid) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.year - 1900));
}

// ------------------------------------------------------------------ setters ---

// The setters below share a shape: brand-check the receiver, ToNumber every
// provided argument in order (side effects run unconditionally), then recompose
// the time from the receiver's current broken-down fields, overriding the fields
// the setter names. On an Invalid Date the "year" setters (which reset t to +0)
// still succeed, while the others stay NaN — but coercion has already happened.

pub fn nativeDateSetFullYear(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    var nums: [3]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    // setFullYear resets an Invalid Date: t defaults to +0 (1970-01-01 UTC).
    const f = if (dd.valid) msToFields(dd.ms) else msToFields(0);
    const year = nums[0];
    const month = if (n > 1) nums[1] else @as(f64, @floatFromInt(f.month));
    const day = if (n > 2) nums[2] else @as(f64, @floatFromInt(f.day));
    return applyResult(arena, dd, composeTime(year, month, day, @floatFromInt(f.hour), @floatFromInt(f.min), @floatFromInt(f.sec), @floatFromInt(f.ms)));
}

pub fn nativeDateSetMonth(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    // [[DateValue]] is read BEFORE ToNumber (which may re-enter and mutate it).
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [2]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    const month = nums[0];
    const day = if (n > 1) nums[1] else @as(f64, @floatFromInt(f.day));
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), month, day, @floatFromInt(f.hour), @floatFromInt(f.min), @floatFromInt(f.sec), @floatFromInt(f.ms)));
}

pub fn nativeDateSetDate(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [1]f64 = undefined;
    _ = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), @floatFromInt(f.month), nums[0], @floatFromInt(f.hour), @floatFromInt(f.min), @floatFromInt(f.sec), @floatFromInt(f.ms)));
}

pub fn nativeDateSetHours(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [4]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    const hour = nums[0];
    const min = if (n > 1) nums[1] else @as(f64, @floatFromInt(f.min));
    const sec = if (n > 2) nums[2] else @as(f64, @floatFromInt(f.sec));
    const ms = if (n > 3) nums[3] else @as(f64, @floatFromInt(f.ms));
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), @floatFromInt(f.month), @floatFromInt(f.day), hour, min, sec, ms));
}

pub fn nativeDateSetMinutes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [3]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    const min = nums[0];
    const sec = if (n > 1) nums[1] else @as(f64, @floatFromInt(f.sec));
    const ms = if (n > 2) nums[2] else @as(f64, @floatFromInt(f.ms));
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), @floatFromInt(f.month), @floatFromInt(f.day), @floatFromInt(f.hour), min, sec, ms));
}

pub fn nativeDateSetSeconds(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [2]f64 = undefined;
    const n = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    const sec = nums[0];
    const ms = if (n > 1) nums[1] else @as(f64, @floatFromInt(f.ms));
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), @floatFromInt(f.month), @floatFromInt(f.day), @floatFromInt(f.hour), @floatFromInt(f.min), sec, ms));
}

pub fn nativeDateSetMilliseconds(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const base_valid = dd.valid;
    const f = msToFields(dd.ms);
    var nums: [1]f64 = undefined;
    _ = try coerceArgs(arena, args, &nums);
    if (!base_valid) return applyResult(arena, dd, null);
    return applyResult(arena, dd, composeTime(@floatFromInt(f.year), @floatFromInt(f.month), @floatFromInt(f.day), @floatFromInt(f.hour), @floatFromInt(f.min), @floatFromInt(f.sec), nums[0]));
}

pub fn nativeDateSetTime(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    const t = if (args.len == 0) std.math.nan(f64) else try realm_mod.toNumberValue(arena, args[0]);
    return applyResult(arena, dd, timeClip(t));
}

pub fn nativeDateSetUTCFullYear(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDateSetFullYear(arena, this_val, args);
}

pub fn nativeDateSetUTCHours(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDateSetHours(arena, this_val, args);
}

pub fn nativeDateSetYear(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const dd = try requireDate(arena, this_val);
    var nums: [1]f64 = undefined;
    _ = try coerceArgs(arena, args, &nums);
    // AnnexB setYear resets an Invalid Date (t defaults to +0) like setFullYear.
    const f = if (dd.valid) msToFields(dd.ms) else msToFields(0);
    // MakeFullYear: 0..99 maps to 1900+y; NaN stays NaN.
    var year = nums[0];
    if (std.math.isFinite(year)) {
        const yt = @trunc(year);
        if (yt >= 0 and yt <= 99) year = 1900 + yt;
    }
    return applyResult(arena, dd, composeTime(year, @floatFromInt(f.month), @floatFromInt(f.day), @floatFromInt(f.hour), @floatFromInt(f.min), @floatFromInt(f.sec), @floatFromInt(f.ms)));
}

// ------------------------------------------------------------------ formatters ---

pub fn nativeDateToUTCString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = (try brandValidDate(arena, this_val)) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    const s = try std.fmt.allocPrint(arena, "{s}, {d:0>2} {s} {s} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        WDAY[@intCast(f.weekday)],
        @as(u8, @intCast(f.day)),
        MON[@intCast(f.month)],
        try yearString(arena, f.year),
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
    });
    return val_mod.makeString(arena, s);
}

pub fn nativeDateToGMTString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDateToUTCString(arena, this_val, args);
}

pub fn nativeDateToDateString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = (try brandValidDate(arena, this_val)) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    const s = try std.fmt.allocPrint(arena, "{s} {s} {d:0>2} {s}", .{
        WDAY[@intCast(f.weekday)],
        MON[@intCast(f.month)],
        @as(u8, @intCast(f.day)),
        try yearString(arena, f.year),
    });
    return val_mod.makeString(arena, s);
}

pub fn nativeDateToTimeString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = (try brandValidDate(arena, this_val)) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    const s = try std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
    });
    return val_mod.makeString(arena, s);
}

pub fn nativeDateToJSON(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 21.4.4.37: O = ToObject(this) (null/undefined throw); tv = ToPrimitive(O,
    // number); a non-finite Number tv yields null; otherwise Invoke(O,
    // "toISOString") — which is looked up on O (user-overridable) and called.
    if (this_val.bits == 0 or this_val.unbox() == .undefined_ or this_val.unbox() == .null_)
        return realm_mod.throwTypeError(arena, "Date.prototype.toJSON called on null or undefined");
    const o = try realm_mod.toObjectForThis(arena, this_val);
    const tv = (try coercion.toPrimitive(arena, o, .number)) orelse o;
    if (tv.bits != 0 and tv.unbox() == .number and !std.math.isFinite(tv.unbox().number))
        return val_mod.makeNull(arena);
    const ctx = realm_mod.active_context orelse return realm_mod.throwTypeError(arena, "no active context");
    const method = try ctx.getProp(arena, o, "toISOString");
    if (method.bits == 0 or !function_proto.isCallableFn(method))
        return realm_mod.throwTypeError(arena, "toISOString is not callable");
    return function_proto.invokeCallback(arena, o, method, &[_]Value{});
}
