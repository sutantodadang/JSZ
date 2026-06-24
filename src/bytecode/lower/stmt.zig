// SPDX-License-Identifier: Apache-2.0
//! R3: compileStmt switch arms extracted from `FnCompiler.compileStmt`.
//! Each function takes `self: *FnCompiler` so it can call back into
//! `self.compileStmt`, `self.compileExpr`, and all other methods.
const std = @import("std");
const ast = @import("../../parser/ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;
const VarKind = ast.VarKind;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const Op = @import("../opcodes.zig").Op;
const cmp = @import("../compiler.zig");
const FnCompiler = cmp.FnCompiler;
const LoopCtx = cmp.LoopCtx;
const LabelEntry = cmp.LabelEntry;
const last_label_error_ptr = &cmp.last_label_error;

pub fn lowerExprStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const r = try self.compileExpr(node.data.expr_stmt);
    last_expr_reg.* = r;
    // Completion value (eval/REPL): an expression statement's value
    // becomes the running completion value.
    try self.writeCompletion(r, line);
    // Do NOT free r here; the caller (compileBody) tracks the last one.
}

pub fn lowerVarDecl(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    const vd = node.data.var_decl;
    if (vd.kind == .let or vd.kind == .const_) {
        // Lexical declaration: the binding was already declared at scope entry
        // via HOIST_LEX (in TDZ). Now initialize it at its source position.
        const is_const = vd.kind == .const_;
        if (vd.init) |init_node| {
            const r = try self.compileExpr(init_node);
            try self.emitInitLexical(vd.name, r, line, is_const);
            self.freeReg();
        } else {
            // No initializer: initialize with undefined.
            const r = self.allocReg();
            try self.emitOp(.LOAD_UNDEF, line);
            try self.emitU8(r);
            try self.emitInitLexical(vd.name, r, line, is_const);
            self.freeReg();
        }
    } else {
        // var declaration: use DEFINE_GLOBAL (define-or-assign).
        if (vd.init) |init_node| {
            const r = try self.compileExpr(init_node);
            // Phase 4d: var declarations always define (not assign) — use DEFINE_GLOBAL
            // so strict-mode functions don't throw ReferenceError for var bindings.
            try self.emitDefine(vd.name, r, line);
            self.freeReg();
        } else if (vd.kind != .var_) {
            // Phase 7 baseline: emit explicit undefined initialization for let.
            // (TDZ for bc path will be added in a dedicated lexical-scope bytecode pass.)
            const r = self.allocReg();
            try self.emitOp(.LOAD_UNDEF, line);
            try self.emitU8(r);
            try self.emitDefine(vd.name, r, line);
            self.freeReg();
        }
    }
}

pub fn lowerBlockStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    _ = line;
    for (node.data.block_stmt.body) |child| {
        try self.compileStmt(child, last_expr_reg);
    }
}

pub fn lowerFunctionDecl(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    // Compile inner function, store into local slot.
    const fd = node.data.function_decl;
    const child_fn = try cmp.compileFunctionStrict(
        self.arena,
        fd.name,
        fd.params,
        fd.body,
        null,
        fd.is_strict,
        fd.is_generator,
        fd.is_async,
        false, // function body: no implicit last-expr return
        false, // function declarations are never arrows
        fd.rest_param,
    );
    const child_idx: u16 = @intCast(self.child_functions.items.len);
    try self.child_functions.append(self.arena, child_fn);

    const r = self.allocReg();
    try self.emitOp(.NEW_CLOSURE, line);
    try self.emitU8(r);
    try self.emitU16(child_idx);
    // Phase 4d: function declarations are var-like bindings; use DEFINE_GLOBAL.
    try self.emitDefine(fd.name, r, line);
    self.freeReg();
}

