// SPDX-License-Identifier: Apache-2.0
//! R2: load/move/global/local opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
//!
//! Contract: return `null` to continue the dispatch loop, or a `RunOutcome`
//! that `runLoop` must return directly (used for uncaught exceptions).
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");

pub inline fn opLoadK(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    frame.registers[rdst] = frame.func.chunk.constants[kidx];
    return null;
}

pub inline fn opLoadTrue(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeBool(self.arena, true);
    return null;
}

pub inline fn opLoadFalse(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeBool(self.arena, false);
    return null;
}

pub inline fn opLoadNull(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeNull(self.arena);
    return null;
}

pub inline fn opLoadUndef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeUndefined(self.arena);
    return null;
}

pub inline fn opMove(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = frame.registers[rsrc];
    return null;
}

pub inline fn opGetGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    // Look up in frame env (chains to global), then realm global.
    // An identifier that resolves nowhere is a ReferenceError
    // (env lookups run no user code, so no frame realloc here).
    if (frame.env.lookup(name)) |v| {
        frame.registers[rdst] = v;
    } else |_| if (self.realm.global_env.lookup(name)) |v| {
        frame.registers[rdst] = v;
    } else |_| {
        const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
        const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
    }
    return null;
}

pub inline fn opGetGlobalOpt(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    // Tolerant load for `typeof <identifier>`: undeclared => undefined.
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    frame.registers[rdst] = frame.env.lookup(name) catch blk: {
        break :blk self.realm.global_env.lookup(name) catch
            try val_mod.makeUndefined(self.arena);
    };
    return null;
}

pub inline fn opHoistVar(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const undef = try val_mod.makeUndefined(self.arena);
    frame.env.hoistVar(name, undef) catch return error.OutOfMemory;
    return null;
}

pub inline fn opSetGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    const value = frame.registers[rsrc];
    const cur_is_strict = frame.func.is_strict;
    // Try to assign in env chain (covers locals and upvalues).
    frame.env.assign(name, value) catch {
        // Not found in chain.
        if (cur_is_strict) {
            // Phase 4d: strict mode — undeclared variable assignment is a ReferenceError.
            const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        } else if (frame.env.parent == null) {
            // Already at global env.
            frame.env.define(name, value) catch return error.OutOfMemory;
        } else {
            // Function-local env: define locally (var hoisting into current env).
            frame.env.define(name, value) catch return error.OutOfMemory;
        }
    };
    return null;
}

pub inline fn opDefineGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    // Phase 4d: always define (never throws ReferenceError in strict mode).
    // Used for var declarations, catch-variable bindings, function declarations.
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    const value = frame.registers[rsrc];
    // Try assign first (update existing binding), else define.
    frame.env.assign(name, value) catch {
        if (frame.env.parent == null) {
            frame.env.define(name, value) catch return error.OutOfMemory;
        } else {
            frame.env.define(name, value) catch return error.OutOfMemory;
        }
    };
    return null;
}

pub inline fn opGetLocal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const slot = code[frame.pc];
    frame.pc += 1;
    // GET_LOCAL reads from registers[slot]. Also sync from env if defined there.
    frame.registers[rdst] = frame.registers[slot];
    return null;
}

pub inline fn opSetLocal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const slot = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    frame.registers[slot] = frame.registers[rsrc];
    return null;
}
