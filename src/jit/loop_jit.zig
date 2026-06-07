// SPDX-License-Identifier: Apache-2.0
//! Phase 9 step 5/6 — native hot-loop fast-forward (OSR-style).
//!
//! At a hot loop back-edge the bc VM asks this module to recognize the canonical
//! monomorphic-integer counter loop
//!
//!     var i = <int>; while (i < <int const>) { i = i + 1; }
//!
//! compiled to the exact opcode template
//!
//!     header: GET_GLOBAL Ra, "i"      LOAD_K Rb, Klimit      LT Rc, Ra, Rb
//!             JMP_IF_FALSE Rc -> exit
//!     body:   GET_GLOBAL Re, "i"      INC Rf, Re             SET_GLOBAL "i", Rf
//!             JMP -> header                                  (the back-edge)
//!
//! When it matches and the live `i` and the limit are integral numbers (the
//! type guard), the remaining iterations are run by a count-loop kernel, the
//! result is boxed once and written back to the global, and the VM jumps to the
//! loop exit. Anything unexpected -> return null and keep interpreting (a
//! graceful deopt; the interpreter is always the correct baseline).
//!
//! The kernel `native_count_loop` is an optional Cranelift-compiled
//! `fn(i64,i64,i64)->i64`, installed by the CLI when built with `-Djit=true`
//! (see src/jit/native.zig + main.zig). When null, a pure-Zig fallback runs, so
//! the optimization — and its tests — work without the native backend; Cranelift
//! is a drop-in for the kernel only.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const Op = @import("../bytecode/opcodes.zig").Op;
const Environment = @import("../runtime/execution_context.zig").Environment;

/// `fn(start, limit, step) -> final` computing `while (i < limit) i += step; i`.
pub const CountLoopFn = *const fn (start: i64, limit: i64, step: i64) callconv(.c) i64;

/// Optional native kernel. Installed by the CLI under `-Djit=true`; null = use
/// the pure-Zig fallback below. The native kernel only implements the canonical
/// `<` comparison; other comparisons use the generalized Zig kernel.
pub var native_count_loop: ?CountLoopFn = null;

/// `fn(start,limit,step,s_init,out_i)->final_s` for `while(i<limit){s+=i;i+=step}`.
pub const AccumulateLoopFn = *const fn (start: i64, limit: i64, step: i64, s_init: f64, out_i: *i64) callconv(.c) f64;

/// Optional native summation kernel (Cranelift). Installed under `-Djit=true`;
/// only used for the canonical `<` / `+` accumulator shape, else the Zig kernel.
pub var native_accumulate_loop: ?AccumulateLoopFn = null;

/// Loop comparison operator recovered from the header compare opcode.
const Cmp = enum { lt, le, gt, ge };

inline fn cmpTrue(i: i64, limit: i64, cmp: Cmp) bool {
    return switch (cmp) {
        .lt => i < limit,
        .le => i <= limit,
        .gt => i > limit,
        .ge => i >= limit,
    };
}

/// Pure-Zig reference kernel: `while (cmp(i, limit)) i += step; return i`.
fn zigCountLoop(start: i64, limit: i64, step: i64, cmp: Cmp) i64 {
    var i = start;
    while (cmpTrue(i, limit, cmp)) i += step;
    return i;
}

inline fn runCountLoop(start: i64, limit: i64, step: i64, cmp: Cmp) i64 {
    if (cmp == .lt) {
        if (native_count_loop) |f| return f(start, limit, step);
    }
    return zigCountLoop(start, limit, step, cmp);
}

/// Induction variable location: a global by constant-name index, or a frame
/// local/register slot. The header load, body load, and store must all agree.
const IndVar = union(enum) { global: u16, local: u8 };

inline fn indEql(a: IndVar, b: IndVar) bool {
    return switch (a) {
        .global => |x| b == .global and b.global == x,
        .local => |x| b == .local and b.local == x,
    };
}

const LoadInfo = struct { ind: IndVar, reg: u8, next: usize };