pub fn lowerIfStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const is = node.data.if_stmt;
    const rcond = try self.compileExpr(is.test_);
    self.freeReg();

    // Completion value: an `if` whose taken branch produces no value
    // (or whose condition is false with no `else`) completes with
    // `undefined` — the UpdateEmpty base. Reset before dispatch; a
    // value-producing branch overwrites it.
    try self.resetCompletion(line);

    // Save sp so both branches start from the same register level.
    const saved_sp = self.sp;

    try self.emitOp(.JMP_IF_FALSE, line);
    try self.emitU8(rcond);
    const patch_else = self.currentOffset();
    try self.emitI16(0);

    try self.compileStmt(is.consequent, last_expr_reg);
    const then_result = last_expr_reg.*;

    if (is.alternate) |alt| {
        // Reset sp to same level for else branch so it uses same register.
        self.sp = saved_sp;

        try self.emitOp(.JMP, line);
        const patch_end = self.currentOffset();
        try self.emitI16(0);

        const else_offset = self.currentOffset();
        self.patchJump(patch_else, else_offset);

        last_expr_reg.* = null;
        try self.compileStmt(alt, last_expr_reg);
        const else_result = last_expr_reg.*;

        // Ensure both results use the same register.
        if (then_result != null and else_result != null and then_result.? != else_result.?) {
            // Move else result to then result register.
            try self.emitOp(.MOVE, line);
            try self.emitU8(then_result.?);
            try self.emitU8(else_result.?);
            last_expr_reg.* = then_result;
            self.sp = then_result.? + 1;
        } else if (then_result != null) {
            last_expr_reg.* = then_result;
        }

        const end_offset = self.currentOffset();
        self.patchJump(patch_end, end_offset);
    } else {
        const end_offset = self.currentOffset();
        self.patchJump(patch_else, end_offset);
        last_expr_reg.* = then_result;
    }
}

pub fn lowerWhileStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const ws = node.data.while_stmt;
    const loop_lbl = self.pending_label;
    self.pending_label = null;
    // Completion value: a loop's value starts fresh at `undefined`.
    try self.resetCompletion(line);
    const prev_reg: ?u8 = if (self.completion_reg != null) self.allocReg() else null;
    const loop_start = self.currentOffset();

    const rcond = try self.compileExpr(ws.test_);
    self.freeReg();

    try self.emitOp(.JMP_IF_FALSE, line);
    try self.emitU8(rcond);
    const patch_exit = self.currentOffset();
    try self.emitI16(0);

    // Save the completion value at the start of this iteration so a
    // `continue` (an empty completion) can revert to it.
    try self.saveLoopPrev(prev_reg, line);
    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .prev_reg = prev_reg });
    try self.compileStmt(ws.body, last_expr_reg);

    // Jump back to loop start (continue lands here too: re-eval cond).
    try self.emitOp(.JMP, line);
    const back_offset = self.currentOffset();
    try self.emitI16(0);
    self.patchJump(back_offset, loop_start);

    const exit_offset = self.currentOffset();
    self.patchJump(patch_exit, exit_offset);
    self.resolveLoop(loop_start, exit_offset);
}

pub fn lowerDoWhileStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const dw = node.data.do_while_stmt;
    const loop_lbl = self.pending_label;
    self.pending_label = null;
    try self.resetCompletion(line);
    const prev_reg: ?u8 = if (self.completion_reg != null) self.allocReg() else null;
    const loop_start = self.currentOffset();

    try self.saveLoopPrev(prev_reg, line);
    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .prev_reg = prev_reg });
    try self.compileStmt(dw.body, last_expr_reg);

    // continue in a do-while jumps to the condition test.
    const cond_offset = self.currentOffset();
    const rcond = try self.compileExpr(dw.test_);
    self.freeReg();

    try self.emitOp(.JMP_IF_TRUE, line);
    try self.emitU8(rcond);
    const back_offset = self.currentOffset();
    try self.emitI16(0);
    self.patchJump(back_offset, loop_start);

    const exit_offset = self.currentOffset();
    self.resolveLoop(cond_offset, exit_offset);
}

