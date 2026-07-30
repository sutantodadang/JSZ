// SPDX-License-Identifier: Apache-2.0
//! Phase 12 — general loop OSR (on-stack replacement) over the Cranelift
//! int-block compiler.
//!
//! At a hot loop back-edge the interpreter asks this module to run the rest of
//! the loop natively. Unlike `loop_jit.zig` (which only recognizes a fixed set of
//! counter/accumulator *templates* and runs closed-form kernels), this compiles
//! the WHOLE loop-body region — arbitrary control flow inside the loop, including
//! `if`/`else`, nested loops, and several interacting integer variables — with
//! the same general bytecode→Cranelift IR compiler used for leaf functions
//! (`jsz_clif_compile_int_block`). It therefore optimizes loops the template
//! recognizer cannot.
//!
//! ## Region model
//! The region is the byte range `[header_pc, jmp_pc+3)` whose last instruction is
//! the back-edge `JMP` at `jmp_pc` (which targets `header_pc`). Bytecode jumps are
//! PC-relative, so a contiguous copy of the range preserves every intra-region
//! branch automatically. The single loop-exit edge (a forward branch out of the
//! region, all such edges must share one target = the resume PC) is rewritten to
//! target an appended `RETURN_UNDEF` terminator — so "loop exited" becomes
//! "native function returned".
//!
//! ## Soundness (env mutated ONLY on a clean, completed exit)
//! The native code runs against a PRIVATE `locals` copy seeded from the live env
//! values (each type-guarded as an integral number ≤ 2^53). The env is written
//! back ONLY when the loop runs to completion with no overflow deopt. On ANY
//! failure — a live value isn't an integer, an arithmetic result escapes ±2^53
//! (the same per-op guard as the leaf path), or the region isn't a pure-int loop
//! — `run` returns null with the env UNTOUCHED, and the caller falls back to the
//! template recognizer and ultimately the interpreter (always the correct
//! baseline). So OSR is purely additive: only the success-path writeback can ever
//! affect observable state, and that writeback reproduces exactly the integer
//! results the interpreter would have computed.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const opcodes = @import("../bytecode/opcodes.zig");
const Op = opcodes.Op;
const Environment = @import("../runtime/execution_context.zig").Environment;

// Cranelift backend FFI — declared here (not imported from native.zig) so this
// file belongs solely to the `jsz` module. Referenced only under -Djit=true (the
// caller is comptime gated), so default builds never link the cdylib.
extern fn jsz_clif_compile_int_block(
    code: [*]const u8,
    len: usize,
    kidx_to_slot: ?[*]const i32,
    n_kidx: usize,
) ?*const anyopaque;

/// Native `fn(regs, consts, locals, deopt) -> i64`. `deopt` is set to 1 when an
/// arithmetic result escapes ±2^53; the return value is unused for OSR.
pub const IntBlockFn = *const fn (regs: [*]i64, consts: [*]const i64, locals: [*]i64, deopt: *i32) callconv(.c) i64;

const F64_SAFE_INT: f64 = 9007199254740992.0; // 2^53

/// A compiled OSR plan for one loop region (cached per (func, back-edge pc)).
pub const OsrPlan = struct {
    code_fn: IntBlockFn,
    /// Unboxed-i64 constant pool (parallel to `func.chunk.constants`).
    consts: []i64,
    /// Dense slot → env variable name (for marshalling in and back out).
    names: [][]const u8,
    /// Dense slot → was it stored to in the region (only these are written back)?
    written: []bool,
    num_regs: u16,
    /// Absolute PCs to resume interpreting at, indexed by the exit number the
    /// native code returns (a loop may leave through several edges — guard, one or
    /// more `break`s — each routed to its own appended terminator block).
    exits: []usize,
};

/// Max distinct loop-exit edges a single OSR region may have (guard + breaks).
const MAX_EXITS = 8;

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn constString(c: Value) ?[]const u8 {
    if (c.bits == 0) return null;
    if (!c.isHeapPtr()) return null;
    return switch (c.unbox()) {
        .string => |s| s,
        else => null,
    };
}

/// Type guard: an integral number in the f64-exact range, else null.
fn intGuard(v: Value) ?i64 {
    if (v.bits == 0) return null;
    if (v.isSmi()) return v.smiValue();
    switch (v.unbox()) {
        .number => |n| {
            if (!std.math.isFinite(n)) return null;
            if (@floor(n) != n) return null;
            if (n < -F64_SAFE_INT or n > F64_SAFE_INT) return null;
            return @intFromFloat(n);
        },
        else => return null,
    }
}

