// SPDX-License-Identifier: Apache-2.0
//! AST -> bytecode compiler for Phase 2.
//! Emits a register-based bytecode (Ignition/Lua-5 style).
//! Each function compiles to a BcFunction with a Chunk, register count,
//! and a list of child BcFunctions for nested closures.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const Op = @import("./opcodes.zig").Op;
const ChunkBuilder = @import("./chunk.zig").ChunkBuilder;
const BcFunction = @import("./function.zig").BcFunction;
const BcClosure = @import("./function.zig").BcClosure;
const ic_mod = @import("../vm/ic.zig");

// ---------------------------------------------------------------- FnCompiler ---

/// Per-function compilation state.
/// Label break tracking: maps label name → list of JMP patch offsets that need patching to exit.
pub const LabelEntry = struct {
    name: []const u8,
    break_patches: std.ArrayListUnmanaged(usize) = .empty,
    continue_patches: std.ArrayListUnmanaged(usize) = .empty,
    // Where the loop starts (for continue with label).
    loop_start: usize = 0,
    /// Block-scope nesting depth at the point this label was entered, so a
    /// `break L` can emit EXIT_SCOPE for every block scope it unwinds out of.
    scope_depth: u32 = 0,
    /// `finally_stack` length at label entry, so `break L` runs (and POP_TRY)
    /// any try-blocks opened inside the labeled statement before jumping out.
    finally_depth: usize = 0,
};

/// Set by `compileProgram` when a `break`/`continue` targets an undefined label
/// (an early SyntaxError per ES). Reset at the start of every `compileProgram`.
/// `bcEval` reads it after compiling so `eval("break L")` throws a SyntaxError.
pub var last_label_error: ?[]const u8 = null;

/// Per-loop compilation context for unlabeled (and labeled) `break`/`continue`.
/// Each `while`/`do-while`/`for` pushes one before compiling its body; `break`
/// and `continue` register their JMP patch offsets here, resolved when the loop
/// pops (break → loop exit, continue → the loop's continue target).
pub const LoopCtx = struct {
    break_patches: std.ArrayListUnmanaged(usize) = .empty,
    continue_patches: std.ArrayListUnmanaged(usize) = .empty,
    /// Label attached to this loop (from a directly-enclosing labeled statement),
    /// so `break L`/`continue L` can target it. null when unlabeled.
    label: ?[]const u8 = null,
    /// Block-scope nesting depth just outside this loop's per-iteration scope.
    /// `break`/`continue` emit EXIT_SCOPE for each block scope between the
    /// statement and this depth so the frame env is balanced on the jump.
    scope_depth: u32 = 0,
    /// `finally_stack` length at loop entry. `break`/`continue` run (and POP_TRY)
    /// each try-block opened inside the loop before jumping out of it.
    finally_depth: usize = 0,
    /// True for the context a `switch` pushes. A switch is a `break` target but
    /// NOT a `continue` target, so unlabeled `continue` skips these entries and
    /// keeps unwinding to the innermost real loop.
    is_switch: bool = false,
};

