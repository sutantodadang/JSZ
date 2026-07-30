// SPDX-License-Identifier: Apache-2.0
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
extern fn jsz_clif_compile_int_block(code: [*]const u8, len: usize, kidx_to_slot: ?[*]const i32, n_kidx: usize) ?*const anyopaque;
const PropSite = extern struct { pc: u32, key_len: u32, key_ptr: u64, ic_ptr: u64 };
extern fn jsz_clif_compile_boxed_block(code: [*]const u8, len: usize, kidx_to_slot: ?[*]const i32, n_kidx: usize, prop_sites: ?[*]const PropSite, n_prop_sites: usize, get_helper: u64, set_helper: u64, call_helper: u64, closure_helper: u64) ?*const anyopaque;

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

/// Phase 12: general int-subset bytecode function compiled to native code.
/// `regs` = unboxed-i64 register file, `consts` = unboxed-i64 constant pool,
/// `locals` = unboxed-i64 function-local variable slots, `deopt` = out-flag set
/// to 1 when an arithmetic result escapes ±2^53 (the caller then discards the
/// result and re-interprets the call). Returns the value of the RETURNed register.
pub const IntBlockFn = *const fn (regs: [*]i64, consts: [*]const i64, locals: [*]i64, deopt: *i32, out_resume_pc: *u32) callconv(.c) i64;

/// Compile a monomorphic-int bytecode function (branches + loops over a register
/// file + env-local variables) to native code. `kidx_to_slot[k]` maps a
/// constant-pool index used as a `GET_GLOBAL`/`SET_GLOBAL`/`DEFINE_GLOBAL` name
/// operand to a `locals` slot, or negative when the name is not a monomorphic-int
/// local (forcing a bail). Null when the bytecode uses an unsupported opcode or a
/// non-local name (caller falls back to the interpreter).
pub fn compileIntBlock(code: []const u8, kidx_to_slot: []const i32) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    const p = jsz_clif_compile_int_block(code.ptr, code.len, map_ptr, kidx_to_slot.len) orelse return null;
    return @ptrCast(p);
}

/// Phase 12 boxed tier: same opcode subset as `compileIntBlock`, but every
/// `regs`/`locals`/`consts` slot holds a boxed `Value` (WebKit NaN-box bits), not
/// an unboxed i64. Arithmetic guards operands are SMI (else sets `deopt`), runs
/// the 2^53 overflow guard, then re-boxes the result (`makeNumber` semantics). The
/// returned i64 is itself a boxed `Value`. Null on unsupported opcode / non-local.
pub fn compileBoxedBlock(code: []const u8, kidx_to_slot: []const i32) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    // These FFI tests exercise the int-subset only (no property access).
    const p = jsz_clif_compile_boxed_block(code.ptr, code.len, map_ptr, kidx_to_slot.len, null, 0, 0, 0, 0, 0) orelse return null;
    return @ptrCast(p);
}

// NaN-box helpers for the boxed-tier tests (single-file module can't import
// value.zig; these mirror its committed JSVALUE64 constants — pinned by the
// contract test in value.zig).
const NB_NUMBER_TAG: u64 = 0xfffe_0000_0000_0000;
const NB_DOUBLE_OFFSET: u64 = 0x0002_0000_0000_0000;
fn boxSmi(n: i32) i64 {
    return @bitCast(NB_NUMBER_TAG | @as(u64, @as(u32, @bitCast(n))));
}
fn isBoxedSmi(b: i64) bool {
    return (@as(u64, @bitCast(b)) & NB_NUMBER_TAG) == NB_NUMBER_TAG;
}
fn unboxSmi(b: i64) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(b)))));
}
fn isBoxedDouble(b: i64) bool {
    const u = @as(u64, @bitCast(b));
    return (u & NB_NUMBER_TAG) != 0 and (u & NB_NUMBER_TAG) != NB_NUMBER_TAG;
}
fn unboxDouble(b: i64) f64 {
    return @bitCast(@as(u64, @bitCast(b)) -% NB_DOUBLE_OFFSET);
}
fn boxDouble(d: f64) i64 {
    return @bitCast(@as(u64, @bitCast(d)) +% NB_DOUBLE_OFFSET);
}
const NB_NULL: i64 = 0x2; // a non-number boxed value (for deopt tests)

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