/// Parse a GET_GLOBAL/GET_LOCAL at `pc`, returning the loaded var, dest reg and
/// the pc after the instruction.
fn parseLoad(code: []const u8, pc: usize) ?LoadInfo {
    if (pc >= code.len) return null;
    switch (@as(Op, @enumFromInt(code[pc]))) {
        .GET_GLOBAL => {
            if (pc + 4 > code.len) return null;
            return .{ .ind = .{ .global = rdU16(code, pc + 2) }, .reg = code[pc + 1], .next = pc + 4 };
        },
        .GET_LOCAL => {
            if (pc + 3 > code.len) return null;
            return .{ .ind = .{ .local = code[pc + 2] }, .reg = code[pc + 1], .next = pc + 3 };
        },
        else => return null,
    }
}

/// Parse a SET_GLOBAL/SET_LOCAL storing `src_reg` into `target`; returns the pc
/// after the instruction, or null if it does not match.
fn parseStore(code: []const u8, pc: usize, target: IndVar, src_reg: u8) ?usize {
    if (pc >= code.len) return null;
    switch (target) {
        .global => |kn| {
            if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .SET_GLOBAL) return null;
            if (rdU16(code, pc + 1) != kn or code[pc + 3] != src_reg) return null;
            return pc + 4;
        },
        .local => |sl| {
            if (pc + 3 > code.len or @as(Op, @enumFromInt(code[pc])) != .SET_LOCAL) return null;
            if (code[pc + 1] != sl or code[pc + 2] != src_reg) return null;
            return pc + 3;
        },
    }
}

/// Read the live Value of an induction/accumulator var (global via env, local
/// via the register file).
fn readVar(ind: IndVar, constants: []const Value, env: *Environment, registers: []Value) ?Value {
    switch (ind) {
        .global => |kn| {
            const nv = constants[kn];
            if (nv.bits == 0 or nv.unbox() != .string) return null;
            return env.lookup(nv.toPtr().string) catch return null;
        },
        .local => |sl| return registers[sl],
    }
}

fn writeVar(ind: IndVar, constants: []const Value, env: *Environment, registers: []Value, v: Value) void {
    switch (ind) {
        .global => |kn| {
            const name = constants[kn].toPtr().string;
            env.assign(name, v) catch env.define(name, v) catch {};
        },
        .local => |sl| registers[sl] = v,
    }
}

inline fn accApply(s: f64, x: f64, op: u8) f64 {
    return switch (op) {
        '+' => s + x,
        '-' => s - x,
        '*' => s * x,
        else => s,
    };
}

/// Kernel for a counter loop carrying one accumulator updated by `s = s op i`
/// (in f64, matching the interpreter's arithmetic and iteration order).
const AccResult = struct { i: i64, s: f64 };

fn zigAccumulateLoop(start: i64, limit: i64, step: i64, cmp: Cmp, s_init: f64, op: u8) AccResult {
    var i = start;
    var s = s_init;
    while (cmpTrue(i, limit, cmp)) {
        s = accApply(s, @floatFromInt(i), op);
        i += step;
    }
    return .{ .i = i, .s = s };
}

/// Multiple accumulators folding the induction var: each `s[k] = s[k] op[k] i`
/// per iteration (f64, interpreter order). Mutates `s` in place; returns final i.
fn zigMultiAccLoop(start: i64, limit: i64, step: i64, cmp: Cmp, ops: []const u8, s: []f64) i64 {
    var i = start;
    while (cmpTrue(i, limit, cmp)) {
        const fi: f64 = @floatFromInt(i);
        for (ops, 0..) |op, k| s[k] = accApply(s[k], fi, op);
        i += step;
    }
    return i;
}

inline fn runAccumulateLoop(start: i64, limit: i64, step: i64, cmp: Cmp, s_init: f64, op: u8) AccResult {
    if (cmp == .lt and op == '+') {
        if (native_accumulate_loop) |f| {
            var out_i: i64 = undefined;
            const s = f(start, limit, step, s_init, &out_i);
            return .{ .i = out_i, .s = s };
        }
    }
    return zigAccumulateLoop(start, limit, step, cmp, s_init, op);
}

inline fn rdU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

