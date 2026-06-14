// SPDX-License-Identifier: Apache-2.0
//! R2: arithmetic/bitwise opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
//!
//! CRITICAL: several arms (ADD, SUB, MUL, etc.) call user code that can
//! REALLOCATE self.frames; those arms re-fetch
//! self.frames.items[self.frames.items.len - 1] AFTER such calls.
//! DO NOT replace those re-fetches with `frame` — the pointer is stale.
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");

pub inline fn opAdd(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (val_mod.smiArith(lv, rv, '+')) |s| {
        frame.registers[rdst] = s;
        ac.mode = .number_pair;
    } else if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) {
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, lv.unbox().number + rv.unbox().number);
    } else {
        const sum = self.jsAdd(lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in addition")) |oc| return oc;
            return null;
        };
        // jsAdd may invoke user ToPrimitive hooks, which can
        // reallocate self.frames; re-fetch the current frame.
        self.frames.items[self.frames.items.len - 1].registers[rdst] = sum;
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
    }
    return null;
}

pub inline fn opSub(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntArithChecked(lv, rv, .sub) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt arithmetic")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const ln = try self.toNumberCoerced(lv);
        const rn = try self.toNumberCoerced(rv);
        ac.mode = .unknown;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln - rn);
    } else if (val_mod.smiArith(lv, rv, '-')) |s| {
        frame.registers[rdst] = s;
        ac.mode = .number_pair;
    } else {
        const r = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            lv.unbox().number - rv.unbox().number
        else
            bcv.toNumber(lv) - bcv.toNumber(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
    }
    return null;
}

pub inline fn opMul(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntArithChecked(lv, rv, .mul) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt arithmetic")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const ln = try self.toNumberCoerced(lv);
        const rn = try self.toNumberCoerced(rv);
        ac.mode = .unknown;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln * rn);
    } else if (val_mod.smiArith(lv, rv, '*')) |s| {
        frame.registers[rdst] = s;
        ac.mode = .number_pair;
    } else {
        const r = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            lv.unbox().number * rv.unbox().number
        else
            bcv.toNumber(lv) * bcv.toNumber(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
    }
    return null;
}

pub inline fn opDiv(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntArithChecked(lv, rv, .div) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt arithmetic")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        ac.mode = .unknown;
        const ln = self.toNumberCoerced(lv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
            return null;
        };
        const rn = self.toNumberCoerced(rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln / rn);
    } else {
        const r = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            lv.unbox().number / rv.unbox().number
        else
            bcv.toNumber(lv) / bcv.toNumber(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
    }
    return null;
}

pub inline fn opMod(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntArithChecked(lv, rv, .mod) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt arithmetic")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const l = try self.toNumberCoerced(lv);
        const r = try self.toNumberCoerced(rv);
        ac.mode = .unknown;
        const res = bcv.jsRemainder(l, r);
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, res);
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            lv.unbox().number
        else
            bcv.toNumber(lv);
        const r = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            rv.unbox().number
        else
            bcv.toNumber(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const res = bcv.jsRemainder(l, r);
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, res);
    }
    return null;
}

pub inline fn opExp(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    // ToNumeric both operands (may reenter JS via valueOf → frame realloc),
    // then dispatch BigInt vs Number exponentiation. Throws route through
    // the VM try/catch machinery.
    const result = self.expOp(lv, rv) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in exponentiation")) |oc| return oc;
        return null;
    };
    self.frames.items[self.frames.items.len - 1].registers[rdst] = result;
    return null;
}

pub inline fn opNeg(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const sv = frame.registers[rsrc];
    if (sv.bits != 0 and sv.unbox() == .bigint) {
        frame.registers[rdst] = try val_mod.bigIntNegate(self.arena, sv);
    } else if (bcv.isObjectOperand(sv)) {
        const n = try self.toNumberCoerced(sv);
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, -n);
    } else {
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, -bcv.toNumber(sv));
    }
    return null;
}

