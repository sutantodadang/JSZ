// SPDX-License-Identifier: Apache-2.0
//! Phase 4b: Math object — constants and functions.
//! All numeric operations delegate to std.math.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const intrinsics = @import("intrinsics.zig");
const coercion = @import("coercion.zig");

/// R1: create the Math object, populate constants + functions, and bind the `Math` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const math_obj = try JsObject.create(arena, null);
    // Constants — ES value properties of the Math object are
    // { writable: false, enumerable: false, configurable: false }, so
    // `delete Math.PI` etc. returns false and never removes them.
    const consts = .{
        .{ "PI", std.math.pi },
        .{ "E", std.math.e },
        .{ "LN2", std.math.ln2 },
        .{ "LN10", std.math.ln10 },
        .{ "LOG2E", std.math.log2e },
        .{ "LOG10E", std.math.log10e },
        .{ "SQRT2", std.math.sqrt2 },
        .{ "SQRT1_2", 1.0 / std.math.sqrt2 },
    };
    inline for (consts) |c| {
        _ = try math_obj.defineOwnData(c[0], try val_mod.makeNumber(arena, c[1]), .{ .writable = false, .enumerable = false, .configurable = false });
    }
    // Functions
    const func_fns = .{
        .{ "abs", nativeAbs },
        .{ "floor", nativeFloor },
        .{ "ceil", nativeCeil },
        .{ "round", nativeRound },
        .{ "trunc", nativeTrunc },
        .{ "sqrt", nativeSqrt },
        .{ "pow", nativePow },
        .{ "exp", nativeExp },
        .{ "log", nativeLog },
        .{ "sin", nativeSin },
        .{ "cos", nativeCos },
        .{ "tan", nativeTan },
        .{ "random", nativeRandom },
        .{ "acos", nativeAcos },
        .{ "asin", nativeAsin },
        .{ "atan", nativeAtan },
        .{ "atan2", nativeAtan2 },
        .{ "sign", nativeSign },
        .{ "cbrt", nativeCbrt },
        .{ "log2", nativeLog2 },
        .{ "log10", nativeLog10 },
        .{ "log1p", nativeLog1p },
        .{ "expm1", nativeExpm1 },
        .{ "sinh", nativeSinh },
        .{ "cosh", nativeCosh },
        .{ "tanh", nativeTanh },
        .{ "asinh", nativeAsinh },
        .{ "acosh", nativeAcosh },
        .{ "atanh", nativeAtanh },
        .{ "hypot", nativeHypot },
        .{ "clz32", nativeClz32 },
        .{ "fround", nativeFround },
        .{ "f16round", nativeF16round },
        .{ "imul", nativeImul },
    };
    inline for (func_fns) |pair| {
        try math_obj.set(pair[0], try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], 0));
    }
    // Math.min/max spec `.length` is 2. Named explicitly: the plain *Len
    // constructor leaves `.name` unset, which reports "" instead of "min"/"max".
    try math_obj.set("min", try val_mod.makeNativeFunctionNamedLen(arena, nativeMin, "min", 2));
    try math_obj.set("max", try val_mod.makeNativeFunctionNamedLen(arena, nativeMax, "max", 2));
    try math_obj.set("sumPrecise", try val_mod.makeNativeFunctionNamedLen(arena, nativeSumPrecise, "sumPrecise", 1));
    const math_val = try val_mod.makeObject(arena, math_obj);
    try ctx.env.define("Math", math_val);
}

/// ES ToNumber for a Math argument. Spec-faithful: runs `@@toPrimitive` /
/// `valueOf` / `toString` on objects, propagates their throws, and raises a
/// TypeError for Symbol/BigInt instead of silently yielding NaN.
fn getNum(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    return coercion.toNumberThrowing(arena, v);
}

pub fn nativeAbs(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @abs(n));
}

pub fn nativeFloor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @floor(n));
}

pub fn nativeCeil(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @ceil(n));
}

pub fn nativeRound(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    // ES Math.round (20.2.2.28): closest integer, ties toward +Infinity, preserving
    // NaN/±Infinity/±0. NOT `floor(n+0.5)` — that rounds 0.5-ε up to 1 because the
    // float add loses precision (the spec's #4 carve-out). Compute against floor()
    // and the exact fractional part instead.
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return val_mod.makeNumber(arena, n);
    // (0, 0.5) → +0 ; (-0.5, 0) and -0.5 → -0.
    if (n > 0 and n < 0.5) return val_mod.makeNumber(arena, 0.0);
    if (n < 0 and n >= -0.5) return val_mod.makeNumber(arena, -0.0);
    const fl = @floor(n);
    const frac = n - fl;
    const r = if (frac >= 0.5) fl + 1 else fl; // ties (frac==0.5) round up (+Inf)
    return val_mod.makeNumber(arena, r);
}