/// Skip completion-value bookkeeping ops (`MOVE`, `LOAD_UNDEF`) that the program
/// compiler interleaves into the top-level loop body to track the eval/REPL
/// completion value. They write only the dedicated completion/prev registers —
/// never the induction or accumulator variables — so eliding them is sound for
/// the fast-forward. The final `pc == jmp_pc` body-shape check still rejects any
/// genuinely-extra instruction.
fn skipBenign(code: []const u8, pc_in: usize) usize {
    var pc = pc_in;
    while (pc < code.len) {
        switch (@as(Op, @enumFromInt(code[pc]))) {
            .MOVE => {
                if (pc + 3 > code.len) break;
                pc += 3;
            },
            .LOAD_UNDEF => {
                if (pc + 2 > code.len) break;
                pc += 2;
            },
            else => break,
        }
    }
    return pc;
}

/// Type guard: read an integral i64 from a number Value, or null if it is not a
/// finite integral number within the exactly-representable i64 range (2^53).
fn intGuard(v: Value) ?i64 {
    if (v.bits == 0) return null;
    switch (v.unbox()) {
        .number => |n| {
            if (!std.math.isFinite(n)) return null;
            if (@floor(n) != n) return null;
            if (n < -9007199254740992.0 or n > 9007199254740992.0) return null; // ±2^53
            return @intFromFloat(n);
        },
        else => return null,
    }
}