pub inline fn opBitAnd(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntBitChecked(lv, rv, .band) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt bitwise op")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lo = try self.toInt32Coerced(lv);
        const ro = try self.toInt32Coerced(rv);
        ac.mode = .unknown;
        const r: i32 = lo & ro;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const r0 = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toInt32(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: i32 = l & r0;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opBitOr(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntBitChecked(lv, rv, .bor) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt bitwise op")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lo = try self.toInt32Coerced(lv);
        const ro = try self.toInt32Coerced(rv);
        ac.mode = .unknown;
        const r: i32 = lo | ro;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const r0 = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toInt32(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: i32 = l | r0;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opBitXor(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntBitChecked(lv, rv, .bxor) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt bitwise op")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const lo = try self.toInt32Coerced(lv);
        const ro = try self.toInt32Coerced(rv);
        ac.mode = .unknown;
        const r: i32 = lo ^ ro;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const r0 = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toInt32(rv);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: i32 = l ^ r0;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opShl(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntBitChecked(lv, rv, .shl) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt shift")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const l = try self.toInt32Coerced(lv);
        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
        ac.mode = .unknown;
        const r: i32 = l << shift;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const shift: u5 = @intCast((if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toUint32(rv)) & 0x1F);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: i32 = l << shift;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opShr(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        const res = self.bigIntBitChecked(lv, rv, .shr) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in BigInt shift")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
        ac.mode = .unknown;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const l = try self.toInt32Coerced(lv);
        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
        ac.mode = .unknown;
        const r: i32 = l >> shift;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const shift: u5 = @intCast((if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toUint32(rv)) & 0x1F);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: i32 = l >> shift;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opUshr(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lv = frame.registers[rlhs];
    const rv = frame.registers[rrhs];
    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
    if (bcv.BcVm.isBigOperand(lv) or bcv.BcVm.isBigOperand(rv)) {
        _ = self.throwTypeErr("BigInts have no unsigned right shift, use >> instead") catch {};
        ac.mode = .unknown;
        if (try self.raisePendingException("BigInt >>> unsupported")) |oc| return oc;
        return null;
    }
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv)) {
        const l = try self.toInt32Coerced(lv);
        const u: u32 = @bitCast(l);
        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
        ac.mode = .unknown;
        const r: u32 = u >> shift;
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const l = if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
        else
            bcv.toInt32(lv);
        const u: u32 = @bitCast(l);
        const shift: u5 = @intCast((if (ac.mode == .number_pair and bcv.isNumberValue(lv) and bcv.isNumberValue(rv))
            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
        else
            bcv.toUint32(rv)) & 0x1F);
        ac.mode = if (bcv.isNumberValue(lv) and bcv.isNumberValue(rv)) .number_pair else .unknown;
        const r: u32 = u >> shift;
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opBitNot(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const sv = frame.registers[rsrc];
    if (bcv.BcVm.isBigOperand(sv)) {
        frame.registers[rdst] = try val_mod.bigIntBitNot(self.arena, sv);
    } else if (bcv.isObjectOperand(sv)) {
        const r: i32 = ~(try self.toInt32Coerced(sv));
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    } else {
        const r: i32 = ~bcv.toInt32(sv);
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
    }
    return null;
}

pub inline fn opInc(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const sv = frame.registers[rsrc];
    if (bcv.BcVm.isBigOperand(sv)) {
        const one = try val_mod.makeBigIntFromI64(self.arena, 1);
        frame.registers[rdst] = try val_mod.bigIntBinary(self.arena, sv, one, .add);
    } else if (bcv.isObjectOperand(sv)) {
        const n = try self.toNumberCoerced(sv);
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, n + 1.0);
    } else {
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, bcv.toNumber(sv) + 1.0);
    }
    return null;
}

pub inline fn opDec(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const sv = frame.registers[rsrc];
    if (bcv.BcVm.isBigOperand(sv)) {
        const one = try val_mod.makeBigIntFromI64(self.arena, 1);
        frame.registers[rdst] = try val_mod.bigIntBinary(self.arena, sv, one, .sub);
    } else if (bcv.isObjectOperand(sv)) {
        const n = try self.toNumberCoerced(sv);
        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, n - 1.0);
    } else {
        frame.registers[rdst] = try val_mod.makeNumber(self.arena, bcv.toNumber(sv) - 1.0);
    }
    return null;
}
