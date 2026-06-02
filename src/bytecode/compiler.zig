// SPDX-License-Identifier: MIT
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
const LabelEntry = struct {
    name: []const u8,
    break_patches: std.ArrayListUnmanaged(usize) = .empty,
    continue_patches: std.ArrayListUnmanaged(usize) = .empty,
    // Where the loop starts (for continue with label).
    loop_start: usize = 0,
};

const FnCompiler = struct {
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
    /// Phase 8: is this function compiled in strict mode? PTC only applies in
    /// strict mode (ES2015 14.6).
    is_strict: bool = false,
    /// Phase 8: nesting depth of try/catch/finally regions. A call in the
    /// operand of `return` is only in tail position when try_depth == 0
    /// (a pending finally would run after the call returns, so it is not tail).
    try_depth: u32 = 0,

    const Self = @This();

    fn init(arena: std.mem.Allocator, name: ?[]const u8, params: [][]const u8) FnCompiler {
        return FnCompiler{
            .arena = arena,
            .builder = ChunkBuilder.init(arena),
            .name = name,
            .param_names = params,
        };
    }

    /// Allocate a new register and track high-water mark.
    fn allocReg(self: *Self) u8 {
        const r = self.sp;
        self.sp += 1;
        if (self.sp > self.max_regs) self.max_regs = self.sp;
        return r;
    }

    /// Free the top register (drop sp).
    fn freeReg(self: *Self) void {
        if (self.sp > 0) self.sp -= 1;
    }

    fn emitOp(self: *Self, op: Op, line: u32) !void {
        try self.builder.emitOp(op, line);
    }

    fn emitU8(self: *Self, v: u8) !void {
        try self.builder.emitU8(v);
    }

    fn emitU16(self: *Self, v: u16) !void {
        try self.builder.emitU16(v);
    }

    fn emitI16(self: *Self, v: i16) !void {
        try self.builder.emitI16(v);
    }

    fn addConstant(self: *Self, v: Value) !u16 {
        return self.builder.addConstant(v);
    }

    fn currentOffset(self: *const Self) usize {
        return self.builder.currentOffset();
    }

    fn patchJump(self: *Self, at: usize, target: usize) void {
        self.builder.patchJump(at, target);
    }

    // --------------------------------------------------------- resolve name ---
    // Phase 2: always use env-based (GET_GLOBAL/SET_GLOBAL) for named variables.
    // This ensures inner closures can capture outer variables via the env chain.
    // GET_LOCAL/SET_LOCAL are reserved for compiler-generated register temporaries.

    // --------------------------------------------------------- emit name load ---

    /// Load a named identifier into Rdst via env chain lookup.
    fn emitLoad(self: *Self, name: []const u8, rdst: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.GET_GLOBAL, line);
        try self.emitU8(rdst);
        try self.emitU16(kidx);
    }

    // --------------------------------------------------------- emit name store ---

    fn emitStore(self: *Self, name: []const u8, rsrc: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.SET_GLOBAL, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
    }

    /// Phase 4d: Emit DEFINE_GLOBAL — defines a new binding (used for var decls,
    /// catch variables). Always defines; never throws ReferenceError in strict mode.
    fn emitDefine(self: *Self, name: []const u8, rsrc: u8, line: u32) !void {
        const sv = try val_mod.makeString(self.arena, name);
        const kidx = try self.addConstant(sv);
        try self.emitOp(.DEFINE_GLOBAL, line);
        try self.emitU16(kidx);
        try self.emitU8(rsrc);
    }

    // -------------------------------------------------------- compile expr -> R ---

    /// Compile an expression, placing result in a NEW register (sp is bumped).
    /// Caller is responsible for calling freeReg() when done with the register.
    /// Returns the register index.
    fn compileExpr(self: *Self, node: *Node) error{OutOfMemory}!u8 {
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

    fn compileUnary(self: *Self, u: ast.UnaryExpr, line: u32) error{OutOfMemory}!u8 {
        switch (u.op) {
            .typeof_ => {
                // typeof: always use env-based load (won't throw for undeclared).
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
                // Phase 2: always true.
                _ = try self.compileExpr(u.operand);
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
                // Unary +: just load as number. We can't call toNumber in compiler,
                // so emit NEG(NEG(x)) trick — actually emit SUB 0,x is better.
                // Simplest: load 0, then SUB is wrong. Just use the value as-is
                // since NEG NEG would work but is wasteful.
                // Best approach: emit NEG twice.
                const rsrc = try self.compileExpr(u.operand);
                const rdst = rsrc;
                self.sp = rsrc;
                self.sp += 1;
                // NEG then NEG to coerce to number and negate twice = original.
                try self.emitOp(.NEG, line);
                try self.emitU8(rdst);
                try self.emitU8(rsrc);
                try self.emitOp(.NEG, line);
                try self.emitU8(rdst);
                try self.emitU8(rdst);
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

    fn compileBinary(self: *Self, b: ast.BinaryExpr, line: u32) error{OutOfMemory}!u8 {
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
                // Not supported yet: always false.
                try self.emitOp(.LOAD_FALSE, line);
                try self.emitU8(rdst);
                return rdst;
            },
        };
        try self.emitOp(op, line);
        try self.emitU8(rdst);
        try self.emitU8(rlhs);
        try self.emitU8(rrhs);
        return rdst;
    }

    fn compileLogical(self: *Self, l: ast.LogicalExpr, line: u32) error{OutOfMemory}!u8 {
        const rlhs = try self.compileExpr(l.left);
        // The result register is rlhs.

        // JMP past rhs evaluation if short-circuit.
        const jump_op: Op = if (l.op == .and_) .JMP_IF_FALSE else .JMP_IF_TRUE;
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

    fn compileTernary(self: *Self, ce: ast.CondExpr, line: u32) error{OutOfMemory}!u8 {
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

    fn compileAssign(self: *Self, a: ast.AssignExpr, line: u32) error{OutOfMemory}!u8 {
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
            const rhs = try self.compileExpr(a.value);
            if (a.target.kind == .identifier) {
                try self.emitStore(a.target.data.identifier, rhs, line);
            } else if (a.target.kind == .member_expr) {
                try self.compileMemberWrite(a.target.data.member_expr, rhs, line);
            }
            return rhs;
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
            .assign => unreachable,
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

    fn compileMemberRead(self: *Self, me: ast.MemberExpr, line: u32) error{OutOfMemory}!u8 {
        const robj = try self.compileExpr(me.object);
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

    fn compileMemberWrite(self: *Self, me: ast.MemberExpr, rval: u8, line: u32) error{OutOfMemory}!void {
        const robj = try self.compileExpr(me.object);
        if (!me.computed) {
            const prop_name = me.property.data.identifier;
            const sv = try val_mod.makeString(self.arena, prop_name);
            const kidx = try self.addConstant(sv);
            try self.emitOp(.SET_PROP, line);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            try self.emitU8(rval);
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

    fn compileObjectLiteral(self: *Self, ol: ast.ObjectLiteral, line: u32) error{OutOfMemory}!u8 {
        const robj = self.allocReg();
        try self.emitOp(.NEW_OBJECT, line);
        try self.emitU8(robj);

        for (ol.properties) |prop| {
            const rval = try self.compileExpr(prop.value);
            const sv = try val_mod.makeString(self.arena, prop.key);
            const kidx = try self.addConstant(sv);
            try self.emitOp(.SET_PROP, line);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            try self.emitU8(rval);
            self.freeReg(); // free rval
        }
        return robj;
    }

    fn compileArrayLiteral(self: *Self, al: ast.ArrayLiteral, line: u32) error{OutOfMemory}!u8 {
        const len_hint: u8 = if (al.elements.len <= 255) @intCast(al.elements.len) else 255;
        const robj = self.allocReg();
        try self.emitOp(.NEW_ARRAY, line);
        try self.emitU8(robj);
        try self.emitU8(len_hint);

        for (al.elements, 0..) |elem, i| {
            const rval = try self.compileExpr(elem);
            // Use static string key for the index.
            const key_str = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return error.OutOfMemory;
            const sv = try val_mod.makeString(self.arena, key_str);
            const kidx = try self.addConstant(sv);
            try self.emitOp(.SET_PROP, line);
            try self.emitU8(robj);
            try self.emitU16(kidx);
            try self.emitU8(rval);
            self.freeReg(); // free rval
        }
        return robj;
    }

    fn compileUpdate(self: *Self, u: ast.UpdateExpr, line: u32) error{OutOfMemory}!u8 {
        const r_old = try self.compileExpr(u.operand);

        if (u.prefix) {
            // Pre: compute new value, store, return new.
            const r_new = r_old;
            try self.emitOp(if (u.op == .inc) .INC else .DEC, line);
            try self.emitU8(r_new);
            try self.emitU8(r_old);
            if (u.operand.kind == .identifier) {
                try self.emitStore(u.operand.data.identifier, r_new, line);
            }
            return r_new;
        } else {
            // Post: compute new value, store, return OLD.
            const r_scratch = self.allocReg();
            try self.emitOp(.MOVE, line);
            try self.emitU8(r_scratch);
            try self.emitU8(r_old);
            try self.emitOp(if (u.op == .inc) .INC else .DEC, line);
            try self.emitU8(r_scratch);
            try self.emitU8(r_scratch);
            if (u.operand.kind == .identifier) {
                try self.emitStore(u.operand.data.identifier, r_scratch, line);
            }
            self.freeReg(); // free r_scratch
            return r_old; // return old value
        }
    }

    fn compileCall(self: *Self, c: ast.CallExpr, line: u32, tail: bool) error{OutOfMemory}!u8 {
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

            // Compile args into R[base+2..].
            const nargs: u8 = @intCast(c.args.len);
            for (c.args) |arg| {
                _ = try self.compileExpr(arg);
            }

            const ret_dst = base;
            try self.emitOp(.METHOD_CALL, line);
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

        // Compile each argument into consecutive registers.
        const nargs: u8 = @intCast(c.args.len);
        for (c.args) |arg| {
            _ = try self.compileExpr(arg);
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

    fn compileFuncExpr(self: *Self, fe: ast.FuncExpr, line: u32) error{OutOfMemory}!u8 {
        // Compile inner function.
        const child_fn = try compileFunctionStrict(
            self.arena,
            fe.name,
            fe.params,
            fe.body,
            fe.name, // nfe_name: if named, bind inside
            fe.is_strict,
        );

        const child_idx: u16 = @intCast(self.child_functions.items.len);
        try self.child_functions.append(self.arena, child_fn);

        const r = self.allocReg();
        try self.emitOp(.NEW_CLOSURE, line);
        try self.emitU8(r);
        try self.emitU16(child_idx);
        return r;
    }

    // ---------------------------------------------------------- compile stmts ---

    /// Compile a single statement. Returns the "expression result" register
    /// (only meaningful for expr_stmt; others return null-register sentinel 0xFF).
    fn compileStmt(self: *Self, node: *Node, last_expr_reg: *?u8) error{OutOfMemory}!void {
        const line: u32 = node.start;
        switch (node.kind) {
            .expr_stmt => {
                const r = try self.compileExpr(node.data.expr_stmt);
                last_expr_reg.* = r;
                // Do NOT free r here; the caller (compileBody) tracks the last one.
            },
            .var_decl => {
                const vd = node.data.var_decl;
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
            },
            .block_stmt => {
                for (node.data.block_stmt.body) |child| {
                    try self.compileStmt(child, last_expr_reg);
                }
            },
            .function_decl => {
                // Compile inner function, store into local slot.
                const fd = node.data.function_decl;
                const child_fn = try compileFunctionStrict(
                    self.arena,
                    fd.name,
                    fd.params,
                    fd.body,
                    null,
                    fd.is_strict,
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
            },
            .if_stmt => {
                const is = node.data.if_stmt;
                const rcond = try self.compileExpr(is.test_);
                self.freeReg();

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
            },
            .while_stmt => {
                const ws = node.data.while_stmt;
                const loop_start = self.currentOffset();

                const rcond = try self.compileExpr(ws.test_);
                self.freeReg();

                try self.emitOp(.JMP_IF_FALSE, line);
                try self.emitU8(rcond);
                const patch_exit = self.currentOffset();
                try self.emitI16(0);

                try self.compileStmt(ws.body, last_expr_reg);

                // Jump back to loop start.
                try self.emitOp(.JMP, line);
                const back_offset = self.currentOffset();
                try self.emitI16(0);
                self.patchJump(back_offset, loop_start);

                const exit_offset = self.currentOffset();
                self.patchJump(patch_exit, exit_offset);
            },
            .do_while_stmt => {
                const dw = node.data.do_while_stmt;
                const loop_start = self.currentOffset();

                try self.compileStmt(dw.body, last_expr_reg);

                const rcond = try self.compileExpr(dw.test_);
                self.freeReg();

                try self.emitOp(.JMP_IF_TRUE, line);
                try self.emitU8(rcond);
                const back_offset = self.currentOffset();
                try self.emitI16(0);
                self.patchJump(back_offset, loop_start);
            },
            .for_stmt => {
                const fs = node.data.for_stmt;
                if (fs.init) |init_node| {
                    var dummy: ?u8 = null;
                    try self.compileStmt(init_node, &dummy);
                }

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

                try self.compileStmt(fs.body, last_expr_reg);

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

                if (patch_exit) |pe| {
                    self.patchJump(pe, self.currentOffset());
                }
            },
            .return_stmt => {
                if (node.data.return_stmt) |rv_node| {
                    // Phase 8: proper tail call. `return f(args);` is a tail call
                    // when in strict mode and not inside a try/finally region.
                    // Direct (non-member) callees only — `return obj.m()` falls
                    // back to a normal METHOD_CALL + RETURN. The TAIL_CALL opcode
                    // performs the return itself, so no RETURN is emitted.
                    if (self.is_strict and self.try_depth == 0 and
                        rv_node.kind == .call_expr and
                        rv_node.data.call_expr.callee.kind != .member_expr)
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
            },
            .throw_stmt => {
                const rv = try self.compileExpr(node.data.throw_stmt);
                try self.emitOp(.THROW, line);
                try self.emitU8(rv);
                self.freeReg();
            },
            .try_stmt => {
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
                    // Bind catch param: DEFINE_GLOBAL "name", Rexc (always defines, never strict-throws)
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
            },
            .break_stmt => {
                const label = node.data.break_stmt;
                if (label) |lname| {
                    // Find the matching label entry and add a patch.
                    var i = self.label_stack.items.len;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, self.label_stack.items[i].name, lname)) {
                            try self.emitOp(.JMP, line);
                            try self.label_stack.items[i].break_patches.append(self.arena, self.currentOffset());
                            try self.emitI16(0);
                            break;
                        }
                    } else {
                        // Label not found — emit stub JMP 0.
                        try self.emitOp(.JMP, line);
                        try self.emitI16(0);
                    }
                } else {
                    // Unlabeled break: emit JMP 0 (patched by loop structure).
                    try self.emitOp(.JMP, line);
                    try self.emitI16(0);
                }
            },
            .continue_stmt => {
                // emit JMP 0 (no label support yet for continue).
                try self.emitOp(.JMP, line);
                try self.emitI16(0);
            },
            .for_in_stmt => {
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
                            try self.emitOp(.SET_GLOBAL, line);
                            try self.emitU8(@intCast(name_idx & 0xFF));
                            try self.emitU8(@intCast((name_idx >> 8) & 0xFF));
                            try self.emitU8(rkey);
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
            },
            .switch_stmt => {
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
            },
            .labeled_stmt => {
                // Phase 4d: push label, compile body, patch breaks to exit.
                const ls = node.data.labeled_stmt;
                try self.label_stack.append(self.arena, LabelEntry{
                    .name = ls.name,
                    .loop_start = self.currentOffset(),
                });
                try self.compileStmt(ls.body, last_expr_reg);
                const exit = self.currentOffset();
                // Patch all break patches for this label.
                var entry = self.label_stack.pop().?;
                for (entry.break_patches.items) |bp| {
                    self.patchJump(bp, exit);
                }
                entry.break_patches.deinit(self.arena);
                entry.continue_patches.deinit(self.arena);
            },
            .empty_stmt => {},
            .debugger_stmt => {
                // Phase 8: emit a DEBUGGER opcode so the VM can fire a debug
                // hook (breakpoint-style pause). No-op when no hook installed.
                try self.emitOp(.DEBUGGER, line);
            },
            else => {},
        }
    }

    /// Compile a function body.
    fn compileBody(self: *Self, body: []*Node) error{OutOfMemory}!void {
        var last_expr_stmt_reg: ?u8 = null;
        var last_other_reg: ?u8 = null;

        for (body) |stmt| {
            // Reclaim register from previous expression statement.
            if (last_expr_stmt_reg) |pr| {
                self.sp = pr;
                last_expr_stmt_reg = null;
            } else if (last_other_reg) |pr| {
                self.sp = pr;
                last_other_reg = null;
            }

            var last_expr_reg: ?u8 = null;
            try self.compileStmt(stmt, &last_expr_reg);
            if (stmt.kind == .expr_stmt) {
                last_expr_stmt_reg = last_expr_reg;
            } else {
                last_other_reg = last_expr_reg;
            }
        }

        // Emit final return using last expression statement result.
        const ret_reg = last_expr_stmt_reg orelse last_other_reg;
        if (ret_reg) |r| {
            try self.emitOp(.RETURN, 0);
            try self.emitU8(r);
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
    return compileFunctionStrict(arena, name, params, body, nfe_name, false);
}

fn compileFunctionStrict(
    arena: std.mem.Allocator,
    name: ?[]const u8,
    params: [][]const u8,
    body: []*Node,
    nfe_name: ?[]const u8,
    is_strict: bool,
) error{OutOfMemory}!*BcFunction {
    var fc = FnCompiler.init(arena, name, params);
    fc.nfe_name = nfe_name;
    fc.is_strict = is_strict;

    // Phase 2: all variable access is env-based (GET_GLOBAL/SET_GLOBAL).
    // Params are passed via env on CALL setup (see bc_vm.zig CALL handler).
    // Register slots are used only for compiler temporaries.
    // sp starts at 0; max_regs tracks highest allocated temporary register.

    try fc.compileBody(body);

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
        .arity = @intCast(params.len),
        .chunk = chunk,
        .num_regs = num_regs,
        .child_functions = child_fns,
        .param_names = params,
        .is_strict = is_strict,
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
    const f = try compileFunctionStrict(
        arena,
        source_name,
        &[_][]const u8{},
        program.body,
        null,
        program.is_strict,
    );
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
