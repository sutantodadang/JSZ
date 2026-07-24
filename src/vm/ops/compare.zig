// SPDX-License-Identifier: Apache-2.0
//! R2: comparison/logical opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
const std = @import("std");
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
    // BigInt cross-type abstract equality needs an arena (to build the
    // comparison BigInt), so route it through the method path too.
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or isBigIntOperand(lv) or isBigIntOperand(rv)) {
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

inline fn isBigIntOperand(v: val_mod.Value) bool {
    return v.bits != 0 and v.unbox() == .bigint;
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
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or isBigIntOperand(lv) or isBigIntOperand(rv)) {
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

/// Coerce both relational operands via ToPrimitive(number) and reject a Symbol
/// result: IsLessThan applies ToNumeric to a non-string primitive, and
/// ToNumeric(Symbol) is a TypeError (`sym < 1`, `Symbol.iterator >= "x"`, …).
/// A Symbol is never a String, so "either primitive is a Symbol" is exactly the
/// case the spec throws on. BigInt is left alone (it compares fine).
const RelPair = struct { lp: val_mod.Value, rp: val_mod.Value };
inline fn relationalPrims(self: *BcVm, lv: val_mod.Value, rv: val_mod.Value) !RelPair {
    const lp = try self.coerceForRelational(lv);
    const rp = try self.coerceForRelational(rv);
    if (bcv.isSymbolOperand(lp) or bcv.isSymbolOperand(rp))
        return self.throwTypeErr("Cannot convert a Symbol value to a number");
    return .{ .lp = lp, .rp = rp };
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
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or bcv.isSymbolOperand(lv) or bcv.isSymbolOperand(rv)) {
        const pr = relationalPrims(self, lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in comparison")) |oc| return oc;
            return null;
        };
        const r = bcv.jsLessThan(pr.lp, pr.rp) orelse false;
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
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or bcv.isSymbolOperand(lv) or bcv.isSymbolOperand(rv)) {
        const pr = relationalPrims(self, lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in comparison")) |oc| return oc;
            return null;
        };
        const r2 = bcv.jsLessThan(pr.rp, pr.lp);
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
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or bcv.isSymbolOperand(lv) or bcv.isSymbolOperand(rv)) {
        const pr = relationalPrims(self, lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in comparison")) |oc| return oc;
            return null;
        };
        const r = bcv.jsLessThan(pr.rp, pr.lp) orelse false;
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
    if (bcv.isObjectOperand(lv) or bcv.isObjectOperand(rv) or bcv.isSymbolOperand(lv) or bcv.isSymbolOperand(rv)) {
        const pr = relationalPrims(self, lv, rv) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in comparison")) |oc| return oc;
            return null;
        };
        const r2 = bcv.jsLessThan(pr.lp, pr.rp);
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
    // typeof respects TDZ: if the operand is the TDZ sentinel (a live-exported
    // let/const binding not yet initialized), throw ReferenceError.
    const realm_mod = @import("../../runtime/realm.zig");
    if (realm_mod.tdz_marker) |marker| {
        if (tv.bits != 0 and tv.unbox() == .symbol and
            tv.toPtr().symbol == marker.toPtr().symbol)
        {
            const msg = try std.fmt.allocPrint(self.arena, "Cannot access binding before initialization", .{});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            return null;
        }
    }
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
