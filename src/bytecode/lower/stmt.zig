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
            // NamedEvaluation: `let/const x = function(){}` — inject binding name as hint.
            if (init_node.kind == .function_expr) self.name_hint = vd.name;
            const r = try self.compileExpr(init_node);
            self.name_hint = null; // defensive clear (no-op if consumed inside)
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
            // NamedEvaluation: `var x = function(){}` — inject binding name as hint.
            if (init_node.kind == .function_expr) self.name_hint = vd.name;
            const r = try self.compileExpr(init_node);
            self.name_hint = null; // defensive clear (no-op if consumed inside)
            if (self.with_depth > 0) {
                // Inside a `with`, the `var x = init` initializer is an ordinary
                // assignment whose ResolveBinding("x") crosses the with-object
                // environment: if the with-object HasProperty "x", PutValue writes
                // there, not to the hoisted var binding. SET_GLOBAL consults the
                // with-stack; the var name was already hoisted at scope entry, so
                // env.assign finds the binding when no with-object shadows it.
                try self.emitStore(vd.name, r, line);
            } else {
                // Phase 4d: var declarations always define (not assign) — use
                // DEFINE_GLOBAL so strict-mode functions don't throw ReferenceError
                // for var bindings.
                try self.emitDefine(vd.name, r, line);
            }
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
    // A real `{ ... }` block forms its own lexical scope. Synthetic
    // statement-sequence blocks (class desugaring, multi-declarator lowering)
    // are transparent: their bindings belong to the enclosing scope, so they
    // emit no ENTER_SCOPE/EXIT_SCOPE. For a real block, collect its own
    // `let`/`const` names; if any exist, push a child env, hoist them (TDZ),
    // then pop the scope on exit.
    var lex_names = std.ArrayList([]const u8){};
    // Direct-child function declarations are block-scoped too
    // (BlockDeclarationInstantiation): they are instantiated at block entry, so
    // a forward reference inside the block resolves, and their binding lives in
    // the block's own record rather than shadowing an outer `let`/parameter.
    var fn_decls = std.ArrayList(*Node){};
    if (node.data.block_stmt.lexical_scope) {
        for (node.data.block_stmt.body) |child| {
            try self.collectLexicalNames(child, &lex_names);
            if (child.kind == .function_decl) try fn_decls.append(self.arena, child);
        }
    }
    const has_scope = lex_names.items.len > 0 or fn_decls.items.len > 0;
    if (has_scope) {
        try self.emitOp(.ENTER_SCOPE, line);
        self.block_scope_depth += 1;
        for (lex_names.items) |nm| try self.emitHoistLexical(nm, line);
        var fd_reg: ?u8 = null;
        for (fn_decls.items) |fd| try lowerBlockFunctionDecl(self, fd, &fd_reg);
    }
    // Reclaim registers between statements — same discipline as compileBody so
    // that deeply-nested or repeated blocks do not exhaust the u8 register space.
    // We only free slots allocated *inside* this block (>= entry_sp) to avoid
    // clobbering live values from the enclosing scope.
    const entry_sp = self.sp;
    var prev_reg: ?u8 = null;
    for (node.data.block_stmt.body) |child| {
        if (prev_reg) |pr| {
            if (pr >= entry_sp) self.sp = pr;
            prev_reg = null;
        }
        // Already instantiated at block entry above. Reaching the declaration
        // is where Annex B.3.3 copies its value out to the var scope (the spec
        // replaces FunctionDeclaration Evaluation with exactly that step).
        if (has_scope and child.kind == .function_decl) {
            try self.emitAnnexBSync(child, child.start);
            continue;
        }
        var child_reg: ?u8 = null;
        try self.compileStmt(child, &child_reg);
        prev_reg = child_reg;
    }
    last_expr_reg.* = prev_reg;
    if (has_scope) {
        try self.emitOp(.EXIT_SCOPE, line);
        self.block_scope_depth -= 1;
    }
}