pub const FnCompiler = struct {
    arena: std.mem.Allocator,
    builder: ChunkBuilder,
    /// Current register stack pointer (next free register).
    sp: u8 = 0,
    /// High-water mark for num_regs.
    max_regs: u8 = 0,
    /// Child functions (closures compiled recursively).
    child_functions: std.ArrayListUnmanaged(*BcFunction) = .empty,
    /// Name of this function (for diagnostics).
    name: ?[]const u8,
    /// Parameters.
    param_names: [][]const u8,
    /// Are we in a named function expression (NFE)? If so, name is bound internally.
    nfe_name: ?[]const u8 = null,
    /// Phase 4d: label stack for labeled break/continue.
    label_stack: std.ArrayListUnmanaged(LabelEntry) = .empty,
    /// Phase 13: stack of enclosing loops for unlabeled/labeled break+continue.
    loop_stack: std.ArrayListUnmanaged(LoopCtx) = .empty,
    /// Phase 13: a pending label from a labeled statement, consumed by the next
    /// loop so `break L`/`continue L` target that loop. null otherwise.
    pending_label: ?[]const u8 = null,
    /// Phase 13 completion values: the register accumulating the program's
    /// completion value (the result of `eval`/REPL). Non-null only while compiling
    /// the top-level program (implicit-return mode); function bodies leave it null
    /// so none of the completion bookkeeping is emitted for them.
    completion_reg: ?u8 = null,
    /// Phase 8: is this function compiled in strict mode? PTC only applies in
    /// strict mode (ES2015 14.6).
    is_strict: bool = false,
    /// W2-async: is this an async function body? When true, `__await__(x)`
    /// compiles to a YIELD suspend instead of a synchronous native call.
    is_async: bool = false,
    /// W2-asyncgen: is this an `async function*` body? When true, `await`
    /// suspends via AWAIT (not YIELD) so the async-generator driver can tell an
    /// await apart from a yield. `yield` always uses YIELD.
    is_async_generator: bool = false,
    /// True for any generator body (sync `function*` or `async function*`).
    /// Gates emission of the PARAMS_DONE marker for eager parameter binding.
    is_generator: bool = false,
    /// Set when a PARAMS_DONE marker was emitted (the function has a
    /// destructuring-param prelude). The VM runs the prelude eagerly at call time.
    has_param_init: bool = false,
    /// M14: this function literal is an arrow (no own `arguments`/`this`).
    is_arrow: bool = false,
    /// M14: the body read an identifier named `arguments`. Combined with
    /// `!is_arrow` this drives BcFunction.uses_arguments.
    saw_arguments: bool = false,
    /// NamedEvaluation: when set, the next compiled anonymous function expression
    /// adopts this as its name. Consumed (cleared) immediately on use so nested
    /// functions are unaffected.
    name_hint: ?[]const u8 = null,
    /// Phase 8: nesting depth of try/catch/finally regions. A call in the
    /// operand of `return` is only in tail position when try_depth == 0
    /// (a pending finally would run after the call returns, so it is not tail).
    try_depth: u32 = 0,
    /// Finalizer AST nodes of the try/catch regions currently being compiled
    /// (innermost last). A `return` inside these runs each finalizer inline,
    /// innermost-first, before the RETURN — ES try/finally on a return
    /// completion. Popped before a finalizer's own body is compiled so a
    /// `return` within `finally` does not re-run that same finalizer.
    finally_stack: std.ArrayListUnmanaged(?*ast.Node) = .empty,
    /// Number of block scopes (ENTER_SCOPE) currently open in the bytecode being
    /// emitted. Used so `break`/`continue` emit matching EXIT_SCOPE ops.
    block_scope_depth: u32 = 0,
    /// Annex B.3.3: block-level function declaration names that also get a
    /// `var`-scoped binding in this scope (see collectAnnexBNames). Computed
    /// once per body in compileBody; drives the var-hoisting pre-pass.
    annexb_fn_names: std.ArrayList([]const u8) = .empty,
    /// The individual declarations the extension applies to. Keyed by node
    /// rather than by name because applicability is per-declaration: in
    /// `{ function x(){} } { let x; { function x(){} } }` the first gets the
    /// var binding and the second must not overwrite it.
    annexb_fn_sites: std.ArrayList(*ast.Node) = .empty,
    /// Number of enclosing `with` statements whose body is currently being
    /// compiled. When >0, a `var x = init` initializer must route its store
    /// through the with-object environment (SET_GLOBAL) rather than a direct
    /// DEFINE_GLOBAL, since ResolveBinding("x") crosses the with-object env.
    with_depth: u32 = 0,
    /// ES2020 optional chaining: while compiling an `optional_chain`, this points
    /// to the list of JMP_IF_NULLISH patch offsets emitted by optional links.
    /// They are all patched to the chain's short-circuit landing pad. null when
    /// not inside an optional chain.
    optional_jumps: ?*std.ArrayListUnmanaged(usize) = null,

    const Self = @This();

    pub fn init(arena: std.mem.Allocator, name: ?[]const u8, params: [][]const u8) FnCompiler {
        return FnCompiler{
            .arena = arena,
            .builder = ChunkBuilder.init(arena),
            .name = name,
            .param_names = params,
        };
    }

    /// Allocate a new register and track high-water mark.
    pub fn allocReg(self: *Self) u8 {
        const r = self.sp;
        self.sp += 1;
        if (self.sp > self.max_regs) self.max_regs = self.sp;
        return r;
    }

    /// Free the top register (drop sp).
    pub fn freeReg(self: *Self) void {
        if (self.sp > 0) self.sp -= 1;
    }

    pub fn emitOp(self: *Self, op: Op, line: u32) !void {
        try self.builder.emitOp(op, line);
    }

    pub fn emitU8(self: *Self, v: u8) !void {
        try self.builder.emitU8(v);
    }

    pub fn emitU16(self: *Self, v: u16) !void {
        try self.builder.emitU16(v);
    }

    pub fn emitI16(self: *Self, v: i16) !void {
        try self.builder.emitI16(v);
    }

    pub fn addConstant(self: *Self, v: Value) !u16 {
        return self.builder.addConstant(v);
    }

    pub fn currentOffset(self: *const Self) usize {
        return self.builder.currentOffset();
    }

    pub fn patchJump(self: *Self, at: usize, target: usize) void {
        self.builder.patchJump(at, target);
    }

    /// Completion values (program/eval only): record `r` as the running
    /// completion value. No-op outside implicit-return compilation.
    pub fn writeCompletion(self: *Self, r: u8, line: u32) error{OutOfMemory}!void {
        if (self.completion_reg) |cr| {
            if (cr != r) {
                try self.emitOp(.MOVE, line);
                try self.emitU8(cr);
                try self.emitU8(r);
            }
        }
    }

    /// Completion values: reset the completion register to `undefined` (the
    /// UpdateEmpty base used by `if` and at loop entry). No-op outside
    /// implicit-return compilation.
    pub fn resetCompletion(self: *Self, line: u32) error{OutOfMemory}!void {
        if (self.completion_reg) |cr| {
            try self.emitOp(.LOAD_UNDEF, line);
            try self.emitU8(cr);
        }
    }

    /// Pop the innermost loop context, patching its `break` jumps to `exit` and
    /// its `continue` jumps to `continue_target`.
    pub fn resolveLoop(self: *Self, continue_target: usize, exit: usize) void {
        var ctx = self.loop_stack.pop().?;
        for (ctx.break_patches.items) |bp| self.patchJump(bp, exit);
        for (ctx.continue_patches.items) |cp| self.patchJump(cp, continue_target);
        ctx.break_patches.deinit(self.arena);
        ctx.continue_patches.deinit(self.arena);
    }

    /// ES2020 optional chaining: if inside an optional chain, emit a
    /// `JMP_IF_NULLISH rtest` guard whose target is the chain's short-circuit
    /// landing pad (patched later by compileOptionalChain).
    pub fn emitOptionalGuard(self: *Self, rtest: u8, line: u32) error{OutOfMemory}!void {
        const list = self.optional_jumps orelse return;
        try self.emitOp(.JMP_IF_NULLISH, line);
        try self.emitU8(rtest);
        const patch = self.currentOffset();
        try self.emitI16(0);
        try list.append(self.arena, patch);
    }

    // --------------------------------------------------------- resolve name ---
    // Phase 2: always use env-based (GET_GLOBAL/SET_GLOBAL) for named variables.
    // This ensures inner closures can capture outer variables via the env chain.
    // GET_LOCAL/SET_LOCAL are reserved for compiler-generated register temporaries.

    // --------------------------------------------------------- emit name load ---

    /// Load a named identifier into Rdst via env chain lookup.
    pub fn emitLoad(self: *Self, name: []const u8, rdst: u8, line: u32) !void {
        if (std.mem.eql(u8, name, "arguments")) self.saw_arguments = true;
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.GET_GLOBAL, line);
        try self.emitU8(rdst);
        try self.emitU16(kidx);
    }

    /// Tolerant identifier load (undeclared => `undefined`, never a
    /// ReferenceError). Only for the operand of `typeof <identifier>`.
    pub fn emitLoadOpt(self: *Self, name: []const u8, rdst: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.GET_GLOBAL_OPT, line);
        try self.emitU8(rdst);
        try self.emitU16(kidx);
    }

    /// Emit a HOIST_VAR for `name` (binds it to undefined at scope entry if it
    /// has no own binding yet).
    pub fn emitHoist(self: *Self, name: []const u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.HOIST_VAR, line);
        try self.emitU16(kidx);
    }

    /// Add `name` to `list` if not already present (dedup hoisted names).
    pub fn addHoistName(self: *Self, list: *std.ArrayList([]const u8), name: []const u8) !void {
        for (list.items) |n| {
            if (std.mem.eql(u8, n, name)) return;
        }
        try list.append(self.arena, name);
    }

    /// Collect `var` and function-declaration names reachable in the current
    /// function/script scope (recursing through nested statements but NOT into
    /// nested function bodies — those are separate scopes). `let`/`const` are
    /// block-scoped and intentionally excluded.
    /// `nested` is true once the walk has entered a block / clause / loop body:
    /// a function declaration found there is NOT an ordinary var-scoped
    /// declaration, and only gets a var binding via the Annex B.3.3 set
    /// computed separately by `collectAnnexBNames`.
    pub fn collectHoistedNames(self: *Self, node: *ast.Node, list: *std.ArrayList([]const u8), nested: bool) error{OutOfMemory}!void {
        switch (node.kind) {
            .var_decl => {
                if (node.data.var_decl.kind == .var_) {
                    try self.addHoistName(list, node.data.var_decl.name);
                }
            },
            .function_decl => if (!nested) try self.addHoistName(list, node.data.function_decl.name),
            .block_stmt => {
                const inner = nested or node.data.block_stmt.lexical_scope;
                for (node.data.block_stmt.body) |c| try self.collectHoistedNames(c, list, inner);
            },
            .if_stmt => {
                try self.collectHoistedNames(node.data.if_stmt.consequent, list, true);
                if (node.data.if_stmt.alternate) |a| try self.collectHoistedNames(a, list, true);
            },
            .while_stmt => try self.collectHoistedNames(node.data.while_stmt.body, list, true),
            .do_while_stmt => try self.collectHoistedNames(node.data.do_while_stmt.body, list, true),
            .with_stmt => try self.collectHoistedNames(node.data.with_stmt.body, list, true),
            .for_stmt => {
                if (node.data.for_stmt.init) |i| try self.collectHoistedNames(i, list, nested);
                try self.collectHoistedNames(node.data.for_stmt.body, list, true);
            },
            .for_in_stmt => {
                try self.collectHoistedNames(node.data.for_in_stmt.left, list, nested);
                try self.collectHoistedNames(node.data.for_in_stmt.body, list, true);
            },
            .try_stmt => {
                try self.collectHoistedNames(node.data.try_stmt.block, list, nested);
                if (node.data.try_stmt.handler) |h| try self.collectHoistedNames(h.body, list, nested);
                if (node.data.try_stmt.finalizer) |f| try self.collectHoistedNames(f, list, nested);
            },
            .switch_stmt => {
                for (node.data.switch_stmt.cases) |case| {
                    for (case.body) |c| try self.collectHoistedNames(c, list, true);
                }
            },
            .labeled_stmt => try self.collectHoistedNames(node.data.labeled_stmt.body, list, nested),
            else => {},
        }
    }

    /// Annex B.3.3 (Web-compat semantics for block-level function declarations):
    /// collect the names of function declarations nested inside a block / `if`
    /// clause / loop body that additionally get a `var`-scoped binding in this
    /// scope. A declaration is excluded when replacing it with `var F` would be
    /// an early error — that is, when some enclosing construct between it and
    /// this scope already binds F lexically (`let`/`const`/`class`, a `for` head
    /// binding) or F is a parameter of the enclosing function. `blocked` is the
    /// running set of such names along the current path; `nested` distinguishes
    /// a genuine block-level declaration from an ordinary top-level one.
    /// Applicability is decided per declaration, so `out` (the names to hoist)
    /// is accompanied by `annexb_fn_sites` (the declarations that sync).
    pub fn collectAnnexBNames(
        self: *Self,
        node: *ast.Node,
        blocked: *std.ArrayList([]const u8),
        out: *std.ArrayList([]const u8),
        nested: bool,
    ) error{OutOfMemory}!void {
        switch (node.kind) {
            .function_decl => {
                if (!nested) return; // an ordinary declaration of this scope
                const name = node.data.function_decl.name;
                for (blocked.items) |b| if (std.mem.eql(u8, b, name)) return;
                try self.addHoistName(out, name);
                try self.annexb_fn_sites.append(self.arena, node);
            },
            .block_stmt => {
                const bs = node.data.block_stmt;
                // A transparent (desugaring) block is not a scope: its contents
                // belong to the enclosing one, so neither its bindings nor its
                // function declarations change classification.
                if (!bs.lexical_scope) {
                    for (bs.body) |c| try self.collectAnnexBNames(c, blocked, out, nested);
                    return;
                }
                const mark = blocked.items.len;
                for (bs.body) |c| try self.collectLexicalNames(c, blocked);
                for (bs.body) |c| try self.collectAnnexBNames(c, blocked, out, true);
                blocked.shrinkRetainingCapacity(mark);
            },
            .if_stmt => {
                // Each clause behaves as a block containing the declaration
                // (B.3.4, FunctionDeclarations in IfStatement Statement Clauses).
                try self.collectAnnexBNames(node.data.if_stmt.consequent, blocked, out, true);
                if (node.data.if_stmt.alternate) |a| try self.collectAnnexBNames(a, blocked, out, true);
            },
            .while_stmt => try self.collectAnnexBNames(node.data.while_stmt.body, blocked, out, true),
            .do_while_stmt => try self.collectAnnexBNames(node.data.do_while_stmt.body, blocked, out, true),
            .with_stmt => try self.collectAnnexBNames(node.data.with_stmt.body, blocked, out, true),
            .for_stmt => {
                const mark = blocked.items.len;
                if (node.data.for_stmt.init) |i| try self.collectLexicalNames(i, blocked);
                try self.collectAnnexBNames(node.data.for_stmt.body, blocked, out, true);
                blocked.shrinkRetainingCapacity(mark);
            },
            .for_in_stmt => {
                const mark = blocked.items.len;
                try self.collectLexicalNames(node.data.for_in_stmt.left, blocked);
                try self.collectAnnexBNames(node.data.for_in_stmt.body, blocked, out, true);
                blocked.shrinkRetainingCapacity(mark);
            },
            .try_stmt => {
                const ts = node.data.try_stmt;
                try self.collectAnnexBNames(ts.block, blocked, out, nested);
                if (ts.handler) |h| {
                    // A catch parameter does NOT block the extension: B.3.5
                    // exempts a `CatchParameter: BindingIdentifier` from the
                    // "VarDeclaredNames of the Block must not collide" early
                    // error, so `var F` there is legal and the var binding is
                    // still created. (Only a destructuring catch parameter
                    // would block — this engine parses none.)
                    try self.collectAnnexBNames(h.body, blocked, out, nested);
                }
                if (ts.finalizer) |f| try self.collectAnnexBNames(f, blocked, out, nested);
            },
            .switch_stmt => {
                // The whole switch body is one block scope shared by every case.
                const mark = blocked.items.len;
                for (node.data.switch_stmt.cases) |case| {
                    for (case.body) |c| try self.collectLexicalNames(c, blocked);
                }
                for (node.data.switch_stmt.cases) |case| {
                    for (case.body) |c| try self.collectAnnexBNames(c, blocked, out, true);
                }
                blocked.shrinkRetainingCapacity(mark);
            },
            // A label introduces no scope, so it does not change classification.
            .labeled_stmt => try self.collectAnnexBNames(node.data.labeled_stmt.body, blocked, out, nested),
            else => {},
        }
    }

    /// True when `decl` is a block-level function declaration that Annex B.3.3
    /// also gives a `var`-scoped binding in the enclosing function/script scope.
    pub fn isAnnexBFunction(self: *Self, decl: *ast.Node) bool {
        for (self.annexb_fn_sites.items) |n| {
            if (n == decl) return true;
        }
        return false;
    }

    /// Collect `let`/`const` declaration names reachable at function/script scope
    /// (recursing through nested statements but NOT into nested function bodies).
    /// These need HOIST_LEX emitted at scope entry to put them in TDZ.
    pub fn collectLexicalNames(self: *Self, node: *ast.Node, list: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
        switch (node.kind) {
            .var_decl => {
                if (node.data.var_decl.kind == .let or node.data.var_decl.kind == .const_) {
                    try self.addHoistName(list, node.data.var_decl.name);
                }
            },
            .block_stmt => {
                // A real nested block is its own lexical scope (handled by
                // lowerBlockStmt via ENTER_SCOPE); its `let`/`const` must NOT be
                // hoisted into this enclosing scope. A transparent block (class
                // desugaring, multi-declarator lowering) belongs to this scope,
                // so its lexical names ARE collected here.
                if (!node.data.block_stmt.lexical_scope) {
                    for (node.data.block_stmt.body) |c| try self.collectLexicalNames(c, list);
                }
            },
            .if_stmt => {
                try self.collectLexicalNames(node.data.if_stmt.consequent, list);
                if (node.data.if_stmt.alternate) |a| try self.collectLexicalNames(a, list);
            },
            .while_stmt => try self.collectLexicalNames(node.data.while_stmt.body, list),
            .do_while_stmt => try self.collectLexicalNames(node.data.do_while_stmt.body, list),
            .with_stmt => try self.collectLexicalNames(node.data.with_stmt.body, list),
            .for_stmt => {
                // Do NOT recurse into for_stmt.init — a `let`/`const` in the
                // C-style for header is scoped to the loop (per-iteration), not
                // the enclosing block, and is set up by the for-loop lowering.
                // Hoisting it here would let an enclosing-scope read (e.g. an
                // outer `let n = i` before a shadowing inner `for (let i ...)`)
                // resolve to the loop binding in TDZ. Mirrors for_in_stmt.
                try self.collectLexicalNames(node.data.for_stmt.body, list);
            },
            .for_in_stmt => {
                // Do NOT recurse into for_in_stmt.left — loop-scoped let/const
                // bindings are per-iteration and should NOT be hoisted to the
                // enclosing function/module scope. They are initialized directly
                // by the for-in/for-of lowering via INIT_LEX each iteration.
                try self.collectLexicalNames(node.data.for_in_stmt.body, list);
            },
            .try_stmt => {
                try self.collectLexicalNames(node.data.try_stmt.block, list);
                if (node.data.try_stmt.handler) |h| try self.collectLexicalNames(h.body, list);
                if (node.data.try_stmt.finalizer) |f| try self.collectLexicalNames(f, list);
            },
            .switch_stmt => {
                for (node.data.switch_stmt.cases) |case| {
                    for (case.body) |c| try self.collectLexicalNames(c, list);
                }
            },
            .labeled_stmt => try self.collectLexicalNames(node.data.labeled_stmt.body, list),
            else => {},
        }
    }

    // --------------------------------------------------------- emit name store ---

    pub fn emitStore(self: *Self, name: []const u8, rsrc: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.SET_GLOBAL, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
    }

    /// Phase 4d: Emit DEFINE_GLOBAL — defines a new binding (used for var decls,
    /// catch variables). Always defines; never throws ReferenceError in strict mode.
    pub fn emitDefine(self: *Self, name: []const u8, rsrc: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.DEFINE_GLOBAL, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
    }

    /// Emit a DEFINE_LOCAL for `name` (binds it in the *current* environment
    /// record only — BlockDeclarationInstantiation for a block-level function).
    pub fn emitDefineLocal(self: *Self, name: []const u8, rsrc: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.DEFINE_LOCAL, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
    }

    /// Emit the Annex B.3.3 var-scope sync for a block-level function
    /// declaration; a no-op for declarations the extension does not apply to.
    pub fn emitAnnexBSync(self: *Self, decl: *ast.Node, line: u32) !void {
        if (!self.isAnnexBFunction(decl)) return;
        const sv = try val_mod.makeString(self.arena, decl.data.function_decl.name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.SYNC_ANNEXB_FN, line);
        try self.emitU16(kidx);
    }

    /// Emit a HOIST_LEX for `name` (declares it as an uninitialized lexical
    /// binding in TDZ at scope entry).
    pub fn emitHoistLexical(self: *Self, name: []const u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.HOIST_LEX, line);
        try self.emitU16(kidx);
    }

    /// Emit an INIT_LEX for `name` (initializes an existing lexical binding
    /// with R[rsrc], taking it out of TDZ). is_const=true marks the binding
    /// as immutable so later assignments throw TypeError.
    pub fn emitInitLexical(self: *Self, name: []const u8, rsrc: u8, line: u32, is_const: bool) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.INIT_LEX, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
        try self.emitU8(if (is_const) 1 else 0);
    }

    /// Emit EXIT_SCOPE for every block scope between the current depth and
    /// `target_depth` (exclusive). Used on `break`/`continue` jump paths so the
    /// frame env is unwound to the loop's level. Does NOT mutate
    /// `block_scope_depth` (textual nesting is unchanged; only the runtime jump
    /// path pops envs).
    pub fn emitExitScopesTo(self: *Self, target_depth: u32, line: u32) !void {
        var d = self.block_scope_depth;
        while (d > target_depth) : (d -= 1) {
            try self.emitOp(.EXIT_SCOPE, line);
        }
    }

    // -------------------------------------------------------- compile expr -> R ---

    /// Compile an expression, placing result in a NEW register (sp is bumped).
    /// Caller is responsible for calling freeReg() when done with the register.
    /// Returns the register index.
    pub fn compileExpr(self: *Self, node: *Node) error{OutOfMemory}!u8 {
        const line: u32 = node.start;
        switch (node.kind) {
            .number_literal => {
                const r = self.allocReg();
                const v = try val_mod.makeNumber(self.arena, node.data.number_literal);
                const kidx = try self.addConstant(v);
                try self.emitOp(.LOAD_K, line);
                try self.emitU8(r);
                try self.emitU16(kidx);
                return r;
            },
            .bigint_literal => {
                const r = self.allocReg();
                const v = val_mod.makeBigIntFromLiteral(self.arena, node.data.bigint_literal) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The lexer should only emit valid BigInt digits/radix; if a
                    // malformed literal slips through, fall back to 0n rather than
                    // crashing the process (such inputs are rejected at parse time).
                    else => val_mod.makeBigIntFromLiteral(self.arena, "0") catch return error.OutOfMemory,
                };
                const kidx = try self.addConstant(v);
                try self.emitOp(.LOAD_K, line);
                try self.emitU8(r);
                try self.emitU16(kidx);
                return r;
            },
            .string_literal => {
                const r = self.allocReg();
                const v = try val_mod.makeString(self.arena, node.data.string_literal);
                const kidx = try self.addConstant(v);
                try self.emitOp(.LOAD_K, line);
                try self.emitU8(r);
                try self.emitU16(kidx);
                return r;
            },
            .bool_literal => {
                const r = self.allocReg();
                if (node.data.bool_literal) {
                    try self.emitOp(.LOAD_TRUE, line);
                } else {
                    try self.emitOp(.LOAD_FALSE, line);
                }
                try self.emitU8(r);
                return r;
            },
            .null_literal => {
                const r = self.allocReg();
                try self.emitOp(.LOAD_NULL, line);
                try self.emitU8(r);
                return r;
            },
            .undefined_literal => {
                const r = self.allocReg();
                try self.emitOp(.LOAD_UNDEF, line);
                try self.emitU8(r);
                return r;
            },
            .identifier => {
                const r = self.allocReg();
                try self.emitLoad(node.data.identifier, r, line);
                return r;
            },
            .this_expr => {
                // Phase 3a: emit GET_THIS to retrieve current frame's this slot.
                const r = self.allocReg();
                try self.emitOp(.GET_THIS, line);
                try self.emitU8(r);
                return r;
            },
            .yield_expr => {
                // W2: `yield e` — evaluate e into r, suspend; on resume the VM
                // writes the sent value back into r (the expression's result).
                const r = if (node.data.yield_expr) |yn| try self.compileExpr(yn) else blk: {
                    const rr = self.allocReg();
                    try self.emitOp(.LOAD_UNDEF, line);
                    try self.emitU8(rr);
                    break :blk rr;
                };
                try self.emitOp(.YIELD, line);
                try self.emitU8(r);
                return r;
            },
            .unary_expr => return self.compileUnary(node.data.unary_expr, line),
            .binary_expr => return self.compileBinary(node.data.binary_expr, line),
            .logical_expr => return self.compileLogical(node.data.logical_expr, line),
            .assignment_expr => return self.compileAssign(node.data.assignment_expr, line),
            .update_expr => return self.compileUpdate(node.data.update_expr, line),
            .conditional_expr => return self.compileTernary(node.data.conditional_expr, line),
            .sequence_expr => {
                const se = node.data.sequence_expr;
                var last: u8 = 0;
                for (se.exprs, 0..) |e, i| {
                    const r = try self.compileExpr(e);
                    if (i < se.exprs.len - 1) {
                        self.freeReg(); // discard intermediate results
                    } else {
                        last = r;
                    }
                }
                return last;
            },
            .spread_expr => {
                return self.compileExpr(node.data.spread_expr);
            },
            .call_expr => return self.compileCall(node.data.call_expr, line, false),
            .function_expr => return self.compileFuncExpr(node.data.function_expr, line),
            .member_expr => {
                return self.compileMemberRead(node.data.member_expr, line);
            },
            .optional_chain => return self.compileOptionalChain(node.data.optional_chain, line),
            .object_literal => {
                return self.compileObjectLiteral(node.data.object_literal, line);
            },
            .array_literal => {
                return self.compileArrayLiteral(node.data.array_literal, line);
            },
            .new_expr => {
                // Phase 4a: NEW_INSTANCE Rdst base nargs
                // R[base] = constructor, R[base+1..base+nargs] = args
                const ne = node.data.new_expr;
                const base = self.sp;
                // `new C(...xs)`: an argument spread needs a runtime args array and
                // the spread-construct opcode (the static-nargs ABI can't expand it).
                var has_spread = false;
                for (ne.args) |a| {
                    if (a.kind == .spread_expr) {
                        has_spread = true;
                        break;
                    }
                }
                if (has_spread) {
                    const rcallee = try self.compileExpr(ne.callee);
                    const rargs = self.allocReg();
                    try self.emitOp(.NEW_ARRAY, line);
                    try self.emitU8(rargs);
                    try self.emitU8(0);
                    for (ne.args) |a| {
                        if (a.kind == .spread_expr) {
                            const riter = try self.compileExpr(a.data.spread_expr);
                            try self.emitOp(.ARRAY_SPREAD, line);
                            try self.emitU8(rargs);
                            try self.emitU8(riter);
                            self.freeReg();
                        } else {
                            const rval = try self.compileExpr(a);
                            try self.emitOp(.ARRAY_APPEND, line);
                            try self.emitU8(rargs);
                            try self.emitU8(rval);
                            self.freeReg();
                        }
                    }
                    try self.emitOp(.NEW_INSTANCE_SPREAD, line);
                    try self.emitU8(rcallee); // Rdst = rcallee (lowest slot)
                    try self.emitU8(rcallee);
                    try self.emitU8(rargs);
                    self.sp = rcallee + 1;
                    return rcallee;
                }
                // Compile constructor into R[base].
                _ = self.allocReg();
                self.sp = base;
                _ = try self.compileExpr(ne.callee);
                self.sp = base + 1;
                // Compile args.
                const nargs: u8 = @intCast(ne.args.len);
                for (ne.args) |a| {
                    _ = try self.compileExpr(a);
                }
                // Emit NEW_INSTANCE, result goes to R[base].
                try self.emitOp(.NEW_INSTANCE, line);
                try self.emitU8(base); // Rdst = base
                try self.emitU8(base); // callee at base
                try self.emitU8(nargs);
                self.sp = base + 1;
                return base;
            },
            .regex_literal => {
                // Phase 4c: compile regex literal as:
                //   R[base] = RegExp (constructor)
                //   R[base+1] = pattern string
                //   R[base+2] = flags string
                //   NEW_INSTANCE Rdst=base, base=base, nargs=2
                const rl = node.data.regex_literal;
                const base = self.sp;
                // Load RegExp constructor
                _ = self.allocReg();
                self.sp = base;
                try self.emitLoad("RegExp", base, line);
                self.sp = base + 1;
                // Load pattern
                const pat_val = try val_mod.makeString(self.arena, rl.pattern);
                const pat_kidx = try self.addConstant(pat_val);
                const r_pat = self.allocReg();
                try self.emitOp(.LOAD_K, line);
                try self.emitU8(r_pat);
                try self.emitU16(pat_kidx);
                // Load flags
                const flags_val = try val_mod.makeString(self.arena, rl.flags);
                const flags_kidx = try self.addConstant(flags_val);
                const r_flags = self.allocReg();
                try self.emitOp(.LOAD_K, line);
                try self.emitU8(r_flags);
                try self.emitU16(flags_kidx);
                // NEW_INSTANCE
                try self.emitOp(.NEW_INSTANCE, line);
                try self.emitU8(base); // Rdst = base
                try self.emitU8(base); // callee at base
                try self.emitU8(2); // nargs = 2
                self.sp = base + 1;
                return base;
            },
            else => {
                const r = self.allocReg();
                try self.emitOp(.LOAD_UNDEF, line);
                try self.emitU8(r);
                return r;
            },
        }
    }

    pub fn compileUnary(self: *Self, u: ast.UnaryExpr, line: u32) error{OutOfMemory}!u8 {
        switch (u.op) {
            .typeof_ => {
                // typeof: a bare identifier uses a tolerant load so an
                // undeclared name yields "undefined" instead of throwing a
                // ReferenceError. Other operands use the normal eval path.
                if (u.operand.kind == .identifier) {
                    const r = self.allocReg();
                    try self.emitLoadOpt(u.operand.data.identifier, r, line);
                    try self.emitOp(.TYPEOF, line);
                    try self.emitU8(r);
                    try self.emitU8(r);
                    return r;
                }
                const r_src = try self.compileExpr(u.operand);
                const r_dst = r_src;
                self.sp = r_src;
                self.sp += 1;
                try self.emitOp(.TYPEOF, line);
                try self.emitU8(r_dst);
                try self.emitU8(r_src);
                return r_dst;
            },
            .void_ => {
                const r = try self.compileExpr(u.operand);
                self.freeReg();
                _ = r;
                const rdst = self.allocReg();
                try self.emitOp(.LOAD_UNDEF, line);
                try self.emitU8(rdst);
                return rdst;
            },
            .delete_ => {
                const operand = u.operand;
                if (operand.kind == .member_expr) {
                    // `delete obj.prop` / `delete obj[expr]`: delete the own
                    // property and yield a boolean result.
                    const me = operand.data.member_expr;
                    // `delete super.x` / `delete super[e]` is always a ReferenceError
                    // (IsSuperReference). Thrown WITHOUT evaluating the base or the
                    // key expression (ES: ToPropertyKey/this-binding never reached).
                    if (me.object.kind == .identifier and std.mem.eql(u8, me.object.data.identifier, "super")) {
                        return try self.emitThrowError("ReferenceError", "Unsupported reference to 'super'", line);
                    }
                    const robj = try self.compileExpr(me.object);
                    if (me.computed) {
                        const rkey = try self.compileExpr(me.property);
                        try self.emitOp(.DELETE_PROP, line);
                        try self.emitU8(robj);
                        try self.emitU8(robj);
                        try self.emitU8(rkey);
                    } else {
                        const name = me.property.data.identifier;
                        const sv = try val_mod.makeString(self.arena, name);
                        const kidx = try self.addConstant(sv);
                        const rkey = self.allocReg();
                        try self.emitOp(.LOAD_K, line);
                        try self.emitU8(rkey);
                        try self.emitU16(kidx);
                        try self.emitOp(.DELETE_PROP, line);
                        try self.emitU8(robj);
                        try self.emitU8(robj);
                        try self.emitU8(rkey);
                    }
                    self.sp = robj + 1; // free key (and computed-key reg)
                    return robj;
                }
                // `delete <identifier>`: resolve the binding reference WITHOUT
                // evaluating its value (so `delete undeclared` never throws). The
                // boolean result depends on whether the binding is deletable.
                if (operand.kind == .identifier) {
                    const name = operand.data.identifier;
                    // `delete arguments` still references `arguments`, so the callee
                    // must materialize its (non-deletable) binding → result false.
                    if (std.mem.eql(u8, name, "arguments")) self.saw_arguments = true;
                    const sv = try val_mod.makeString(self.arena, name);
                    const kidx = try self.addConstant(sv);
                    const r = self.allocReg();
                    try self.emitOp(.DELETE_NAME, line);
                    try self.emitU8(r);
                    try self.emitU16(kidx);
                    return r;
                }
                // Deleting any other non-reference (e.g. `delete 1`, `delete f()`):
                // evaluate for side effects, result is `true`.
                _ = try self.compileExpr(operand);
                self.freeReg();
                const r = self.allocReg();
                try self.emitOp(.LOAD_TRUE, line);
                try self.emitU8(r);
                return r;
            },
            .neg => {
                const rsrc = try self.compileExpr(u.operand);
                const rdst = rsrc;
                self.sp = rsrc;
                self.sp += 1;
                try self.emitOp(.NEG, line);
                try self.emitU8(rdst);
                try self.emitU8(rsrc);
                return rdst;
            },
            .pos => {
                // Unary + is ToNumber(operand). A single TO_NUMBER does the
                // coercion in one step and, unlike the previous NEG,NEG lowering,
                // correctly throws a TypeError on a BigInt operand (`+1n`).
                const rsrc = try self.compileExpr(u.operand);
                const rdst = rsrc;
                self.sp = rsrc;
                self.sp += 1;
                try self.emitOp(.TO_NUMBER, line);
                try self.emitU8(rdst);
                try self.emitU8(rsrc);
                return rdst;
            },
            .not => {
                const rsrc = try self.compileExpr(u.operand);
                const rdst = rsrc;
                self.sp = rsrc;
                self.sp += 1;
                try self.emitOp(.NOT, line);
                try self.emitU8(rdst);
                try self.emitU8(rsrc);
                return rdst;
            },
            .bit_not => {
                const rsrc = try self.compileExpr(u.operand);
                const rdst = rsrc;
                self.sp = rsrc;
                self.sp += 1;
                try self.emitOp(.BIT_NOT, line);
                try self.emitU8(rdst);
                try self.emitU8(rsrc);
                return rdst;
            },
            .pre_inc => {
                // ++x: load x, add 1, store back, result is new value.
                const rsrc = try self.compileExpr(u.operand);
                try self.emitOp(.INC, line);
                try self.emitU8(rsrc);
                try self.emitU8(rsrc);
                // store back
                if (u.operand.kind == .identifier) {
                    try self.emitStore(u.operand.data.identifier, rsrc, line);
                }
                return rsrc;
            },
            .pre_dec => {
                const rsrc = try self.compileExpr(u.operand);
                try self.emitOp(.DEC, line);
                try self.emitU8(rsrc);
                try self.emitU8(rsrc);
                if (u.operand.kind == .identifier) {
                    try self.emitStore(u.operand.data.identifier, rsrc, line);
                }
                return rsrc;
            },
        }
    }

    pub fn compileBinary(self: *Self, b: ast.BinaryExpr, line: u32) error{OutOfMemory}!u8 {
        const rlhs = try self.compileExpr(b.left);
        const rrhs = try self.compileExpr(b.right);
        // Free both, then alloc result (we use rlhs as rdst to minimize register pressure).
        self.sp = rlhs;
        self.sp += 1; // reclaim rrhs slot
        const rdst = rlhs; // overwrite lhs register with result

        const op: Op = switch (b.op) {
            .add => .ADD,
            .sub => .SUB,
            .mul => .MUL,
            .div => .DIV,
            .mod => .MOD,
            .exp => .EXP,
            .lt => .LT,
            .lte => .LE,
            .gt => .GT,
            .gte => .GE,
            .eq => .EQ,
            .neq => .NEQ,
            .strict_eq => .SEQ,
            .strict_neq => .SNEQ,
            .bit_and => .BIT_AND,
            .bit_or => .BIT_OR,
            .bit_xor => .BIT_XOR,
            .lshift => .SHL,
            .rshift => .SHR,
            .urshift => .USHR,
            .instanceof => {
                // Phase 4a: real instanceof check.
                try self.emitOp(.INSTANCEOF, line);
                try self.emitU8(rdst);
                try self.emitU8(rlhs);
                try self.emitU8(rrhs);
                return rdst;
            },
            .in => {
                // `key in obj`: HasProperty(R[rrhs], R[rlhs]).
                try self.emitOp(.IN, line);
                try self.emitU8(rdst);
                try self.emitU8(rlhs);
                try self.emitU8(rrhs);
                return rdst;
            },
        };
        try self.emitOp(op, line);
        try self.emitU8(rdst);
        try self.emitU8(rlhs);
        try self.emitU8(rrhs);
        return rdst;
    }

    pub fn compileLogical(self: *Self, l: ast.LogicalExpr, line: u32) error{OutOfMemory}!u8 {
        const rlhs = try self.compileExpr(l.left);
        // The result register is rlhs.

        // JMP past rhs evaluation if short-circuit.
        const jump_op: Op = switch (l.op) {
            .and_ => .JMP_IF_FALSE,
            .or_ => .JMP_IF_TRUE,
            .nullish => .JMP_IF_NOT_NULLISH,
        };
        try self.emitOp(jump_op, line);
        try self.emitU8(rlhs);
        const patch_offset = self.currentOffset();
        try self.emitI16(0); // placeholder

        // If not short-circuiting, evaluate rhs and put into rlhs.
        self.freeReg(); // free rlhs temporarily
        const rrhs = try self.compileExpr(l.right);
        // Move rrhs into rlhs if they differ.
        if (rrhs != rlhs) {
            try self.emitOp(.MOVE, line);
            try self.emitU8(rlhs);
            try self.emitU8(rrhs);
            self.freeReg(); // free rrhs
            self.sp = rlhs + 1;
        }

        const end_offset = self.currentOffset();
        self.patchJump(patch_offset, end_offset);

        return rlhs;
    }

    pub fn compileTernary(self: *Self, ce: ast.CondExpr, line: u32) error{OutOfMemory}!u8 {
        const rcond = try self.compileExpr(ce.test_);
        self.freeReg(); // free condition register after test

        // JMP_IF_FALSE over then-branch.
        try self.emitOp(.JMP_IF_FALSE, line);
        try self.emitU8(rcond);
        const patch_else = self.currentOffset();
        try self.emitI16(0);

        // Then branch: result goes to r_result.
        const r_result = try self.compileExpr(ce.consequent);
        const saved_sp = self.sp;
        _ = saved_sp;

        // JMP over else branch.
        try self.emitOp(.JMP, line);
        const patch_end = self.currentOffset();
        try self.emitI16(0);

        const else_offset = self.currentOffset();
        self.patchJump(patch_else, else_offset);

        // Else branch: result must go to same register as then-branch.
        // Free r_result so else can allocate same slot.
        self.freeReg();
        const r_else = try self.compileExpr(ce.alternate);
        if (r_else != r_result) {
            try self.emitOp(.MOVE, line);
            try self.emitU8(r_result);
            try self.emitU8(r_else);
            self.freeReg();
            self.sp = r_result + 1;
        }

        const end_offset = self.currentOffset();
        self.patchJump(patch_end, end_offset);

        return r_result;
    }

    pub fn compileAssign(self: *Self, a: ast.AssignExpr, line: u32) error{OutOfMemory}!u8 {
        if (a.op == .assign) {
            // Peephole: x = x + 1 / x = x - 1 -> INC/DEC
            if (a.target.kind == .identifier and a.value.kind == .binary_expr) {
                const target_name = a.target.data.identifier;
                const b = a.value.data.binary_expr;
                if ((b.op == .add or b.op == .sub) and
                    b.left.kind == .identifier and
                    std.mem.eql(u8, b.left.data.identifier, target_name) and
                    b.right.kind == .number_literal and
                    b.right.data.number_literal == 1.0)
                {
                    const rsrc = try self.compileExpr(a.target);
                    try self.emitOp(if (b.op == .add) .INC else .DEC, line);
                    try self.emitU8(rsrc);
                    try self.emitU8(rsrc);
                    try self.emitStore(target_name, rsrc, line);
                    return rsrc;
                }
            }
            // NamedEvaluation: `x = function(){}` — inject binding name as hint.
            if (a.target.kind == .identifier and a.value.kind == .function_expr) {
                self.name_hint = a.target.data.identifier;
            }
            const rhs = try self.compileExpr(a.value);
            self.name_hint = null; // defensive clear (no-op if consumed inside)
            if (a.target.kind == .identifier) {
                try self.emitStore(a.target.data.identifier, rhs, line);
            } else if (a.target.kind == .member_expr) {
                try self.compileMemberWrite(a.target.data.member_expr, rhs, line);
            } else if (a.target.kind == .object_literal or a.target.kind == .array_literal) {
                // Destructuring assignment: `{ a: x, b } = rhs` / `[a, b] = rhs`.
                // The object/array literal node doubles as the assignment pattern.
                // The whole expression still evaluates to `rhs`, so keep it live.
                try self.compileDestructure(a.target, rhs, line);
                self.sp = rhs + 1;
            }
            return rhs;
        }
        // ES2021 logical assignment: short-circuit RHS + store.
        switch (a.op) {
            .logical_and, .logical_or, .logical_nullish => return self.compileLogicalAssign(a, line),
            else => {},
        }
        // Compound assignment.
        const rcur = try self.compileExpr(a.target);
        const rrhs = try self.compileExpr(a.value);
        self.sp = rcur;
        self.sp += 1;
        const rdst = rcur;

        const op: Op = switch (a.op) {
            .add => .ADD,
            .sub => .SUB,
            .mul => .MUL,
            .div => .DIV,
            .mod => .MOD,
            .exp => .EXP,
            .bit_and => .BIT_AND,
            .bit_or => .BIT_OR,
            .bit_xor => .BIT_XOR,
            .lshift => .SHL,
            .rshift => .SHR,
            .urshift => .USHR,
            .assign, .logical_and, .logical_or, .logical_nullish => unreachable,
        };
        try self.emitOp(op, line);
        try self.emitU8(rdst);
        try self.emitU8(rcur);
        try self.emitU8(rrhs);

        if (a.target.kind == .identifier) {
            try self.emitStore(a.target.data.identifier, rdst, line);
        } else if (a.target.kind == .member_expr) {
            try self.compileMemberWrite(a.target.data.member_expr, rdst, line);
        }
        return rdst;
    }

    /// Assign the value held in register `rsrc` to a destructuring pattern
    /// `target` (an object/array literal reused as an AssignmentPattern), or to a
    /// nested simple target (identifier / member / `pattern = default`). `rsrc`
    /// is read-only and must stay live for the caller; helpers only allocate
    /// registers above it. Array patterns read positionally (`rsrc[i]`), matching
    /// the index-based binding-declaration desugaring.
    /// Emit `__requireObjectCoercible__(R[rsrc])` — a spec RequireObjectCoercible
    /// guard that throws a TypeError when `rsrc` is null/undefined before a
    /// destructuring-assignment pattern reads it (matching the binding-pattern
    /// desugar, which the parser already routes through the same helper). `rsrc`
    /// is left untouched; the call result is discarded into a scratch register.
    fn emitRequireCoercible(self: *Self, rsrc: u8, line: u32) error{OutOfMemory}!void {
        const save_sp = self.sp;
        const callee = self.allocReg();
        const gi = try self.addConstant(try val_mod.makeString(self.arena, "__requireObjectCoercible__"));
        try self.emitOp(.GET_GLOBAL, line);
        try self.emitU8(callee);
        try self.emitU16(@intCast(gi));
        const arg = self.allocReg();
        try self.emitOp(.MOVE, line);
        try self.emitU8(arg);
        try self.emitU8(rsrc);
        try self.emitOp(.CALL, line);
        try self.emitU8(callee);
        try self.emitU8(1);
        try self.emitU8(callee); // discard result
        self.sp = save_sp;
    }

    /// Emit a call to a named global helper with one or two register arguments,
    /// writing the result into `dst` (which the caller has already allocated and
    /// keeps live below the scratch area). Drives the iterator-protocol
    /// destructuring helpers (__getIterator__ / __destrIterStep__ /
    /// __destrIterRest__ / __destrIterClose__) from the assignment-pattern path,
    /// mirroring the binding-pattern desugar in the parser.
    fn emitDestrCall(self: *Self, name: []const u8, r_a: u8, r_b: ?u8, dst: u8, line: u32) error{OutOfMemory}!void {
        const save_sp = self.sp;
        const callee = self.allocReg();
        const gi = try self.addConstant(try val_mod.makeString(self.arena, name));
        try self.emitOp(.GET_GLOBAL, line);
        try self.emitU8(callee);
        try self.emitU16(@intCast(gi));
        const a0 = self.allocReg(); // == callee + 1
        try self.emitOp(.MOVE, line);
        try self.emitU8(a0);
        try self.emitU8(r_a);
        var argc: u8 = 1;
        if (r_b) |rb| {
            const a1 = self.allocReg(); // == callee + 2
            try self.emitOp(.MOVE, line);
            try self.emitU8(a1);
            try self.emitU8(rb);
            argc = 2;
        }
        try self.emitOp(.CALL, line);
        try self.emitU8(callee);
        try self.emitU8(argc);
        try self.emitU8(dst); // result register (below callee, stays live)
        self.sp = save_sp;
    }

    pub fn compileDestructure(self: *Self, target: *Node, rsrc: u8, line: u32) error{OutOfMemory}!void {
        switch (target.kind) {
            .identifier => try self.emitStore(target.data.identifier, rsrc, line),
            .member_expr => try self.compileMemberWrite(target.data.member_expr, rsrc, line),
            .assignment_expr => {
                // `pattern = default`: substitute `default` only when `rsrc` is
                // `undefined` (a destructuring default does NOT apply to null).
                const ae = target.data.assignment_expr;
                if (ae.op != .assign) return; // only plain `=` is a valid default
                const rt = self.allocReg();
                try self.emitOp(.MOVE, line);
                try self.emitU8(rt);
                try self.emitU8(rsrc);
                // Compute `rt === undefined` and skip the default-load when false.
                const rundef = self.allocReg();
                try self.emitOp(.LOAD_UNDEF, line);
                try self.emitU8(rundef);
                const rcond = self.allocReg();
                try self.emitOp(.SEQ, line);
                try self.emitU8(rcond);
                try self.emitU8(rt);
                try self.emitU8(rundef);
                try self.emitOp(.JMP_IF_FALSE, line);
                try self.emitU8(rcond);
                const patch = self.currentOffset();
                try self.emitI16(0);
                self.sp = rt + 1; // free rundef/rcond (already consumed) before default expr
                // NamedEvaluation: `[a = function(){}] = rhs` names the anonymous
                // default "a" (only when the target is a plain identifier).
                if (ae.target.kind == .identifier and ae.value.kind == .function_expr)
                    self.name_hint = ae.target.data.identifier;
                const rd = try self.compileExpr(ae.value);
                self.name_hint = null;
                try self.emitOp(.MOVE, line);
                try self.emitU8(rt);
                try self.emitU8(rd);
                self.sp = rt + 1; // free any regs the default expr used
                self.patchJump(patch, self.currentOffset());
                try self.compileDestructure(ae.target, rt, line);
                self.sp = rt; // free rt
            },
            .object_literal => {
                // `({a} = null)` / `for ({a} of [null])`: destructuring null or
                // undefined throws before any property read.
                try self.emitRequireCoercible(rsrc, line);
                for (target.data.object_literal.properties) |prop| {
                    if (prop.kind != .init) continue; // patterns carry only data props
                    const rval = self.allocReg();
                    if (prop.computed_key) |key_node| {
                        const rkey = try self.compileExpr(key_node);
                        try self.emitOp(.GET_PROP_DYN, line);
                        try self.emitU8(rval);
                        try self.emitU8(rsrc);
                        try self.emitU8(rkey);
                        self.sp = rval + 1; // free rkey
                    } else {
                        const sv = try val_mod.makeString(self.arena, prop.key);
                        const kidx = try self.addConstant(sv);
                        try self.emitOp(.GET_PROP, line);
                        try self.emitU8(rval);
                        try self.emitU8(rsrc);
                        try self.emitU16(kidx);
                    }
                    try self.compileDestructure(prop.value, rval, line);
                    self.sp = rval; // free rval
                }
            },
            .array_literal => {
                // ES ArrayAssignmentPattern: destructure through the iterator
                // protocol (GetIterator → IteratorStep per element → IteratorClose
                // when the pattern finishes before the iterator is exhausted),
                // reusing the shared runtime helpers so custom @@iterator methods,
                // non-array iterables, holes, defaults and `...rest` all behave per
                // spec rather than via positional index reads. A nullish `rsrc`
                // throws a TypeError inside __getIterator__ (GetIterator does the
                // RequireObjectCoercible check), so no separate guard is needed.
                // `__box` ({}) tracks done-ness across the helper calls, matching
                // the binding-pattern desugar's straight-line lowering.
                const elems = target.data.array_literal.elements;
                const rit = self.allocReg();
                try self.emitDestrCall("__getIterator__", rsrc, null, rit, line);
                const rbox = self.allocReg();
                try self.emitOp(.NEW_OBJECT, line);
                try self.emitU8(rbox);
                var saw_rest = false;
                for (elems) |elem| {
                    // Elision hole (`[, x] = rhs`): advance one step, discard.
                    if (elem.kind == .array_hole) {
                        const scratch = self.allocReg();
                        try self.emitDestrCall("__destrIterStep__", rit, rbox, scratch, line);
                        self.sp = scratch; // free scratch
                        continue;
                    }
                    if (elem.kind == .spread_expr) {
                        // Rest `...t = rhs`: collect the remaining values into a
                        // fresh Array. Must be final; no IteratorClose follows.
                        const rrest = self.allocReg();
                        try self.emitDestrCall("__destrIterRest__", rit, rbox, rrest, line);
                        try self.compileDestructure(elem.data.spread_expr, rrest, line);
                        self.sp = rrest; // free rrest
                        saw_rest = true;
                        break;
                    }
                    // Normal element: one IteratorStep into a temp, then assign
                    // (handles identifier / member / default / nested sub-pattern).
                    const rstep = self.allocReg();
                    try self.emitDestrCall("__destrIterStep__", rit, rbox, rstep, line);
                    try self.compileDestructure(elem, rstep, line);
                    self.sp = rstep; // free rstep
                }
                if (!saw_rest) {
                    const scratch = self.allocReg();
                    try self.emitDestrCall("__destrIterClose__", rit, rbox, scratch, line);
                    self.sp = scratch; // free scratch
                }
                self.sp = rit; // free rit + rbox
            },
            else => {}, // unsupported pattern element: leave unassigned
        }
    }

    /// ES2021 logical assignment (`&&=`, `||=`, `??=`). Short-circuits: reads the
    /// target, and only evaluates+stores the RHS when the condition holds. The
    /// result register always ends up holding either the original or new value.
    pub fn compileLogicalAssign(self: *Self, a: ast.AssignExpr, line: u32) error{OutOfMemory}!u8 {
        // Skip RHS+store when the condition is NOT met (result stays = current value).
        const skip_op: Op = switch (a.op) {
            .logical_and => .JMP_IF_FALSE, // &&=: only assign if truthy
            .logical_or => .JMP_IF_TRUE, // ||=: only assign if falsy
            .logical_nullish => .JMP_IF_NOT_NULLISH, // ??=: only assign if nullish
            else => unreachable,
        };
        if (a.target.kind == .member_expr) return self.compileLogicalAssignMember(a, skip_op, line);

        const rcur = try self.compileExpr(a.target);
        try self.emitOp(skip_op, line);
        try self.emitU8(rcur);
        const patch_end = self.currentOffset();
        try self.emitI16(0);

        // Assign branch: evaluate RHS into rcur's slot, store, keep result in rcur.
        self.freeReg(); // free rcur slot so RHS can reuse it
        // NamedEvaluation: `ident &&= function(){}` / `... ??= () => {}` names the
        // anonymous function after the identifier target (ES step "If
        // IsAnonymousFunctionDefinition(rhs) and IsIdentifierRef(lhs)").
        if (a.target.kind == .identifier and a.value.kind == .function_expr) {
            self.name_hint = a.target.data.identifier;
        }
        const rrhs = try self.compileExpr(a.value);
        self.name_hint = null; // defensive clear (no-op if consumed inside)
        if (a.target.kind == .identifier) {
            try self.emitStore(a.target.data.identifier, rrhs, line);
        }
        if (rrhs != rcur) {
            try self.emitOp(.MOVE, line);
            try self.emitU8(rcur);
            try self.emitU8(rrhs);
            self.sp = rcur + 1;
        }

        const end = self.currentOffset();
        self.patchJump(patch_end, end);
        return rcur;
    }

    /// Logical assignment with a member target (`obj.p &&= v` / `obj[k()] ??= v`).
    /// ES evaluates the LeftHandSideExpression's reference exactly ONCE (before the
    /// RHS): the object and, for a computed access, the property key are each
    /// evaluated a single time, then reused for both the read (GetValue) and, on
    /// the assign branch, the write (PutValue). This also makes a nullish base
    /// throw a TypeError before the RHS runs, per RequireObjectCoercible.
    fn compileLogicalAssignMember(self: *Self, a: ast.AssignExpr, skip_op: Op, line: u32) error{OutOfMemory}!u8 {
        const me = a.target.data.member_expr;
        const robj = try self.compileExpr(me.object);
        // Resolve the key once: a static/literal key is a constant; a computed
        // expression key is evaluated into its own register (single evaluation).
        var static_kidx: ?u16 = null;
        var rkey: u8 = 0;
        if (!me.computed) {
            static_kidx = try self.addConstant(try val_mod.makeString(self.arena, me.property.data.identifier));
        } else if (me.property.kind == .string_literal) {
            static_kidx = try self.addConstant(try val_mod.makeString(self.arena, me.property.data.string_literal));
        } else if (me.property.kind == .number_literal) {
            const key_str = std.fmt.allocPrint(self.arena, "{d}", .{me.property.data.number_literal}) catch return error.OutOfMemory;
            static_kidx = try self.addConstant(try val_mod.makeString(self.arena, key_str));
        } else {
            rkey = try self.compileExpr(me.property);
        }

        // Read current value into rcur.
        const rcur = self.allocReg();
        if (static_kidx) |kidx| {
            try self.emitOp(.GET_PROP, line);
            try self.emitU8(rcur);
            try self.emitU8(robj);
            try self.emitU16(kidx);
        } else {
            try self.emitOp(.GET_PROP_DYN, line);
            try self.emitU8(rcur);
            try self.emitU8(robj);
            try self.emitU8(rkey);
        }

        // Short-circuit: on the skip path the result stays the current value.
        try self.emitOp(skip_op, line);
        try self.emitU8(rcur);
        const patch_end = self.currentOffset();
        try self.emitI16(0);

        // Assign branch: evaluate RHS, write back through the SAME object/key.
        const rrhs = try self.compileExpr(a.value);
        if (static_kidx) |kidx| {
            try self.emitOp(.SET_PROP, line);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            try self.emitU8(rrhs);
        } else {
            try self.emitOp(.SET_PROP_DYN, line);
            try self.emitU8(robj);
            try self.emitU8(rkey);
            try self.emitU8(rrhs);
        }
        try self.emitOp(.MOVE, line);
        try self.emitU8(rcur);
        try self.emitU8(rrhs);

        const end = self.currentOffset();
        self.patchJump(patch_end, end);
        // Collapse the result down to the base register (where compilation
        // started), matching the single-result-register convention of other
        // expression compilers; free the object/key/rhs scratch above it.
        try self.emitOp(.MOVE, line);
        try self.emitU8(robj);
        try self.emitU8(rcur);
        self.sp = robj + 1;
        return robj;
    }

    pub fn compileMemberRead(self: *Self, me: ast.MemberExpr, line: u32) error{OutOfMemory}!u8 {
        const robj = try self.compileExpr(me.object);
        // ES2020 `obj?.prop`: short-circuit the whole chain if obj is nullish.
        if (me.optional) try self.emitOptionalGuard(robj, line);
        if (!me.computed) {
            // Static member access: GET_PROP Rdst Robj K"name"
            const prop_name = me.property.data.identifier;
            const sv = try val_mod.makeString(self.arena, prop_name);
            const kidx = try self.addConstant(sv);
            const rdst = robj; // reuse object register slot
            self.sp = robj;
            self.sp += 1;
            try self.emitOp(.GET_PROP, line);
            try self.emitU8(rdst);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            return rdst;
        } else {
            // Computed with literal key can still be static.
            if (me.property.kind == .string_literal) {
                const prop_name = me.property.data.string_literal;
                const sv = try val_mod.makeString(self.arena, prop_name);
                const kidx = try self.addConstant(sv);
                const rdst = robj;
                self.sp = robj;
                self.sp += 1;
                try self.emitOp(.GET_PROP, line);
                try self.emitU8(rdst);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                return rdst;
            }
            if (me.property.kind == .number_literal) {
                const key_str = std.fmt.allocPrint(self.arena, "{d}", .{
                    me.property.data.number_literal,
                }) catch return error.OutOfMemory;
                const sv = try val_mod.makeString(self.arena, key_str);
                const kidx = try self.addConstant(sv);
                const rdst = robj;
                self.sp = robj;
                self.sp += 1;
                try self.emitOp(.GET_PROP, line);
                try self.emitU8(rdst);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                return rdst;
            }
            // Dynamic member access: GET_PROP_DYN Rdst Robj Rkey
            const rkey = try self.compileExpr(me.property);
            const rdst = robj;
            self.sp = robj;
            self.sp += 1;
            try self.emitOp(.GET_PROP_DYN, line);
            try self.emitU8(rdst);
            try self.emitU8(robj);
            try self.emitU8(rkey);
            return rdst;
        }
    }

    /// Compile an ES2020 optional chain. Establishes the short-circuit boundary:
    /// every optional link emits a JMP_IF_NULLISH guard (via emitOptionalGuard)
    /// recorded in a fresh jump list; on short-circuit they all land on a pad that
    /// loads `undefined` into the chain's result register. The chain result always
    /// lives in the base register where the chain started, so a single
    /// LOAD_UNDEF restores a consistent result.
    pub fn compileOptionalChain(self: *Self, inner: *Node, line: u32) error{OutOfMemory}!u8 {
        var jumps: std.ArrayListUnmanaged(usize) = .empty;
        const saved = self.optional_jumps;
        self.optional_jumps = &jumps;

        const rres = try self.compileExpr(inner);

        // Skip the short-circuit pad on the normal (non-nullish) path.
        try self.emitOp(.JMP, line);
        const patch_end = self.currentOffset();
        try self.emitI16(0);

        // Short-circuit landing pad: every optional guard jumps here.
        const pad = self.currentOffset();
        for (jumps.items) |patch| self.patchJump(patch, pad);
        try self.emitOp(.LOAD_UNDEF, line);
        try self.emitU8(rres);

        const end = self.currentOffset();
        self.patchJump(patch_end, end);

        self.optional_jumps = saved;
        return rres;
    }

    pub fn compileMemberWrite(self: *Self, me: ast.MemberExpr, rval: u8, line: u32) error{OutOfMemory}!void {
        const robj = try self.compileExpr(me.object);
        if (!me.computed) {
            const prop_name = me.property.data.identifier;
            const sv = try val_mod.makeString(self.arena, prop_name);
            const kidx = try self.addConstant(sv);
            // Class-desugar private-element installation: create the element
            // rather than requiring an existing one (PrivateFieldAdd).
            try self.emitOp(if (me.private_define) .DEFINE_PRIVATE else .SET_PROP, line);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            try self.emitU8(rval);
            if (me.private_define) try self.emitU8(@intFromBool(me.private_method));
        } else {
            if (me.property.kind == .string_literal) {
                const prop_name = me.property.data.string_literal;
                const sv = try val_mod.makeString(self.arena, prop_name);
                const kidx = try self.addConstant(sv);
                try self.emitOp(.SET_PROP, line);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                try self.emitU8(rval);
                self.freeReg(); // free robj
                return;
            }
            if (me.property.kind == .number_literal) {
                const key_str = std.fmt.allocPrint(self.arena, "{d}", .{
                    me.property.data.number_literal,
                }) catch return error.OutOfMemory;
                const sv = try val_mod.makeString(self.arena, key_str);
                const kidx = try self.addConstant(sv);
                try self.emitOp(.SET_PROP, line);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                try self.emitU8(rval);
                self.freeReg(); // free robj
                return;
            }
            const rkey = try self.compileExpr(me.property);
            try self.emitOp(.SET_PROP_DYN, line);
            try self.emitU8(robj);
            try self.emitU8(rkey);
            try self.emitU8(rval);
            self.freeReg(); // free rkey
        }
        self.freeReg(); // free robj
    }

    pub fn compileObjectLiteral(self: *Self, ol: ast.ObjectLiteral, line: u32) error{OutOfMemory}!u8 {
        const robj = self.allocReg();
        try self.emitOp(.NEW_OBJECT, line);
        try self.emitU8(robj);

        for (ol.properties) |prop| {
            // ES2018 object-literal spread `{...expr}`: parsed as an ObjectProp
            // whose `value` is a `.spread_expr` node (key/computed_key unused).
            // Compile the operand, then call the `__objSpreadInto__` runtime
            // helper to CopyDataProperties directly into `robj` (mutates in
            // place; later properties in source order still override, since
            // this call happens exactly where the spread sits in the loop).
            if (prop.value.kind == .spread_expr) {
                const base_sp = self.sp;
                const b = self.allocReg();
                const c_helper = try self.addConstant(try val_mod.makeString(self.arena, "__objSpreadInto__"));
                try self.emitOp(.GET_GLOBAL, line);
                try self.emitU8(b);
                try self.emitU16(@intCast(c_helper));
                const a1 = self.allocReg();
                try self.emitOp(.MOVE, line);
                try self.emitU8(a1);
                try self.emitU8(robj);
                _ = try self.compileExpr(prop.value.data.spread_expr);
                try self.emitOp(.CALL, line);
                try self.emitU8(b);
                try self.emitU8(2);
                try self.emitU8(b);
                self.sp = base_sp;
                continue;
            }
            // ES6 computed key `{ [expr]: value }`: evaluate key at runtime and
            // set dynamically (handles symbol keys).
            if (prop.computed_key) |key_node| {
                const rkey = try self.compileExpr(key_node);
                const rval = try self.compileExpr(prop.value);
                if (prop.kind == .init) {
                    try self.emitOp(.SET_PROP_DYN, line);
                    try self.emitU8(robj);
                    try self.emitU8(rkey);
                    try self.emitU8(rval);
                } else {
                    // Computed accessor key: `{ get [expr]() {} }`.
                    try self.emitOp(.DEFINE_ACCESSOR_DYN, line);
                    try self.emitU8(robj);
                    try self.emitU8(rkey);
                    try self.emitU8(if (prop.kind == .get) @as(u8, 0) else @as(u8, 1));
                    try self.emitU8(rval);
                }
                self.freeReg(); // free rval
                self.freeReg(); // free rkey
                continue;
            }
            // NamedEvaluation: `{key: function(){}}` data property — inject key as hint.
            if (prop.kind == .init and prop.value.kind == .function_expr) {
                self.name_hint = prop.key;
            }
            const rval = try self.compileExpr(prop.value);
            self.name_hint = null; // defensive clear (no-op if consumed inside)
            const sv = try val_mod.makeString(self.arena, prop.key);
            const kidx = try self.addConstant(sv);
            if (prop.kind == .init) {
                try self.emitOp(.SET_PROP, line);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                try self.emitU8(rval);
            } else {
                try self.emitOp(.DEFINE_ACCESSOR, line);
                try self.emitU8(robj);
                try self.emitU16(kidx);
                try self.emitU8(if (prop.kind == .get) @as(u8, 0) else @as(u8, 1));
                try self.emitU8(rval);
            }
            self.freeReg(); // free rval
        }
        return robj;
    }

    pub fn compileArrayLiteral(self: *Self, al: ast.ArrayLiteral, line: u32) error{OutOfMemory}!u8 {
        const len_hint: u8 = if (al.elements.len <= 255) @intCast(al.elements.len) else 255;
        const robj = self.allocReg();
        try self.emitOp(.NEW_ARRAY, line);
        try self.emitU8(robj);
        try self.emitU8(len_hint);

        // Append every element in source order. Elisions (`[1,,3]`) become real
        // holes via ARRAY_APPEND_HOLE (length grows, no index created); spreads
        // expand via ARRAY_SPREAD. Using the integer-index append opcodes avoids
        // the per-element decimal-key string a SET_PROP path would allocate.
        var i: usize = 0;
        while (i < al.elements.len) {
            const elem = al.elements[i];
            if (elem.kind == .array_hole) {
                // Coalesce a run of consecutive holes into count-bearing ops
                // (a u8 count per op; a run longer than 255 emits several).
                var run: usize = 0;
                while (i < al.elements.len and al.elements[i].kind == .array_hole) : (i += 1) run += 1;
                while (run > 0) {
                    const c: u8 = if (run > 255) 255 else @intCast(run);
                    try self.emitOp(.ARRAY_APPEND_HOLE, line);
                    try self.emitU8(robj);
                    try self.emitU8(c);
                    run -= c;
                }
                continue;
            }
            if (elem.kind == .spread_expr) {
                const riter = try self.compileExpr(elem.data.spread_expr);
                try self.emitOp(.ARRAY_SPREAD, line);
                try self.emitU8(robj);
                try self.emitU8(riter);
                self.freeReg(); // free riter
            } else {
                const rval = try self.compileExpr(elem);
                try self.emitOp(.ARRAY_APPEND, line);
                try self.emitU8(robj);
                try self.emitU8(rval);
                self.freeReg(); // free rval
            }
            i += 1;
        }
        return robj;
    }

    /// Emit `throw new <CtorName>(<msg>)` and leave the constructed error in the
    /// returned register. Used for runtime-thrown early-ish errors the evaluator
    /// must raise without evaluating the surrounding operands (e.g. `delete
    /// super.x` → ReferenceError, which never touches the base object or key).
    fn emitThrowError(self: *Self, ctor_name: []const u8, msg: []const u8, line: u32) error{OutOfMemory}!u8 {
        const base = self.sp;
        _ = self.allocReg();
        self.sp = base;
        try self.emitLoad(ctor_name, base, line); // error constructor at R[base]
        self.sp = base + 1;
        const rmsg = self.allocReg();
        const kidx = try self.addConstant(try val_mod.makeString(self.arena, msg));
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rmsg);
        try self.emitU16(kidx);
        self.sp = base + 2;
        try self.emitOp(.NEW_INSTANCE, line);
        try self.emitU8(base); // Rdst = base
        try self.emitU8(base); // callee at base
        try self.emitU8(1); // nargs
        self.sp = base + 1;
        try self.emitOp(.THROW, line);
        try self.emitU8(base);
        return base;
    }

    pub fn compileUpdate(self: *Self, u: ast.UpdateExpr, line: u32) error{OutOfMemory}!u8 {
        const r_old = try self.compileExpr(u.operand);

        if (u.prefix) {
            // Pre: compute new value, store, return new.
            const r_new = r_old;
            try self.emitOp(if (u.op == .inc) .INC else .DEC, line);
            try self.emitU8(r_new);
            try self.emitU8(r_old);
            if (u.operand.kind == .identifier) {
                try self.emitStore(u.operand.data.identifier, r_new, line);
            } else if (u.operand.kind == .member_expr) {
                // Write the incremented value back to `obj.prop` / `obj[key]`.
                // compileMemberWrite re-evaluates the object/key above r_new (it
                // never clobbers r_new), matching the compound-assign lowering.
                try self.compileMemberWrite(u.operand.data.member_expr, r_new, line);
            }
            return r_new;
        } else {
            // Post: compute new value, store, return OLD (coerced to numeric).
            // ES UpdateExpression: `oldValue := ? ToNumeric(GetValue(lhs))`, so
            // the returned old value must be the *numeric* coercion of the
            // operand (e.g. `new Boolean(true)` → 1), not the raw operand. Coerce
            // once into r_old (running any valueOf/@@toPrimitive exactly once);
            // INC/DEC on the already-numeric r_old runs no further user code.
            try self.emitOp(.TO_NUMERIC, line);
            try self.emitU8(r_old);
            try self.emitU8(r_old);
            const r_scratch = self.allocReg();
            try self.emitOp(if (u.op == .inc) .INC else .DEC, line);
            try self.emitU8(r_scratch);
            try self.emitU8(r_old);
            if (u.operand.kind == .identifier) {
                try self.emitStore(u.operand.data.identifier, r_scratch, line);
            } else if (u.operand.kind == .member_expr) {
                // Write the incremented value back to the member target while
                // returning the pre-increment value held in r_old.
                try self.compileMemberWrite(u.operand.data.member_expr, r_scratch, line);
            }
            self.freeReg(); // free r_scratch
            return r_old; // return old (numeric) value
        }
    }

    /// Sync `yield* rhs` with full next/throw/return forwarding (ES
    /// YieldExpression delegation). Drives the inner iterator via
    /// `__yieldStarStep__`, yields each value, and forwards the resume completion
    /// (normal sent value / `throw` / `return`) back to the inner iterator.
    fn compileYieldStar(self: *Self, rhs: *Node, line: u32) error{OutOfMemory}!u8 {
        const lower = @import("./lower/stmt.zig");
        const base_sp = self.sp;
        // riter = __getIterator__(rhs)
        const riter = self.allocReg();
        {
            const b = self.allocReg();
            self.sp = b;
            const gi = try self.builder.addConstant(try val_mod.makeString(self.arena, "__getIterator__"));
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(gi));
            self.sp = b + 1;
            _ = try self.compileExpr(rhs);
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(1);
            try self.emitU8(riter);
            self.sp = riter + 1;
        }
        const rtype = self.allocReg();
        const rval = self.allocReg();
        const rstep = self.allocReg();
        const rresult = self.allocReg();
        const rret = self.allocReg();
        const rdone = self.allocReg();
        const rraw = self.allocReg();
        const loop_top = self.sp;
        const k0 = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 0));
        const k1 = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 1));
        const k2 = try self.builder.addConstant(try val_mod.makeNumber(self.arena, 2));
        const c_step = try self.builder.addConstant(try val_mod.makeString(self.arena, "__yieldStarStep__"));
        const c_rcv = try self.builder.addConstant(try val_mod.makeString(self.arena, "__retComplVal__"));
        const c_ret = try self.builder.addConstant(try val_mod.makeString(self.arena, "ret"));
        const c_val = try self.builder.addConstant(try val_mod.makeString(self.arena, "value"));
        const c_done = try self.builder.addConstant(try val_mod.makeString(self.arena, "done"));
        const c_raw = try self.builder.addConstant(try val_mod.makeString(self.arena, "raw"));
        // rtype = 0 (normal); rval = undefined
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rtype);
        try self.emitI16(@intCast(k0));
        try self.emitOp(.LOAD_UNDEF, line);
        try self.emitU8(rval);

        const loop_start = self.currentOffset();
        // rstep = __yieldStarStep__(riter, rtype, rval)
        {
            const b = self.allocReg();
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(c_step));
            const a1 = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(a1);
            try self.emitU8(riter);
            const a2 = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(a2);
            try self.emitU8(rtype);
            const a3 = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(a3);
            try self.emitU8(rval);
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(3);
            try self.emitU8(rstep);
            self.sp = loop_top;
        }
        // rret = rstep.ret; rresult = rstep.value; rdone = rstep.done
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rret);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(c_ret));
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rresult);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(c_val));
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rdone);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(c_done));
        // rraw = rstep.raw — the inner iterator result object, yielded verbatim
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rraw);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(c_raw));
        // if rret → the outer generator returns rresult
        try self.emitOp(.JMP_IF_TRUE, line);
        try self.emitU8(rret);
        const ret_patch = self.currentOffset();
        try self.emitI16(0);
        // if rdone → yield* completes with rresult
        try self.emitOp(.JMP_IF_TRUE, line);
        try self.emitU8(rdone);
        const exit_patch = self.currentOffset();
        try self.emitI16(0);
        // yield rresult; capture the resume completion (throw / return-completion
        // land at the catch via PUSH_TRY; a normal resume falls through).
        try self.emitOp(.PUSH_TRY, line);
        try self.emitU8(rresult);
        const catch_patch = self.currentOffset();
        try self.emitI16(0);
        // YIELD_STAR rraw: surface the inner result object to the consumer
        // verbatim. On normal resume the sent value lands back in rraw.
        try self.emitOp(.YIELD_STAR, line);
        try self.emitU8(rraw);
        try self.emitOp(.POP_TRY, line);
        // normal resume: rval = sent value; rtype = 0
        try self.emitOp(.MOVE, line);
        try self.emitU8(rval);
        try self.emitU8(rraw);
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rtype);
        try self.emitI16(@intCast(k0));
        try self.emitOp(.JMP, line);
        const back1 = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back1, loop_start);
        // catch: rresult holds the injected exception / return-completion
        self.patchJump(catch_patch, self.currentOffset());
        try self.emitOp(.JMP_IF_RET_COMPL, line);
        try self.emitU8(rresult);
        const rc_patch = self.currentOffset();
        try self.emitI16(0);
        // throw resume: rval = exception; rtype = 1
        try self.emitOp(.MOVE, line);
        try self.emitU8(rval);
        try self.emitU8(rresult);
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rtype);
        try self.emitI16(@intCast(k1));
        try self.emitOp(.JMP, line);
        const back2 = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back2, loop_start);
        // return-completion resume: rval = __retComplVal__(rresult); rtype = 2
        self.patchJump(rc_patch, self.currentOffset());
        {
            const b = self.allocReg();
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(c_rcv));
            const a1 = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(a1);
            try self.emitU8(rresult);
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(1);
            try self.emitU8(rval);
            self.sp = loop_top;
        }
        try self.emitOp(.LOAD_K, line);
        try self.emitU8(rtype);
        try self.emitI16(@intCast(k2));
        try self.emitOp(.JMP, line);
        const back3 = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back3, loop_start);
        // ret: the outer generator returns rresult (run finally first)
        self.patchJump(ret_patch, self.currentOffset());
        try lower.runPendingFinally(self, rresult, 0, line);
        try self.emitOp(.RETURN, line);
        try self.emitU8(rresult);
        // exit: yield* evaluates to rresult
        self.patchJump(exit_patch, self.currentOffset());
        try self.emitOp(.MOVE, line);
        try self.emitU8(base_sp);
        try self.emitU8(rresult);
        self.sp = base_sp + 1;
        return base_sp;
    }

    /// Async `yield* rhs` inside an `async function*`: delegate over the async
    /// iterator, awaiting each step. (next-only; resume completions not yet
    /// forwarded to the inner async iterator.)
    fn compileAsyncYieldStar(self: *Self, rhs: *Node, line: u32) error{OutOfMemory}!u8 {
        const base_sp = self.sp;
        const riter = self.allocReg();
        {
            const b = self.allocReg();
            self.sp = b;
            const gi = try self.builder.addConstant(try val_mod.makeString(self.arena, "__getAsyncIterator__"));
            try self.emitOp(.GET_GLOBAL, line);
            try self.emitU8(b);
            try self.emitU16(@intCast(gi));
            self.sp = b + 1;
            _ = try self.compileExpr(rhs);
            try self.emitOp(.CALL, line);
            try self.emitU8(b);
            try self.emitU8(1);
            try self.emitU8(riter);
            self.sp = riter + 1;
        }
        const rstep = self.allocReg();
        const rresult = self.allocReg();
        const loop_start = self.currentOffset();
        {
            const b = self.allocReg();
            const si = try self.builder.addConstant(try val_mod.makeString(self.arena, "__asyncIterStep__"));
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
            try self.emitOp(.AWAIT, line);
            try self.emitU8(rstep);
            self.sp = rresult + 1;
        }
        const vi = try self.builder.addConstant(try val_mod.makeString(self.arena, "value"));
        try self.emitOp(.GET_PROP, line);
        try self.emitU8(rresult);
        try self.emitU8(rstep);
        try self.emitU16(@intCast(vi));
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
        self.sp = rresult + 1;
        try self.emitOp(.YIELD, line);
        try self.emitU8(rresult);
        try self.emitOp(.JMP, line);
        const back = self.currentOffset();
        try self.emitI16(0);
        self.patchJump(back, loop_start);
        self.patchJump(patch_exit, self.currentOffset());
        try self.emitOp(.MOVE, line);
        try self.emitU8(base_sp);
        try self.emitU8(rresult);
        self.sp = base_sp + 1;
        return base_sp;
    }

    pub fn compileCall(self: *Self, c: ast.CallExpr, line: u32, tail: bool) error{OutOfMemory}!u8 {
        // W2-async: inside an async function `await x` is parsed as __await__(x).
        // Compile it as a YIELD suspend: evaluate x into r, suspend; the async
        // driver resumes with the resolved value written back into r. Outside an
        // async function `__await__` stays a synchronous-drain native call.
        if (self.is_async and c.callee.kind == .identifier and
            std.mem.eql(u8, c.callee.data.identifier, "__await__") and c.args.len == 1)
        {
            const r = try self.compileExpr(c.args[0]);
            // Async generators tag awaits as AWAIT so the driver distinguishes
            // them from yields; plain async functions keep YIELD.
            try self.emitOp(if (self.is_async_generator) .AWAIT else .YIELD, line);
            try self.emitU8(r);
            return r;
        }
        // W2: `yield* x` is parsed as __yield_star__(x). Compiled inline as a
        // delegation loop so the YIELD suspends the enclosing generator.
        if (c.callee.kind == .identifier and std.mem.eql(u8, c.callee.data.identifier, "__yield_star__") and c.args.len == 1) {
            if (self.is_async_generator) return try self.compileAsyncYieldStar(c.args[0], line);
            return try self.compileYieldStar(c.args[0], line);
        }
        // Call-argument spread: `f(...xs)` / `obj.m(a, ...xs)` build a runtime
        // args array and dispatch via CALL_SPREAD (the static-nargs CALL ABI
        // cannot express a variable argument count).
        for (c.args) |a| {
            if (a.kind == .spread_expr) return try self.compileCallSpread(c, line);
        }

        const is_method = c.callee.kind == .member_expr;

        if (is_method) {
            // METHOD_CALL layout:
            // R[base]   = this object
            // R[base+1] = function value (resolved property)
            // R[base+2..base+1+nargs] = args
            const base = self.sp;

            // Compile object into R[base].
            const me = c.callee.data.member_expr;
            _ = self.allocReg(); // reserve base
            self.sp = base;
            const robj = try self.compileExpr(me.object);
            _ = robj;
            self.sp = base + 1;

            // ES2020 `a?.b()`: short-circuit if the object is nullish.
            if (me.optional) try self.emitOptionalGuard(base, line);

            // Compile the property read into R[base+1].
            _ = self.allocReg(); // reserve base+1
            self.sp = base + 1;
            if (!me.computed) {
                const prop_name = me.property.data.identifier;
                const sv = try val_mod.makeString(self.arena, prop_name);
                const kidx = try self.addConstant(sv);
                try self.emitOp(.GET_PROP, line);
                try self.emitU8(base + 1);
                try self.emitU8(base);
                try self.emitU16(kidx);
                self.sp = base + 2;
            } else {
                const rkey = try self.compileExpr(me.property);
                try self.emitOp(.GET_PROP_DYN, line);
                try self.emitU8(base + 1);
                try self.emitU8(base);
                try self.emitU8(rkey);
                self.freeReg(); // free rkey
                self.sp = base + 2;
            }

            // ES2020 `a.b?.()`: short-circuit if the resolved callee is nullish.
            if (c.optional) try self.emitOptionalGuard(base + 1, line);

            // Compile args into R[base+2..].
            const nargs: u8 = @intCast(c.args.len);
            for (c.args) |arg| {
                _ = try self.compileExpr(arg);
            }

            const ret_dst = base;
            try self.emitOp(if (tail) .TAIL_METHOD_CALL else .METHOD_CALL, line);
            try self.emitU8(base);
            try self.emitU8(nargs);
            try self.emitU8(ret_dst);

            self.sp = base + 1;
            return ret_dst;
        }

        // Regular call layout: R[base] = callee, R[base+1..base+1+nargs] = args.
        const base = self.sp;
        // Bump sp for callee slot.
        _ = self.allocReg();
        // Compile callee into base.
        const saved_sp = self.sp;
        self.sp = base; // reset to compile callee there
        const rcallee = try self.compileExpr(c.callee);
        _ = rcallee;
        self.sp = saved_sp; // restore

        // ES2020 `f?.(args)`: short-circuit if callee is nullish (args not evaluated).
        if (c.optional) try self.emitOptionalGuard(base, line);

        // Compile each argument into consecutive registers.
        const nargs: u8 = @intCast(c.args.len);
        for (c.args) |arg| {
            _ = try self.compileExpr(arg);
        }

        // A call written as the bare identifier `eval` is a *direct* eval
        // (§13.3.6.1) — the eval'd code sees this scope. Flag it for the call
        // dispatch here, where the syntactic shape is still known; any other
        // callee expression (`(0,eval)(s)`, `o.eval(s)`, an aliased binding)
        // reaches %eval% indirectly and runs in global scope. Emitted after the
        // arguments so an intervening call cannot consume the flag first.
        // `eval?.(s)` is an OptionalExpression, not a CallExpression, so it is
        // NOT a direct eval however it is written.
        if (!c.optional and c.callee.kind == .identifier and
            std.mem.eql(u8, c.callee.data.identifier, "eval"))
        {
            try self.emitOp(.MARK_DIRECT_EVAL, line);
            // The eval'd source may name `arguments`, which the enclosing
            // function cannot see by scanning its own body — so a direct eval
            // forces the arguments object to be materialized (§10.2.11 step 15
            // treats a function containing a direct eval as using it).
            self.saw_arguments = true;
        }

        // Emit CALL (or TAIL_CALL when this call is in tail position).
        const ret_dst = base; // result goes back into base register.
        try self.emitOp(if (tail) .TAIL_CALL else .CALL, line);
        try self.emitU8(base);
        try self.emitU8(nargs);
        try self.emitU8(ret_dst);

        // Free all arg registers, keep only ret_dst.
        self.sp = base + 1;
        return ret_dst;
    }

    /// Compile a call whose arguments include a spread (`f(...xs)`,
    /// `obj.m(a, ...xs)`). Builds a runtime argument array and emits CALL_SPREAD.
    pub fn compileCallSpread(self: *Self, c: ast.CallExpr, line: u32) error{OutOfMemory}!u8 {
        var rthis: u8 = 0;
        var rcallee: u8 = 0;
        var rdst: u8 = 0;
        if (c.callee.kind == .member_expr) {
            const me = c.callee.data.member_expr;
            rthis = try self.compileExpr(me.object);
            rcallee = self.allocReg();
            if (me.computed) {
                const rkey = try self.compileExpr(me.property);
                try self.emitOp(.GET_PROP_DYN, line);
                try self.emitU8(rcallee);
                try self.emitU8(rthis);
                try self.emitU8(rkey);
                self.sp = rcallee + 1; // free rkey
            } else {
                const name = me.property.data.identifier;
                const sv = try val_mod.makeString(self.arena, name);
                const kidx = try self.addConstant(sv);
                try self.emitOp(.GET_PROP, line);
                try self.emitU8(rcallee);
                try self.emitU8(rthis);
                try self.emitU16(kidx);
            }
            rdst = rthis; // reuse the (lowest) object slot for the result
        } else {
            rcallee = try self.compileExpr(c.callee);
            rthis = self.allocReg();
            try self.emitOp(.LOAD_UNDEF, line);
            try self.emitU8(rthis);
            rdst = rcallee; // lowest slot
        }

        // Build the argument array dynamically.
        const rargs = self.allocReg();
        try self.emitOp(.NEW_ARRAY, line);
        try self.emitU8(rargs);
        try self.emitU8(0);
        for (c.args) |a| {
            if (a.kind == .spread_expr) {
                const riter = try self.compileExpr(a.data.spread_expr);
                try self.emitOp(.ARRAY_SPREAD, line);
                try self.emitU8(rargs);
                try self.emitU8(riter);
                self.freeReg();
            } else {
                const rval = try self.compileExpr(a);
                try self.emitOp(.ARRAY_APPEND, line);
                try self.emitU8(rargs);
                try self.emitU8(rval);
                self.freeReg();
            }
        }

        try self.emitOp(.CALL_SPREAD, line);
        try self.emitU8(rcallee);
        try self.emitU8(rthis);
        try self.emitU8(rargs);
        try self.emitU8(rdst);
        self.sp = rdst + 1;
        return rdst;
    }

    pub fn compileFuncExpr(self: *Self, fe: ast.FuncExpr, line: u32) error{OutOfMemory}!u8 {
        // NamedEvaluation: consume the transient hint and apply it when this
        // function expression is genuinely anonymous and not a method.
        const hint = self.name_hint;
        self.name_hint = null; // consume once — nested anonymous fns must not inherit it
        const eff_name: ?[]const u8 = if (!fe.is_method and fe.name == null) hint else fe.name;
        // Compile inner function.
        const child_fn = try compileFunctionStrict(
            self.arena,
            eff_name,
            fe.params,
            fe.body,
            if (fe.is_method) null else eff_name, // nfe_name: named fn exprs self-bind; methods do not
            fe.is_strict or self.is_strict, // strictness is inherited by nested functions
            fe.is_generator,
            fe.is_async,
            false, // function body: no implicit last-expr return
            fe.is_arrow,
            fe.rest_param,
            fe.param_defaults,
            fe.source_text,
        );

        // Concise methods (object/class method shorthand, getters, setters) are
        // not constructors: propagate the flag so the VM omits the `prototype`
        // property for non-generator methods.
        child_fn.is_method = fe.is_method;

        const child_idx: u16 = @intCast(self.child_functions.items.len);
        try self.child_functions.append(self.arena, child_fn);

        // An arrow child that references `arguments` resolves it lexically — the
        // nearest enclosing non-arrow function must materialize the object.
        if (child_fn.needs_parent_arguments) self.saw_arguments = true;

        const r = self.allocReg();
        try self.emitOp(.NEW_CLOSURE, line);
        try self.emitU8(r);
        try self.emitU16(child_idx);
        return r;
    }

    // ---------------------------------------------------------- compile stmts ---

    /// Compile a single statement. Returns the "expression result" register
    /// (only meaningful for expr_stmt; others return null-register sentinel 0xFF).
    pub fn compileStmt(self: *Self, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
        const line: u32 = node.start;
        _ = line;
        const lower = @import("./lower/stmt.zig");
        switch (node.kind) {
            .expr_stmt => try lower.lowerExprStmt(self, node, last_expr_reg),
            .var_decl => try lower.lowerVarDecl(self, node, last_expr_reg),
            .block_stmt => try lower.lowerBlockStmt(self, node, last_expr_reg),
            .function_decl => try lower.lowerNestedFunctionDecl(self, node, last_expr_reg),
            .if_stmt => try lower.lowerIfStmt(self, node, last_expr_reg),
            .while_stmt => try lower.lowerWhileStmt(self, node, last_expr_reg),
            .do_while_stmt => try lower.lowerDoWhileStmt(self, node, last_expr_reg),
            .with_stmt => try lower.lowerWithStmt(self, node, last_expr_reg),
            .for_stmt => try lower.lowerForStmt(self, node, last_expr_reg),
            .return_stmt => try lower.lowerReturnStmt(self, node, last_expr_reg),
            .throw_stmt => try lower.lowerThrowStmt(self, node, last_expr_reg),
            .try_stmt => try lower.lowerTryStmt(self, node, last_expr_reg),
            .break_stmt => try lower.lowerBreakStmt(self, node, last_expr_reg),
            .continue_stmt => try lower.lowerContinueStmt(self, node, last_expr_reg),
            .for_in_stmt => try lower.lowerForInStmt(self, node, last_expr_reg),
            .switch_stmt => try lower.lowerSwitchStmt(self, node, last_expr_reg),
            .labeled_stmt => try lower.lowerLabeledStmt(self, node, last_expr_reg),
            .empty_stmt => try lower.lowerEmptyStmt(self, node, last_expr_reg),
            .debugger_stmt => try lower.lowerDebuggerStmt(self, node, last_expr_reg),
            .params_done => {
                // Boundary between formal-parameter init and the body. Only
                // generators run their prelude eagerly; others ignore the marker.
                if (self.is_generator) {
                    try self.emitOp(.PARAMS_DONE, node.start);
                    self.has_param_init = true;
                }
            },
            else => {},
        }
    }

    /// Compile a function body. `implicit_return` is true only for the top-level
    /// program (so eval/REPL yields the last expression-statement value); function
    /// bodies pass false and return undefined on fall-through.
    pub fn compileBody(self: *Self, body: []*Node, implicit_return: bool) error{OutOfMemory}!void {
        // Hoisting pre-pass: bind every `var` and function-declaration name in
        // this scope to `undefined` at entry, so reads before initialization
        // yield undefined while genuinely-undeclared names throw ReferenceError.
        {
            // Annex B.3.3 first: a block-level function declaration only gets a
            // var-scoped binding when no lexical declaration or parameter
            // between it and this scope would make `var F` an early error.
            {
                var blocked: std.ArrayList([]const u8) = .empty;
                for (self.param_names) |p| try self.addHoistName(&blocked, p);
                for (body) |stmt| try self.collectLexicalNames(stmt, &blocked);
                for (body) |stmt| try self.collectAnnexBNames(stmt, &blocked, &self.annexb_fn_names, false);
            }
            var hoisted: std.ArrayList([]const u8) = .empty;
            for (body) |stmt| try self.collectHoistedNames(stmt, &hoisted, false);
            for (self.annexb_fn_names.items) |name| try self.addHoistName(&hoisted, name);
            for (hoisted.items) |name| try self.emitHoist(name, 0);
        }

        // Lexical hoisting pre-pass: declare every `let`/`const` name as an
        // uninitialized lexical binding (TDZ) at scope entry, so reads before
        // initialization throw ReferenceError instead of returning undefined.
        {
            var lexical: std.ArrayList([]const u8) = .empty;
            for (body) |stmt| try self.collectLexicalNames(stmt, &lexical);
            for (lexical.items) |name| try self.emitHoistLexical(name, 0);
        }

        // Function declarations are fully instantiated (closure created AND
        // bound) at scope entry, before any statement executes — so forward
        // references resolve. Emit direct-child function declarations here and
        // skip them in the statement loop below. (Nested-block function decls
        // are still lowered at their source position via compileStmt.)
        {
            const lower = @import("./lower/stmt.zig");
            var fd_reg: ?u8 = null;
            for (body) |stmt| {
                if (stmt.kind == .function_decl)
                    try lower.lowerFunctionDecl(self, stmt, &fd_reg);
            }
        }

        // Completion values (eval/REPL): the top-level program accumulates its
        // completion value into a dedicated register, initialized to `undefined`
        // and updated per the ES statement-completion rules (see writeCompletion/
        // resetCompletion and the loop handlers). Allocate it first so it stays
        // below — and untouched by — the per-statement register reclamation.
        // Function bodies leave `completion_reg` null and behave exactly as before.
        if (implicit_return) {
            const cr = self.allocReg();
            try self.emitOp(.LOAD_UNDEF, 0);
            try self.emitU8(cr);
            self.completion_reg = cr;
        }

        var last_expr_stmt_reg: ?u8 = null;
        var last_other_reg: ?u8 = null;
        const reclaim_floor: u8 = if (self.completion_reg) |cr| cr + 1 else 0;

        for (body) |stmt| {
            // Reclaim register from previous statement (never below the completion
            // register, which must persist across statements).
            if (last_expr_stmt_reg) |pr| {
                if (pr >= reclaim_floor) self.sp = pr;
                last_expr_stmt_reg = null;
            } else if (last_other_reg) |pr| {
                if (pr >= reclaim_floor) self.sp = pr;
                last_other_reg = null;
            }

            // Already instantiated at scope entry (see hoisting pre-pass).
            if (stmt.kind == .function_decl) continue;

            var last_expr_reg: ?u8 = null;
            try self.compileStmt(stmt, &last_expr_reg);
            if (stmt.kind == .expr_stmt) {
                last_expr_stmt_reg = last_expr_reg;
            } else {
                last_other_reg = last_expr_reg;
            }
        }

        // Top-level program returns its accumulated completion value (eval / REPL
        // result). Function bodies fall through to undefined unless an explicit
        // `return` executed.
        if (self.completion_reg) |cr| {
            try self.emitOp(.RETURN, 0);
            try self.emitU8(cr);
        } else {
            try self.emitOp(.RETURN_UNDEF, 0);
        }
    }
};