pub fn lowerForStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const fs = node.data.for_stmt;
    const loop_lbl = self.pending_label;
    self.pending_label = null;
    if (fs.init) |init_node| {
        var dummy: ?u8 = null;
        try self.compileStmt(init_node, &dummy);
    }

    try self.resetCompletion(line);
    const prev_reg: ?u8 = if (self.completion_reg != null) self.allocReg() else null;
    const loop_start = self.currentOffset();
    var patch_exit: ?usize = null;

    if (fs.test_) |test_node| {
        const rcond = try self.compileExpr(test_node);
        self.freeReg();
        try self.emitOp(.JMP_IF_FALSE, line);
        try self.emitU8(rcond);
        patch_exit = self.currentOffset();
        try self.emitI16(0);
    }

    try self.saveLoopPrev(prev_reg, line);
    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .prev_reg = prev_reg });
    try self.compileStmt(fs.body, last_expr_reg);

    // continue in a for-loop runs the update expression, then re-tests.
    const update_offset = self.currentOffset();
    if (fs.update) |update_node| {
        const r = try self.compileExpr(update_node);
        self.freeReg();
        _ = r;
    }

    // Jump back.
    try self.emitOp(.JMP, line);
    const back_offset = self.currentOffset();
    try self.emitI16(0);
    self.patchJump(back_offset, loop_start);

    const exit_offset = self.currentOffset();
    if (patch_exit) |pe| {
        self.patchJump(pe, exit_offset);
    }
    self.resolveLoop(update_offset, exit_offset);
}

pub fn lowerReturnStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    if (node.data.return_stmt) |rv_node| {
        // Phase 8 / W7: proper tail call. `return f(args);` and
        // `return obj.m(args);` are tail calls when in strict mode and
        // not inside a try/finally region. compileCall emits TAIL_CALL
        // (direct) or TAIL_METHOD_CALL (member); the opcode performs the
        // return itself, so no RETURN is emitted here.
        if (self.is_strict and self.try_depth == 0 and
            rv_node.kind == .call_expr)
        {
            _ = try self.compileCall(rv_node.data.call_expr, rv_node.start, true);
        } else {
            const r = try self.compileExpr(rv_node);
            try self.emitOp(.RETURN, line);
            try self.emitU8(r);
            self.freeReg();
        }
    } else {
        try self.emitOp(.RETURN_UNDEF, line);
    }
}

pub fn lowerThrowStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    const rv = try self.compileExpr(node.data.throw_stmt);
    try self.emitOp(.THROW, line);
    try self.emitU8(rv);
    self.freeReg();
}

pub fn lowerTryStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const ts = node.data.try_stmt;
    const saved_sp = self.sp;
    // Phase 8: returns anywhere inside try/catch/finally are not in
    // tail position (a pending finally must run after the callee).
    self.try_depth += 1;
    defer self.try_depth -= 1;

    // Allocate a register to receive the caught exception value.
    const rexc: u8 = if (ts.handler != null) blk: {
        const r = self.allocReg();
        self.freeReg(); // don't actually consume it yet — PUSH_TRY reserves it
        break :blk r;
    } else 0xFF; // 0xFF = no catch

    // Emit PUSH_TRY with placeholder handler offset.
    try self.emitOp(.PUSH_TRY, line);
    try self.emitU8(rexc);
    const push_try_patch = self.currentOffset();
    try self.emitI16(0); // placeholder: offset to catch/finally handler

    // Compile try block body.
    self.sp = saved_sp;
    try self.compileStmt(ts.block, last_expr_reg);
    self.sp = saved_sp;

    // Normal exit: POP_TRY, then JMP to finally (or end).
    try self.emitOp(.POP_TRY, line);
    try self.emitOp(.JMP, line);
    const jmp_to_finally_patch = self.currentOffset();
    try self.emitI16(0); // placeholder: jump to finally

    // --- Catch handler starts here ---
    const catch_offset = self.currentOffset();
    self.patchJump(push_try_patch, catch_offset);

    if (ts.handler) |handler| {
        // Bind catch param: DEFINE_GLOBAL "name", Rexc (always defines, never strict-throws).
        // An empty param_name is an optional catch binding (`catch { ... }`) — no binding.
        if (handler.param_name.len > 0)
            try self.emitDefine(handler.param_name, rexc, line);
        // Compile catch body.
        self.sp = saved_sp;
        try self.compileStmt(handler.body, last_expr_reg);
        self.sp = saved_sp;
    }

    // --- Finally block (or end) ---
    const finally_offset = self.currentOffset();
    self.patchJump(jmp_to_finally_patch, finally_offset);

    if (ts.finalizer) |fin| {
        try self.compileStmt(fin, last_expr_reg);
        self.sp = saved_sp;
    }
}

