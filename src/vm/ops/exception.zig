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

pub inline fn opEndFinally(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rtype = code[frame.pc];
    frame.pc += 1;
    const rval = code[frame.pc];
    frame.pc += 1;
    // Pending completion type (a number): 2 = throw, anything else = normal.
    const tv = frame.registers[rtype];
    var is_throw = false;
    if (tv.bits != 0) switch (tv.unbox()) {
        .number => |n| is_throw = (n == 2),
        else => {},
    };
    if (is_throw) {
        const thrown = frame.registers[rval];
        self.last_exception_value = thrown;
        const found = try self.throwException(thrown);
        if (!found) {
            const msg = try bcv.formatExceptionMessage(self.arena, thrown);
            return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown } };
        }
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
    const realm_mod = @import("../../runtime/realm.zig");
    const function_proto_mod = @import("../../runtime/builtins/function_proto.zig");

    // Spec §13.10.2 InstanceofOperator(V = lhs, target = rhs):
    // 1. If Type(target) is not Object, throw a TypeError.
    const rhs_is_object = rhs.bits != 0 and switch (rhs.unbox()) {
        .object, .bc_function, .native_function, .function => true,
        else => false,
    };
    if (!rhs_is_object) {
        realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "Right-hand side of 'instanceof' is not an object");
        if (try self.raisePendingException("Right-hand side of 'instanceof' is not an object")) |oc| return oc;
        return null;
    }
    // 2. Let instOfHandler be ? GetMethod(target, @@hasInstance).
    // 3. If instOfHandler is not undefined, return ToBoolean(Call(handler, target, «V»)).
    if (realm_mod.active_sym_has_instance) |hi_sym| {
        const handler = self.getPropSym(rhs, hi_sym) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error reading Symbol.hasInstance")) |oc| return oc;
            return null;
        };
        const handler_absent = handler.bits == 0 or handler.unbox() == .undefined_ or handler.unbox() == .null_;
        if (!handler_absent) {
            if (!function_proto_mod.isCallableFn(handler)) {
                realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "Symbol.hasInstance method is not callable");
                if (try self.raisePendingException("Symbol.hasInstance method is not callable")) |oc| return oc;
                return null;
            }
            const res = function_proto_mod.invokeCallback(self.arena, rhs, handler, &[_]Value{lhs}) catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("error in Symbol.hasInstance")) |oc| return oc;
                return null;
            };
            // callAccessor may have reallocated self.frames — write via the live top frame.
            self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, bcv.isTruthy(res));
            return null;
        }
    }
    // 4. No @@hasInstance handler: if target is not callable, throw a TypeError.
    if (!function_proto_mod.isCallableFn(rhs)) {
        realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "Right-hand side of 'instanceof' is not callable");
        if (try self.raisePendingException("Right-hand side of 'instanceof' is not callable")) |oc| return oc;
        return null;
    }
    // 5. OrdinaryHasInstance (the direct proto walk).
    // Mechanism B: a generator/async function value is .bc_function, not .object,
    // so jsInstanceofWithTarget would always return false for it as LHS. Coerce it
    // to its backing JsObject so the [[Prototype]] chain walk can succeed.
    var lhs_eff = lhs;
    if (lhs.bits != 0 and lhs.unbox() == .bc_function) {
        const backing = try self.closureBackingObj(lhs.toPtr().bc_function);
        lhs_eff = try val_mod.makeObject(self.arena, backing);
    }
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
        result = bcv.jsInstanceofWithTarget(lhs_eff, target_proto);
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
        result = bcv.jsInstanceofWithTarget(lhs_eff, target_proto);
    } else {
        result = false;
    }
    frame.registers[rdst] = try val_mod.makeBool(self.arena, result);
    return null;
}

pub inline fn opNewInstanceSpread(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rcallee = code[frame.pc];
    frame.pc += 1;
    const rargs = code[frame.pc];
    frame.pc += 1;
    const callee_v = frame.registers[rcallee];
    const args_v = frame.registers[rargs];
    // Flatten the args array into a Value slice (built by the compiler via
    // NEW_ARRAY/ARRAY_APPEND/ARRAY_SPREAD).
    var args_list = std.ArrayListUnmanaged(Value){};
    if (args_v.bits != 0 and args_v.unbox() == .object) {
        const arr = args_v.toPtr().object;
        const n = arr.getArrayLength();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
            const ev = arr.get(key) orelse try val_mod.makeUndefined(self.arena);
            try args_list.append(self.arena, ev);
        }
    }
    const result = self.constructFromArgs(callee_v, args_list.items) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in spread construct")) |oc| return oc;
        return null;
    };
    self.frames.items[self.frames.items.len - 1].registers[rdst] = result;
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
