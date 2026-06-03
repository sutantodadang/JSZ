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

/// Native `fn(i64, i64) -> i64` compiled by Cranelift.
pub const AddFn = *const fn (i64, i64) callconv(.c) i64;
/// Native `fn() -> i64` compiled by Cranelift.
pub const ConstFn = *const fn () callconv(.c) i64;

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