// ---------------------------------------------------------------- compileFunction ---

fn compileFunction(
    arena: std.mem.Allocator,
    name: ?[]const u8,
    params: [][]const u8,
    body: []*Node,
    nfe_name: ?[]const u8,
) error{OutOfMemory}!*BcFunction {
    return compileFunctionStrict(arena, name, params, body, nfe_name, false, false, false, false, false, null, &[_]?*Node{}, null);
}

/// Allocate an AST node from `data` (synthetic — no source span).
fn mkSynthNode(arena: std.mem.Allocator, data: ast.Data) error{OutOfMemory}!*Node {
    const n = try arena.create(Node);
    n.* = .{ .kind = std.meta.activeTag(data), .start = 0, .end = 0, .data = data };
    return n;
}

/// Synthesize a prologue applying default parameter values: for each parameter
/// `p` with a default `d`, prepend `if (p === undefined) p = d;`. An absent
/// argument is bound to undefined at call setup, so this also covers the
/// "fewer arguments than parameters" case. Returns `body` unchanged when no
/// parameter has a default.
fn applyParamDefaults(
    arena: std.mem.Allocator,
    params: [][]const u8,
    param_defaults: []const ?*Node,
    body: []*Node,
) error{OutOfMemory}![]*Node {
    var any = false;
    for (param_defaults) |d| {
        if (d != null) {
            any = true;
            break;
        }
    }
    if (!any) return body;
    var list: std.ArrayList(*Node) = .empty;
    for (params, 0..) |pname, i| {
        if (i >= param_defaults.len) break;
        const dexpr = param_defaults[i] orelse continue;
        const id_test = try mkSynthNode(arena, .{ .identifier = pname });
        const undef = try mkSynthNode(arena, .{ .undefined_literal = {} });
        const test_expr = try mkSynthNode(arena, .{ .binary_expr = .{ .op = .strict_eq, .left = id_test, .right = undef } });
        const id_target = try mkSynthNode(arena, .{ .identifier = pname });
        const assign = try mkSynthNode(arena, .{ .assignment_expr = .{ .op = .assign, .target = id_target, .value = dexpr } });
        const estmt = try mkSynthNode(arena, .{ .expr_stmt = assign });
        const ifs = try mkSynthNode(arena, .{ .if_stmt = .{ .test_ = test_expr, .consequent = estmt, .alternate = null } });
        try list.append(arena, ifs);
    }
    try list.appendSlice(arena, body);
    return list.toOwnedSlice(arena);
}