fn isCompare(op: Op) bool {
    return switch (op) {
        .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => true,
        else => false,
    };
}

/// Analyze + compile the loop whose back-edge `JMP` is at `jmp_pc`. Returns a
/// plan, or null when the region is not a JIT-able pure-integer single-exit loop
/// (the caller then keeps interpreting / tries the template recognizer).
pub fn analyze(
    arena: std.mem.Allocator,
    func: *const BcFunction,
    jmp_pc: usize,
) !?*OsrPlan {
    if (func.is_generator or func.is_async) return null;
    const code = func.chunk.code;
    const constants = func.chunk.constants;
    if (jmp_pc + 3 > code.len) return null;
    if (@as(Op, @enumFromInt(code[jmp_pc])) != .JMP) return null;
    const back_off: i16 = @bitCast(readU16(code, jmp_pc + 1));
    const header_i: i64 = @as(i64, @intCast(jmp_pc + 3)) + back_off;
    if (header_i < 0) return null;
    const header_pc: usize = @intCast(header_i);
    if (header_pc >= jmp_pc) return null; // must be a backward edge
    const region_end = jmp_pc + 3;
    const region_len = region_end - header_pc;

    // ---- Pass A: collect local names (params first → slots 0..arity-1) and
    // validate the opcode subset, single exit edge, and register write-before-read.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var written: std.ArrayListUnmanaged(bool) = .empty;
    for (func.param_names) |p| {
        if (nameSlot(names.items, p) == null) {
            try names.append(arena, p);
            try written.append(arena, false);
        }
    }
    // Registers proven written somewhere strictly before their first read (linear
    // region order from the header). Reading a register never written earlier
    // would mean a value carried in from before the loop → unsound to OSR; bail.
    var reg_written = [_]bool{false} ** 256;

    var exits_buf: [MAX_EXITS]usize = undefined;
    var n_exits: usize = 0;
    var pc = header_pc;
    while (pc < region_end) {
        const op: Op = @enumFromInt(code[pc]);
        const size = opcodes.instrSize(op);
        if (pc + size > region_end) return null; // instr crosses region boundary
        switch (op) {
            // Pure value moves / loads.
            .LOAD_TRUE, .LOAD_FALSE, .LOAD_UNDEF => {
                reg_written[code[pc + 1]] = true;
            },
            .LOAD_K => {
                if (!regsRead(code, pc, op, &reg_written)) return null;
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len) return null;
                const c = constants[kidx];
                if (c.bits == 0 or c.unbox() != .number) return null;
                const n = c.unbox().number;
                if (n != @trunc(n) or @abs(n) >= F64_SAFE_INT) return null;
                reg_written[code[pc + 1]] = true;
            },
            .MOVE => {
                if (!regsRead(code, pc, op, &reg_written)) return null;
                reg_written[code[pc + 1]] = true;
            },
            .GET_GLOBAL => {
                const kidx = readU16(code, pc + 2);
                const slot = try internName(arena, &names, &written, constants, kidx) orelse return null;
                _ = slot;
                reg_written[code[pc + 1]] = true;
            },
            .SET_GLOBAL, .DEFINE_GLOBAL => {
                const kidx = readU16(code, pc + 1);
                const rsrc = code[pc + 3];
                if (!reg_written[rsrc]) return null; // store of an undefined reg
                const slot = try internName(arena, &names, &written, constants, kidx) orelse return null;
                written.items[slot] = true;
            },
            .HOIST_VAR => {},
            .HOIST_LEX => {},
            .INIT_LEX => {},
            .ADD, .SUB, .MUL, .BIT_AND, .BIT_OR, .BIT_XOR, .SHL, .SHR, .USHR => {
                if (!regsRead(code, pc, op, &reg_written)) return null;
                reg_written[code[pc + 1]] = true;
            },
            .BIT_NOT, .TO_NUMERIC, .INC, .DEC => {
                if (!regsRead(code, pc, op, &reg_written)) return null;
                reg_written[code[pc + 1]] = true;
            },
            .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => {
                if (!regsRead(code, pc, op, &reg_written)) return null;
                // Boolean containment: result must be consumed by the immediately
                // following conditional jump on the same register.
                const rdst = code[pc + 1];
                const next = pc + size;
                if (next >= region_end) return null;
                const nop: Op = @enumFromInt(code[next]);
                if (nop != .JMP_IF_TRUE and nop != .JMP_IF_FALSE) return null;
                if (code[next + 1] != rdst) return null;
                reg_written[rdst] = true;
            },
            .JMP => {
                const rel: i16 = @bitCast(readU16(code, pc + 1));
                const target: i64 = @as(i64, @intCast(pc + 3)) + rel;
                if (target < 0) return null;
                const t: usize = @intCast(target);
                if (t < header_pc or t >= region_end) {
                    // Out-of-region edge → a loop exit; intern it (dedup, capped).
                    if (internExit(&exits_buf, &n_exits, t) == null) return null;
                }
            },
            .JMP_IF_TRUE, .JMP_IF_FALSE => {
                const rcond = code[pc + 1];
                if (!reg_written[rcond]) return null;
                const rel: i16 = @bitCast(readU16(code, pc + 2));
                const target: i64 = @as(i64, @intCast(pc + 4)) + rel;
                if (target < 0) return null;
                const t: usize = @intCast(target);
                if (t < header_pc or t >= region_end) {
                    if (internExit(&exits_buf, &n_exits, t) == null) return null;
                }
            },
            else => return null, // RETURN/CALL/property/etc. → not OSR-able
        }
        pc += size;
    }

    if (n_exits == 0) return null; // a loop with no exit edge → bail
    // Each appended terminator block does `LOAD_K r0, Kindex` + `RETURN r0`, so the
    // native function returns WHICH exit fired. Indices live in extra const-pool
    // slots after the function's own constants; keep the name kidx within u16.
    if (constants.len + n_exits > 0xFFFF) return null;

    // ---- Build the region buffer: region copy + one terminator block per exit. ----
    const EXIT_BLOCK = 6; // LOAD_K(4) + RETURN(2)
    const buf = try arena.alloc(u8, region_len + n_exits * EXIT_BLOCK);
    @memcpy(buf[0..region_len], code[header_pc..region_end]);
    for (0..n_exits) |k| {
        const off = region_len + k * EXIT_BLOCK;
        const kidx: u16 = @intCast(constants.len + k);
        buf[off] = @intFromEnum(Op.LOAD_K);
        buf[off + 1] = 0; // r0 (scratch; registers are dead at loop exit)
        buf[off + 2] = @truncate(kidx);
        buf[off + 3] = @truncate(kidx >> 8);
        buf[off + 4] = @intFromEnum(Op.RETURN);
        buf[off + 5] = 0; // return r0 = the exit index
    }
    // Retarget every out-of-region branch in the copied region at its exit block.
    {
        var bp: usize = 0;
        while (bp < region_len) {
            const op: Op = @enumFromInt(buf[bp]);
            const size = opcodes.instrSize(op);
            const rel_at: usize = switch (op) {
                .JMP => bp + 1,
                .JMP_IF_TRUE, .JMP_IF_FALSE => bp + 2,
                else => {
                    bp += size;
                    continue;
                },
            };
            const next = bp + size;
            const rel: i16 = @bitCast(readU16(buf, rel_at));
            const target: i64 = @as(i64, @intCast(header_pc + next)) + rel;
            if (target < @as(i64, @intCast(header_pc)) or target >= @as(i64, @intCast(region_end))) {
                const j = internExit(&exits_buf, &n_exits, @intCast(target)).?; // already interned
                const block_off: i64 = @intCast(region_len + j * EXIT_BLOCK);
                writeI16(buf, rel_at, @intCast(block_off - @as(i64, @intCast(next))));
            }
            bp += size;
        }
    }

    // ---- kidx → slot map + i64 const pool: function constants + exit indices. ----
    const pool_len = constants.len + n_exits;
    const kidx_to_slot = try arena.alloc(i32, pool_len);
    const consts_i64 = try arena.alloc(i64, pool_len);
    for (constants, 0..) |c, k| {
        kidx_to_slot[k] = -1;
        consts_i64[k] = 0;
        if (constString(c)) |nm| {
            if (nameSlot(names.items, nm)) |slot| kidx_to_slot[k] = @intCast(slot);
        } else if (c.bits != 0 and c.unbox() == .number) {
            const n = c.unbox().number;
            if (n == @trunc(n) and @abs(n) < F64_SAFE_INT) consts_i64[k] = @intFromFloat(n);
        }
    }
    for (0..n_exits) |k| {
        kidx_to_slot[constants.len + k] = -1;
        consts_i64[constants.len + k] = @intCast(k); // the exit index itself
    }

    const code_fn = compileNative(buf, kidx_to_slot) orelse return null;
    const plan = try arena.create(OsrPlan);
    plan.* = .{
        .code_fn = code_fn,
        .consts = consts_i64,
        .names = try names.toOwnedSlice(arena),
        .written = try written.toOwnedSlice(arena),
        .num_regs = func.num_regs,
        .exits = try arena.dupe(usize, exits_buf[0..n_exits]),
    };
    return plan;
}