/// A function declaration reaching the ordinary statement path is nested in a
/// construct that is not a statement list of its own — an `if` clause, a loop
/// body, a labelled statement. Annex B.3.4 treats such a declaration as if it
/// were wrapped in a block, so give it a one-statement scope of its own and run
/// the same B.3.3 var-scope sync a block-level declaration gets.
pub fn lowerNestedFunctionDecl(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    try self.emitOp(.ENTER_SCOPE, line);
    self.block_scope_depth += 1;
    var fd_reg: ?u8 = null;
    try lowerBlockFunctionDecl(self, node, &fd_reg);
    try self.emitAnnexBSync(node, line);
    try self.emitOp(.EXIT_SCOPE, line);
    self.block_scope_depth -= 1;
    last_expr_reg.* = null;
}

/// Instantiate a block-level function declaration: create the closure and bind
/// it in the *current* environment record (never an enclosing one).
pub fn lowerBlockFunctionDecl(self: *FnCompiler, node: *Node, fd_reg: *?u8) error{OutOfMemory}!void {
    try lowerFunctionDeclInto(self, node, fd_reg, true);
}

pub fn lowerFunctionDecl(self: *FnCompiler, node: *Node, fd_reg: *?u8) error{OutOfMemory}!void {
    try lowerFunctionDeclInto(self, node, fd_reg, false);
}

