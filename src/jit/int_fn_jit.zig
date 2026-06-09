// SPDX-License-Identifier: Apache-2.0
//! Phase 12 — runtime driver that JITs pure-integer leaf bytecode functions.
//!
//! This is the bc_vm-side glue over the general int-block compiler in
//! `native.zig` (Cranelift). It is reachable ONLY when the binary is built with
//! `-Djit=true` (so the Rust cdylib is linked) AND the JIT tier is in
//! `.experimental` mode — the default build/tests/conformance never touch it.
//!
//! ## Soundness gate (`analyze`)
//! A function is JITed only when every value it stores or returns is a genuine
//! integer, so the result can be re-boxed losslessly. The analyzer rejects a
//! function unless ALL hold:
//!   * every opcode is in the int subset (no calls, property access, etc.);
//!   * every `GET_GLOBAL`/`SET_GLOBAL`/`DEFINE_GLOBAL` names a function-LOCAL
//!     (param or `var`/hoisted name) — never a true global or captured var;
//!   * every `LOAD_K` constant is an integral number in i64-safe range;
//!   * every comparison/`NOT` result is consumed by the IMMEDIATELY following
//!     `JMP_IF_TRUE`/`JMP_IF_FALSE` on the same register — so a boolean never
//!     escapes into a stored/returned value (it only gates a branch).
//!   * not a generator/async function.
//!
//! ## Overflow handling (exact, no speculative boundary)
//! Each arithmetic op in the native code computes in i128 and guards its result
//! against ±2^53 (the f64-exact integer range). If any intermediate escapes, the
//! native function sets an out-flag and returns early; `run` then reports a deopt
//! (returns null) and the caller re-runs the call in the interpreter. Because a
//! JITed function is a side-effect-free pure-int leaf, re-interpreting from
//! scratch is sound. So the fast path is bit-exact with JS number semantics.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const opcodes = @import("../bytecode/opcodes.zig");
const Op = opcodes.Op;

// Cranelift backend FFI (declared here rather than imported from native.zig so
// this file belongs solely to the `jsz` module; native.zig stays owned by the
// CLI root module). Referenced only under -Djit=true (the caller is comptime
// gated), so default builds never link the cdylib.
extern fn jsz_clif_compile_int_block(
    code: [*]const u8,
    len: usize,
    kidx_to_slot: ?[*]const i32,
    n_kidx: usize,
) ?*const anyopaque;

/// Native `fn(regs, consts, locals, deopt) -> i64` produced by the int-block
/// compiler. `deopt` is set to 1 when an arithmetic result escapes ±2^53.
pub const IntBlockFn = *const fn (regs: [*]i64, consts: [*]const i64, locals: [*]i64, deopt: *i32) callconv(.c) i64;

fn compileNative(code: []const u8, kidx_to_slot: []const i32) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    const p = jsz_clif_compile_int_block(code.ptr, code.len, map_ptr, kidx_to_slot.len) orelse return null;
    return @ptrCast(p);
}

