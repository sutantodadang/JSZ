// SPDX-License-Identifier: Apache-2.0
//! R2: jump/branch opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
//!
//! Contract: return `null` to continue the dispatch loop, or a `RunOutcome`
//! that `runLoop` must return directly.
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const loop_jit = @import("../../jit/loop_jit.zig");

pub inline fn opJmp(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const op_site = frame.pc - 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const new_pc: i64 = @intCast(frame.pc);
    frame.pc = @intCast(new_pc + offset);
    if (offset < 0 and self.noteBackedge(frame.func, op_site)) {
        // Hot loop back-edge in experimental mode. First try general
        // OSR (the whole loop body compiled to native code — handles
        // arbitrary control flow); fall back to the closed-form
        // template recognizer; then deopt. On success jump straight
        // to the loop exit, else keep interpreting (graceful deopt).
        if (try self.tryOsrLoop(frame.func, op_site, frame.env, frame.registers)) |exit_pc| {
            frame.pc = exit_pc;
        } else if (loop_jit.tryFastForwardLoop(
            self.arena,
            code,
            frame.func.chunk.constants,
            frame.env,
            frame.registers,
            op_site,
        )) |exit_pc| {
            frame.pc = exit_pc;
            if (self.jit) |jc| jc.compiled += 1;
        } else if (self.jit) |jc| {
            _ = jc.noteDeopt(@intFromPtr(frame.func), @intCast(op_site)) catch {};
        }
    }
    return null;
}

pub inline fn opJmpIfTrue(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const op_site = frame.pc - 1;
    const rcond = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    if (bcv.isTruthy(frame.registers[rcond])) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
    }
    return null;
}

pub inline fn opJmpIfRetCompl(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rcond = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const v = frame.registers[rcond];
    const is_rc = v.bits != 0 and v.unbox() == .object and
        v.toPtr().object.internal_kind == .return_completion;
    if (is_rc) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
    }
    return null;
}

pub inline fn opJmpIfFalse(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const op_site = frame.pc - 1;
    const rcond = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    if (!bcv.isTruthy(frame.registers[rcond])) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
    }
    return null;
}

pub inline fn opJmpIfNullish(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rcond = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    if (frame.registers[rcond].isNullish()) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
    }
    return null;
}

pub inline fn opJmpIfNotNullish(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rcond = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    if (!frame.registers[rcond].isNullish()) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
    }
    return null;
}

pub inline fn opJseq(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const op_site = frame.pc - 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    if (bcv.jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs])) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
    }
    return null;
}

pub inline fn opJge(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const op_site = frame.pc - 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const lt = bcv.jsLessThan(frame.registers[rlhs], frame.registers[rrhs]);
    const ge = if (lt) |v| !v else false;
    if (ge) {
        const new_pc: i64 = @intCast(frame.pc);
        frame.pc = @intCast(new_pc + offset);
        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
    }
    return null;
}