pub fn lowerBreakStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    const label = node.data.break_stmt;
    try self.emitOp(.JMP, line);
    const patch = self.currentOffset();
    try self.emitI16(0);
    if (label) |lname| {
        // Prefer a labeled loop (so `break L` exits the loop); fall back
        // to a labeled non-loop statement block.
        var li = self.loop_stack.items.len;
        while (li > 0) {
            li -= 1;
            if (self.loop_stack.items[li].label) |l| {
                if (std.mem.eql(u8, l, lname)) {
                    try self.loop_stack.items[li].break_patches.append(self.arena, patch);
                    return;
                }
            }
        }
        var i = self.label_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.label_stack.items[i].name, lname)) {
                try self.label_stack.items[i].break_patches.append(self.arena, patch);
                return;
            }
        }
        // Label not found — undefined label is an early SyntaxError.
        if (last_label_error_ptr.* == null)
            last_label_error_ptr.* = std.fmt.allocPrint(self.arena, "undefined label '{s}'", .{lname}) catch "undefined label";
    } else if (self.loop_stack.items.len > 0) {
        try self.loop_stack.items[self.loop_stack.items.len - 1].break_patches.append(self.arena, patch);
    }
}

pub fn lowerContinueStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    const label = node.data.continue_stmt;
    // Resolve the target loop (labeled or innermost) first so we can
    // revert the completion register before jumping.
    var target_idx: ?usize = null;
    if (label) |lname| {
        var li = self.loop_stack.items.len;
        while (li > 0) {
            li -= 1;
            if (self.loop_stack.items[li].label) |l| {
                if (std.mem.eql(u8, l, lname)) {
                    target_idx = li;
                    break;
                }
            }
        }
    } else if (self.loop_stack.items.len > 0) {
        target_idx = self.loop_stack.items.len - 1;
    }
    // Completion value: `continue` yields an empty completion, so the
    // loop's value reverts to its value at this iteration's start.
    if (target_idx) |ti| {
        if (self.loop_stack.items[ti].prev_reg) |pr| {
            if (self.completion_reg) |cr| {
                try self.emitOp(.MOVE, line);
                try self.emitU8(cr);
                try self.emitU8(pr);
            }
        }
    }
    try self.emitOp(.JMP, line);
    const patch = self.currentOffset();
    try self.emitI16(0);
    if (target_idx) |ti| {
        try self.loop_stack.items[ti].continue_patches.append(self.arena, patch);
    } else if (label) |lname| {
        // Labeled continue with no matching loop — early SyntaxError.
        if (last_label_error_ptr.* == null)
            last_label_error_ptr.* = std.fmt.allocPrint(self.arena, "undefined label '{s}'", .{lname}) catch "undefined label";
    }
}