pub fn compileFunctionStrict(
    arena: std.mem.Allocator,
    name: ?[]const u8,
    params: [][]const u8,
    body_in: []*Node,
    nfe_name: ?[]const u8,
    is_strict: bool,
    is_generator: bool,
    is_async: bool,
    implicit_return: bool,
    is_arrow: bool,
    rest_param: ?[]const u8,
    param_defaults: []const ?*Node,
    source_text: ?[]const u8,
) error{OutOfMemory}!*BcFunction {
    var fc = FnCompiler.init(arena, name, params);
    fc.nfe_name = nfe_name;
    fc.is_strict = is_strict;
    fc.is_async = is_async;
    fc.is_async_generator = is_async and is_generator;
    fc.is_generator = is_generator;
    fc.is_arrow = is_arrow;

    // Phase 2: all variable access is env-based (GET_GLOBAL/SET_GLOBAL).
    // Params are passed via env on CALL setup (see bc_vm.zig CALL handler).
    // Register slots are used only for compiler temporaries.
    // sp starts at 0; max_regs tracks highest allocated temporary register.

    const body = try applyParamDefaults(arena, params, param_defaults, body_in);
    try fc.compileBody(body, implicit_return);

    const chunk = try fc.builder.finalize(name orelse "<anonymous>", 0);

    const child_fns = try fc.child_functions.toOwnedSlice(arena);

    // Ensure at least 1 register for the VM to allocate.
    const num_regs = if (fc.max_regs > 0) fc.max_regs else 1;

    const f = try arena.create(BcFunction);
    const ic_table = try arena.alloc(ic_mod.InlineCache, chunk.code.len);
    for (ic_table) |*entry| entry.* = ic_mod.InlineCache{};
    const arith_ic_table = try arena.alloc(ic_mod.ArithCache, chunk.code.len);
    for (arith_ic_table) |*entry| entry.* = ic_mod.ArithCache{};
    const typeof_ic_table = try arena.alloc(ic_mod.TypeofCache, chunk.code.len);
    for (typeof_ic_table) |*entry| entry.* = ic_mod.TypeofCache{};
    const instanceof_ic_table = try arena.alloc(ic_mod.InstanceofCache, chunk.code.len);
    for (instanceof_ic_table) |*entry| entry.* = ic_mod.InstanceofCache{};
    f.* = BcFunction{
        .name = name,
        .source_text = source_text,
        .nfe_name = nfe_name,
        .arity = @intCast(params.len),
        .chunk = chunk,
        .num_regs = num_regs,
        .child_functions = child_fns,
        .param_names = params,
        .rest_param = rest_param,
        .is_strict = is_strict,
        .is_generator = is_generator,
        .has_param_init = fc.has_param_init,
        .is_async = is_async,
        .is_arrow = is_arrow,
        .uses_arguments = fc.saw_arguments and !is_arrow,
        .needs_parent_arguments = is_arrow and fc.saw_arguments,
        .ic_table = ic_table,
        .arith_ic_table = arith_ic_table,
        .typeof_ic_table = typeof_ic_table,
        .instanceof_ic_table = instanceof_ic_table,
    };
    return f;
}

