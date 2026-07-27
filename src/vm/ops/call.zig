// SPDX-License-Identifier: Apache-2.0
//! R2: call/return/closure/yield/halt/debugger opcode handlers extracted from
//! `bc_vm.runLoop`. Each handler is `pub inline fn` so the optimizer folds it
//! back into the dispatch switch — behaviour and codegen are identical to the
//! inline arms.
//!
//! MOST DELICATE GROUP: these append/pop frames and control the loop.
//! RETURN pops a frame then continues (return null, loop re-fetches at top).
//! HALT returns its RunOutcome. YIELD suspends.
//! Copy bodies EXACTLY; preserve every frame re-fetch and early return.
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const BcClosure = @import("../../bytecode/function.zig").BcClosure;
const Environment = @import("../../runtime/execution_context.zig").Environment;

pub inline fn opNewClosure(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const fidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const child_fn = frame.func.child_functions[fidx];
    const closure = try self.arena.create(BcClosure);
    closure.* = BcClosure{
        .func = child_fn,
        .env = @ptrCast(frame.env),
        .realm = self.realmAsOpaque(),
        // Arrows have no own `this`: capture the definition site's `this` now so
        // it's used regardless of how/with-what-this the arrow is later called.
        .captured_this = if (child_fn.is_arrow)
            (if (frame.this_val.bits != 0) frame.this_val else try val_mod.makeUndefined(self.arena))
        else
            Value{},
        // Snapshot the enclosing `with` scopes (the frame's stack already holds
        // any it inherited itself, so one copy carries the whole chain).
        .with_scopes = if (frame.with_stack.items.len > 0)
            try self.arena.dupe(Value, frame.with_stack.items)
        else
            &.{},
    };
    const jsv = try self.arena.create(@import("../../value/value.zig").JsValue);
    jsv.* = @import("../../value/value.zig").JsValue{ .bc_function = closure };
    frame.registers[rdst] = Value.fromPtr(jsv);
    return null;
}