pub fn lowerForInStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    // W2: for-of (iterate_values) uses the iterator protocol via the
    // __getIterator__/__iterStep__ runtime helpers (generators, arrays,
    // strings, Map/Set). for-in (below) keeps key-enumeration.
    if (node.data.for_in_stmt.iterate_values) {
        const fo = node.data.for_in_stmt;
        // A directly-enclosing label (consumed here) lets `break L`/`continue L`
        // target this for-of loop.
        const loop_lbl = self.pending_label;
        self.pending_label = null;
        const base_sp = self.sp;
        const riter = self.allocReg();
        {
            const b = self.allocReg();
            self.sp = b;
            const gi = try self.builder.addConstant(try val_mod.makeString(self.arena, "__getIterator__"));
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(gi));
            self.sp = b + 1;
            _ = try self.compileExpr(fo.right); // arg lands at b+1
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(1);
            try self.emitU8(riter);
            self.sp = riter + 1;
        }
        const rstep = self.allocReg();
        // Completion value: a loop's value starts fresh at `undefined`; prev_reg
        // holds the value at the start of each iteration so a `continue` (an empty
        // completion) reverts to it. No-op outside implicit-return compilation.
        try self.resetCompletion(line);
        const prev_reg: ?u8 = if (self.completion_reg != null) self.allocReg() else null;
        // Permanent registers (riter, rstep, prev_reg) sit below iter_sp; the
        // per-iteration temporaries above it are reclaimed each pass.
        const iter_sp = self.sp;
        const loop_start = self.currentOffset();
        {
            const b = self.allocReg();
            const si = try self.builder.addConstant(try val_mod.makeString(self.arena, "__iterStep__"));
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(si));
            const barg = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(barg);
            try self.emitU8(riter);
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(1);
            try self.emitU8(rstep);
            self.sp = iter_sp;
        }
        // if (rstep.done) exit
        const rdone = self.allocReg();
        const di = try self.builder.addConstant(try val_mod.makeString(self.arena, "done"));
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rdone);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(di));
        try self.emitOp(.JMP_IF_TRUE, line);
        try self.emitU8(rdone);
        const patch_exit = self.currentOffset();
        try self.emitI16(0);
        self.sp = iter_sp;
        // loopvar = rstep.value
        const rval = self.allocReg();
        const vi = try self.builder.addConstant(try val_mod.makeString(self.arena, "value"));
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rval);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(vi));
        const loop_decl_kind: ?VarKind = switch (fo.left.kind) {
            .var_decl => fo.left.data.var_decl.kind,
            else => null,
        };
        const loop_name: ?[]const u8 = switch (fo.left.kind) {
            .var_decl => if (fo.left.data.var_decl.name.len > 0) fo.left.data.var_decl.name else null,
            .identifier => fo.left.data.identifier,
            else => null,
        };
        if (loop_name) |nm| {
            const ni = try self.builder.addConstant(try val_mod.makeString(self.arena, nm));
            if (loop_decl_kind != null and (loop_decl_kind.? == .let or loop_decl_kind.? == .const_)) {
                try self.emitInitLexical(nm, rval, line, loop_decl_kind.? == .const_);
            } else {
                try self.emitOp(.SET_GLOBAL, line);
                try self.emitU16(@intCast(ni));
                try self.emitU8(rval);
            }
        }
        self.sp = iter_sp;
        // Register the loop so `break`/`continue` (labeled or innermost) resolve to
        // it; `continue` jumps to loop_start, which advances the iterator (re-calls
        // __iterStep__) before the next done-check.
        try self.saveLoopPrev(prev_reg, line);
        try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .prev_reg = prev_reg });
        try self.compileStmt(fo.body, last_expr_reg);
        try self.emitOp(.JMP, line);
        const back = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back, loop_start);
        const exit_offset = self.currentOffset();
        self.patchJump(patch_exit, exit_offset);
        self.resolveLoop(loop_start, exit_offset);
        self.sp = base_sp;
        return;
    }
    // Phase 4d: for (var k in obj) { body }
    // Strategy:
    //   rkeys = GET_KEYS(robj)
    //   ri = 0
    //   rlen = keys.length
    //   loop:
    //     if ri >= rlen: exit
    //     rkey = keys[ri]
    //     assign loop var = rkey
    //     body
    //     ri++
    //     jmp loop
    const fi = node.data.for_in_stmt;
    // Save sp; allocate rkeys, ri, rlen as a contiguous block.
    const base_sp = self.sp;
    // Evaluate object into a temp register.
    const robj_tmp = try self.compileExpr(fi.right);
    // Allocate permanent registers: rkeys, ri, rlen.
    const rkeys = self.allocReg(); // sp = base_sp+2 now (robj_tmp=base_sp, rkeys=base_sp+1)
    try self.emitOp(.GET_KEYS, line);
    try self.emitU8(rkeys);
    try self.emitU8(robj_tmp);
    self.freeReg(); // free robj_tmp: sp back to base_sp+1 (rkeys = base_sp)

    // Wait — freeReg pops the TOP which is rkeys now. Need different approach.
    // Use robj_tmp directly as rkeys by overwriting it.
    // Keep rkeys (base_sp+1) live: set sp = base_sp+2 so ri/rlen allocate above rkeys.
    // robj_tmp (base_sp) is effectively dead but its register is below rkeys.
    self.sp = base_sp + 2; // rkeys = base_sp+1 is live

    const ri = self.allocReg(); // ri = base_sp+2
    try self.emitOp(.LOAD_K, line);
    try self.emitU8(ri);
    const zero_idx = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 0.0));
    try self.emitI16(@intCast(zero_idx));

    const rlen = self.allocReg(); // rlen = base_sp+3
    // rlen = keys.length via GET_PROP
    const len_idx = try self.builder.addConstant(try val_mod.makeString(self.arena, "length"));
    try self.emitOp(.GET_PROP, line);
    try self.emitU8(rlen);
    try self.emitU8(rkeys);
    try self.emitU8(@intCast(len_idx & 0xFF));
    try self.emitU8(@intCast((len_idx >> 8) & 0xFF));

    const loop_start = self.currentOffset();

    // if ri >= rlen: exit
    try self.emitOp(.JGE, line);
    try self.emitU8(ri);
    try self.emitU8(rlen);
    const patch_exit = self.currentOffset();
    try self.emitI16(0);

    // rkey = keys[ri]
    const rkey = self.allocReg();
    try self.emitOp(.GET_PROP_DYN, line);
    try self.emitU8(rkey);
    try self.emitU8(rkeys);
    try self.emitU8(ri);

    // assign loop variable = rkey
    // fi.left is either var_decl (var k) or an identifier expr
    switch (fi.left.kind) {
        .var_decl => {
            const vd = fi.left.data.var_decl;
            if (vd.name.len > 0) {
                const name_idx = try self.builder.addConstant(try val_mod.makeString(self.arena, vd.name));
                if (vd.kind == .let or vd.kind == .const_) {
                    try self.emitInitLexical(vd.name, rkey, line, vd.kind == .const_);
                } else {
                    try self.emitOp(.SET_GLOBAL, line);
                    try self.emitU8(@intCast(name_idx & 0xFF));
                    try self.emitU8(@intCast((name_idx >> 8) & 0xFF));
                    try self.emitU8(rkey);
                }
            }
        },
        .identifier => {
            const name = fi.left.data.identifier;
            const name_idx = try self.builder.addConstant(try val_mod.makeString(self.arena, name));
            try self.emitOp(.SET_GLOBAL, line);
            try self.emitU8(@intCast(name_idx & 0xFF));
            try self.emitU8(@intCast((name_idx >> 8) & 0xFF));
            try self.emitU8(rkey);
        },
        else => {},
    }
    self.freeReg(); // free rkey

    // body
    try self.compileStmt(fi.body, last_expr_reg);

    // ri++
    const rone = self.allocReg();
    try self.emitOp(.LOAD_K, line);
    try self.emitU8(rone);
    const one_idx = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 1.0));
    try self.emitI16(@intCast(one_idx));
    try self.emitOp(.ADD, line);
    try self.emitU8(ri);
    try self.emitU8(ri);
    try self.emitU8(rone);
    self.freeReg(); // free rone

    // jump back
    try self.emitOp(.JMP, line);
    const back_offset = self.currentOffset();
    try self.emitI16(0);
    self.patchJump(back_offset, loop_start);

    // patch exit
    self.patchJump(patch_exit, self.currentOffset());

    // restore sp to base_sp (free rlen, ri, rkeys, robj_tmp)
    self.sp = base_sp;
}