// Opcode byte values mirror src/bytecode/opcodes.zig (Op enum order). The
// jit-native test module is single-file (can't import opcodes.zig), so these are
// literals here; opcodes.zig has a comptime test pinning these exact ordinals.
const OP_LOAD_K: u8 = 0;
const OP_GET_GLOBAL: u8 = 6;
const OP_SET_GLOBAL: u8 = 7;
const OP_MUL: u8 = 12;
const OP_ADD: u8 = 10;
const OP_BIT_AND: u8 = 16;
const OP_BIT_OR: u8 = 17;
const OP_BIT_XOR: u8 = 18;
const OP_SHL: u8 = 19;
const OP_SHR: u8 = 20;
const OP_USHR: u8 = 21;
const OP_BIT_NOT: u8 = 23;
const OP_INC: u8 = 24;
const OP_LT: u8 = 30;
const OP_JMP: u8 = 36;
const OP_JMP_IF_FALSE: u8 = 38;
const OP_RETURN: u8 = 45;
const OP_CALL: u8 = 44;
const OP_TO_NUMERIC: u8 = 89;
const OP_DIV: u8 = 13;
const OP_MOD: u8 = 14;
const OP_NEG: u8 = 22;
const no_locals = &[_]i32{};

fn i16lo(v: i16) u8 {
    return @truncate(@as(u16, @bitCast(v)));
}
fn i16hi(v: i16) u8 {
    return @truncate(@as(u16, @bitCast(v)) >> 8);
}

test "Phase 12: general int-block compiler runs an arbitrary sum loop" {
    // `s = 0; while (i < limit) { s = s + i; i = i + 1; } return s;`
    // regs: r0=i, r1=limit, r2=s, r3=cond.
    // Offsets: LT@0(4) JMP_IF_FALSE@4(4) ADD@8(4) INC@12(3) JMP@15(3) RETURN@18(2)
    // JMP_IF_FALSE@4: next=8, target=18 -> rel=+10 ; JMP@15: next=18, target=0 -> rel=-18
    const code = [_]u8{
        OP_LT,           3, 0, 1, // r3 = i < limit
        OP_JMP_IF_FALSE, 3, i16lo(10), i16hi(10), // if !r3 goto RETURN
        OP_ADD,          2, 2, 0, // s = s + i
        OP_INC,          0, 0, // i = i + 1
        OP_JMP,          i16lo(-18), i16hi(-18), // back to LT
        OP_RETURN,       2, // return s
    };

    const f = compileIntBlock(&code, no_locals) orelse return error.IntBlockReturnedNull;

    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    var regs1 = [_]i64{ 0, 10, 0, 0 }; // i=0, limit=10, s=0
    try std.testing.expectEqual(@as(i64, 45), f(&regs1, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc)); // sum 0..9
    try std.testing.expectEqual(@as(i64, 10), regs1[0]); // i ended at 10
    try std.testing.expectEqual(@as(i32, 0), deopt); // no overflow

    var regs2 = [_]i64{ 0, 5, 0, 0 }; // limit=5
    try std.testing.expectEqual(@as(i64, 10), f(&regs2, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc)); // sum 0..4

    var regs3 = [_]i64{ 7, 5, 0, 0 }; // i already past limit -> no iterations
    try std.testing.expectEqual(@as(i64, 0), f(&regs3, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc));
}

test "Phase 12: int-block compiler uses LOAD_K constants and arithmetic" {
    // `r0 = K0; r1 = K1; r2 = r0 * r1; return r2;`  with consts [6, 7] -> 42
    const code = [_]u8{
        OP_LOAD_K, 0, 0, 0, // r0 = consts[0]
        OP_LOAD_K, 1, 1, 0, // r1 = consts[1]
        OP_MUL,    2, 0, 1, // r2 = r0 * r1
        OP_RETURN, 2,
    };
    const f = compileIntBlock(&code, no_locals) orelse return error.IntBlockReturnedNull;
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(i64, 42), f(&regs, &[_]i64{ 6, 7 }, &[_]i64{}, &deopt, &resume_pc));
    try std.testing.expectEqual(@as(i32, 0), deopt);
}