/// Recognize and fast-forward the canonical counter loop whose back-edge `JMP`
/// opcode is at `jmp_pc`. The induction variable may be a global or a frame
/// local (`registers`). Returns the absolute exit PC (loop completed, induction
/// var updated), or null to keep interpreting.
pub fn tryFastForwardLoop(
    arena: std.mem.Allocator,
    code: []const u8,
    constants: []const Value,
    env: *Environment,
    registers: []Value,
    jmp_pc: usize,
) ?usize {
    // Back-edge: JMP op(1) + i16 offset, relative to the next instruction.
    if (jmp_pc + 3 > code.len) return null;
    if (@as(Op, @enumFromInt(code[jmp_pc])) != .JMP) return null;
    const back_off: i16 = @bitCast(rdU16(code, jmp_pc + 1));
    const header_i: i64 = @as(i64, @intCast(jmp_pc + 3)) + back_off;
    if (header_i < 0) return null;
    const header_pc: usize = @intCast(header_i);

    var pc = header_pc;
    // [A] induction load: GET_GLOBAL Ra, Kname  |  GET_LOCAL Ra, slot
    var ind: IndVar = undefined;
    var ra: u8 = undefined;
    switch (@as(Op, @enumFromInt(code[pc]))) {
        .GET_GLOBAL => {
            if (pc + 4 > code.len) return null;
            ra = code[pc + 1];
            ind = .{ .global = rdU16(code, pc + 2) };
            pc += 4;
        },
        .GET_LOCAL => {
            if (pc + 3 > code.len) return null;
            ra = code[pc + 1];
            ind = .{ .local = code[pc + 2] };
            pc += 3;
        },
        else => return null,
    }
    // [B] LOAD_K Rb, Klimit
    if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .LOAD_K) return null;
    const rb = code[pc + 1];
    const klimit = rdU16(code, pc + 2);
    pc += 4;
    // [C] compare Rc, Ra, Rb  — one of LT/LE/GT/GE
    if (pc + 4 > code.len) return null;
    const cmp: Cmp = switch (@as(Op, @enumFromInt(code[pc]))) {
        .LT => .lt,
        .LE => .le,
        .GT => .gt,
        .GE => .ge,
        else => return null,
    };
    const rc = code[pc + 1];
    if (code[pc + 2] != ra or code[pc + 3] != rb) return null;
    pc += 4;
    // [D] JMP_IF_FALSE Rc -> exit
    if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .JMP_IF_FALSE) return null;
    if (code[pc + 1] != rc) return null;
    const exit_off: i16 = @bitCast(rdU16(code, pc + 2));
    const exit_i: i64 = @as(i64, @intCast(pc + 4)) + exit_off;
    if (exit_i < 0) return null;
    const exit_pc: usize = @intCast(exit_i);
    if (exit_pc > code.len) return null;
    pc += 4;
    // Skip the per-iteration completion-value snapshot (`MOVE prev <- completion`).
    pc = skipBenign(code, pc);
    // [acc] Zero or more accumulator blocks before the induction step. Each is
    // present iff the next body load targets a var DIFFERENT from the induction
    // var. Shape (acc folds the current induction value, then i steps):
    //   GET acc;  GET ind;  ADD|SUB|MUL Racc2, Racc, Rind;  SET acc, Racc2
    const Acc = struct { ind: IndVar, op: u8 };
    var accs: [4]Acc = undefined;
    var n_acc: usize = 0;
    while (parseLoad(code, pc)) |first| {
        if (indEql(first.ind, ind)) break; // induction block begins here
        if (n_acc >= accs.len) return null; // too many accumulators to fast-forward
        const accvar = first.ind;
        const il = parseLoad(code, first.next) orelse return null;
        if (!indEql(il.ind, ind)) return null; // accumulator must fold the induction var
        var p = il.next;
        if (p + 4 > code.len) return null;
        const aop: u8 = switch (@as(Op, @enumFromInt(code[p]))) {
            .ADD => '+',
            .SUB => '-',
            .MUL => '*',
            else => return null,
        };
        const racc2 = code[p + 1];
        if (code[p + 2] != first.reg or code[p + 3] != il.reg) return null;
        p += 4;
        pc = parseStore(code, p, accvar, racc2) orelse return null;
        // Skip the completion-value write after this accumulator statement.
        pc = skipBenign(code, pc);
        accs[n_acc] = .{ .ind = accvar, .op = aop };
        n_acc += 1;
    }
    // [E] body load of the same induction var.
    var re: u8 = undefined;
    switch (ind) {
        .global => |kn| {
            if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .GET_GLOBAL) return null;
            re = code[pc + 1];
            if (rdU16(code, pc + 2) != kn) return null;
            pc += 4;
        },
        .local => |sl| {
            if (pc + 3 > code.len or @as(Op, @enumFromInt(code[pc])) != .GET_LOCAL) return null;
            re = code[pc + 1];
            if (code[pc + 2] != sl) return null;
            pc += 3;
        },
    }
    // [F] step update — either `INC/DEC Rf, Re` (±1) or `LOAD_K Rstep, Kstep;
    //     ADD/SUB Rf, Re, Rstep` (±const).
    var step: i64 = undefined;
    var rf: u8 = undefined;
    if (pc + 3 <= code.len and @as(Op, @enumFromInt(code[pc])) == .INC) {
        rf = code[pc + 1];
        if (code[pc + 2] != re) return null;
        step = 1;
        pc += 3;
    } else if (pc + 3 <= code.len and @as(Op, @enumFromInt(code[pc])) == .DEC) {
        rf = code[pc + 1];
        if (code[pc + 2] != re) return null;
        step = -1;
        pc += 3;
    } else {
        // LOAD_K Rstep, Kstep
        if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .LOAD_K) return null;
        const rstep = code[pc + 1];
        const kstep = rdU16(code, pc + 2);
        pc += 4;
        // ADD/SUB Rf, Re, Rstep
        if (pc + 4 > code.len) return null;
        const sign: i64 = switch (@as(Op, @enumFromInt(code[pc]))) {
            .ADD => 1,
            .SUB => -1,
            else => return null,
        };
        rf = code[pc + 1];
        if (code[pc + 2] != re or code[pc + 3] != rstep) return null;
        const k = intGuard(constants[kstep]) orelse return null;
        step = sign * k;
        pc += 4;
    }
    // [G] store back to the same induction var.
    switch (ind) {
        .global => |kn| {
            if (pc + 4 > code.len or @as(Op, @enumFromInt(code[pc])) != .SET_GLOBAL) return null;
            if (rdU16(code, pc + 1) != kn) return null;
            if (code[pc + 3] != rf) return null;
            pc += 4;
        },
        .local => |sl| {
            if (pc + 3 > code.len or @as(Op, @enumFromInt(code[pc])) != .SET_LOCAL) return null;
            if (code[pc + 1] != sl) return null;
            if (code[pc + 2] != rf) return null;
            pc += 3;
        },
    }
    // Skip the completion-value write after the induction step.
    pc = skipBenign(code, pc);
    // [H] the very next instruction must be exactly the back-edge JMP we started
    // from — guarantees the loop body contains nothing else (sound to elide).
    if (pc != jmp_pc) return null;

    // Resolve the induction var's live start value and the limit; type-guard
    // both as integral numbers.
    const limit = intGuard(constants[klimit]) orelse return null;
    const start = intGuard(readVar(ind, constants, env, registers) orelse return null) orelse return null;

    // Termination guard: only fast-forward provably-terminating loops. An
    // ascending compare (lt/le) needs step > 0; a descending one (gt/ge) needs
    // step < 0. Anything else (incl. step == 0) could spin forever — deopt and
    // let the interpreter remain the correct baseline.
    const ascending = (cmp == .lt or cmp == .le);
    if (ascending and step <= 0) return null;
    if (!ascending and step >= 0) return null;

    // Accumulator loop: carry `s = s op i` in f64 (matches the interpreter), then
    // write back both the induction var and the accumulator; box once each.
    // Accumulator loop(s): carry each `s_k = s_k op_k i` in f64 (matching the
    // interpreter's arithmetic + iteration order), then write back the induction
    // var and every accumulator; box once each.
    if (n_acc > 0) {
        var ops: [4]u8 = undefined;
        var s: [4]f64 = undefined;
        for (0..n_acc) |k| {
            const s0_v = readVar(accs[k].ind, constants, env, registers) orelse return null;
            if (s0_v.bits == 0) return null;
            const sj = s0_v.unbox();
            if (sj != .number) return null;
            s[k] = sj.number;
            ops[k] = accs[k].op;
        }
        // Native fast path only for the single `s = s + i`, `<` shape.
        if (n_acc == 1 and ops[0] == '+' and cmp == .lt and native_accumulate_loop != null) {
            const r = runAccumulateLoop(start, limit, step, cmp, s[0], '+');
            writeVar(ind, constants, env, registers, val_mod.makeNumber(arena, @floatFromInt(r.i)) catch return null);
            writeVar(accs[0].ind, constants, env, registers, val_mod.makeNumber(arena, r.s) catch return null);
            return exit_pc;
        }
        const final_i = zigMultiAccLoop(start, limit, step, cmp, ops[0..n_acc], s[0..n_acc]);
        writeVar(ind, constants, env, registers, val_mod.makeNumber(arena, @floatFromInt(final_i)) catch return null);
        for (0..n_acc) |k| {
            writeVar(accs[k].ind, constants, env, registers, val_mod.makeNumber(arena, s[k]) catch return null);
        }
        return exit_pc;
    }

    // Run the remaining iterations in the kernel; box once; store back; exit.
    const final = runCountLoop(start, limit, step, cmp);
    const final_v = val_mod.makeNumber(arena, @floatFromInt(final)) catch return null;
    writeVar(ind, constants, env, registers, final_v);
    return exit_pc;
}