pub fn nativeTrunc(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @trunc(n));
}

pub fn nativeSqrt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @sqrt(n));
}

/// ES Number::exponentiate (6.1.6.1.3). `std.math.pow` follows IEEE-754 `pow`,
/// which disagrees with ECMAScript on the ±1 base cases: IEEE says
/// `pow(-1, ±Infinity) == 1`, ECMAScript says NaN. The special cases below are
/// the spec's table, in spec order; anything not covered falls through to
/// `std.math.pow`.
pub fn numberExponentiate(base: f64, exponent: f64) f64 {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    if (std.math.isNan(exponent)) return nan;
    if (exponent == 0) return 1; // covers +0 and -0
    if (std.math.isNan(base)) return nan;
    // |base| == 1 with an infinite exponent is NaN in ECMAScript (not 1).
    if (std.math.isInf(exponent)) {
        const ab = @abs(base);
        if (ab == 1) return nan;
        if (exponent > 0) return if (ab > 1) inf else 0;
        return if (ab > 1) 0 else inf;
    }
    return std.math.pow(f64, base, exponent);
}

pub fn nativePow(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const base = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    const exp_ = if (args.len > 1) try getNum(arena, args[1]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, numberExponentiate(base, exp_));
}

pub fn nativeExp(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.exp(n));
}

pub fn nativeLog(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, @log(n));
}

pub fn nativeSin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.sin(n));
}

pub fn nativeCos(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cos(n));
}

pub fn nativeTan(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.tan(n));
}

/// Shared body of `Math.min` / `Math.max` (§21.3.2.24-25). Both coerce EVERY
/// argument with ToNumber first — a NaN must not short-circuit the loop, or a
/// later argument's `valueOf` is skipped — and both distinguish ±0, which `<`
/// and `>` cannot.
fn minMax(arena: std.mem.Allocator, args: []const Value, comptime want_max: bool) anyerror!Value {
    var acc: f64 = if (want_max) -std.math.inf(f64) else std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const n = try getNum(arena, a);
        if (std.math.isNan(n)) {
            saw_nan = true;
            continue;
        }
        if (saw_nan) continue;
        if (n == 0 and acc == 0) {
            // ±0 comparison: max prefers +0, min prefers -0.
            const n_neg = std.math.signbit(n);
            const acc_neg = std.math.signbit(acc);
            if (want_max) {
                if (acc_neg and !n_neg) acc = n;
            } else {
                if (!acc_neg and n_neg) acc = n;
            }
            continue;
        }
        if (if (want_max) n > acc else n < acc) acc = n;
    }
    if (saw_nan) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, acc);
}

pub fn nativeMin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return minMax(arena, args, false);
}

pub fn nativeMax(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return minMax(arena, args, true);
}

pub fn nativeRandom(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    // Use std.crypto.random for uniform [0,1).
    const bits = std.crypto.random.int(u53);
    const f: f64 = @as(f64, @floatFromInt(bits)) / @as(f64, 1 << 53);
    return val_mod.makeNumber(arena, f);
}

pub fn nativeAcos(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.acos(n));
}

pub fn nativeAsin(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.asin(n));
}

pub fn nativeAtan(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atan(n));
}

pub fn nativeAtan2(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const y = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    const x = if (args.len > 1) try getNum(arena, args[1]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atan2(y, x));
}

pub fn nativeSign(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
    if (n > 0) return val_mod.makeNumber(arena, 1);
    if (n < 0) return val_mod.makeNumber(arena, -1);
    // Preserve +0 / -0.
    return val_mod.makeNumber(arena, n);
}

pub fn nativeCbrt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cbrt(n));
}

pub fn nativeLog2(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log2(n));
}

pub fn nativeLog10(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log10(n));
}

pub fn nativeLog1p(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.log1p(n));
}

pub fn nativeExpm1(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.expm1(n));
}

pub fn nativeSinh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.sinh(n));
}

pub fn nativeCosh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.cosh(n));
}

pub fn nativeTanh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.tanh(n));
}

pub fn nativeAsinh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.asinh(n));
}

pub fn nativeAcosh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.acosh(n));
}

pub fn nativeAtanh(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    return val_mod.makeNumber(arena, std.math.atanh(n));
}