pub inline fn opCall(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const base = code[frame.pc];
    frame.pc += 1;
    const nargs = code[frame.pc];
    frame.pc += 1;
    const ret_dst = code[frame.pc];
    frame.pc += 1;

    const callee_val = frame.registers[base];
    const this_val = try val_mod.makeUndefined(self.arena); // CALL: this = undefined

    const outcome = try self.doCall(callee_val, this_val, base, nargs, ret_dst);
    if (outcome) |msg| {
        if (self.takeInterruptOutcome()) |oc| return oc;
        if (std.mem.eql(u8, msg, "__js_exception__")) {
            // Native threw a JS exception; last_exception_value already set.
            const exc_val = self.last_exception_value;
            const found = try self.throwException(exc_val);
            const exc_msg = try bcv.formatExceptionMessage(self.arena, exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
        } else {
            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        }
    }
    return null;
}

pub inline fn opTailCall(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const base = code[frame.pc];
    frame.pc += 1;
    const nargs = code[frame.pc];
    frame.pc += 1;
    const ret_dst = code[frame.pc];
    frame.pc += 1;

    const callee_val = frame.registers[base];
    const this_val = try val_mod.makeUndefined(self.arena); // TAIL_CALL: this = undefined

    // Proper tail call (ES2015 14.6): when the callee is a plain
    // bytecode function, reuse the current frame in place instead
    // of pushing a new one. Stack depth stays O(1) for tail
    // recursion. Args are read from the current registers BEFORE
    // the frame is overwritten.
    if (callee_val.bits != 0 and callee_val.unbox() == .bc_function and !callee_val.toPtr().bc_function.func.is_generator) {
        const closure = callee_val.toPtr().bc_function;
        const fn_ptr = closure.func;
        const def_env: *Environment = @ptrCast(@alignCast(closure.env));
        const call_env = try Environment.initVarScope(self.arena, def_env);

        for (fn_ptr.param_names, 0..) |pname, i| {
            const av: Value = if (i < nargs)
                frame.registers[base + 1 + @as(u8, @intCast(i))]
            else
                try val_mod.makeUndefined(self.arena);
            try call_env.define(pname, av);
        }
        try self.defineArguments(call_env, fn_ptr, frame.registers[@as(usize, base) + 1 ..][0..@as(usize, nargs)], closure);
        if (fn_ptr.name) |fname| {
            var is_param = false;
            for (fn_ptr.param_names) |p| {
                if (std.mem.eql(u8, p, fname)) {
                    is_param = true;
                    break;
                }
            }
            if (!is_param) call_env.define(fname, callee_val) catch {};
        }

        const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
        const new_regs = try self.arena.alloc(Value, num_regs);
        for (new_regs) |*r| r.* = Value{};
        for (fn_ptr.param_names, 0..) |_, i| {
            if (i < num_regs) {
                new_regs[i] = if (i < nargs)
                    frame.registers[base + 1 + @as(u8, @intCast(i))]
                else
                    try val_mod.makeUndefined(self.arena);
            }
        }
        if (fn_ptr.name) |fname| {
            var is_param = false;
            for (fn_ptr.param_names) |p| {
                if (std.mem.eql(u8, p, fname)) {
                    is_param = true;
                    break;
                }
            }
            if (!is_param) {
                const nfe_slot = fn_ptr.param_names.len;
                if (nfe_slot < num_regs) new_regs[nfe_slot] = callee_val;
            }
        }

        // Inherit the replaced frame's caller linkage: the callee
        // returns directly to *our* caller — that is the tail call.
        const inherited_caller = frame.caller_idx;
        const inherited_ret = frame.return_dst;
        frame.func = fn_ptr;
        frame.pc = 0;
        frame.registers = new_regs;
        frame.env = call_env;
        frame.return_dst = inherited_ret;
        frame.caller_idx = inherited_caller;
        // OrdinaryCallBindThis: arrows use captured lexical this; sloppy functions
        // substitute the global for undefined/null and box a primitive receiver.
        frame.this_val = try self.bindThisValue(fn_ptr, closure, this_val);
        frame.try_stack = .empty;
    } else {
        // Fallback: native/bound/object callee. Do a normal call,
        // then return its result to our caller (no frame reuse).
        const outcome = try self.doCall(callee_val, this_val, base, nargs, ret_dst);
        if (outcome) |msg| {
            if (self.takeInterruptOutcome()) |oc| return oc;
            if (std.mem.eql(u8, msg, "__js_exception__")) {
                const exc_val = self.last_exception_value;
                const found = try self.throwException(exc_val);
                const exc_msg = try bcv.formatExceptionMessage(self.arena, exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
            } else {
                const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                self.last_exception_value = exc_val;
                const found = try self.throwException(exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            }
        } else {
            const cur = &self.frames.items[self.frames.items.len - 1];
            const result = cur.registers[ret_dst];
            const caller_idx = cur.caller_idx;
            const rd = cur.return_dst;
            _ = self.frames.pop();
            if (caller_idx == null or self.frames.items.len == 0) {
                self.result = result;
                return RunOutcome{ .ok = result };
            }
            if (rd == 0xFF) {
                self.result = result;
                return RunOutcome{ .ok = result };
            }
            self.frames.items[self.frames.items.len - 1].registers[rd] = result;
        }
    }
    return null;
}

pub inline fn opMethodCall(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const base = code[frame.pc];
    frame.pc += 1;
    const nargs = code[frame.pc];
    frame.pc += 1;
    const ret_dst = code[frame.pc];
    frame.pc += 1;

    // R[base] = this object, R[base+1] = function value
    const this_val = frame.registers[base];
    const callee_val = frame.registers[base + 1];

    const outcome = try self.doMethodCall(callee_val, this_val, base, nargs, ret_dst);
    if (outcome) |msg| {
        if (self.takeInterruptOutcome()) |oc| return oc;
        if (std.mem.eql(u8, msg, "__js_exception__")) {
            const exc_val = self.last_exception_value;
            const found = try self.throwException(exc_val);
            const exc_msg = try bcv.formatExceptionMessage(self.arena, exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
        } else {
            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        }
    }
    return null;
}

pub inline fn opTailMethodCall(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const base = code[frame.pc];
    frame.pc += 1;
    const nargs = code[frame.pc];
    frame.pc += 1;
    const ret_dst = code[frame.pc];
    frame.pc += 1;

    // R[base] = this object, R[base+1] = callee, args at base+2..
    const this_val = frame.registers[base];
    const callee_val = frame.registers[base + 1];

    // Proper tail call in member position: when the callee is a
    // plain (non-generator, non-async) bytecode function, reuse the
    // current frame in place. Args are read BEFORE the frame is
    // overwritten. `this` is the receiver object (not undefined).
    if (callee_val.bits != 0 and callee_val.unbox() == .bc_function and
        !callee_val.toPtr().bc_function.func.is_generator and
        !callee_val.toPtr().bc_function.func.is_async)
    {
        const closure = callee_val.toPtr().bc_function;
        const fn_ptr = closure.func;
        const def_env: *Environment = @ptrCast(@alignCast(closure.env));
        const call_env = try Environment.initVarScope(self.arena, def_env);

        for (fn_ptr.param_names, 0..) |pname, i| {
            const av: Value = if (i < nargs)
                frame.registers[base + 2 + @as(u8, @intCast(i))]
            else
                try val_mod.makeUndefined(self.arena);
            try call_env.define(pname, av);
        }
        try self.defineArguments(call_env, fn_ptr, frame.registers[@as(usize, base) + 2 ..][0..@as(usize, nargs)], closure);
        if (fn_ptr.name) |fname| {
            var is_param = false;
            for (fn_ptr.param_names) |p| {
                if (std.mem.eql(u8, p, fname)) {
                    is_param = true;
                    break;
                }
            }
            if (!is_param) call_env.define(fname, callee_val) catch {};
        }

        const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
        const new_regs = try self.arena.alloc(Value, num_regs);
        for (new_regs) |*r| r.* = Value{};
        for (fn_ptr.param_names, 0..) |_, i| {
            if (i < num_regs) {
                new_regs[i] = if (i < nargs)
                    frame.registers[base + 2 + @as(u8, @intCast(i))]
                else
                    try val_mod.makeUndefined(self.arena);
            }
        }
        if (fn_ptr.name) |fname| {
            var is_param = false;
            for (fn_ptr.param_names) |p| {
                if (std.mem.eql(u8, p, fname)) {
                    is_param = true;
                    break;
                }
            }
            if (!is_param) {
                const nfe_slot = fn_ptr.param_names.len;
                if (nfe_slot < num_regs) new_regs[nfe_slot] = callee_val;
            }
        }

        const inherited_caller = frame.caller_idx;
        const inherited_ret = frame.return_dst;
        frame.func = fn_ptr;
        frame.pc = 0;
        frame.registers = new_regs;
        frame.env = call_env;
        frame.return_dst = inherited_ret;
        frame.caller_idx = inherited_caller;
        // OrdinaryCallBindThis: arrows use captured lexical this; sloppy functions
        // substitute the global for undefined/null and box a primitive receiver.
        frame.this_val = try self.bindThisValue(fn_ptr, closure, this_val);
        frame.try_stack = .empty;
    } else {
        // Fallback: native/bound/getter/generator/async callee. Do a
        // normal method call, then return its result to our caller.
        const outcome = try self.doMethodCall(callee_val, this_val, base, nargs, ret_dst);
        if (outcome) |msg| {
            if (self.takeInterruptOutcome()) |oc| return oc;
            if (std.mem.eql(u8, msg, "__js_exception__")) {
                const exc_val = self.last_exception_value;
                const found = try self.throwException(exc_val);
                const exc_msg = try bcv.formatExceptionMessage(self.arena, exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
            } else {
                const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                self.last_exception_value = exc_val;
                const found = try self.throwException(exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            }
        } else {
            const cur = &self.frames.items[self.frames.items.len - 1];
            const result = cur.registers[ret_dst];
            const caller_idx = cur.caller_idx;
            const rd = cur.return_dst;
            _ = self.frames.pop();
            if (caller_idx == null or self.frames.items.len == 0) {
                self.result = result;
                return RunOutcome{ .ok = result };
            }
            if (rd == 0xFF) {
                self.result = result;
                return RunOutcome{ .ok = result };
            }
            self.frames.items[self.frames.items.len - 1].registers[rd] = result;
        }
    }
    return null;
}

pub inline fn opCallSpread(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rcallee = code[frame.pc];
    frame.pc += 1;
    const rthis = code[frame.pc];
    frame.pc += 1;
    const rargs = code[frame.pc];
    frame.pc += 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const callee_v = frame.registers[rcallee];
    const this_v = frame.registers[rthis];
    const args_v = frame.registers[rargs];
    // Flatten the args array into a Value slice.
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
    // Consume the one-shot direct-eval marker exactly as doCall does: `eval(...xs)`
    // is a direct eval only when the callee genuinely *is* %eval%. bcEval reads
    // self.direct_eval_call and runs in the current (caller) frame's scope, which
    // is still on top of the stack across this native invokeCallback.
    const realm_mod = @import("../../runtime/realm.zig");
    const prev_direct_eval = self.direct_eval_call;
    self.direct_eval_call = self.direct_eval_mark and realm_mod.isEvalIntrinsic(callee_v);
    self.direct_eval_mark = false;
    self.param_eval_mark = false;
    self.field_eval_mark = false;
    defer self.direct_eval_call = prev_direct_eval;

    const fp = @import("../../runtime/builtins/function_proto.zig");
    const result = fp.invokeCallback(self.arena, this_v, callee_v, args_list.items) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in spread call")) |oc| return oc;
        return null;
    };
    self.frames.items[self.frames.items.len - 1].registers[rdst] = result;
    return null;
}

pub inline fn opReturn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const result = frame.registers[rsrc];
    const caller_idx = frame.caller_idx;
    const ret_dst = frame.return_dst;
    _ = self.frames.pop();

    if (caller_idx == null or self.frames.items.len == 0) {
        self.result = result;
        return RunOutcome{ .ok = result };
    }
    if (ret_dst == 0xFF) {
        // Sentinel: re-entrant callback result — store in self.result and exit loop.
        self.result = result;
        return RunOutcome{ .ok = result };
    }
    const caller = &self.frames.items[self.frames.items.len - 1];
    caller.registers[ret_dst] = result;
    return null;
}

pub inline fn opReturnUndef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const result = try val_mod.makeUndefined(self.arena);
    const caller_idx = frame.caller_idx;
    const ret_dst = frame.return_dst;
    _ = self.frames.pop();

    if (caller_idx == null or self.frames.items.len == 0) {
        self.result = result;
        return RunOutcome{ .ok = result };
    }
    if (ret_dst == 0xFF) {
        self.result = result;
        return RunOutcome{ .ok = result };
    }
    const caller = &self.frames.items[self.frames.items.len - 1];
    caller.registers[ret_dst] = result;
    return null;
}

pub inline fn opHalt(self: *BcVm, _: *BcCallFrame) !?RunOutcome {
    return RunOutcome{ .ok = self.result };
}

pub inline fn opYield(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const yielded = frame.registers[rsrc];
    // The frame must belong to a generator (compiler only emits
    // YIELD inside generator bodies). Save the suspended frame.
    const state = frame.gen orelse {
        // `yield`/`await` reached a frame with no generator state. The compiler
        // normally emits these only in generator/async bodies, but some
        // desugarings (e.g. `yield` inside a class computed property name) can
        // land here. Throw a SyntaxError instead of dereferencing null (segfault).
        const msg = "yield/await in unsupported context";
        const exc_val = try self.makeErrorObjectBc("SyntaxError", msg);
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        return null;
    };
    state.resume_reg = rsrc;
    state.last_suspend_await = false; // a `yield` suspend
    state.raw_yield = false; // plain yield → consumer gets a wrapped result
    state.at_user_yield = true; // now in "suspendedYield"
    state.frame = frame.*; // pc already advanced past YIELD
    _ = self.frames.pop();
    self.result = yielded;
    self.gen_yielded = true;
    return RunOutcome{ .ok = yielded };
}

/// YIELD_STAR — identical suspend to YIELD, but flags the suspend so the driver
/// surfaces the yielded value to the consumer VERBATIM (no `{value,done}` wrap).
/// Used by `yield*`: the inner iterator's result object passes through unchanged.
pub inline fn opYieldStar(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const yielded = frame.registers[rsrc];
    const state = frame.gen orelse {
        // `yield`/`await` reached a frame with no generator state. The compiler
        // normally emits these only in generator/async bodies, but some
        // desugarings (e.g. `yield` inside a class computed property name) can
        // land here. Throw a SyntaxError instead of dereferencing null (segfault).
        const msg = "yield/await in unsupported context";
        const exc_val = try self.makeErrorObjectBc("SyntaxError", msg);
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        return null;
    };
    state.resume_reg = rsrc;
    state.last_suspend_await = false; // still a `yield` suspend
    state.raw_yield = true; // delegated yield → pass inner result through unwrapped
    state.at_user_yield = true; // now in "suspendedYield"
    state.frame = frame.*; // pc already advanced past YIELD_STAR
    _ = self.frames.pop();
    self.result = yielded;
    self.gen_yielded = true;
    return RunOutcome{ .ok = yielded };
}

/// W2-asyncgen: AWAIT — same suspend mechanics as YIELD, but flags the suspend
/// as an `await` so the async-generator driver resumes internally (rather than
/// producing a result to the consumer). Used only in `async function*` bodies.
pub inline fn opAwait(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const awaited = frame.registers[rsrc];
    const state = frame.gen orelse {
        // `yield`/`await` reached a frame with no generator state. The compiler
        // normally emits these only in generator/async bodies, but some
        // desugarings (e.g. `yield` inside a class computed property name) can
        // land here. Throw a SyntaxError instead of dereferencing null (segfault).
        const msg = "yield/await in unsupported context";
        const exc_val = try self.makeErrorObjectBc("SyntaxError", msg);
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        return null;
    };
    state.resume_reg = rsrc;
    state.last_suspend_await = true; // an `await` suspend
    state.frame = frame.*; // pc already advanced past AWAIT
    _ = self.frames.pop();
    self.result = awaited;
    self.gen_yielded = true;
    return RunOutcome{ .ok = awaited };
}

/// PARAMS_DONE — suspend after a generator's eager parameter initialization.
/// No operand, no consumer-visible value: the generator build driver runs the
/// body to this point at call time and stops here. The first `.next(v)` resumes
/// after this op (v is ignored, per spec, so resume_reg points at a scratch reg).
pub inline fn opParamsDone(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const state = frame.gen orelse {
        // `yield`/`await` reached a frame with no generator state. The compiler
        // normally emits these only in generator/async bodies, but some
        // desugarings (e.g. `yield` inside a class computed property name) can
        // land here. Throw a SyntaxError instead of dereferencing null (segfault).
        const msg = "yield/await in unsupported context";
        const exc_val = try self.makeErrorObjectBc("SyntaxError", msg);
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        return null;
    };
    state.resume_reg = 0; // first .next() value is discarded
    state.last_suspend_await = false;
    state.raw_yield = false;
    state.params_initialized = true;
    state.frame = frame.*; // pc already points past the 1-byte op
    _ = self.frames.pop();
    self.result = try val_mod.makeUndefined(self.arena);
    self.gen_yielded = true;
    return RunOutcome{ .ok = self.result };
}

pub inline fn opDebugger(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    // Phase 8: fire the installed debug hook (no-op if none).
    const debugger_mod = @import("../../runtime/debugger.zig");
    if (debugger_mod.active_hook) |hook| {
        const dbg_pc = frame.pc - 1; // pc of the DEBUGGER op byte
        const off: u32 = if (dbg_pc < frame.func.chunk.lines.len)
            frame.func.chunk.lines[dbg_pc]
        else
            0;
        hook(debugger_mod.active_hook_ctx, .{
            .reason = .debugger_statement,
            .source_name = frame.func.chunk.source_name,
            .source_offset = off,
            .function_name = frame.func.name orelse "<anonymous>",
            .pc = dbg_pc,
        });
    }
    return null;
}