pub fn lowerSwitchStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    // Phase 4d: switch(disc) { case X: ... default: ... }
    // Compile as chain of strict-equality checks + JMPs.
    const sw = node.data.switch_stmt;
    const rdisc = try self.compileExpr(sw.discriminant);

    // We'll collect patch offsets for end-of-switch breaks.
    // Each case that matches jumps to its body.
    // At end of each body we fall through (or break jumps to end).
    // Approach: compile all test blocks first as a dispatch chain,
    // then bodies inline. Simpler: compile sequentially with fall-through.

    // Simple sequential approach:
    // For each non-default case:
    //   rv = strict_eq(rdisc, case_val)
    //   if rv: jmp to case_body
    // After tests: jmp to default or end
    // case_body_N: <stmts> (fall-through to next)
    // end:

    var case_body_patches = try self.arena.alloc(usize, sw.cases.len);
    var default_idx: ?usize = null;

    // Emit test chain.
    for (sw.cases, 0..) |case, ci| {
        if (case.test_ == null) {
            default_idx = ci;
            case_body_patches[ci] = 0; // placeholder
            continue;
        }
        const rcv = try self.compileExpr(case.test_.?);
        try self.emitOp(.JSEQ, line);
        try self.emitU8(rdisc);
        try self.emitU8(rcv);
        self.freeReg(); // free rcv
        case_body_patches[ci] = self.currentOffset();
        try self.emitI16(0);
    }
    self.freeReg(); // free rdisc

    // JMP to default or end.
    var patch_default_or_end: ?usize = null;
    if (default_idx != null) {
        try self.emitOp(.JMP, line);
        patch_default_or_end = self.currentOffset();
        try self.emitI16(0);
    } else {
        try self.emitOp(.JMP, line);
        patch_default_or_end = self.currentOffset();
        try self.emitI16(0);
    }

    // Emit case bodies. Patch the jump-to-body addresses.
    var break_patches = std.ArrayListUnmanaged(usize).empty;
    for (sw.cases, 0..) |case, ci| {
        const body_start = self.currentOffset();
        if (case.test_ != null) {
            self.patchJump(case_body_patches[ci], body_start);
        } else {
            // default — patch the default jump.
            if (patch_default_or_end) |pd| {
                self.patchJump(pd, body_start);
                patch_default_or_end = null;
            }
        }
        for (case.body) |stmt| {
            if (stmt.kind == .break_stmt) {
                try self.emitOp(.JMP, line);
                try break_patches.append(self.arena, self.currentOffset());
                try self.emitI16(0);
            } else {
                try self.compileStmt(stmt, last_expr_reg);
            }
        }
    }

    const end_offset = self.currentOffset();

    // Patch default-or-end jump if default was not found.
    if (patch_default_or_end) |pd| {
        self.patchJump(pd, end_offset);
    }

    // Patch all break jumps.
    for (break_patches.items) |bp| {
        self.patchJump(bp, end_offset);
    }
}

