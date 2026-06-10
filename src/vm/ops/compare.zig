// SPDX-License-Identifier: Apache-2.0
//! R2: comparison/logical opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");
const ic_mod = @import("../ic.zig");

pub inline fn opEq(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const r = self.abstractEqual(lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
    } else {
        frame.registers[rdst] = try val_mod.makeBool(self.arena, bcv.jsAbstractEqual(lv, rv));
    }
    return null;
}

pub inline fn opNeq(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const r = self.abstractEqual(lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, !r);
    } else {
        frame.registers[rdst] = try val_mod.makeBool(self.arena, !bcv.jsAbstractEqual(lv, rv));
    }
    return null;
}

pub inline fn opSeq(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const r = bcv.jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    return null;
}

pub inline fn opSneq(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const r = !bcv.jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    return null;
}

pub inline fn opLt(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lp = try self.coerceForRelational(lv);
        const rp = try self.coerceForRelational(rv);
        const r = bcv.jsLessThan(lp, rp) orelse false;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
    } else {
        const r = bcv.jsLessThan(lv, rv) orelse false;
        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    }
    return null;
}

pub inline fn opLe(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    // a <= b == !(b < a)
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lp = try self.coerceForRelational(lv);
        const rp = try self.coerceForRelational(rv);
        const r2 = bcv.jsLessThan(rp, lp);
        const r = if (r2) |v| !v else false;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
    } else {
        const r2 = bcv.jsLessThan(rv, lv);
        const r = if (r2) |v| !v else false;
        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    }
    return null;
}

pub inline fn opGt(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lp = try self.coerceForRelational(lv);
        const rp = try self.coerceForRelational(rv);
        const r = bcv.jsLessThan(rp, lp) orelse false;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
    } else {
        const r = bcv.jsLessThan(rv, lv) orelse false;
        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    }
    return null;
}

pub inline fn opGe(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    // a >= b == !(a < b)
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lp = try self.coerceForRelational(lv);
        const rp = try self.coerceForRelational(rv);
        const r2 = bcv.jsLessThan(lp, rp);
        const r = if (r2) |v| !v else false;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
    } else {
        const r2 = bcv.jsLessThan(lv, rv);
        const r = if (r2) |v| !v else false;
        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
    }
    return null;
}

pub inline fn opNot(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeBool(self.arena, !bcv.isTruthy(frame.registers[rsrc]));
    return null;
}

pub inline fn opTypeof(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const tv = frame.registers[rsrc];
    const info = bcv.classifyTypeof(tv);
    const cache = &@constCast(frame.func.typeof_ic_table)[site_pc];
    const hit = cache.initialized and cache.tag == info.tag and
        (info.shape == null or cache.shape == info.shape);
    const ts = if (hit) cache.result else info.result;
    if (!hit) {
        cache.initialized = true;
        cache.tag = info.tag;
        cache.shape = info.shape;
        cache.result = info.result;
    }
    frame.registers[rdst] = try val_mod.makeString(self.arena, ts);
    return null;
}