/// A compiled JIT plan for one pure-int function.
pub const JitPlan = struct {
    code_fn: IntBlockFn,
    /// Unboxed-i64 constant pool (parallel to `chunk.constants`).
    consts: []i64,
    /// Number of distinct function-local variable slots.
    n_slots: u16,
    num_regs: u16,
    arity: u16,
};

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn isLocalName(local_names: []const []const u8, name: []const u8) ?u16 {
    for (local_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return null;
}

fn constString(c: Value) ?[]const u8 {
    if (c.bits == 0) return null;
    if (!c.isHeapPtr()) return null;
    return switch (c.unbox()) {
        .string => |s| s,
        else => null,
    };
}

/// True for the compare/NOT opcodes whose result must be consumed immediately
/// by a conditional jump (so the boolean never escapes).
fn isCompare(op: Op) bool {
    return switch (op) {
        .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => true,
        else => false,
    };
}

/// Analyze + compile `func`. Returns a plan, or null when the function is not a
/// JIT-able pure-integer leaf (the caller then keeps interpreting).
pub fn analyze(arena: std.mem.Allocator, func: *const BcFunction) !?*JitPlan {
    if (func.is_generator or func.is_async) return null;
    const code = func.chunk.code;
    const constants = func.chunk.constants;
    if (code.len == 0 or constants.len == 0) return null;

    // ---- Pass A: collect function-local names (params first → slots 0..arity-1,
    // matching the marshalling), then DEFINE_GLOBAL / HOIST_VAR names. ----
    var local_names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (func.param_names) |p| {
        if (isLocalName(local_names.items, p) == null) try local_names.append(arena, p);
    }
    // Also collect jump targets, so an unreachable trailing RETURN_UNDEF epilogue
    // (emitted after an explicit `return`) can be told apart from a live one.
    var jump_targets: std.ArrayListUnmanaged(usize) = .empty;
    {
        var pc: usize = 0;
        while (pc < code.len) {
            const op: Op = @enumFromInt(code[pc]);
            const size = opcodes.instrSize(op);
            if (pc + size > code.len) return null;
            const next = pc + size;
            switch (op) {
                .DEFINE_GLOBAL, .HOIST_VAR => {
                    const kidx = readU16(code, pc + 1);
                    if (kidx < constants.len) {
                        if (constString(constants[kidx])) |nm| {
                            if (isLocalName(local_names.items, nm) == null)
                                try local_names.append(arena, nm);
                        }
                    }
                },
                .JMP => {
                    const rel: i16 = @bitCast(readU16(code, pc + 1));
                    try jump_targets.append(arena, @intCast(@as(isize, @intCast(next)) + rel));
                },
                .JMP_IF_TRUE, .JMP_IF_FALSE => {
                    const rel: i16 = @bitCast(readU16(code, pc + 2));
                    try jump_targets.append(arena, @intCast(@as(isize, @intCast(next)) + rel));
                },
                else => {},
            }
            pc += size;
        }
    }
    const isJumpTarget = struct {
        fn f(targets: []const usize, off: usize) bool {
            for (targets) |t| if (t == off) return true;
            return false;
        }
    }.f;
    const n_slots: u16 = @intCast(local_names.items.len);

    // ---- Pass B: build kidx→slot map (-1 = not a local) and the i64 const pool. ----
    const kidx_to_slot = try arena.alloc(i32, constants.len);
    const consts_i64 = try arena.alloc(i64, constants.len);
    for (constants, 0..) |c, k| {
        kidx_to_slot[k] = -1;
        consts_i64[k] = 0;
        if (constString(c)) |nm| {
            if (isLocalName(local_names.items, nm)) |slot| kidx_to_slot[k] = slot;
        } else if (c.bits != 0 and c.unbox() == .number) {
            const n = c.unbox().number;
            if (n == @trunc(n) and @abs(n) < 9007199254740992.0) { // integral, < 2^53
                consts_i64[k] = @intFromFloat(n);
            }
        }
    }

    // ---- Pass C: validate opcode subset + name locality + LOAD_K integrality +
    // the compare-then-jump boolean-containment rule. ----
    var pc: usize = 0;
    var prev_terminates = false; // previous op was an unconditional RETURN/JMP
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const size = opcodes.instrSize(op);
        if (pc + size > code.len) return null;
        switch (op) {
            .RETURN_UNDEF => {
                // Only a DEAD trailing epilogue is allowed: not a jump target and
                // preceded by an unconditional terminator. The native compiler
                // returns 0 here, which is never observed because it's unreachable.
                if (isJumpTarget(jump_targets.items, pc) or !prev_terminates) return null;
            },
            .LOAD_K => {
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len) return null;
                const c = constants[kidx];
                if (c.bits == 0 or c.unbox() != .number) return null;
                const n = c.unbox().number;
                if (n != @trunc(n) or @abs(n) >= 9007199254740992.0) return null;
            },
            .GET_GLOBAL => {
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len or kidx_to_slot[kidx] < 0) return null;
            },
            .SET_GLOBAL, .DEFINE_GLOBAL => {
                const kidx = readU16(code, pc + 1);
                if (kidx >= constants.len or kidx_to_slot[kidx] < 0) return null;
            },
            .HOIST_VAR => {},
            .MOVE, .ADD, .SUB, .MUL, .INC, .DEC, .RETURN, .JMP, .JMP_IF_TRUE, .JMP_IF_FALSE => {},
            .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => {
                // Boolean containment: the result reg (operand 0) must be read by
                // the very next instruction, which must be a conditional jump on it.
                const rdst = code[pc + 1];
                const next = pc + size;
                if (next >= code.len) return null;
                const nop: Op = @enumFromInt(code[next]);
                if (nop != .JMP_IF_TRUE and nop != .JMP_IF_FALSE) return null;
                if (code[next + 1] != rdst) return null;
            },
            else => return null, // unsupported opcode → bail
        }
        prev_terminates = (op == .RETURN or op == .JMP);
        pc += size;
    }

    // ---- Compile via Cranelift. ----
    const code_fn = compileNative(code, kidx_to_slot) orelse return null;
    const plan = try arena.create(JitPlan);
    plan.* = .{
        .code_fn = code_fn,
        .consts = consts_i64,
        .n_slots = n_slots,
        .num_regs = func.num_regs,
        .arity = func.arity,
    };
    return plan;
}

/// Run `plan` for a call with `args` (all guaranteed SMI by the caller).
/// Returns the re-boxed result Value, or null to signal a deopt — an arithmetic
/// result escaped ±2^53, so the caller must re-run the call in the interpreter
/// (sound: a JITed function is a side-effect-free pure-int leaf). Params occupy
/// local slots 0..arity-1.
pub fn run(arena: std.mem.Allocator, plan: *const JitPlan, args: []const Value) !?Value {
    const regs = try arena.alloc(i64, if (plan.num_regs > 0) plan.num_regs else 1);
    @memset(regs, 0);
    const locals = try arena.alloc(i64, if (plan.n_slots > 0) plan.n_slots else 1);
    @memset(locals, 0);
    var i: usize = 0;
    while (i < args.len and i < plan.n_slots) : (i += 1) {
        locals[i] = args[i].smiValue();
    }
    var deopt: i32 = 0;
    const r = plan.code_fn(regs.ptr, plan.consts.ptr, locals.ptr, &deopt);
    if (deopt != 0) return null; // overflow past 2^53 — fall back to interpreter.
    // Re-box: SMI when it fits i32, else a heap double (exact: |r| <= 2^53).
    if (r >= -2147483648 and r <= 2147483647) return Value.fromSmi(r);
    return try val_mod.makeNumber(arena, @floatFromInt(r));
}