/// Intern an out-of-region exit target into `buf[0..n.*]` (dedup); returns its
/// index, or null when the exit table is full (too many distinct exits → bail).
fn internExit(buf: *[MAX_EXITS]usize, n: *usize, target: usize) ?usize {
    for (buf[0..n.*], 0..) |t, i| {
        if (t == target) return i;
    }
    if (n.* >= MAX_EXITS) return null;
    buf[n.*] = target;
    n.* += 1;
    return n.* - 1;
}

/// Validate that every SOURCE register of `op` at `pc` was written earlier in the
/// region (linear order). Returns false to bail (a value carried in a register
/// from before the loop is not safe to OSR).
fn regsRead(code: []const u8, pc: usize, op: Op, reg_written: *const [256]bool) bool {
    return switch (op) {
        .MOVE => reg_written[code[pc + 2]],
        .BIT_NOT, .TO_NUMERIC, .INC, .DEC, .NOT => reg_written[code[pc + 2]],
        .ADD, .SUB, .MUL, .BIT_AND, .BIT_OR, .BIT_XOR, .SHL, .SHR, .USHR, .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE => reg_written[code[pc + 2]] and reg_written[code[pc + 3]],
        else => true,
    };
}

fn nameSlot(items: []const []const u8, name: []const u8) ?usize {
    for (items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// Resolve a name-constant at `kidx` to a dense slot, interning it if new.
/// Returns null when the constant is not a string (not a name).
fn internName(
    arena: std.mem.Allocator,
    names: *std.ArrayListUnmanaged([]const u8),
    written: *std.ArrayListUnmanaged(bool),
    constants: []const Value,
    kidx: u16,
) !?usize {
    if (kidx >= constants.len) return null;
    const nm = constString(constants[kidx]) orelse return null;
    if (nameSlot(names.items, nm)) |slot| return slot;
    try names.append(arena, nm);
    try written.append(arena, false);
    return names.items.len - 1;
}

fn writeI16(buf: []u8, at: usize, v: i16) void {
    const u: u16 = @bitCast(v);
    buf[at] = @truncate(u);
    buf[at + 1] = @truncate(u >> 8);
}

fn compileNative(code: []const u8, kidx_to_slot: []const i32) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    const p = jsz_clif_compile_int_block(code.ptr, code.len, map_ptr, kidx_to_slot.len) orelse return null;
    return @ptrCast(p);
}

/// Run the OSR plan: marshal the live env vars in, run the loop natively, and on
/// a clean completed exit write the mutated vars back and return `exit_pc`.
/// Returns null (env UNTOUCHED) on a type-guard miss or an overflow deopt — the
/// caller then keeps interpreting.
pub fn run(
    arena: std.mem.Allocator,
    plan: *const OsrPlan,
    env: *Environment,
    registers: []Value,
) ?usize {
    _ = registers; // region registers are scratch (zeroed); env carries loop state.
    const n = plan.names.len;
    const locals = arena.alloc(i64, if (n > 0) n else 1) catch return null;
    @memset(locals, 0);
    // Marshal in: every live name must currently hold an integral number.
    for (plan.names, 0..) |name, i| {
        const v = env.lookup(name) catch return null;
        locals[i] = intGuard(v) orelse return null;
    }
    const regs = arena.alloc(i64, if (plan.num_regs > 0) plan.num_regs else 1) catch return null;
    @memset(regs, 0);

    var deopt: i32 = 0;
    const exit_idx = plan.code_fn(regs.ptr, plan.consts.ptr, locals.ptr, &deopt);
    if (deopt != 0) return null; // overflow past 2^53 — env untouched, fall back.
    // The native code returns which exit edge fired; map it to a resume PC.
    if (exit_idx < 0 or @as(usize, @intCast(exit_idx)) >= plan.exits.len) return null;

    // Clean exit: write the mutated vars back (box once each), then resume.
    for (plan.names, 0..) |name, i| {
        if (!plan.written[i]) continue;
        const boxed = val_mod.makeNumber(arena, @floatFromInt(locals[i])) catch return null;
        env.assign(name, boxed) catch (env.define(name, boxed) catch return null);
    }
    return plan.exits[@intCast(exit_idx)];
}