test "JIT int-block implements JavaScript int32 bitwise and shift semantics" {
    const BinaryCase = struct {
        op: u8,
        lhs: i64,
        rhs: i64,
        expected: i64,
    };
    const cases = [_]BinaryCase{
        .{ .op = OP_BIT_AND, .lhs = 0x1234, .rhs = 0xff, .expected = 0x34 },
        .{ .op = OP_BIT_OR, .lhs = 0x1200, .rhs = 0x34, .expected = 0x1234 },
        .{ .op = OP_BIT_XOR, .lhs = -1, .rhs = 0xff, .expected = -256 },
        .{ .op = OP_SHL, .lhs = 1, .rhs = 33, .expected = 2 },
        .{ .op = OP_SHR, .lhs = -8, .rhs = 1, .expected = -4 },
        .{ .op = OP_USHR, .lhs = -1, .rhs = 0, .expected = 4_294_967_295 },
    };

    for (cases) |case| {
        const code = [_]u8{ case.op, 2, 0, 1, OP_RETURN, 2 };
        const f = compileIntBlock(&code, no_locals) orelse return error.IntBlockReturnedNull;
        var regs = [_]i64{ case.lhs, case.rhs, 0 };
        var deopt: i32 = 0;
        var resume_pc: u32 = 0xFFFFFFFF;
        const result = f(&regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
        try std.testing.expectEqual(case.expected, result);
        try std.testing.expectEqual(@as(i32, 0), deopt);
    }

    const not_code = [_]u8{ OP_BIT_NOT, 1, 0, OP_RETURN, 1 };
    const not_fn = compileIntBlock(&not_code, no_locals) orelse return error.IntBlockReturnedNull;
    var not_regs = [_]i64{ 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(i64, -1), not_fn(&not_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc));
}

test "JIT boxed bitwise keeps int32 results and unsigned shift range" {
    const and_code = [_]u8{ OP_BIT_AND, 2, 0, 1, OP_RETURN, 2 };
    const and_fn = compileBoxedBlock(&and_code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var and_regs = [_]i64{ boxSmi(0x1234), boxSmi(0xff), 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    const and_result = and_fn(&and_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(and_result));
    try std.testing.expectEqual(@as(i32, 0x34), unboxSmi(and_result));

    const ushr_code = [_]u8{ OP_USHR, 2, 0, 1, OP_RETURN, 2 };
    const ushr_fn = compileBoxedBlock(&ushr_code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var ushr_regs = [_]i64{ boxSmi(-1), boxSmi(0), 0 };
    deopt = 0;
    const ushr_result = ushr_fn(&ushr_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(ushr_result));
    try std.testing.expectEqual(@as(f64, 4_294_967_295), unboxDouble(ushr_result));
}

test "JIT boxed bitwise fine-deopts non-SMI operands" {
    const code = [_]u8{ OP_BIT_XOR, 2, 0, 1, OP_RETURN, 2 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var regs = [_]i64{ boxDouble(1.5), boxSmi(1), 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    _ = f(&regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);
}

test "JIT ToNumeric preserves numeric values and deopts other boxed values" {
    const code = [_]u8{ OP_TO_NUMERIC, 1, 0, OP_RETURN, 1 };
    const int_fn = compileIntBlock(&code, no_locals) orelse return error.IntBlockReturnedNull;
    var int_regs = [_]i64{ 42, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(i64, 42), int_fn(&int_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc));

    const boxed_fn = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var boxed_regs = [_]i64{ boxDouble(1.5), 0 };
    deopt = 0;
    const numeric = boxed_fn(&boxed_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expectEqual(@as(f64, 1.5), unboxDouble(numeric));

    var null_regs = [_]i64{ NB_NULL, 0 };
    deopt = 0;
    resume_pc = 0xFFFFFFFF;
    _ = boxed_fn(&null_regs, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);
}

test "JIT boxed DIV computes exact f64 quotients and canonicalizes integral results" {
    const code = [_]u8{ OP_DIV, 2, 0, 1, OP_RETURN, 2 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;

    // 7 / 2 = 3.5 -> boxed double.
    var regs1 = [_]i64{ boxSmi(7), boxSmi(2), 0 };
    const r1 = f(&regs1, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r1));
    try std.testing.expectEqual(@as(f64, 3.5), unboxDouble(r1));

    // 8 / 2 = 4 -> canonicalized to SMI.
    deopt = 0;
    var regs2 = [_]i64{ boxSmi(8), boxSmi(2), 0 };
    const r2 = f(&regs2, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(r2));
    try std.testing.expectEqual(@as(i32, 4), unboxSmi(r2));

    // 1 / 0 = +Infinity.
    deopt = 0;
    var regs3 = [_]i64{ boxSmi(1), boxSmi(0), 0 };
    const r3 = f(&regs3, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r3));
    try std.testing.expectEqual(std.math.inf(f64), unboxDouble(r3));

    // Non-numeric lhs -> fine-deopt at this pc.
    deopt = 0;
    resume_pc = 0xFFFFFFFF;
    var regs4 = [_]i64{ NB_NULL, boxSmi(1), 0 };
    _ = f(&regs4, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);
}

test "JIT boxed MOD matches JS % semantics including -0" {
    const code = [_]u8{ OP_MOD, 2, 0, 1, OP_RETURN, 2 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;

    // 7 % 3 = 1.
    var regs1 = [_]i64{ boxSmi(7), boxSmi(3), 0 };
    const r1 = f(&regs1, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(r1));
    try std.testing.expectEqual(@as(i32, 1), unboxSmi(r1));

    // -7 % 3 = -1.
    deopt = 0;
    var regs2 = [_]i64{ boxSmi(-7), boxSmi(3), 0 };
    const r2 = f(&regs2, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(r2));
    try std.testing.expectEqual(@as(i32, -1), unboxSmi(r2));

    // -6 % 3 = -0 (JS: sign follows the dividend).
    deopt = 0;
    var regs3 = [_]i64{ boxSmi(-6), boxSmi(3), 0 };
    const r3 = f(&regs3, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r3));
    const d3 = unboxDouble(r3);
    try std.testing.expectEqual(@as(f64, 0), d3);
    try std.testing.expect(std.math.signbit(d3));

    // 5 % 0 -> fine-deopt (non-zero-divisor guard).
    deopt = 0;
    resume_pc = 0xFFFFFFFF;
    var regs4 = [_]i64{ boxSmi(5), boxSmi(0), 0 };
    _ = f(&regs4, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);

    // Double lhs -> fine-deopt (SMI-only fast path).
    deopt = 0;
    resume_pc = 0xFFFFFFFF;
    var regs5 = [_]i64{ boxDouble(1.5), boxSmi(1), 0 };
    _ = f(&regs5, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);
}

test "JIT boxed NEG handles -0, doubles, and deopts non-numeric operands" {
    const code = [_]u8{ OP_NEG, 1, 0, OP_RETURN, 1 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;

    // -5.
    var regs1 = [_]i64{ boxSmi(5), 0 };
    const r1 = f(&regs1, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(r1));
    try std.testing.expectEqual(@as(i32, -5), unboxSmi(r1));

    // -0 (0 negated stays a double per makeNumber's -0 exclusion).
    deopt = 0;
    var regs2 = [_]i64{ boxSmi(0), 0 };
    const r2 = f(&regs2, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r2));
    const d2 = unboxDouble(r2);
    try std.testing.expectEqual(@as(f64, 0), d2);
    try std.testing.expect(std.math.signbit(d2));

    // -1.5.
    deopt = 0;
    var regs3 = [_]i64{ boxDouble(1.5), 0 };
    const r3 = f(&regs3, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r3));
    try std.testing.expectEqual(@as(f64, -1.5), unboxDouble(r3));

    // Non-numeric -> fine-deopt.
    deopt = 0;
    resume_pc = 0xFFFFFFFF;
    var regs4 = [_]i64{ NB_NULL, 0 };
    _ = f(&regs4, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 3), deopt);
    try std.testing.expectEqual(@as(u32, 0), resume_pc);
}

test "Phase 12: int-lane compiler rejects DIV (boxed-only opcode)" {
    const code = [_]u8{ OP_DIV, 2, 0, 1, OP_RETURN, 2 };
    try std.testing.expect(compileIntBlock(&code, no_locals) == null);
}

test "Phase 12: int-block compiler bails on an unsupported opcode" {
    // CALL is outside the int subset -> compiler returns null (interpreter fallback).
    const code = [_]u8{ OP_CALL, 0, 0, 0 };
    try std.testing.expect(compileIntBlock(&code, no_locals) == null);
}

test "Phase 12: int-fn compiler runs a real env-local function (sum)" {
    // Mirrors the real env-based bytecode for:
    //   function sum(n){ var s=0; var i=0; while(i<n){ s=s+i; i=i+1; } return s; }
    // Variables live in the env (GET_GLOBAL/SET_GLOBAL); names map to local slots:
    //   K0="s"->slot0, K1="i"->slot1, K2="n"->slot2, K3=0 (numeric literal, not a name).
    const code = [_]u8{
        OP_LOAD_K,       0, 3, 0, // r0 = consts[3] (=0)
        OP_SET_GLOBAL,   0, 0, 0, // s = r0            (K0, Rsrc=r0)
        OP_LOAD_K,       0, 3, 0, // r0 = 0
        OP_SET_GLOBAL,   1, 0, 0, // i = r0            (K1)
        // loop@16:
        OP_GET_GLOBAL,   0, 1, 0, // r0 = i            (K1)
        OP_GET_GLOBAL,   1, 2, 0, // r1 = n            (K2)
        OP_LT,           2, 0, 1, // r2 = i < n
        OP_JMP_IF_FALSE, 2, i16lo(30), i16hi(30), // if !r2 goto end@62
        OP_GET_GLOBAL,   0, 0, 0, // r0 = s            (K0)
        OP_GET_GLOBAL,   1, 1, 0, // r1 = i            (K1)
        OP_ADD,          2, 0, 1, // r2 = s + i
        OP_SET_GLOBAL,   0, 0, 2, // s = r2            (K0, Rsrc=r2)
        OP_GET_GLOBAL,   0, 1, 0, // r0 = i            (K1)
        OP_INC,          1, 0, // r1 = i + 1
        OP_SET_GLOBAL,   1, 0, 1, // i = r1            (K1, Rsrc=r1)
        OP_JMP,          i16lo(-46), i16hi(-46), // goto loop@16
        // end@62:
        OP_GET_GLOBAL,   0, 0, 0, // r0 = s            (K0)
        OP_RETURN,       0,
    };
    // K0->slot0(s), K1->slot1(i), K2->slot2(n), K3->-1 (numeric const, not a name).
    const map = [_]i32{ 0, 1, 2, -1 };
    const f = compileIntBlock(&code, &map) orelse return error.IntFnReturnedNull;

    const consts = [_]i64{ 0, 0, 0, 0 }; // only consts[3] (=0) is read
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    var locals1 = [_]i64{ 0, 0, 10 }; // s=0, i=0, n=10
    try std.testing.expectEqual(@as(i64, 45), f(&regs, &consts, &locals1, &deopt, &resume_pc)); // sum 0..9
    try std.testing.expectEqual(@as(i64, 10), locals1[1]); // i ended at 10
    try std.testing.expectEqual(@as(i32, 0), deopt);

    var locals2 = [_]i64{ 0, 0, 100 }; // n=100 -> sum 0..99 = 4950
    try std.testing.expectEqual(@as(i64, 4950), f(&regs, &consts, &locals2, &deopt, &resume_pc));

    var locals3 = [_]i64{ 0, 0, 0 }; // n=0 -> no iterations -> 0
    try std.testing.expectEqual(@as(i64, 0), f(&regs, &consts, &locals3, &deopt, &resume_pc));
}

test "Phase 12: int-fn bails when a name is not a local (true global)" {
    // GET_GLOBAL of K0 where K0 maps to -1 (a real global like `Math`) -> bail.
    const code = [_]u8{ OP_GET_GLOBAL, 0, 0, 0, OP_RETURN, 0 };
    const map = [_]i32{-1};
    try std.testing.expect(compileIntBlock(&code, &map) == null);
}

test "Phase 12: int-block guards arithmetic overflow past 2^53 and deopts" {
    // `r2 = r0 * r1; return r2;` — the product is exact in i64 but the guard
    // deopts whenever |product| > 2^53 (f64-exact range), so the caller can
    // re-interpret instead of returning a value that f64 can't represent.
    const code = [_]u8{
        OP_MUL,    2, 0, 1, // r2 = r0 * r1
        OP_RETURN, 2,
    };
    const f = compileIntBlock(&code, no_locals) orelse return error.IntBlockReturnedNull;

    // In range: 1000 * 1000 = 1e6 <= 2^53 -> no deopt, exact result.
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    var regs1 = [_]i64{ 1000, 1000, 0 };
    try std.testing.expectEqual(@as(i64, 1_000_000), f(&regs1, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc));
    try std.testing.expectEqual(@as(i32, 0), deopt);

    // Overflow: 1e8 * 1e8 = 1e16 > 2^53 (~9.007e15) -> deopt flag set.
    deopt = 0;
    var regs2 = [_]i64{ 100_000_000, 100_000_000, 0 };
    _ = f(&regs2, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 1), deopt);

    // Boundary: exactly 2^53 is still representable -> no deopt.
    deopt = 0;
    var regs3 = [_]i64{ 9_007_199_254_740_992, 1, 0 };
    try std.testing.expectEqual(@as(i64, 9_007_199_254_740_992), f(&regs3, &[_]i64{}, &[_]i64{}, &deopt, &resume_pc));
    try std.testing.expectEqual(@as(i32, 0), deopt);
}

test "Phase 12 boxed: env-local sum on boxed Values matches the int path (parity)" {
    // Same bytecode as the int env-local `sum`, but regs/consts/locals carry boxed
    // Values. K3 is boxed 0; locals are boxed [s,i,n]; the result is a boxed Value.
    const code = [_]u8{
        OP_LOAD_K,       0, 3, 0,
        OP_SET_GLOBAL,   0, 0, 0,
        OP_LOAD_K,       0, 3, 0,
        OP_SET_GLOBAL,   1, 0, 0,
        OP_GET_GLOBAL,   0, 1, 0,
        OP_GET_GLOBAL,   1, 2, 0,
        OP_LT,           2, 0, 1,
        OP_JMP_IF_FALSE, 2, i16lo(30), i16hi(30),
        OP_GET_GLOBAL,   0, 0, 0,
        OP_GET_GLOBAL,   1, 1, 0,
        OP_ADD,          2, 0, 1,
        OP_SET_GLOBAL,   0, 0, 2,
        OP_GET_GLOBAL,   0, 1, 0,
        OP_INC,          1, 0,
        OP_SET_GLOBAL,   1, 0, 1,
        OP_JMP,          i16lo(-46), i16hi(-46),
        OP_GET_GLOBAL,   0, 0, 0,
        OP_RETURN,       0,
    };
    const map = [_]i32{ 0, 1, 2, -1 };
    const f = compileBoxedBlock(&code, &map) orelse return error.BoxedBlockReturnedNull;

    const consts = [_]i64{ 0, 0, 0, boxSmi(0) }; // only K3 (boxed 0) is read
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    var locals = [_]i64{ boxSmi(0), boxSmi(0), boxSmi(100) }; // s=0,i=0,n=100
    const r = f(&regs, &consts, &locals, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedSmi(r));
    try std.testing.expectEqual(@as(i32, 4950), unboxSmi(r)); // sum 0..99
}

test "Phase 12 boxed: arithmetic re-boxes an out-of-i32 result as a double" {
    // r0 = K0; r1 = K1; r2 = r0 * r1; return r2;  100000*100000 = 1e10 (> i32 max,
    // < 2^53) → boxed as an offset-double, not an SMI.
    const code = [_]u8{
        OP_LOAD_K, 0, 0, 0,
        OP_LOAD_K, 1, 1, 0,
        OP_MUL,    2, 0, 1,
        OP_RETURN, 2,
    };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    const r = f(&regs, &[_]i64{ boxSmi(100000), boxSmi(100000) }, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expectEqual(@as(i32, 0), deopt);
    try std.testing.expect(isBoxedDouble(r));
    try std.testing.expectEqual(@as(f64, 1e10), unboxDouble(r));
}

test "Phase 12 boxed: arithmetic on a non-number operand deopts" {
    // r2 = r0 * r1; return r2;  with r0 = null (a non-number) → numeric guard
    // fails → deopt (the interpreter's null→0 coercion is not done in native).
    const code = [_]u8{ OP_MUL, 2, 0, 1, OP_RETURN, 2 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    _ = f(&regs, &[_]i64{ NB_NULL, boxSmi(2) }, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expect(deopt != 0);
}

test "Phase 12 boxed: full f64 arithmetic (SMI+double, re-box, -0)" {
    // ADD/MUL r2,r0,r1 read registers — seed operands into the regs array.
    const code = [_]u8{ OP_ADD, 2, 0, 1, OP_RETURN, 2 };
    const fadd = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    const mcode = [_]u8{ OP_MUL, 2, 0, 1, OP_RETURN, 2 };
    const fmul = compileBoxedBlock(&mcode, no_locals) orelse return error.BoxedBlockReturnedNull;
    const noc = &[_]i64{};
    var d: i32 = 0;
    var rpc: u32 = 0xFFFFFFFF;

    var a1 = [_]i64{ boxDouble(1.5), boxDouble(2.5), 0 };
    const r1 = fadd(&a1, noc, noc, &d, &rpc);
    try std.testing.expectEqual(@as(i32, 0), d);
    try std.testing.expect(isBoxedSmi(r1));
    try std.testing.expectEqual(@as(i32, 4), unboxSmi(r1));

    var a2 = [_]i64{ boxDouble(0.5), boxDouble(0.25), 0 };
    const r2 = fadd(&a2, noc, noc, &d, &rpc);
    try std.testing.expect(isBoxedDouble(r2));
    try std.testing.expectEqual(@as(f64, 0.75), unboxDouble(r2));

    var a3 = [_]i64{ boxSmi(3), boxDouble(1.5), 0 };
    const r3 = fadd(&a3, noc, noc, &d, &rpc);
    try std.testing.expect(isBoxedDouble(r3));
    try std.testing.expectEqual(@as(f64, 4.5), unboxDouble(r3));

    var a4 = [_]i64{ boxSmi(-1), boxSmi(0), 0 };
    const r4 = fmul(&a4, noc, noc, &d, &rpc);
    try std.testing.expect(isBoxedDouble(r4));
    const nz = unboxDouble(r4);
    try std.testing.expect(nz == 0.0 and std.math.signbit(nz));

    var a5 = [_]i64{ boxSmi(0), boxSmi(0), 0 };
    const r5 = fmul(&a5, noc, noc, &d, &rpc);
    try std.testing.expect(isBoxedSmi(r5));
    try std.testing.expectEqual(@as(i32, 0), unboxSmi(r5));
}

test "Phase 12 boxed: overflow past 2^53 deopts" {
    const code = [_]u8{ OP_MUL, 2, 0, 1, OP_RETURN, 2 };
    const f = compileBoxedBlock(&code, no_locals) orelse return error.BoxedBlockReturnedNull;
    var regs = [_]i64{ 0, 0, 0 };
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    _ = f(&regs, &[_]i64{ boxSmi(100000000), boxSmi(100000000) }, &[_]i64{}, &deopt, &resume_pc);
    try std.testing.expect(deopt != 0);
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
