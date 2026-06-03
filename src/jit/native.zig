// SPDX-License-Identifier: MIT
//! Phase 9 baseline JIT — Zig FFI surface over the Cranelift native backend
//! (`jit-native/` Rust cdylib). This is the first real native-codegen milestone:
//! drive Cranelift from Zig and call the emitted machine code.
//!
//! Not linked into the main `jsz` binary yet — exercised by `zig build jit-native`,
//! which builds the Rust cdylib, links its import lib, and runs the tests below.
//! See docs/JIT.md for the tiering / deopt plan.
const std = @import("std");

// C ABI exported by jit-native (see jit-native/src/lib.rs).
extern fn jsz_clif_available() c_int;
extern fn jsz_clif_compile_add() ?*const anyopaque;
extern fn jsz_clif_compile_const(k: i64) ?*const anyopaque;
extern fn jsz_clif_compile_count_loop() ?*const anyopaque;
extern fn jsz_clif_compile_guarded_iadd() ?*const anyopaque;
extern fn jsz_clif_compile_accumulate_loop() ?*const anyopaque;

/// Native `fn(i64, i64) -> i64` compiled by Cranelift.
pub const AddFn = *const fn (i64, i64) callconv(.c) i64;
/// Native `fn() -> i64` compiled by Cranelift.
pub const ConstFn = *const fn () callconv(.c) i64;
/// Native `while (i < limit) i += step; return i;` over unboxed i64 (step 4).
pub const CountLoopFn = *const fn (start: i64, limit: i64, step: i64) callconv(.c) i64;
/// Native guarded add: returns a+b when both flagged int, else sets `deopt`
/// and returns 0 (step 4 — models a type-guard fast path + deopt exit).
pub const GuardedAddFn = *const fn (a: i64, b: i64, a_is_int: i32, b_is_int: i32, deopt: *i32) callconv(.c) i64;
/// Native summation loop: `while (i<limit){ s += (f64)i; i += step; } *out_i=i; return s;`.
pub const AccumulateLoopFn = *const fn (start: i64, limit: i64, step: i64, s_init: f64, out_i: *i64) callconv(.c) f64;

/// True when the Cranelift backend is linked into this binary.
pub fn available() bool {
    return jsz_clif_available() == 1;
}

/// Compile a native `a + b` (i64) function. Null on codegen failure.
pub fn compileAdd() ?AddFn {
    const p = jsz_clif_compile_add() orelse return null;
    return @ptrCast(p);
}

/// Compile a native `() -> k` (i64) function. Null on codegen failure.
pub fn compileConst(k: i64) ?ConstFn {
    const p = jsz_clif_compile_const(k) orelse return null;
    return @ptrCast(p);
}

/// Compile the monomorphic-int counter loop kernel (step 4). Null on failure.
pub fn compileCountLoop() ?CountLoopFn {
    const p = jsz_clif_compile_count_loop() orelse return null;
    return @ptrCast(p);
}

/// Compile the guarded-add fast path with a deopt out-flag (step 4). Null on failure.
pub fn compileGuardedAdd() ?GuardedAddFn {
    const p = jsz_clif_compile_guarded_iadd() orelse return null;
    return @ptrCast(p);
}

/// Compile the native summation accumulator loop kernel. Null on failure.
pub fn compileAccumulateLoop() ?AccumulateLoopFn {
    const p = jsz_clif_compile_accumulate_loop() orelse return null;
    return @ptrCast(p);
}

test "cranelift backend is available" {
    try std.testing.expect(available());
}

test "cranelift compiles a native i64 add" {
    const f = compileAdd() orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(i64, 5), f(2, 3));
    try std.testing.expectEqual(@as(i64, -1), f(2, -3));
    try std.testing.expectEqual(@as(i64, 0), f(0, 0));
    try std.testing.expectEqual(@as(i64, 1_000_000), f(999_999, 1));
}

test "cranelift compiles a native const return" {
    const f = compileConst(42) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(i64, 42), f());
    const g = compileConst(-7) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(i64, -7), g());
}

test "step 4: native monomorphic-int counter loop matches JS while-loop semantics" {
    const loop = compileCountLoop() orelse return error.SkipZigTest;
    // `var i = 0; while (i < 5000) i = i + 1; i;`  ->  5000
    try std.testing.expectEqual(@as(i64, 5000), loop(0, 5000, 1));
    // step 2: 0,2,4,6,8 -> 10 (8 < 10 -> 10; 10 < 10 false)
    try std.testing.expectEqual(@as(i64, 10), loop(0, 10, 2));
    // already past limit: no iterations
    try std.testing.expectEqual(@as(i64, 5), loop(5, 5, 1));
    // overshoot: 0,3,6,9 -> 9 (9 < 7 false after first cross... 0<7,3<7,6<7,9!<7)
    try std.testing.expectEqual(@as(i64, 9), loop(0, 7, 3));
}

test "step 4: guarded add takes fast path or deopts on the type guard" {
    const gadd = compileGuardedAdd() orelse return error.SkipZigTest;
    var deopt: i32 = 0;
    // both integral -> fast path, no deopt
    try std.testing.expectEqual(@as(i64, 5), gadd(2, 3, 1, 1, &deopt));
    try std.testing.expectEqual(@as(i32, 0), deopt);
    // left not integral -> deopt
    deopt = 0;
    try std.testing.expectEqual(@as(i64, 0), gadd(2, 3, 0, 1, &deopt));
    try std.testing.expectEqual(@as(i32, 1), deopt);
    // right not integral -> deopt
    deopt = 0;
    try std.testing.expectEqual(@as(i64, 0), gadd(2, 3, 1, 0, &deopt));
    try std.testing.expectEqual(@as(i32, 1), deopt);
}

test "native summation accumulator loop matches JS semantics" {
    const acc = compileAccumulateLoop() orelse return error.SkipZigTest;
    var fi: i64 = 0;
    // sum 0..9 = 45, final i = 10
    try std.testing.expectEqual(@as(f64, 45), acc(0, 10, 1, 0, &fi));
    try std.testing.expectEqual(@as(i64, 10), fi);
    // seed 100, step 2: i = 0,2,4,6,8 -> 100 + (0+2+4+6+8) = 120, final i = 10
    try std.testing.expectEqual(@as(f64, 120), acc(0, 10, 2, 100, &fi));
    try std.testing.expectEqual(@as(i64, 10), fi);
    // already past limit: no iterations, s + i unchanged
    try std.testing.expectEqual(@as(f64, 7), acc(5, 5, 1, 7, &fi));
    try std.testing.expectEqual(@as(i64, 5), fi);
}
