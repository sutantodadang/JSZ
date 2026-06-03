// SPDX-License-Identifier: MIT
//! Phase 4b: Math object — constants and functions.
//! All numeric operations delegate to std.math.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;

fn getNum(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .number => |n| n,
        .boolean => |b| if (b) 1.0 else 0.0,
        .null_ => 0.0,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\n\r")) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

pub fn nativeAbs(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @abs(n));
}

pub fn nativeFloor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @floor(n));
}

pub fn nativeCeil(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @ceil(n));
}

pub fn nativeRound(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @round(n));
}

pub fn nativeTrunc(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @trunc(n));
}

pub fn nativeSqrt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @sqrt(n));
}

pub fn nativePow(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const base = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const exp_ = if (args.len > 1) getNum(args[1]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.pow(f64, base, exp_));
}

pub fn nativeExp(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.exp(n));
}

pub fn nativeLog(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @log(n));
}

pub fn nativeSin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.sin(n));
}

pub fn nativeCos(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cos(n));
}

pub fn nativeTan(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.tan(n));
}

pub fn nativeMin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeNumber(arena, std.math.inf(f64));
    var result = getNum(args[0]);
    for (args[1..]) |a| {
        const n = getNum(a);
        if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
        if (n < result) result = n;
    }
    return val_mod.makeNumber(arena, result);
}

pub fn nativeMax(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeNumber(arena, -std.math.inf(f64));
    var result = getNum(args[0]);
    for (args[1..]) |a| {
        const n = getNum(a);
        if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
        if (n > result) result = n;
    }
    return val_mod.makeNumber(arena, result);
}

pub fn nativeRandom(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    // Use std.crypto.random for uniform [0,1).
    const bits = std.crypto.random.int(u53);
    const f: f64 = @as(f64, @floatFromInt(bits)) / @as(f64, 1 << 53);
    return val_mod.makeNumber(arena, f);
}