pub fn lowerLabeledStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    _ = line;
    // Phase 4d: push label, compile body, patch breaks to exit.
    // Phase 13: also expose the label to a directly-enclosed loop via
    // `pending_label` so `break L`/`continue L` target the loop.
    const ls = node.data.labeled_stmt;
    // Only hand the label to a DIRECTLY-enclosed loop (so `break L`/
    // `continue L` target the loop). When the body is a block or other
    // statement, the label belongs to that statement and break is
    // resolved via `label_stack` — otherwise the label would leak into
    // a nested loop and `break L` would exit the loop instead of the
    // block (e.g. `L: { while(true){break L} unreachable; }`).
    self.pending_label = switch (ls.body.kind) {
        .while_stmt, .do_while_stmt, .for_stmt, .for_in_stmt => ls.name,
        else => null,
    };
    try self.label_stack.append(self.arena, LabelEntry{
        .name = ls.name,
        .loop_start = self.currentOffset(),
    });
    try self.compileStmt(ls.body, last_expr_reg);
    self.pending_label = null;
    const exit = self.currentOffset();
    // Patch all break patches for this label.
    var entry = self.label_stack.pop().?;
    for (entry.break_patches.items) |bp| {
        self.patchJump(bp, exit);
    }
    entry.break_patches.deinit(self.arena);
    entry.continue_patches.deinit(self.arena);
}

pub fn lowerEmptyStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = self;
    _ = node;
    _ = last_expr_reg;
}

pub fn lowerDebuggerStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    // Phase 8: emit a DEBUGGER opcode so the VM can fire a debug
    // hook (breakpoint-style pause). No-op when no hook installed.
    try self.emitOp(.DEBUGGER, line);
}
