// SPDX-License-Identifier: MIT
//! Phase 4d: Date — constructor + prototype methods.
//! Storage: internal_kind = .date, internal_slot -> DateData{ ms: i64 }.
//! All UTC. Uses std.time.timestamp() for Date.now().
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");

pub const DateData = struct {
    ms: i64,
};

pub var active_date_proto: ?*JsObject = null;

// ------------------------------------------------------------------ helpers ---

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
const DateFields = struct {
    year: i32,
    month: i32,
    day: i32,
    weekday: i32,
    hour: i32,
    min: i32,
    sec: i32,
    ms: i32,
};

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
    if (rem_secs < 0) { rem_secs += 86400; days -= 1; }

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

/// UTC fields -> milliseconds since epoch.
fn fieldsToMs(year: i32, month: i32, day: i32, hour: i32, min_: i32, sec_: i32, ms_: i32) i64 {
    // Normalize month overflow.
    var y = year;
    var m = month;
    while (m >= 12) { m -= 12; y += 1; }
    while (m < 0)   { m += 12; y -= 1; }

    // Days from epoch to Jan 1 of year.
    var days: i64 = 0;
    if (y >= 1970) {
        var yr: i32 = 1970;
        while (yr < y) : (yr += 1) {
            days += if (isLeapYear(yr)) 366 else 365;
        }
    } else {
        var yr: i32 = 1969;
        while (yr >= y) : (yr -= 1) {
            days -= if (isLeapYear(yr)) 366 else 365;
        }
    }
    // Add days for months.
    var mo: i32 = 0;
    while (mo < m) : (mo += 1) {
        days += daysInMonth(mo, y);
    }
    days += @as(i64, day) - 1;

    return days * 86400_000 + @as(i64, hour) * 3_600_000 + @as(i64, min_) * 60_000 + @as(i64, sec_) * 1000 + ms_;
}

fn getDateData(this_val: Value) ?*DateData {
    if (this_val.bits == 0) return null;
    const inner = this_val.toPtr().*;
    if (inner != .object) return null;
    const obj = inner.object;
    if (obj.internal_kind != .date) return null;
    if (obj.internal_slot == null) return null;
    return @ptrCast(@alignCast(obj.internal_slot.?));
}

fn createDateObject(arena: std.mem.Allocator, ms: i64) !Value {
    const dd = try arena.create(DateData);
    dd.* = DateData{ .ms = ms };
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
    return switch (args[idx].toPtr().*) {
        .number => |n| @intFromFloat(n),
        else => default,
    };
}

// ------------------------------------------------------------------ Date.now ---

pub fn nativeDateNow(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const ts = std.time.milliTimestamp();
    return val_mod.makeNumber(arena, @floatFromInt(ts));
}

// ------------------------------------------------------------------ Date constructor ---

pub fn nativeDateCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ms: i64 = blk: {
        if (args.len == 0) {
            break :blk std.time.milliTimestamp();
        } else if (args.len == 1) {
            // new Date(ms) or new Date(string) — we only support ms.
            const v = args[0];
            if (v.bits != 0) {
                switch (v.toPtr().*) {
                    .number => |n| break :blk @intFromFloat(n),
                    else => break :blk std.time.milliTimestamp(),
                }
            }
            break :blk 0;
        } else {
            // new Date(year, month, day?, hour?, min?, sec?, ms?)
            const y  = argToI32(args, 0, 1970);
            const mo = argToI32(args, 1, 0);
            const d  = argToI32(args, 2, 1);
            const h  = argToI32(args, 3, 0);
            const mi = argToI32(args, 4, 0);
            const s  = argToI32(args, 5, 0);
            const ms_ = argToI32(args, 6, 0);
            break :blk fieldsToMs(y, mo, d, h, mi, s, ms_);
        }
    };

    // Populate `this` object (called with new).
    if (this_val.bits != 0 and this_val.toPtr().* == .object) {
        const dd = try arena.create(DateData);
        dd.* = DateData{ .ms = ms };
        this_val.toPtr().object.internal_kind = .date;
        this_val.toPtr().object.internal_slot = dd;
        return this_val;
    }
    return createDateObject(arena, ms);
}

// ------------------------------------------------------------------ prototype methods ---

pub fn nativeDateGetTime(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @floatFromInt(dd.ms));
}

pub fn nativeDateGetFullYear(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.year));
}

pub fn nativeDateGetMonth(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.month));
}

pub fn nativeDateGetDate(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.day));
}

pub fn nativeDateGetDay(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.weekday));
}

pub fn nativeDateGetHours(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.hour));
}

pub fn nativeDateGetMinutes(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.min));
}

pub fn nativeDateGetSeconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.sec));
}

pub fn nativeDateGetMilliseconds(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeNumber(arena, std.math.nan(f64));
    const f = msToFields(dd.ms);
    return val_mod.makeNumber(arena, @floatFromInt(f.ms));
}

pub fn nativeDateValueOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeDateGetTime(arena, this_val, args);
}

pub fn nativeDateToISOString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    // Use unsigned casts to avoid '+' sign in Zig format specifiers.
    const s = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, @intCast(@max(0, f.year))),
        @as(u8, @intCast(f.month + 1)),
        @as(u8, @intCast(f.day)),
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
        @as(u16, @intCast(f.ms)),
    });
    return val_mod.makeString(arena, s);
}

pub fn nativeDateToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dd = getDateData(this_val) orelse return val_mod.makeString(arena, "Invalid Date");
    const f = msToFields(dd.ms);
    const s = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, @intCast(@max(0, f.year))),
        @as(u8, @intCast(f.month + 1)),
        @as(u8, @intCast(f.day)),
        @as(u8, @intCast(f.hour)),
        @as(u8, @intCast(f.min)),
        @as(u8, @intCast(f.sec)),
        @as(u16, @intCast(f.ms)),
    });
    return val_mod.makeString(arena, s);
}