fn lowerFunctionDeclInto(self: *FnCompiler, node: *Node, last_expr_reg: *?u8, local: bool) error{OutOfMemory}!void {
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
        fd.is_strict or self.is_strict, // strictness is inherited by nested declarations
        fd.is_generator,
        fd.is_async,
        false, // function body: no implicit last-expr return
        false, // function declarations are never arrows
        fd.rest_param,
        fd.param_defaults,
        fd.source_text,
    );
    const child_idx: u16 = @intCast(self.child_functions.items.len);
    try self.child_functions.append(self.arena, child_fn);

    const r = self.allocReg();
    try self.emitOp(.NEW_CLOSURE, line);
    try self.emitU8(r);
    try self.emitU16(child_idx);
    // Phase 4d: function declarations are var-like bindings; use DEFINE_GLOBAL.
    if (local) try self.emitDefineLocal(fd.name, r, line) else try self.emitDefine(fd.name, r, line);
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
    const loop_start = self.currentOffset();

    const rcond = try self.compileExpr(ws.test_);
    self.freeReg();

    try self.emitOp(.JMP_IF_FALSE, line);
    try self.emitU8(rcond);
    const patch_exit = self.currentOffset();
    try self.emitI16(0);

    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .scope_depth = self.block_scope_depth, .finally_depth = self.finally_stack.items.len, .continue_finally_depth = self.finally_stack.items.len });
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
    const loop_start = self.currentOffset();

    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .scope_depth = self.block_scope_depth, .finally_depth = self.finally_stack.items.len, .continue_finally_depth = self.finally_stack.items.len });
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

    // A `let`/`const` in the C-style header (`for (let i = 0; ...)`) is scoped
    // to the loop, not the enclosing block. Wrap init + test + body + update in
    // a dedicated scope so the bindings shadow same-named outer bindings without
    // leaking, and so a read in the enclosing scope before the loop does not
    // resolve to the loop binding in TDZ. The EXIT_SCOPE is emitted AFTER the
    // break/normal-exit target, so break and continue both unwind to the same
    // (inner) depth and the single EXIT_SCOPE pops the loop scope on every exit.
    var for_lex = std.ArrayList([]const u8){};
    if (fs.init) |init_node| try self.collectLexicalNames(init_node, &for_lex);
    const has_for_scope = for_lex.items.len > 0;
    if (has_for_scope) {
        try self.emitOp(.ENTER_SCOPE, line);
        self.block_scope_depth += 1;
        for (for_lex.items) |nm| try self.emitHoistLexical(nm, line);
    }

    if (fs.init) |init_node| {
        var dummy: ?u8 = null;
        try self.compileStmt(init_node, &dummy);
    }

    try self.resetCompletion(line);
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

    try self.loop_stack.append(self.arena, LoopCtx{ .label = loop_lbl, .scope_depth = self.block_scope_depth, .finally_depth = self.finally_stack.items.len, .continue_finally_depth = self.finally_stack.items.len });
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

    if (has_for_scope) {
        try self.emitOp(.EXIT_SCOPE, line);
        self.block_scope_depth -= 1;
    }
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
            // Run any enclosing finally blocks before returning (the value in `r`
            // is pinned across them). No-op when not inside a try/finally.
            try runPendingFinally(self, r, 0, line);
            try self.emitOp(.RETURN, line);
            try self.emitU8(r);
            self.freeReg();
        }
    } else {
        try runPendingFinally(self, null, 0, line);
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

/// CatchClauseEvaluation (§14.15.3): the catch parameter lives in its own
/// declarative environment record, distinct from both the enclosing scope and
/// the catch Block's own record. Without it `catch (e)` would leak `e` outward
/// and, worse, overwrite a same-named `var` in the enclosing function. Returns
/// whether a scope was pushed (an optional catch binding pushes none).
fn enterCatchScope(self: *FnCompiler, param_name: []const u8, rexc: u8, line: u32) error{OutOfMemory}!bool {
    if (param_name.len == 0) return false;
    try self.emitOp(.ENTER_SCOPE, line);
    self.block_scope_depth += 1;
    // DEFINE_LOCAL, not DEFINE_GLOBAL: the binding belongs to the record just
    // pushed, so it must not walk out and assign an outer binding of that name.
    try self.emitDefineLocal(param_name, rexc, line);
    return true;
}

fn exitCatchScope(self: *FnCompiler, scoped: bool, line: u32) error{OutOfMemory}!void {
    if (!scoped) return;
    try self.emitOp(.EXIT_SCOPE, line);
    self.block_scope_depth -= 1;
}

pub fn lowerTryStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const ts = node.data.try_stmt;
    const saved_sp = self.sp;
    // Completion value: every TryStatement production ends in
    // UpdateEmpty(<result>, undefined), so an empty try/catch/finally completes
    // with `undefined` rather than the enclosing script's running value.
    try self.resetCompletion(line);
    // Phase 8: returns anywhere inside try/catch/finally are not in
    // tail position (a pending finally must run after the callee).
    self.try_depth += 1;
    defer self.try_depth -= 1;

    // --- try/catch with NO finally: a single exception handler. ---
    if (ts.finalizer == null) {
        const rexc: u8 = if (ts.handler != null) blk: {
            const r = self.allocReg();
            self.freeReg(); // PUSH_TRY reserves it
            break :blk r;
        } else 0xFF;
        try self.emitOp(.PUSH_TRY, line);
        try self.emitU8(rexc);
        const push_try_patch = self.currentOffset();
        try self.emitI16(0);
        // A `return`/`break`/`continue` inside the try body must POP_TRY this
        // handler on the way out (null = no finalizer to run). The catch body is
        // not protected by it, so it is popped before the catch compiles.
        try self.finally_stack.append(self.arena, .{ .finalizer = null });
        self.sp = saved_sp;
        try self.compileStmt(ts.block, last_expr_reg);
        self.sp = saved_sp;
        _ = self.finally_stack.pop();
        try self.emitOp(.POP_TRY, line);
        try self.emitOp(.JMP, line);
        const jmp_end = self.currentOffset();
        try self.emitI16(0);
        const catch_offset = self.currentOffset();
        self.patchJump(push_try_patch, catch_offset);
        if (ts.handler) |handler| {
            // A return-completion (Generator.return) is not observable by catch:
            // re-raise it so it propagates (and is converted to a return at the
            // generator boundary).
            try self.emitOp(.JMP_IF_RET_COMPL, line);
            try self.emitU8(rexc);
            const rethrow_patch = self.currentOffset();
            try self.emitI16(0);
            const scoped = try enterCatchScope(self, handler.param_name, rexc, line);
            self.sp = saved_sp;
            try self.compileStmt(handler.body, last_expr_reg);
            self.sp = saved_sp;
            try exitCatchScope(self, scoped, line);
            try self.emitOp(.JMP, line);
            const jmp_over_rethrow = self.currentOffset();
            try self.emitI16(0);
            self.patchJump(rethrow_patch, self.currentOffset());
            try self.emitOp(.THROW, line);
            try self.emitU8(rexc);
            self.patchJump(jmp_over_rethrow, self.currentOffset());
        }
        self.patchJump(jmp_end, self.currentOffset());
        return;
    }

    // --- try WITH finally: route normal + throw completions through one finally
    // copy via a completion register (rct: 0=normal, 2=throw; rcv = value to
    // re-raise). END_FINALLY re-raises on throw, chaining to the next outer
    // handler. `return` runs the finalizer inline at the return site
    // (finally_stack); a `return`/`throw` inside the finalizer overrides the
    // pending completion because it executes before END_FINALLY.
    const fin = ts.finalizer.?;
    const rct = self.allocReg(); // completion type
    const rcv = self.allocReg(); // completion value (exception)
    // Completion value: a normally-completing Finally is discarded and the
    // try/catch block's value wins, so snapshot V across the finalizer.
    const rcompl_save: ?u8 = if (self.completion_reg != null) self.allocReg() else null;
    const body_sp = self.sp;
    const k_normal = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 0));
    const k_throw = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 2));

    try self.finally_stack.append(self.arena, .{ .finalizer = fin });

    // An exception in the try body lands in rcv.
    try self.emitOp(.PUSH_TRY, line);
    try self.emitU8(rcv);
    const push_try_patch = self.currentOffset();
    try self.emitI16(0);

    self.sp = body_sp;
    try self.compileStmt(ts.block, last_expr_reg);
    self.sp = body_sp;
    // try body completed normally
    try self.emitOp(.POP_TRY, line);
    try self.emitOp(.LOAD_K, line);
    try self.emitU8(rct);
    try self.emitI16(@intCast(k_normal));
    try self.emitOp(.JMP, line);
    const jmp_norm = self.currentOffset();
    try self.emitI16(0);

    // --- exception handler ---
    const handler_offset = self.currentOffset();
    self.patchJump(push_try_patch, handler_offset);
    var jmp_catch_norm: ?usize = null;
    if (ts.handler) |handler| {
        // A return-completion (Generator.return) skips the catch body and runs
        // only the finally: route it to the throw-completion path so END_FINALLY
        // re-raises the sentinel after the finalizer.
        try self.emitOp(.JMP_IF_RET_COMPL, line);
        try self.emitU8(rcv);
        const skip_catch_patch = self.currentOffset();
        try self.emitI16(0);
        // The catch body is itself protected by the finally. PUSH_TRY comes
        // *before* the catch scope is entered so the recorded environment is the
        // one outside it — a throw from the catch body then unwinds the scope.
        try self.emitOp(.PUSH_TRY, line);
        try self.emitU8(rcv);
        const catch_try_patch = self.currentOffset();
        try self.emitI16(0);
        const scoped = try enterCatchScope(self, handler.param_name, rcv, line);
        self.sp = body_sp;
        try self.compileStmt(handler.body, last_expr_reg);
        self.sp = body_sp;
        try exitCatchScope(self, scoped, line);
        try self.emitOp(.POP_TRY, line);
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rct);
        try self.emitI16(@intCast(k_normal));
        try self.emitOp(.JMP, line);
        jmp_catch_norm = self.currentOffset();
        try self.emitI16(0);
        // catch threw (or a return-completion skipped catch) → rcv holds the
        // value; mark it a throw completion and fall to the finally.
        const catch_handler_offset = self.currentOffset();
        self.patchJump(catch_try_patch, catch_handler_offset);
        self.patchJump(skip_catch_patch, catch_handler_offset);
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rct);
        try self.emitI16(@intCast(k_throw));
        // fall through to finally
    } else {
        // No catch: the exception in rcv propagates after the finally.
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rct);
        try self.emitI16(@intCast(k_throw));
        // fall through to finally
    }

    // --- finally ---
    const finally_offset = self.currentOffset();
    self.patchJump(jmp_norm, finally_offset);
    if (jmp_catch_norm) |jc| self.patchJump(jc, finally_offset);
    _ = self.finally_stack.pop(); // out of the protected region
    self.sp = body_sp;
    if (rcompl_save) |sv| {
        try self.emitOp(.MOVE, line);
        try self.emitU8(sv);
        try self.emitU8(self.completion_reg.?);
    }
    try self.compileStmt(fin, last_expr_reg);
    if (rcompl_save) |sv| {
        try self.emitOp(.MOVE, line);
        try self.emitU8(self.completion_reg.?);
        try self.emitU8(sv);
    }
    self.sp = body_sp;
    try self.emitOp(.END_FINALLY, line);
    try self.emitU8(rct);
    try self.emitU8(rcv);
    self.sp = saved_sp;
}

