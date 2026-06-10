// SPDX-License-Identifier: Apache-2.0
//! R2: exception/try/instanceof/construct opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const TryEntry = bcv.TryEntry;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;

pub inline fn opThrow(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const thrown_val = frame.registers[rsrc];
    self.last_exception_value = thrown_val;

    // Attach a synchronous stack trace to Error-like throwables
    // that lack one (e.g. user `throw new Error(...)`, which is
    // constructed via the realm ctor without frame access).
    if (thrown_val.bits != 0 and thrown_val.unbox() == .object) {
        const eo = thrown_val.toPtr().object;
        if (eo.getOwn("message") != null) self.captureStackBc(eo);
    }

    // Walk frame stack looking for a PUSH_TRY entry.
    var found_handler = false;
    var fi: usize = self.frames.items.len;
    while (fi > 0) {
        fi -= 1;
        const f = &self.frames.items[fi];
        if (f.try_stack.items.len > 0) {
            const entry = f.try_stack.pop().?;
            // Jump to handler in that frame.
            f.pc = entry.handler_pc;
            // Store exception in target register.
            if (entry.rexc != 0xFF) {
                f.registers[entry.rexc] = thrown_val;
            }
            // Pop all frames above fi.
            while (self.frames.items.len > fi + 1) {
                _ = self.frames.pop();
            }
            found_handler = true;
            break;
        }
        // Re-entrancy boundary (native callback or coroutine frame,
        // marked return_dst == 0xFF). The exception must not escape
        // into the caller's frames — those belong to a different
        // invocation (async driver, microtask reaction, native call).
        // Stop so this invocation's runLoop reports it uncaught; the
        // boundary owner converts it (e.g. rejects the async result
        // promise, which then resumes the awaiter with a throw).
        if (f.return_dst == 0xFF) break;
    }
    if (!found_handler) {
        // Uncaught exception. Format Error-like objects nicely.
        const msg = try bcv.formatExceptionMessage(self.arena, thrown_val);
        return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown_val } };
    }
    return null;
}

pub inline fn opPushTry(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rexc = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const handler_pc: usize = @intCast(@as(i64, @intCast(frame.pc)) + offset);
    try frame.try_stack.append(self.arena, TryEntry{
        .rexc = rexc,
        .handler_pc = handler_pc,
    });
    return null;
}

pub inline fn opPopTry(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    if (frame.try_stack.items.len > 0) {
        _ = frame.try_stack.pop();
    }
    return null;
}

pub inline fn opInstanceof(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rlhs = code[frame.pc];
    frame.pc += 1;
    const rrhs = code[frame.pc];
    frame.pc += 1;
    const lhs = frame.registers[rlhs];
    const rhs = frame.registers[rrhs];
    var result = false;
    const cache = &@constCast(frame.func.instanceof_ic_table)[site_pc];
    if (rhs.bits != 0 and rhs.unbox() == .object) {
        const rhs_obj = rhs.toPtr().object;
        var target_proto: ?*JsObject = null;
        if (cache.initialized and cache.rhs_obj != null and cache.rhs_obj.? == @as(*anyopaque, @ptrCast(rhs_obj))) {
            if (cache.target_proto) |tp| target_proto = @ptrCast(@alignCast(tp));
        } else {
            if (rhs_obj.get("prototype")) |pv| {
                if (pv.bits != 0 and pv.unbox() == .object) target_proto = pv.toPtr().object;
            }
            cache.initialized = true;
            cache.rhs_obj = @ptrCast(rhs_obj);
            cache.target_proto = if (target_proto) |tp| @ptrCast(tp) else null;
        }
        result = bcv.jsInstanceofWithTarget(lhs, target_proto);
    } else if (rhs.bits != 0 and rhs.unbox() == .bc_function) {
        // W2 unification: rhs is a bc constructor; its prototype
        // lives on the backing object (materialized once any
        // instance exists). Not cached (closure-keyed).
        var target_proto: ?*JsObject = null;
        if (rhs.toPtr().bc_function.obj) |fobj| {
            const o: *JsObject = @ptrCast(@alignCast(fobj));
            if (o.get("prototype")) |pv| {
                if (pv.bits != 0 and pv.unbox() == .object) target_proto = pv.toPtr().object;
            }
        }
        result = bcv.jsInstanceofWithTarget(lhs, target_proto);
    } else {
        result = false;
    }
    frame.registers[rdst] = try val_mod.makeBool(self.arena, result);
    return null;
}

pub inline fn opNewInstance(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const base = code[frame.pc];
    frame.pc += 1;
    const nargs = code[frame.pc];
    frame.pc += 1;
    const callee_val = frame.registers[base];
    const outcome = try self.doConstruct(callee_val, base, nargs, rdst);
    if (outcome) |msg| {
        // doConstruct returned error string: throw it.
        // "__js_exception__" is the sentinel for a JS exception already in last_exception_value.
        const thrown_val = if (std.mem.eql(u8, msg, "__js_exception__"))
            self.last_exception_value
        else blk: {
            self.last_exception_value = try self.makeErrorObjectBc("TypeError", msg);
            break :blk self.last_exception_value;
        };
        const found = try self.throwException(thrown_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown_val } };
    }
    return null;
}