// ---------------------------------------------------------------- public API ---

pub const Compiler = struct {
    arena: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return Compiler{ .arena = allocator };
    }
};

pub fn compileProgram(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    source_name: []const u8,
) !*BcFunction {
    last_label_error = null;
    const f = try compileFunctionStrict(
        arena,
        source_name,
        &[_][]const u8{},
        program.body,
        null,
        program.is_strict,
        false,
        false,
        true, // top-level program: yield last expression-statement value (eval result)
        false, // program is not an arrow
        null, // program has no rest parameter
        &[_]?*ast.Node{}, // no parameters → no defaults
        null,
    );
    return f;
}

/// Milestone 16 — Phase 1: compile an ES-module top level to a `BcFunction`.
///
/// Same lowering as `compileProgram` (top-level program that yields its last
/// expression-statement value), but module code is strict by spec (§11.2.2):
/// strictness is forced on regardless of a "use strict" directive, so nested
/// functions inherit it. The import/export desugar has already happened in the
/// parser, so the body is plain (strict) statements over `require`/`exports`.
pub fn compileModule(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    source_name: []const u8,
) !*BcFunction {
    last_label_error = null;
    const f = try compileFunctionStrict(
        arena,
        source_name,
        &[_][]const u8{},
        program.body,
        null,
        true, // module code is always strict
        false,
        program.has_tla, // M16 TLA: a module with top-level await compiles its
        // body as async so `await` truly suspends (driven as a coroutine by
        // runMainAsync); modules without TLA stay synchronous.
        true, // top-level program: yield last expression-statement value
        false, // program is not an arrow
        null, // program has no rest parameter
        &[_]?*ast.Node{}, // no parameters → no defaults
        null,
    );
    f.is_module = true;
    return f;
}

// ---------------------------------------------------------------- tests ---

test "compiler: compile empty program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const prog = ast.Program{ .body = &[_]*ast.Node{} };
    const f = try compileProgram(alloc, &prog, "<test>");
    try std.testing.expect(f.arity == 0);
    try std.testing.expect(f.chunk.code.len > 0);
}

test "compiler: compileModule is always strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parser_mod = @import("../parser/parser.zig");
    var p = parser_mod.Parser.init("export var x = 1;", alloc);
    const stmts = switch (p.parseModule()) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast.Program{ .body = stmts, .is_strict = true, .is_module = true };
    const f = try compileModule(alloc, &prog, "<module-test>");
    try std.testing.expect(f.is_strict);
    try std.testing.expect(f.chunk.code.len > 0);
}

test "compiler: compile number literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parser_mod = @import("../parser/parser.zig");
    var p = parser_mod.Parser.init("42", alloc);
    const result = p.parseScript();
    const stmts = switch (result) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast.Program{ .body = stmts };
    const f = try compileProgram(alloc, &prog, "<test>");
    try std.testing.expect(f.chunk.code.len > 0);
    try std.testing.expect(f.chunk.constants.len > 0);
}