/// Unwind the open try-blocks from the top of `finally_stack` down to `floor`
/// ahead of an abrupt completion (`return`/`break`/`continue`): POP_TRY each
/// crossed try (so its runtime handler is removed) and run its finalizer inline,
/// innermost-first. `rv_reg` (if any) is pinned by keeping `sp` above it so a
/// finalizer cannot clobber the return value. A `return`/`break`/`continue`
/// within a finalizer sees only the still-outer try-blocks.
pub fn runPendingFinally(self: *FnCompiler, rv_reg: ?u8, floor: usize, line: u32) error{OutOfMemory}!void {
    var i = self.finally_stack.items.len;
    while (i > floor) {
        i -= 1;
        // Remove this region's runtime handler; the cleanup (and the completion)
        // run outside its protection.
        try self.emitOp(.POP_TRY, line);
        switch (self.finally_stack.items[i]) {
            .finalizer => |fin| if (fin) |fnode| {
                const saved_len = self.finally_stack.items.len;
                self.finally_stack.items.len = i; // only outer try-blocks stay active
                const saved_sp = self.sp;
                if (rv_reg) |r| self.sp = r + 1; // pin the return value
                var dummy: ?u8 = null;
                try self.compileStmt(fnode, &dummy);
                self.sp = saved_sp;
                self.finally_stack.items.len = saved_len;
            },
            // Leaving a for-of early (`break`/`continue L`/`return`) closes its
            // iterator. This is a non-throw completion, so IteratorClose's own
            // errors — a throwing or non-Object `return()` — propagate.
            .close_iter => |riter| {
                const saved_sp = self.sp;
                if (rv_reg) |r| self.sp = @max(self.sp, r + 1); // pin the return value
                const scratch = self.allocReg();
                try self.emitDestrCall("__destrIterClose__", riter, null, scratch, line);
                self.sp = saved_sp;
            },
        }
    }
}