// ---------------------------------------------------------------------------
// Tests — exercise the pure-Zig kernel + the guard. Recognition is covered
// end-to-end by the integration tests (loop result must match the interpreter).
// ---------------------------------------------------------------------------
test "zig count-loop kernel matches JS while-loop semantics" {
    try std.testing.expectEqual(@as(i64, 5000), zigCountLoop(0, 5000, 1, .lt));
    try std.testing.expectEqual(@as(i64, 10), zigCountLoop(0, 10, 2, .lt));
    try std.testing.expectEqual(@as(i64, 5), zigCountLoop(5, 5, 1, .lt));
    try std.testing.expectEqual(@as(i64, 9), zigCountLoop(0, 7, 3, .lt));
    // <= is inclusive: stop when i > limit.
    try std.testing.expectEqual(@as(i64, 11), zigCountLoop(0, 10, 1, .le));
    try std.testing.expectEqual(@as(i64, 12), zigCountLoop(0, 10, 2, .le));
    // descending.
    try std.testing.expectEqual(@as(i64, 0), zigCountLoop(10, 0, -1, .gt));
    try std.testing.expectEqual(@as(i64, -1), zigCountLoop(10, 0, -1, .ge));
    try std.testing.expectEqual(@as(i64, -2), zigCountLoop(10, 0, -2, .ge));
}

test "intGuard accepts integral numbers, rejects non-integers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(?i64, 42), intGuard(try val_mod.makeNumber(a, 42.0)));
    try std.testing.expectEqual(@as(?i64, -7), intGuard(try val_mod.makeNumber(a, -7.0)));
    try std.testing.expectEqual(@as(?i64, null), intGuard(try val_mod.makeNumber(a, 1.5)));
    try std.testing.expectEqual(@as(?i64, null), intGuard(try val_mod.makeString(a, "x")));
    try std.testing.expectEqual(@as(?i64, null), intGuard(Value{}));
}
