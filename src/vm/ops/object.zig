// SPDX-License-Identifier: Apache-2.0
//! R2: object/array construction opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;

pub inline fn opNewObject(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const obj = if (self.heap) |heap|
        try JsObject.createOnHeap(heap, self.realm.object_prototype)
    else
        try JsObject.create(self.arena, self.realm.object_prototype);
    frame.registers[rdst] = try val_mod.makeObject(self.arena, obj);
    return null;
}

pub inline fn opNewArray(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    _ = code[frame.pc];
    frame.pc += 1; // length hint (unused in runtime)
    const arr = if (self.heap) |heap|
        try JsObject.createArrayOnHeap(heap, self.realm.array_prototype)
    else
        try JsObject.createArray(self.arena, self.realm.array_prototype);
    frame.registers[rdst] = try val_mod.makeObject(self.arena, arr);
    return null;
}

pub inline fn opArrayAppend(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self; // dense integer append uses the object's own arena
    const code = frame.func.chunk.code;
    const rarr = code[frame.pc];
    frame.pc += 1;
    const rval = code[frame.pc];
    frame.pc += 1;
    const arr_val = frame.registers[rarr];
    const val = frame.registers[rval];
    if (arr_val.bits != 0 and arr_val.unbox() == .object) {
        // Integer-index append: no per-element decimal-key allocation.
        try arr_val.toPtr().object.appendElement(val);
    }
    return null;
}

pub inline fn opArrayAppendHole(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rarr = code[frame.pc];
    frame.pc += 1;
    const count = code[frame.pc];
    frame.pc += 1;
    const arr_val = frame.registers[rarr];
    if (arr_val.bits != 0 and arr_val.unbox() == .object) {
        // Array-literal elision (`[1,,3]`): grow length by `count` real holes.
        arr_val.toPtr().object.appendHoles(count);
    }
    return null;
}

pub inline fn opArraySpread(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rarr = code[frame.pc];
    frame.pc += 1;
    const riter = code[frame.pc];
    frame.pc += 1;
    const arr_val = frame.registers[rarr];
    const iter_src = frame.registers[riter];
    if (arr_val.bits != 0 and arr_val.unbox() == .object) {
        const arr = arr_val.toPtr().object;
        const iter_mod = @import("../../runtime/builtins/es2015_collections.zig");
        const it = iter_mod.nativeGetIterator(self.arena, Value{}, &[_]Value{iter_src}) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("is not iterable")) |oc| return oc;
            return null;
        };
        while (true) {
            const step = iter_mod.nativeIterStep(self.arena, Value{}, &[_]Value{it}) catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("iterator error")) |oc| return oc;
                break;
            };
            if (step.bits == 0 or step.unbox() != .object) break;
            // IteratorComplete: an absent `done` is `undefined` (falsy), not the
            // end of iteration. IteratorValue reads `value` through the full
            // [[Get]] path so an accessor getter runs and a throw propagates.
            const done_v = self.getProp(step, "done") catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("iterator error")) |oc| return oc;
                break;
            };
            if (bcv.isTruthy(done_v)) break;
            const v = self.getProp(step, "value") catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("iterator error")) |oc| return oc;
                break;
            };
            try arr.appendElement(v);
        }
    }
    return null;
}