pub fn lowerBreakStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    const label = node.data.break_stmt;
    if (label) |lname| {
        // Prefer a labeled loop (so `break L` exits the loop); fall back
        // to a labeled non-loop statement block.
        var li = self.loop_stack.items.len;
        while (li > 0) {
            li -= 1;
            if (self.loop_stack.items[li].label) |l| {
                if (std.mem.eql(u8, l, lname)) {
                    try runPendingFinally(self, null, self.loop_stack.items[li].finally_depth, line);
                    try self.emitExitScopesTo(self.loop_stack.items[li].scope_depth, line);
                    try self.emitOp(.JMP, line);
                    const patch = self.currentOffset();
                    try self.emitI16(0);
                    try self.loop_stack.items[li].break_patches.append(self.arena, patch);
                    return;
                }
            }
        }
        var i = self.label_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.label_stack.items[i].name, lname)) {
                try runPendingFinally(self, null, self.label_stack.items[i].finally_depth, line);
                try self.emitExitScopesTo(self.label_stack.items[i].scope_depth, line);
                try self.emitOp(.JMP, line);
                const patch = self.currentOffset();
                try self.emitI16(0);
                try self.label_stack.items[i].break_patches.append(self.arena, patch);
                return;
            }
        }
        // Label not found — undefined label is an early SyntaxError.
        if (last_label_error_ptr.* == null)
            last_label_error_ptr.* = std.fmt.allocPrint(self.arena, "undefined label '{s}'", .{lname}) catch "undefined label";
        // Still emit a JMP placeholder to keep the instruction stream valid.
        try self.emitOp(.JMP, line);
        _ = self.currentOffset();
        try self.emitI16(0);
    } else if (self.loop_stack.items.len > 0) {
        const ti = self.loop_stack.items.len - 1;
        try runPendingFinally(self, null, self.loop_stack.items[ti].finally_depth, line);
        try self.emitExitScopesTo(self.loop_stack.items[ti].scope_depth, line);
        try self.emitOp(.JMP, line);
        const patch = self.currentOffset();
        try self.emitI16(0);
        try self.loop_stack.items[ti].break_patches.append(self.arena, patch);
    } else {
        // `break` with no enclosing loop/label — emit a placeholder JMP.
        try self.emitOp(.JMP, line);
        _ = self.currentOffset();
        try self.emitI16(0);
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
    } else {
        // Innermost enclosing *loop*: a switch pushes a break-only context, so
        // `continue` inside a switch must jump past it to the real loop.
        var li = self.loop_stack.items.len;
        while (li > 0) {
            li -= 1;
            if (!self.loop_stack.items[li].is_switch) {
                target_idx = li;
                break;
            }
        }
    }
    // Completion value: `continue` propagates the running value rather than
    // resetting it — LoopEvaluation step "if stmtResult.[[Value]] is not EMPTY,
    // set V to stmtResult.[[Value]]" applies to a continue completion too, and
    // the enclosing UpdateEmpty chain has already filled in the value. (`if`
    // and loop entry are what reset V; see resetCompletion.)
    // Run (and POP_TRY) any try-blocks opened inside the loop, then unwind block
    // scopes, before jumping to the loop's continue target.
    if (target_idx) |ti| {
        // `continue` re-enters the target loop, so its own for-of IteratorClose
        // cleanup must NOT run (any *inner* for-of between here and the target
        // still does, since those loops are being left).
        try runPendingFinally(self, null, self.loop_stack.items[ti].continue_finally_depth, line);
        try self.emitExitScopesTo(self.loop_stack.items[ti].scope_depth, line);
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
            const gi = try self.builder.addConstant(try val_mod.makeString(self.arena, if (fo.is_await) "__getAsyncIterator__" else "__getIterator__"));
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
        // Completion value: a loop's value starts fresh at `undefined`. No-op
        // outside implicit-return (completion-value) compilation.
        try self.resetCompletion(line);
        // Any abrupt exit from the loop must run IteratorClose (ECMA-262 7.4.5
        // ForIn/OfBodyEvaluation): a throw or generator `.return()` lands in the
        // handler below, while `break` / `return` / a `continue` targeting an
        // OUTER loop unwind through the `close_iter` cleanup. Only exhausting
        // the iterator, or a `continue` back into this same loop, skips it.
        //
        // The protected region starts AFTER `next()` and the `done`/`value`
        // reads: those set [[Done]] before their abrupt return, so a throwing
        // `next()` must NOT be followed by a close. The region therefore opens
        // per-iteration, and this leading PUSH_TRY is the counterpart of the
        // POP_TRY that `loop_start` runs before every step (including the very
        // first one and every `continue`), which keeps the try stack balanced.
        const rexc = self.allocReg();
        self.freeReg(); // PUSH_TRY reserves it
        var handler_patches = std.ArrayList(usize){};
        try self.emitOp(.PUSH_TRY, line);
        try self.emitU8(rexc);
        try handler_patches.append(self.arena, self.currentOffset());
        try self.emitI16(0);
        // Recorded BEFORE the cleanup is pushed, so `break` unwinds through it.
        const break_finally_depth = self.finally_stack.items.len;
        try self.finally_stack.append(self.arena, .{ .close_iter = riter });
        // Permanent registers (riter, rstep, rexc) sit below iter_sp; the
        // per-iteration temporaries above it are reclaimed each pass.
        const iter_sp = self.sp;
        const loop_start = self.currentOffset();
        try self.emitOp(.POP_TRY, line);
        {
            const b = self.allocReg();
            const si = try self.builder.addConstant(try val_mod.makeString(self.arena, if (fo.is_await) "__asyncIterStep__" else "__iterStep__"));
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
            // for-await: __asyncIterStep__ returns a promise of {value,done};
            // await it so rstep holds the resolved result. The suspend writes the
            // resolved value back into R[rstep]. AWAIT inside an async generator,
            // YIELD inside a plain async function.
            if (fo.is_await) {
                try self.emitOp(if (self.is_async_generator) .AWAIT else .YIELD, line);
                try self.emitU8(rstep);
            }
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
        // From here on the iterator is live and un-exhausted: re-arm the handler
        // so a failing binding/destructuring or a throwing body closes it.
        try self.emitOp(.PUSH_TRY, line);
        try self.emitU8(rexc);
        try handler_patches.append(self.arena, self.currentOffset());
        try self.emitI16(0);
        const loop_decl_kind: ?VarKind = switch (fo.left.kind) {
            .var_decl => fo.left.data.var_decl.kind,
            else => null,
        };
        const loop_name: ?[]const u8 = switch (fo.left.kind) {
            .var_decl => if (fo.left.data.var_decl.name.len > 0) fo.left.data.var_decl.name else null,
            .identifier => fo.left.data.identifier,
            else => null,
        };
        // A `let`/`const` for-of binding is fresh per iteration (closures created
        // in the body capture a distinct binding each pass). Wrap each iteration's
        // binding + body in its own block scope.
        const is_lexical_loopvar = loop_name != null and loop_decl_kind != null and
            (loop_decl_kind.? == .let or loop_decl_kind.? == .const_);
        const outer_depth = self.block_scope_depth;
        if (is_lexical_loopvar) {
            try self.emitOp(.ENTER_SCOPE, line);
            self.block_scope_depth += 1;
            try self.emitHoistLexical(loop_name.?, line);
        }
        if (loop_name) |nm| {
            const ni = try self.builder.addConstant(try val_mod.makeString(self.arena, nm));
            if (is_lexical_loopvar) {
                try self.emitInitLexical(nm, rval, line, loop_decl_kind.? == .const_);
            } else {
                try self.emitOp(.SET_GLOBAL, line);
                try self.emitU16(@intCast(ni));
                try self.emitU8(rval);
            }
        } else switch (fo.left.kind) {
            // `for ([a, b] of it)` / `for ({x} of it)` / `for (o.p of it)`: the
            // head is an AssignmentPattern (or member target) with no declaration.
            // Assign each iteration's value into it via the destructuring helper.
            .array_literal, .object_literal, .member_expr => try self.compileDestructure(fo.left, rval, line),
            else => {},
        }
        self.sp = iter_sp;
        // Register the loop so `break`/`continue` (labeled or innermost) resolve to
        // it; `continue` jumps to loop_start, which advances the iterator (re-calls
        // __iterStep__) before the next done-check. scope_depth is the depth
        // *outside* the per-iteration scope so break/continue unwind it.
        try self.loop_stack.append(self.arena, LoopCtx{
            .label = loop_lbl,
            .scope_depth = outer_depth,
            // `break` leaves the loop, so it unwinds the IteratorClose cleanup;
            // `continue` re-enters it, so it stops just above.
            .finally_depth = break_finally_depth,
            .continue_finally_depth = self.finally_stack.items.len,
        });
        try self.compileStmt(fo.body, last_expr_reg);
        if (is_lexical_loopvar) {
            try self.emitOp(.EXIT_SCOPE, line);
            self.block_scope_depth -= 1;
        }
        try self.emitOp(.JMP, line);
        const back = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back, loop_start);
        _ = self.finally_stack.pop(); // out of the protected region
        // Iterator exhausted (or its `next()`/`done`/`value` threw): the handler
        // was already popped at `loop_start`, and the iterator completed on its
        // own, so nothing to close.
        self.patchJump(patch_exit, self.currentOffset());
        try self.emitOp(.JMP, line);
        const jmp_after = self.currentOffset();
        try self.emitI16(0);
        // Handler: the completion is in `rexc`, so every call here allocates
        // above it. A throw completion wins outright (IteratorClose's own errors
        // are discarded); a generator return-completion is not a throw, so a
        // throwing or non-Object `return()` replaces it.
        for (handler_patches.items) |hp| self.patchJump(hp, self.currentOffset());
        self.sp = rexc + 1;
        try self.emitOp(.JMP_IF_RET_COMPL, line);
        try self.emitU8(rexc);
        const ret_compl_patch = self.currentOffset();
        try self.emitI16(0);
        {
            const scratch = self.allocReg();
            try self.emitDestrCall("__destrIterCloseThrow__", riter, null, scratch, line);
            self.sp = rexc + 1;
        }
        try self.emitOp(.THROW, line);
        try self.emitU8(rexc);
        self.patchJump(ret_compl_patch, self.currentOffset());
        {
            const scratch = self.allocReg();
            try self.emitDestrCall("__destrIterClose__", riter, null, scratch, line);
            self.sp = rexc + 1;
        }
        try self.emitOp(.THROW, line);
        try self.emitU8(rexc);
        // `break` targets land here: each already emitted its own POP_TRY and
        // IteratorClose while unwinding.
        const exit_offset = self.currentOffset();
        self.patchJump(jmp_after, exit_offset);
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

    // Completion value: like every other iteration statement, a for-in's value
    // starts fresh at `undefined` (ForIn/OfBodyEvaluation step 2).
    try self.resetCompletion(line);

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
    // Completion value: CaseBlockEvaluation starts with V = undefined, so a
    // switch whose selected clauses produce nothing completes with `undefined`
    // rather than leaving the enclosing script's running value in place.
    try self.resetCompletion(line);

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

    // A switch is a `break` target, so push a context that lowerBreakStmt can
    // find. This must cover the WHOLE case body, not just a `break` written as
    // a direct statement of the case: a `break` nested in an if/block/try is
    // lowered by lowerBreakStmt, which without this entry would target the
    // innermost enclosing loop (or emit a dangling jump when there is none).
    try self.loop_stack.append(self.arena, LoopCtx{
        .label = null,
        .scope_depth = self.block_scope_depth,
        .finally_depth = self.finally_stack.items.len,
        .continue_finally_depth = self.finally_stack.items.len,
        .is_switch = true,
    });

    // Emit case bodies. Patch the jump-to-body addresses.
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
            try self.compileStmt(stmt, last_expr_reg);
        }
    }

    const end_offset = self.currentOffset();

    // Patch default-or-end jump if default was not found.
    if (patch_default_or_end) |pd| {
        self.patchJump(pd, end_offset);
    }

    // Patch every break that targeted this switch.
    var ctx = self.loop_stack.pop().?;
    for (ctx.break_patches.items) |bp| self.patchJump(bp, end_offset);
    ctx.break_patches.deinit(self.arena);
    ctx.continue_patches.deinit(self.arena);
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
        .scope_depth = self.block_scope_depth,
        .finally_depth = self.finally_stack.items.len,
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

pub fn lowerWithStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    const line: u32 = node.start;
    const ws = node.data.with_stmt;
    // Evaluate the object, push it as a with-scope, compile the body, then pop.
    // The PUSH_WITH copies the value onto the frame's with-stack, so the source
    // register is free immediately after.
    const robj = try self.compileExpr(ws.object);
    try self.emitOp(.PUSH_WITH, line);
    try self.emitU8(robj);
    self.sp = robj;
    // Completion value: `with` returns UpdateEmpty(bodyCompletion, undefined).
    try self.resetCompletion(line);
    self.with_depth += 1;
    try self.compileStmt(ws.body, last_expr_reg);
    self.with_depth -= 1;
    try self.emitOp(.POP_WITH, line);
}

pub fn lowerDebuggerStmt(self: *FnCompiler, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
    _ = last_expr_reg;
    const line: u32 = node.start;
    // Phase 8: emit a DEBUGGER opcode so the VM can fire a debug
    // hook (breakpoint-style pause). No-op when no hook installed.
    try self.emitOp(.DEBUGGER, line);
}
