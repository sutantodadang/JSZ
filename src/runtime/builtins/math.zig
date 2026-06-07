// SPDX-License-Identifier: Apache-2.0
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
    // ES Math.round = floor(n + 0.5) (ties round toward +Infinity), preserving
    // NaN/±Infinity/±0. Differs from @round, which rounds halves away from zero.
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return val_mod.makeNumber(arena, n);
    const r = @floor(n + 0.5);
    // Values in (-0.5, 0] produce -0 per spec.
    if (r == 0 and n < 0) return val_mod.makeNumber(arena, -0.0);
    return val_mod.makeNumber(arena, r);
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

pub fn nativeAcos(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.acos(n));
}

pub fn nativeAsin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.asin(n));
}

pub fn nativeAtan(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atan(n));
}

pub fn nativeAtan2(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const y = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const x = if (args.len > 1) getNum(args[1]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atan2(y, x));
}

pub fn nativeSign(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
    if (n > 0) return val_mod.makeNumber(arena, 1);
    if (n < 0) return val_mod.makeNumber(arena, -1);
    // Preserve +0 / -0.
    return val_mod.makeNumber(arena, n);
}

pub fn nativeCbrt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cbrt(n));
}

pub fn nativeLog2(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log2(n));
}

pub fn nativeLog10(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log10(n));
}

pub fn nativeLog1p(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log1p(n));
}

pub fn nativeExpm1(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.expm1(n));
}

pub fn nativeSinh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.sinh(n));
}

pub fn nativeCosh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cosh(n));
}

pub fn nativeTanh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.tanh(n));
}

pub fn nativeAsinh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.asinh(n));
}

pub fn nativeAcosh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.acosh(n));
}

pub fn nativeAtanh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atanh(n));
}

pub fn nativeHypot(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // sqrt of the sum of squares; +Inf if any arg is infinite, NaN propagates otherwise.
    var any_inf = false;
    var any_nan = false;
    var sum: f64 = 0;
    for (args) |a| {
        const n = getNum(a);
        if (std.math.isInf(n)) any_inf = true;
        if (std.math.isNan(n)) any_nan = true;
        sum += n * n;
    }
    if (any_inf) return val_mod.makeNumber(arena, std.math.inf(f64));
    if (any_nan) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @sqrt(sum));
}

fn toUint32(n: f64) u32 {
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return 0;
    const trunced = @trunc(n);
    const m = @mod(trunced, 4294967296.0);
    const pos = if (m < 0) m + 4294967296.0 else m;
    return @intFromFloat(pos);
}

pub fn nativeClz32(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const u = toUint32(n);
    const lz: u32 = if (u == 0) 32 else @clz(u);
    return val_mod.makeNumber(arena, @floatFromInt(lz));
}

pub fn nativeFround(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f: f32 = @floatCast(n);
    return val_mod.makeNumber(arena, @floatCast(f));
}

pub fn nativeImul(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const b = if (args.len > 1) getNum(args[1]) else std.math.nan(f64);
    const ia: i32 = @bitCast(toUint32(a));
    const ib: i32 = @bitCast(toUint32(b));
    const prod: i32 = ia *% ib;
    return val_mod.makeNumber(arena, @floatFromInt(prod));
}