pub fn nativeHypot(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // sqrt of the sum of squares; +Inf if any arg is infinite, NaN propagates otherwise.
    var any_inf = false;
    var any_nan = false;
    var sum: f64 = 0;
    for (args) |a| {
        const n = try getNum(arena, a);
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
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    const u = toUint32(n);
    const lz: u32 = if (u == 0) 32 else @clz(u);
    return val_mod.makeNumber(arena, @floatFromInt(lz));
}

pub fn nativeFround(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f: f32 = @floatCast(n);
    return val_mod.makeNumber(arena, @floatCast(f));
}

pub fn nativeF16round(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    if (std.math.isNan(n)) return val_mod.makeNumber(arena, std.math.nan(f64));
    const f: f16 = @floatCast(n);
    return val_mod.makeNumber(arena, @floatCast(f));
}

pub fn nativeImul(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a = if (args.len > 0) try getNum(arena, args[0]) else std.math.nan(f64);
    const b = if (args.len > 1) try getNum(arena, args[1]) else std.math.nan(f64);
    const ia: i32 = @bitCast(toUint32(a));
    const ib: i32 = @bitCast(toUint32(b));
    const prod: i32 = ia *% ib;
    return val_mod.makeNumber(arena, @floatFromInt(prod));
}

// ---------------------------------------------------------------- Math.sumPrecise ---

/// Exact accumulator for `Math.sumPrecise`: a two's-complement fixed-point
/// integer whose bit 0 has place value 2**-SUM_BIAS. Every finite double is
/// `mantissa * 2**e` with a 53-bit mantissa and `e >= -1074`, so the whole
/// double range lands at bit positions [14, 2059] and a 53-bit mantissa reaches
/// bit 2111 — SUM_LIMBS*64 = 2560 bits leaves ~448 bits of headroom for carries,
/// far more than the 2**53 element cap the spec imposes. Accumulating this way
/// makes the sum exact, so the single rounding at the end is correctly rounded.
const SUM_LIMBS = 40;
const SUM_BIAS = 1088;
const Acc = [SUM_LIMBS]u64;

/// acc += (mantissa << bitpos), or -= when `negate`.
fn accAdd(acc: *Acc, mantissa: u64, bitpos: usize, negate: bool) void {
    const limb = bitpos >> 6;
    if (limb >= SUM_LIMBS) return;
    const off: u7 = @intCast(bitpos & 63);
    const wide: u128 = @as(u128, mantissa) << off;
    const parts = [2]u64{ @truncate(wide), @truncate(wide >> 64) };
    var carry: u1 = if (negate) 1 else 0;
    var i: usize = 0;
    while (limb + i < SUM_LIMBS) : (i += 1) {
        const raw: u64 = if (i < 2) parts[i] else 0;
        const operand: u64 = if (negate) ~raw else raw;
        // Once the operand is all-zero (add) / all-one (subtract) and the carry
        // has settled, the remaining limbs are unchanged.
        if (i >= 2 and carry == (if (negate) @as(u1, 1) else @as(u1, 0))) break;
        const s1 = @addWithOverflow(acc[limb + i], operand);
        const s2 = @addWithOverflow(s1[0], @as(u64, carry));
        acc[limb + i] = s2[0];
        carry = s1[1] | s2[1];
    }
}

fn accNegate(acc: *Acc) void {
    var carry: u1 = 1;
    for (acc) |*l| {
        const s = @addWithOverflow(~l.*, @as(u64, carry));
        l.* = s[0];
        carry = s[1];
    }
}

fn accBit(acc: *const Acc, i: usize) u1 {
    if (i >= SUM_LIMBS * 64) return 0;
    return @intCast((acc[i >> 6] >> @intCast(i & 63)) & 1);
}

/// True when any bit strictly below `i` is set (the sticky bit for rounding).
fn accAnyBelow(acc: *const Acc, i: usize) bool {
    const limb = i >> 6;
    for (acc[0..@min(limb, SUM_LIMBS)]) |l| if (l != 0) return true;
    if (limb < SUM_LIMBS) {
        const off: u6 = @intCast(i & 63);
        if (off != 0 and (acc[limb] & ((@as(u64, 1) << off) - 1)) != 0) return true;
    }
    return false;
}

/// The 64 bits starting at position `start`.
fn accWindow(acc: *const Acc, start: usize) u64 {
    const limb = start >> 6;
    if (limb >= SUM_LIMBS) return 0;
    const off: u6 = @intCast(start & 63);
    var v = acc[limb] >> off;
    if (off != 0 and limb + 1 < SUM_LIMBS) v |= acc[limb + 1] << @intCast(64 - @as(u32, off));
    return v;
}

/// Round the exact accumulator to the nearest double (ties-to-even).
fn accToDouble(acc_in: Acc) f64 {
    var acc = acc_in;
    const negative = acc[SUM_LIMBS - 1] >> 63 != 0;
    if (negative) accNegate(&acc);
    // Highest set bit; none means the sum is exactly zero.
    var hi: usize = 0;
    var found = false;
    var i: usize = SUM_LIMBS;
    while (i > 0) {
        i -= 1;
        if (acc[i] != 0) {
            hi = i * 64 + (63 - @clz(acc[i]));
            found = true;
            break;
        }
    }
    if (!found) return 0.0;
    // Lowest bit position the result can represent: 53 significant bits, but
    // never below 2**-1074 (bit 14 here), which is the subnormal granularity.
    var lo: usize = if (hi >= 52) hi - 52 else 0;
    if (lo < SUM_BIAS - 1074) lo = SUM_BIAS - 1074;
    var q = accWindow(&acc, lo);
    // Round to nearest, ties to even, using the bit just below `lo` plus sticky.
    if (accBit(&acc, lo - 1) == 1 and (accAnyBelow(&acc, lo - 1) or (q & 1) == 1)) q += 1;
    const mag = std.math.ldexp(@as(f64, @floatFromInt(q)), @as(i32, @intCast(lo)) - SUM_BIAS);
    return if (negative) -mag else mag;
}

const SumState = enum { minus_zero, finite, plus_infinity, minus_infinity, not_a_number };

/// Math.sumPrecise(items) — sum an iterable of Numbers with a single correctly
/// rounded result (ES2025 `Math.sumPrecise`). Values are NOT coerced: anything
/// that is not a Number is a TypeError, and the iterator is closed on the way
/// out.
pub fn nativeSumPrecise(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const collections = @import("es2015_collections.zig");
    const items = if (args.len > 0) args[0] else Value{};
    const iter = try collections.nativeGetIterator(arena, Value{}, &[_]Value{items});

    var acc: Acc = [_]u64{0} ** SUM_LIMBS;
    var state: SumState = .minus_zero;

    while (true) {
        const step = collections.nativeIterStep(arena, Value{}, &[_]Value{iter}) catch |e| return e;
        const done = try readIterField(arena, step, "done");
        if (val_mod.toBoolean(done)) break;
        const v = try readIterField(arena, step, "value");
        const is_number = v.bits != 0 and v.unbox() == .number;
        if (!is_number) {
            collections.closeIterator(arena, iter);
            return throwTypeError(arena, "Math.sumPrecise: iterable must yield only Numbers");
        }
        const n = v.unbox().number;
        if (state == .not_a_number) continue;
        if (std.math.isNan(n)) {
            state = .not_a_number;
        } else if (std.math.isInf(n)) {
            if (n > 0) {
                state = if (state == .minus_infinity) .not_a_number else .plus_infinity;
            } else {
                state = if (state == .plus_infinity) .not_a_number else .minus_infinity;
            }
        } else if (state == .minus_zero or state == .finite) {
            // -0 leaves the state alone: an all-(-0) sum (including the empty
            // one) is -0, while any other value makes the result a normal +0.
            if (!(n == 0 and std.math.signbit(n))) {
                state = .finite;
                addExact(&acc, n);
            }
        }
    }

    return val_mod.makeNumber(arena, switch (state) {
        .not_a_number => std.math.nan(f64),
        .plus_infinity => std.math.inf(f64),
        .minus_infinity => -std.math.inf(f64),
        .minus_zero => -0.0,
        .finite => accToDouble(acc),
    });
}

/// Add a finite double to the exact accumulator with no rounding.
fn addExact(acc: *Acc, n: f64) void {
    const bits: u64 = @bitCast(n);
    const negative = bits >> 63 != 0;
    const biased_exp: u64 = (bits >> 52) & 0x7FF;
    var mantissa: u64 = bits & 0xF_FFFF_FFFF_FFFF;
    var e: i32 = undefined;
    if (biased_exp == 0) {
        e = -1074; // subnormal (or zero): no implicit leading 1
    } else {
        mantissa |= @as(u64, 1) << 52;
        e = @as(i32, @intCast(biased_exp)) - 1075;
    }
    if (mantissa == 0) return;
    accAdd(acc, mantissa, @intCast(e + SUM_BIAS), negative);
}

fn readIterField(arena: std.mem.Allocator, step: Value, key: []const u8) anyerror!Value {
    const realm_m = @import("../realm.zig");
    if (realm_m.active_context) |ctx| return ctx.getProp(arena, step, key);
    if (step.bits != 0 and step.unbox() == .object)
        return step.toPtr().object.get(key) orelse val_mod.makeUndefined(arena);
    return val_mod.makeUndefined(arena);
}

fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const realm_m = @import("../realm.zig");
    const JsObjectT = @import("../../object/object.zig").JsObject;
    const proto = realm_m.error_proto_TypeError;
    const obj = if (realm_m.active_heap) |h|
        try JsObjectT.createOnHeap(h, proto)
    else
        try JsObjectT.create(arena, proto);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    realm_m.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}
