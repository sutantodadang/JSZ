// SPDX-License-Identifier: MIT
//! Tree-walking evaluator for Phase 1/3a/3b.
//! Implements ES5 expression/statement subset sufficient to run fib(20)
//! and the integration test suite.
//! Phase 3b: object literals and array literals allocate on the GC heap when
//! a Heap is present; otherwise fall back to arena allocation.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const FuncVal = val_mod.FuncVal;
const JsObject = @import("../object/object.zig").JsObject;
const Environment = @import("../runtime/execution_context.zig").Environment;
const Realm = @import("../runtime/realm.zig").Realm;
const err_mod = @import("../runtime/error.zig");
const Heap = @import("../gc/heap.zig").Heap;
const gc_mod = @import("../gc/gc.zig");
const promise_mod = @import("../runtime/builtins/promise.zig");

// ------------------------------------------------------------------ EvalResult --

pub const EvalException = struct {
    message: []const u8,
    value: Value = Value{},
};

pub const StmtResult = union(enum) {
    /// Normal completion; carries the last expression value.
    value: Value,
    /// return statement.
    return_: Value,
    /// break statement. Carries optional label (Phase 4d).
    break_: ?[]const u8,
    /// continue statement. Carries optional label (Phase 4d).
    continue_: ?[]const u8,
    /// Generator yield suspended the current statement.
    yield_suspend: void,
    /// Runtime exception.
    exception: EvalException,
};

// -------------------------------------------------------------------- Vm ----

pub const Vm = struct {
    arena: std.mem.Allocator,
    realm: Realm,
    /// Phase 3b: optional GC heap. Null in standalone/test mode.
    heap: ?*Heap = null,
    /// Carries the exception message through Zig error propagation.
    last_exception_msg: []const u8 = "",
    /// Carries the thrown exception Value (for JS-level catch).
    last_exception_value: Value = Value{},
    /// Current `this` value for the executing call frame.
    current_this: Value,
    /// Innermost call's local environment (null at top-level).
    /// Walking this chains to all enclosing envs + global. Required for GC
    /// root scanning when a collection fires mid-call.
    current_call_env: ?*Environment = null,
    /// Phase 4d: strict mode flag for current function/program scope.
    is_strict: bool = false,
    /// Phase 4d: Context interface pointer for callbacks.
    context: @import("../runtime/realm.zig").Context = undefined,
    /// Active generator capture context while materializing a generator.
    generator_capture: ?*GeneratorCapture = null,
    /// Phase 7: derived constructor must call super before touching `this`.
    derived_super_pending: bool = false,
    derived_super_called: bool = false,
    /// ES2020 optional chaining: set true when an optional link (`?.`) sees a
    /// nullish base; propagated up the chain so the enclosing `optional_chain`
    /// node yields `undefined` and skips remaining links.
    optional_short_circuit: bool = false,

    fn checkThisBeforeSuper(self: *Vm) EvalError!void {
        if (self.derived_super_pending and !self.derived_super_called) {
            const msg = "Must call super constructor in derived class before accessing 'this'";
            self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
            self.last_exception_value = try self.makeReferenceErrorObject(msg);
            return EvalError.JsException;
        }
    }

    fn isSuperCall(c: ast.CallExpr) bool {
        if (c.callee.kind != .member_expr) return false;
        const me = c.callee.data.member_expr;
        if (me.computed or me.object.kind != .identifier or me.property.kind != .identifier) return false;
        return std.mem.eql(u8, me.object.data.identifier, "super") and
            std.mem.eql(u8, me.property.data.identifier, "call");
    }

    fn genLoopTop(self: *Vm, stmt: *Node) ?*GenLoopFrame {
        if (self.generator_capture) |cap| {
            if (cap.loop_stack.items.len > 0) {
                const top = &cap.loop_stack.items[cap.loop_stack.items.len - 1];
                if (top.stmt == stmt) return top;
            }
        }
        return null;
    }

    fn genLoopPush(self: *Vm, stmt: *Node) error{OutOfMemory}!void {
        if (self.generator_capture) |cap| {
            try cap.loop_stack.append(self.arena, .{ .stmt = stmt, .phase = .enter });
        }
    }

    fn genLoopPop(self: *Vm) void {
        if (self.generator_capture) |cap| {
            _ = cap.loop_stack.pop();
        }
    }

    fn takeGeneratorSuspend(self: *Vm) ?StmtResult {
        if (self.generator_capture) |cap| {
            if (cap.suspend_requested) {
                cap.suspend_requested = false;
                return StmtResult{ .yield_suspend = {} };
            }
        }
        return null;
    }

    pub fn init(arena: std.mem.Allocator) !Vm {
        const realm = try Realm.init(arena);
        // Install ES5 spec globals: NaN, Infinity, undefined.
        const nan_val = try val_mod.makeNumber(arena, std.math.nan(f64));
        const inf_val = try val_mod.makeNumber(arena, std.math.inf(f64));
        const undef_val = try val_mod.makeUndefined(arena);
        try realm.global_env.define("NaN", nan_val);
        try realm.global_env.define("Infinity", inf_val);
        try realm.global_env.define("undefined", undef_val);
        // Expose __gc__ noop in tree mode (called by tests; realm has no heap).
        const gc_fn = try val_mod.makeNativeFunction(arena, nativeGcNoop);
        try realm.global_env.define("__gc__", gc_fn);
        const microtask_fn = try val_mod.makeNativeFunction(arena, promise_mod.nativeRunMicrotasks);
        try realm.global_env.define("__runMicrotasks__", microtask_fn);
        const await_fn = try val_mod.makeNativeFunction(arena, promise_mod.nativeAwait);
        try realm.global_env.define("__await__", await_fn);
        const undef_this = try val_mod.makeUndefined(arena);
        return Vm{ .arena = arena, .realm = realm, .current_this = undef_this, .generator_capture = null };
    }

    /// Init with an attached GC heap. Object literals will be heap-allocated.
    /// NOTE: After calling this, call registerHeapCallback(heap) once you have
    /// the final stack address of the Vm.
    pub fn initWithHeap(arena: std.mem.Allocator, heap: *Heap) !Vm {
        var realm = try Realm.init(arena);
        try realm.activateHeap(heap);
        const nan_val = try val_mod.makeNumber(arena, std.math.nan(f64));
        const inf_val = try val_mod.makeNumber(arena, std.math.inf(f64));
        const undef_val = try val_mod.makeUndefined(arena);
        try realm.global_env.define("NaN", nan_val);
        try realm.global_env.define("Infinity", inf_val);
        try realm.global_env.define("undefined", undef_val);
        const gc_fn = try val_mod.makeNativeFunction(arena, nativeGcCollect);
        try realm.global_env.define("__gc__", gc_fn);
        const microtask_fn = try val_mod.makeNativeFunction(arena, promise_mod.nativeRunMicrotasks);
        try realm.global_env.define("__runMicrotasks__", microtask_fn);
        const await_fn = try val_mod.makeNativeFunction(arena, promise_mod.nativeAwait);
        try realm.global_env.define("__await__", await_fn);
        const undef_this = try val_mod.makeUndefined(arena);
        return Vm{ .arena = arena, .realm = realm, .heap = heap, .current_this = undef_this, .generator_capture = null };
    }

    /// Register this Vm as a GC root-scan source.
    /// Call once, after the Vm is in its final stack location.
    pub fn registerHeapCallback(self: *Vm, heap: *Heap) !void {
        try heap.addScanCallback(.{
            .ctx = self,
            .scan = vmScanCallback,
        });
    }

    pub fn unregisterHeapCallback(self: *Vm, heap: *Heap) void {
        heap.removeScanCallback(self);
        self.realm.deinit();
    }

    pub fn deinit(_: *Vm) void {}

    // ---------------------------------------------------------------- helpers ---

    fn makeUndefined(self: *Vm) !Value {
        return val_mod.makeUndefined(self.arena);
    }

    fn makeNumber(self: *Vm, n: f64) !Value {
        return val_mod.makeNumber(self.arena, n);
    }

    fn makeBool(self: *Vm, b: bool) !Value {
        return val_mod.makeBool(self.arena, b);
    }

    fn makeString(self: *Vm, s: []const u8) !Value {
        return val_mod.makeString(self.arena, s);
    }

    fn makeNull(self: *Vm) !Value {
        return val_mod.makeNull(self.arena);
    }

    fn throwException(msg: []const u8) StmtResult {
        return StmtResult{ .exception = .{ .message = msg } };
    }

    // ------------------------------------------------------------------ hoisting ---

    /// Pre-scan a block of statements for var declarations and function decls,
    /// defining them in the given environment. Var initializers are NOT run;
    /// only the name is bound to undefined (or function value for func decls).
    fn hoistDeclarations(self: *Vm, stmts: []*Node, env: *Environment) !void {
        for (stmts) |stmt| {
            try self.hoistOne(stmt, env);
        }
    }

    fn hoistOne(self: *Vm, node: *Node, env: *Environment) !void {
        switch (node.kind) {
            .var_decl => {
                if (node.data.var_decl.kind != .var_) return;
                const name = node.data.var_decl.name;
                if (env.bindings.get(name) == null) {
                    const undef = try self.makeUndefined();
                    try env.define(name, undef);
                }
            },
            .block_stmt => {
                // Multiple var decls wrapped in a block by the parser
                for (node.data.block_stmt.body) |child| {
                    try self.hoistOne(child, env);
                }
            },
            .function_decl => {
                // Hoist function declaration: bind name to function value now.
                const fd = node.data.function_decl;
                const fv = try self.arena.create(FuncVal);
                fv.* = FuncVal{
                    .name = fd.name,
                    .params = fd.params,
                    .param_defaults = @as([*]?*anyopaque, @ptrCast(fd.param_defaults.ptr))[0..fd.param_defaults.len],
                    .rest_param = fd.rest_param,
                    .body_ptr = undefined, // will be set below via FuncWrapper
                    .closure_env = @ptrCast(env),
                    .is_strict = fd.is_strict,
                    .prototype_obj = try JsObject.create(self.arena, self.realm.object_prototype),
                    .is_arrow = false,
                    .lexical_this = Value{},
                    .is_generator = fd.is_generator,
                };
                // Wrap body slice so callFunction can recover it.
                const fw = try self.arena.create(FuncWrapper);
                fw.* = FuncWrapper{ .fv = fv, .body = fd.body };
                fv.body_ptr = @ptrCast(fw);
                const fv_val = try val_mod.makeFunction(self.arena, fv);
                try env.define(fd.name, fv_val);
            },
            .if_stmt => {
                // Hoist through branches
                try self.hoistOne(node.data.if_stmt.consequent, env);
                if (node.data.if_stmt.alternate) |alt| try self.hoistOne(alt, env);
            },
            .while_stmt => try self.hoistOne(node.data.while_stmt.body, env),
            .do_while_stmt => try self.hoistOne(node.data.do_while_stmt.body, env),
            .for_stmt => {
                if (node.data.for_stmt.init) |init_node_| try self.hoistOne(init_node_, env);
                try self.hoistOne(node.data.for_stmt.body, env);
            },
            .for_in_stmt => {
                if (node.data.for_in_stmt.left.kind == .var_decl) {
                    try self.hoistOne(node.data.for_in_stmt.left, env);
                }
                try self.hoistOne(node.data.for_in_stmt.body, env);
            },
            .switch_stmt => {
                for (node.data.switch_stmt.cases) |case| {
                    for (case.body) |stmt| try self.hoistOne(stmt, env);
                }
            },
            .labeled_stmt => try self.hoistOne(node.data.labeled_stmt.body, env),
            .try_stmt => {
                const ts = node.data.try_stmt;
                try self.hoistOne(ts.block, env);
                if (ts.handler) |h| try self.hoistOne(h.body, env);
                if (ts.finalizer) |f| try self.hoistOne(f, env);
            },
            else => {},
        }
    }

    fn predeclareLexicalsInBlock(self: *Vm, stmts: []*Node, env: *Environment) !void {
        const undef = try self.makeUndefined();
        for (stmts) |stmt| {
            if (stmt.kind == .var_decl) {
                const vd = stmt.data.var_decl;
                if (vd.kind != .var_) {
                    try env.defineLexical(vd.name, switch (vd.kind) {
                        .let => .let,
                        .const_ => .const_,
                        .var_ => .var_,
                    }, false, undef);
                }
            }
        }
    }

    // ---------------------------------------------------------------- context (Phase 4d) ---

    /// Called by invokeCallback to re-enter the VM for a JS function call.
    fn vmInvokeJs(ptr: *anyopaque, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
        const self: *Vm = @ptrCast(@alignCast(ptr));
        _ = arena; // use self.arena
        const inner = fn_val.toPtr().*;
        switch (inner) {
            .function => |fv| {
                return self.callFunction(fv, @constCast(args), this_val) catch |e| {
                    if (e == error.JsException) {
                        const realm_mod = @import("../runtime/realm.zig");
                        realm_mod.pending_exception = self.last_exception_value;
                        return error.JsException;
                    }
                    return error.OutOfMemory;
                };
            },
            .native_function => |nf| {
                return nf.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) return error.JsException;
                    return error.OutOfMemory;
                };
            },
            .object => |obj| {
                // Error constructor or bound function.
                if (obj.internal_kind == .bound_function) {
                    const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                    if (obj.internal_slot) |slot| {
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var combined = try self.arena.alloc(Value, bd.prefix.len + args.len);
                        for (bd.prefix, 0..) |v, i| combined[i] = v;
                        for (args, 0..) |v, i| combined[bd.prefix.len + i] = v;
                        return vmInvokeJs(ptr, self.arena, bd.this_val, bd.target, combined);
                    }
                }
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.toPtr().* == .native_function) {
                        const nf2 = call_val.toPtr().native_function;
                        return nf2.invoke(self.arena, this_val, args) catch |e| {
                            if (e == error.JsException) return error.JsException;
                            return error.OutOfMemory;
                        };
                    }
                }
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = self.makeTypeErrorObject("object is not a function") catch Value{};
                return error.JsException;
            },
            else => {
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = self.makeTypeErrorObject("value is not a function") catch Value{};
                return error.JsException;
            },
        }
    }

    fn activateContext(self: *Vm) void {
        self.context = @import("../runtime/realm.zig").Context{
            .ptr = self,
            .invoke_fn = vmInvokeJs,
        };
        const realm_mod = @import("../runtime/realm.zig");
        realm_mod.active_context = &self.context;
        realm_mod.eval_hook = vmEvalHook;
    }

    /// Re-enter the interpreter for the global `eval(src)`. Runs in the global
    /// scope (indirect-eval semantics, sufficient for ES5 conformance tests).
    fn vmEvalHook(ctx_ptr: *anyopaque, arena: std.mem.Allocator, source: []const u8) anyerror!Value {
        const self: *Vm = @ptrCast(@alignCast(ctx_ptr));
        const realm_mod = @import("../runtime/realm.zig");
        const parser_mod = @import("../parser/parser.zig");
        var p = parser_mod.Parser.init(source, arena);
        const pr = p.parseScript();
        const stmts = switch (pr) {
            .ok => |s| s,
            .err => |e| {
                realm_mod.pending_exception = self.makeErrorObject("SyntaxError", e.message) catch Value{};
                return error.JsException;
            },
        };
        const global_env = self.realm.global_env;
        try self.hoistDeclarations(stmts, global_env);
        var last = try self.makeUndefined();
        for (stmts) |stmt| {
            const r = try self.evalStatement(stmt, global_env);
            switch (r) {
                .value => |v| last = v,
                .exception => |ex| {
                    self.last_exception_value = ex.value;
                    self.last_exception_msg = ex.message;
                    realm_mod.pending_exception = ex.value;
                    return error.JsException;
                },
                else => {},
            }
        }
        return last;
    }

    fn deactivateContext(_: *Vm) void {
        @import("../runtime/realm.zig").active_context = null;
    }

    // ---------------------------------------------------------------- runScript ---

    /// Execute a top-level program, return the last expression statement value.
    pub fn runScript(self: *Vm, stmts: []*Node) !StmtResult {
        self.activateContext();
        defer self.deactivateContext();
        const global_env = self.realm.global_env;
        // Hoist top-level var / function declarations.
        try self.hoistDeclarations(stmts, global_env);
        // Predeclare top-level lexical declarations in TDZ.
        try self.predeclareLexicalsInBlock(stmts, global_env);
        var last = try self.makeUndefined();
        for (stmts) |stmt| {
            const r = try self.evalStatement(stmt, global_env);
            switch (r) {
                .value => |v| last = v,
                .return_ => return r, // propagate (shouldn't happen at top-level)
                .break_ => return r,
                .continue_ => return r,
                .exception => return r,
                .yield_suspend => return r,
            }
        }
        return StmtResult{ .value = last };
    }

    // ---------------------------------------------------------------- statements ---

    pub fn evalStatement(self: *Vm, node: *Node, env: *Environment) std.mem.Allocator.Error!StmtResult {
        switch (node.kind) {
            .expr_stmt => {
                const v = self.evalExpression(node.data.expr_stmt, env) catch |e| switch (e) {
                    error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                    else => return error.OutOfMemory,
                };
                if (self.takeGeneratorSuspend()) |sr| return sr;
                return StmtResult{ .value = v };
            },
            .var_decl => {
                const vd = node.data.var_decl;
                const init_val: Value = if (vd.init) |init_node|
                    self.evalExpression(init_node, env) catch |e| switch (e) {
                        error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                        else => return error.OutOfMemory,
                    }
                else
                    try self.makeUndefined();

                switch (vd.kind) {
                    .var_ => {
                        if (vd.init != null) {
                            env.assign(vd.name, init_val) catch |ae| switch (ae) {
                                error.NotDefined => try env.define(vd.name, init_val),
                                else => return error.OutOfMemory,
                            };
                        }
                    },
                    .let, .const_ => {
                        env.initialize(vd.name, init_val) catch |ae| switch (ae) {
                            error.NotDefined => {
                                try env.defineLexical(vd.name, if (vd.kind == .const_) .const_ else .let, true, init_val);
                            },
                            error.ConstAssignment, error.TemporalDeadZone => {
                                const msg = try std.fmt.allocPrint(self.arena, "{s} cannot be accessed before initialization", .{vd.name});
                                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
                                self.last_exception_value = self.makeReferenceErrorObject(msg) catch Value{};
                                return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                            },
                            else => return error.OutOfMemory,
                        };
                    },
                }
                if (self.takeGeneratorSuspend()) |sr| return sr;
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .block_stmt => {
                // Blocks create a lexical environment for let/const and TDZ.
                const block_env = try Environment.init(self.arena, env);
                try self.predeclareLexicalsInBlock(node.data.block_stmt.body, block_env);
                var last = try self.makeUndefined();
                for (node.data.block_stmt.body) |stmt| {
                    const r = try self.evalStatement(stmt, block_env);
                    switch (r) {
                        .value => |v| last = v,
                        else => return r,
                    }
                }
                return StmtResult{ .value = last };
            },
            .function_decl => {
                // Already hoisted; re-evaluate to handle forward refs correctly.
                // In Phase 1 we just return undefined.
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .if_stmt => {
                const is = node.data.if_stmt;
                const cond = self.evalExpression(is.test_, env) catch |e| switch (e) {
                    error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                    else => return error.OutOfMemory,
                };
                if (isTruthy(cond)) {
                    return self.evalStatement(is.consequent, env);
                } else if (is.alternate) |alt| {
                    return self.evalStatement(alt, env);
                }
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .while_stmt => {
                const ws = node.data.while_stmt;
                const in_gen = self.generator_capture != null;
                var loop_frame = if (in_gen) self.genLoopTop(node) else null;
                const resuming = loop_frame != null;
                if (!resuming and in_gen) {
                    try self.genLoopPush(node);
                    loop_frame = self.genLoopTop(node);
                }
                while (true) {
                    if (in_gen) {
                        if (loop_frame) |lf| lf.phase = .cond;
                    }
                    const cond = self.evalExpression(ws.test_, env) catch |e| switch (e) {
                        error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                        else => return error.OutOfMemory,
                    };
                    if (!isTruthy(cond)) break;
                    if (in_gen) {
                        if (loop_frame) |lf| lf.phase = .body;
                    }
                    const r = try self.evalStatement(ws.body, env);
                    switch (r) {
                        .value => {},
                        .break_ => |lbl| {
                            _ = lbl;
                            break;
                        },
                        .continue_ => |lbl| {
                            _ = lbl;
                            continue;
                        },
                        else => return r,
                    }
                }
                if (in_gen) self.genLoopPop();
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .do_while_stmt => {
                const dw = node.data.do_while_stmt;
                while (true) {
                    const r = try self.evalStatement(dw.body, env);
                    switch (r) {
                        .value => {},
                        .break_ => |lbl| {
                            _ = lbl;
                            break;
                        },
                        .continue_ => |lbl| {
                            _ = lbl;
                        },
                        else => return r,
                    }
                    const cond = self.evalExpression(dw.test_, env) catch |e| switch (e) {
                        error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                        else => return error.OutOfMemory,
                    };
                    if (!isTruthy(cond)) break;
                }
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .for_stmt => {
                const fs = node.data.for_stmt;
                const in_gen = self.generator_capture != null;
                var loop_frame = if (in_gen) self.genLoopTop(node) else null;
                const resuming = loop_frame != null;

                if (!resuming) {
                    if (fs.init) |init_node| {
                        const r = try self.evalStatement(init_node, env);
                        switch (r) {
                            .value => {},
                            else => return r,
                        }
                    }
                    if (in_gen) {
                        try self.genLoopPush(node);
                        loop_frame = self.genLoopTop(node);
                    }
                }

                while (true) {
                    if (in_gen) {
                        if (loop_frame) |lf| lf.phase = .cond;
                    }
                    if (fs.test_) |test_node| {
                        const cond = self.evalExpression(test_node, env) catch |e| switch (e) {
                            error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                            else => return error.OutOfMemory,
                        };
                        if (!isTruthy(cond)) break;
                    }
                    if (in_gen) {
                        if (loop_frame) |lf| lf.phase = .body;
                    }
                    const r = try self.evalStatement(fs.body, env);
                    switch (r) {
                        .value => {},
                        .break_ => |lbl| {
                            if (lbl != null) return r;
                            break;
                        },
                        .continue_ => |lbl| {
                            if (lbl != null) return r;
                        },
                        else => return r,
                    }
                    if (in_gen) {
                        if (loop_frame) |lf| lf.phase = .update;
                    }
                    if (fs.update) |update_node| {
                        _ = self.evalExpression(update_node, env) catch |e| switch (e) {
                            error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                            else => return error.OutOfMemory,
                        };
                    }
                }
                if (in_gen) self.genLoopPop();
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .break_stmt => return StmtResult{ .break_ = node.data.break_stmt },
            .continue_stmt => return StmtResult{ .continue_ = node.data.continue_stmt },
            .for_in_stmt => {
                const fi = node.data.for_in_stmt;
                // Evaluate the object.
                const obj_val = self.evalExpression(fi.right, env) catch |e| switch (e) {
                    error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                    else => return error.OutOfMemory,
                };
                // Collect enumerable keys (own + inherited, snapshot).
                var keys = std.ArrayList([]const u8){};
                var seen = std.StringHashMapUnmanaged(void){};
                defer seen.deinit(self.arena);
                if (obj_val.bits != 0) {
                    switch (obj_val.toPtr().*) {
                        .object => |obj| {
                            // Enumerate own properties only (prototype-chain properties
                            // from built-in prototypes are not user-visible as enumerable).
                            if (obj.is_array) {
                                var i: u32 = 0;
                                while (i < obj.array_length) : (i += 1) {
                                    const key = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch continue;
                                    if (!seen.contains(key)) {
                                        try seen.put(self.arena, key, {});
                                        try keys.append(self.arena, key);
                                    }
                                }
                            } else {
                                var it = obj.props.iterator();
                                while (it.next()) |entry| {
                                    const k = entry.key_ptr.*;
                                    if (!seen.contains(k)) {
                                        try seen.put(self.arena, k, {});
                                        try keys.append(self.arena, k);
                                    }
                                }
                            }
                        },
                        .string => |s| {
                            if (fi.iterate_values) {
                                for (s, 0..) |_, i| {
                                    const key = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch continue;
                                    if (!seen.contains(key)) {
                                        try seen.put(self.arena, key, {});
                                        try keys.append(self.arena, key);
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
                var iter_values = std.ArrayList(Value){};
                var use_iter_values = false;
                if (fi.iterate_values and obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                    use_iter_values = self.collectIteratorValues(&iter_values, obj_val) catch |e| switch (e) {
                        error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                        else => return error.OutOfMemory,
                    };
                }
                if (fi.iterate_values and !use_iter_values) {
                    if (obj_val.bits == 0) {
                        self.last_exception_msg = "TypeError: value is not iterable";
                        self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                        return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                    }
                    switch (obj_val.toPtr().*) {
                        .string => {},
                        .object => |obj| {
                            if (!obj.is_array) {
                                self.last_exception_msg = "TypeError: value is not iterable";
                                self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                                return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                            }
                        },
                        else => {
                            self.last_exception_msg = "TypeError: value is not iterable";
                            self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                            return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                        },
                    }
                }
                const iter_len: usize = if (use_iter_values) iter_values.items.len else keys.items.len;
                var iter_idx: usize = 0;
                while (iter_idx < iter_len) : (iter_idx += 1) {
                    const iter_val: Value = if (use_iter_values)
                        iter_values.items[iter_idx]
                    else blk: {
                        const key = keys.items[iter_idx];
                        if (fi.iterate_values and obj_val.bits != 0 and obj_val.toPtr().* == .string) {
                            const idx = std.fmt.parseInt(usize, key, 10) catch 0;
                            const s = obj_val.toPtr().string;
                            if (idx < s.len) {
                                const one = [_]u8{s[idx]};
                                break :blk try self.makeString(one[0..]);
                            }
                            break :blk try self.makeUndefined();
                        }
                        if (fi.iterate_values and obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                            break :blk obj_val.toPtr().object.get(key) orelse try self.makeUndefined();
                        }
                        break :blk try val_mod.makeString(self.arena, key);
                    };

                    var iter_env_for_body: *Environment = env;
                    // Assign loop variable.
                    switch (fi.left.kind) {
                        .var_decl => {
                            const vd = fi.left.data.var_decl;
                            const name = vd.name;
                            if (vd.kind == .var_) {
                                env.assign(name, iter_val) catch |e| switch (e) {
                                    error.NotDefined => try env.define(name, iter_val),
                                    error.ConstAssignment => {
                                        const msg = try std.fmt.allocPrint(self.arena, "Assignment to constant variable '{s}'", .{name});
                                        self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                                        self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                                        return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                                    },
                                    error.TemporalDeadZone => {
                                        const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
                                        self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
                                        self.last_exception_value = self.makeReferenceErrorObject(msg) catch Value{};
                                        return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                                    },
                                    else => return error.OutOfMemory,
                                };
                            } else {
                                const iter_scope = try Environment.init(self.arena, env);
                                try iter_scope.defineLexical(name, if (vd.kind == .const_) .const_ else .let, true, iter_val);
                                iter_env_for_body = iter_scope;
                            }
                        },
                        .identifier => {
                            const name = fi.left.data.identifier;
                            env.assign(name, iter_val) catch |e| switch (e) {
                                error.NotDefined => try env.define(name, iter_val),
                                error.ConstAssignment => {
                                    const msg = try std.fmt.allocPrint(self.arena, "Assignment to constant variable '{s}'", .{name});
                                    self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                                    self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                                    return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                                },
                                error.TemporalDeadZone => {
                                    const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
                                    self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
                                    self.last_exception_value = self.makeReferenceErrorObject(msg) catch Value{};
                                    return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } };
                                },
                                else => return error.OutOfMemory,
                            };
                        },
                        else => {},
                    }
                    const r = try self.evalStatement(fi.body, iter_env_for_body);
                    switch (r) {
                        .value => {},
                        .break_ => |lbl| {
                            if (lbl != null) return r;
                            break;
                        },
                        .continue_ => |lbl| {
                            if (lbl != null) return r;
                        },
                        else => return r,
                    }
                }
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .switch_stmt => {
                const sw = node.data.switch_stmt;
                const disc = self.evalExpression(sw.discriminant, env) catch |e| switch (e) {
                    error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                    else => return error.OutOfMemory,
                };
                // Find matching case (strict equality).
                var matched = false;
                var default_idx: ?usize = null;
                for (sw.cases, 0..) |case, ci| {
                    if (case.test_ == null) {
                        default_idx = ci;
                        continue;
                    }
                    if (!matched) {
                        const cv = self.evalExpression(case.test_.?, env) catch |e| switch (e) {
                            error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                            else => return error.OutOfMemory,
                        };
                        if (jsStrictEqual(disc, cv)) matched = true;
                    }
                    if (matched) {
                        for (case.body) |stmt| {
                            const r = try self.evalStatement(stmt, env);
                            switch (r) {
                                .value => {},
                                .break_ => |lbl| {
                                    if (lbl == null) return StmtResult{ .value = try self.makeUndefined() };
                                    return r;
                                },
                                else => return r,
                            }
                        }
                    }
                }
                // If no match, run default case.
                if (!matched) {
                    if (default_idx) |di| {
                        // Run from default case onward (fall-through).
                        var run = false;
                        for (sw.cases, 0..) |case, ci| {
                            if (ci == di or run) {
                                run = true;
                                for (case.body) |stmt| {
                                    const r = try self.evalStatement(stmt, env);
                                    switch (r) {
                                        .value => {},
                                        .break_ => |lbl| {
                                            if (lbl == null) return StmtResult{ .value = try self.makeUndefined() };
                                            return r;
                                        },
                                        else => return r,
                                    }
                                }
                            }
                        }
                    }
                }
                return StmtResult{ .value = try self.makeUndefined() };
            },
            .labeled_stmt => {
                const ls = node.data.labeled_stmt;
                const r = try self.evalStatement(ls.body, env);
                switch (r) {
                    .break_ => |lbl| {
                        if (lbl) |l| {
                            if (std.mem.eql(u8, l, ls.name)) {
                                return StmtResult{ .value = try self.makeUndefined() };
                            }
                        }
                        return r;
                    },
                    .continue_ => |lbl| {
                        if (lbl) |l| {
                            if (std.mem.eql(u8, l, ls.name)) {
                                // continue to labeled loop — propagate continue without label
                                // (the loop itself handles it). But here we just return value.
                                return StmtResult{ .value = try self.makeUndefined() };
                            }
                        }
                        return r;
                    },
                    else => return r,
                }
            },
            .return_stmt => {
                const rv: Value = if (node.data.return_stmt) |v_node|
                    (self.evalExpression(v_node, env) catch |e| switch (e) {
                        error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                        else => return error.OutOfMemory,
                    })
                else
                    try self.makeUndefined();
                return StmtResult{ .return_ = rv };
            },
            .empty_stmt => return StmtResult{ .value = try self.makeUndefined() },
            .debugger_stmt => return StmtResult{ .value = try self.makeUndefined() },
            .throw_stmt => {
                const arg = self.evalExpression(node.data.throw_stmt, env) catch |e| switch (e) {
                    error.JsException => return StmtResult{ .exception = .{ .message = self.last_exception_msg, .value = self.last_exception_value } },
                    else => return error.OutOfMemory,
                };
                // Build a string message from the thrown value.
                // Error-like objects (have name + message) format as "Name: message".
                const msg = formatExceptionMessage(self.arena, arg) catch "error";
                self.last_exception_msg = msg;
                self.last_exception_value = arg;
                return StmtResult{ .exception = .{ .message = msg, .value = arg } };
            },
            .try_stmt => {
                return self.evalTryStmt(node.data.try_stmt, env);
            },
            else => return StmtResult{ .value = try self.makeUndefined() },
        }
    }

    // -------------------------------------------------------------- expressions ---

    const EvalError = error{ JsException, OutOfMemory };

    pub fn evalExpression(self: *Vm, node: *Node, env: *Environment) EvalError!Value {
        switch (node.kind) {
            .number_literal => return self.makeNumber(node.data.number_literal),
            .string_literal => return self.makeString(node.data.string_literal),
            .bool_literal => return self.makeBool(node.data.bool_literal),
            .null_literal => return self.makeNull(),
            .undefined_literal => return self.makeUndefined(),
            .this_expr => {
                return self.current_this;
            },
            .identifier => {
                const name = node.data.identifier;
                return env.lookup(name) catch |e| switch (e) {
                    error.NotDefined => {
                        const detail = std.fmt.allocPrint(self.arena, "{s} is not defined", .{name}) catch "is not defined";
                        self.last_exception_msg = std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{detail}) catch "ReferenceError";
                        self.last_exception_value = self.makeReferenceErrorObject(detail) catch Value{};
                        return EvalError.JsException;
                    },
                    error.TemporalDeadZone => {
                        const detail = std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name}) catch "TDZ";
                        self.last_exception_msg = std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{detail}) catch "ReferenceError";
                        self.last_exception_value = self.makeReferenceErrorObject(detail) catch Value{};
                        return EvalError.JsException;
                    },
                    else => return EvalError.OutOfMemory,
                };
            },
            .unary_expr => return self.evalUnary(node.data.unary_expr, env),
            .binary_expr => return self.evalBinary(node.data.binary_expr, env),
            .logical_expr => return self.evalLogical(node.data.logical_expr, env),
            .assignment_expr => return self.evalAssign(node.data.assignment_expr, env),
            .update_expr => return self.evalUpdate(node.data.update_expr, env),
            .conditional_expr => {
                const ce = node.data.conditional_expr;
                const cond = try self.evalExpression(ce.test_, env);
                if (isTruthy(cond)) {
                    return self.evalExpression(ce.consequent, env);
                } else {
                    return self.evalExpression(ce.alternate, env);
                }
            },
            .sequence_expr => {
                const se = node.data.sequence_expr;
                var last = try self.makeUndefined();
                for (se.exprs) |e| {
                    last = try self.evalExpression(e, env);
                }
                return last;
            },
            .spread_expr => {
                return self.evalExpression(node.data.spread_expr, env);
            },
            .yield_expr => {
                if (self.generator_capture) |capture| {
                    if (capture.skip_yields > 0) {
                        capture.skip_yields -= 1;
                        if (capture.resume_index < capture.resume_values.len) {
                            const resumed = capture.resume_values[capture.resume_index];
                            capture.resume_index += 1;
                            return resumed;
                        }
                        return self.makeUndefined();
                    }
                    const yv = if (node.data.yield_expr) |yn|
                        try self.evalExpression(yn, env)
                    else
                        try self.makeUndefined();
                    try capture.yields.append(self.arena, yv);
                    capture.suspend_requested = true;
                    if (capture.resume_index < capture.resume_values.len) {
                        const resumed = capture.resume_values[capture.resume_index];
                        capture.resume_index += 1;
                        return resumed;
                    }
                    return self.makeUndefined();
                }
                self.last_exception_msg = "SyntaxError: yield is only valid inside generator functions";
                self.last_exception_value = self.makeErrorObject("SyntaxError", "yield is only valid inside generator functions") catch Value{};
                return EvalError.JsException;
            },
            .call_expr => return self.evalCall(node.data.call_expr, env),
            .new_expr => {
                return self.evalNewExpr(node.data.new_expr, env);
            },
            .function_expr => {
                const fe = node.data.function_expr;
                const fv = try self.arena.create(FuncVal);
                fv.* = FuncVal{
                    .name = fe.name,
                    .params = fe.params,
                    .param_defaults = @as([*]?*anyopaque, @ptrCast(fe.param_defaults.ptr))[0..fe.param_defaults.len],
                    .rest_param = fe.rest_param,
                    .body_ptr = @ptrCast(fe.body.ptr),
                    .closure_env = @ptrCast(env),
                    .is_strict = fe.is_strict,
                    .prototype_obj = if (fe.is_arrow) null else try JsObject.create(self.arena, self.realm.object_prototype),
                    .is_arrow = fe.is_arrow,
                    .lexical_this = if (fe.is_arrow) self.current_this else Value{},
                    .is_generator = fe.is_generator,
                    .requires_super = fe.requires_super,
                };
                // Store body length in a hidden way — we pack it via a wrapper.
                // Actually we need to store body length. Let's use a FuncWrapper.
                const fw = try self.arena.create(FuncWrapper);
                fw.* = FuncWrapper{ .fv = fv, .body = fe.body };
                fv.body_ptr = @ptrCast(fw);
                return val_mod.makeFunction(self.arena, fv);
            },
            .member_expr => {
                return self.evalMemberExpr(node.data.member_expr, env);
            },
            .optional_chain => {
                // Short-circuit boundary: evaluate the wrapped chain with a fresh
                // flag; if any optional link tripped it, the whole chain is undefined.
                const saved = self.optional_short_circuit;
                self.optional_short_circuit = false;
                const result = try self.evalExpression(node.data.optional_chain, env);
                const tripped = self.optional_short_circuit;
                self.optional_short_circuit = saved;
                if (tripped) return self.makeUndefined();
                return result;
            },
            .object_literal => {
                return self.evalObjectLiteral(node.data.object_literal, env);
            },
            .array_literal => {
                return self.evalArrayLiteral(node.data.array_literal, env);
            },
            .regex_literal => {
                return self.evalRegexLiteral(node.data.regex_literal);
            },
            else => return self.makeUndefined(),
        }
    }

    fn evalRegexLiteral(self: *Vm, rl: ast.RegexLiteral) EvalError!Value {
        const regexp_mod = @import("../runtime/builtins/regexp.zig");
        const cr = self.arena.create(regexp_mod.CompiledRegex) catch return EvalError.OutOfMemory;
        cr.* = regexp_mod.compileRegex(self.arena, rl.pattern, rl.flags) catch {
            // Throw SyntaxError
            const realm_m = @import("../runtime/realm.zig");
            const msg_s = std.fmt.allocPrint(self.arena, "Invalid regular expression: /{s}/{s}", .{ rl.pattern, rl.flags }) catch "SyntaxError";
            const proto_opt = realm_m.error_proto_SyntaxError;
            const obj = if (self.heap) |heap|
                JsObject.createOnHeap(heap, proto_opt) catch null
            else
                JsObject.create(self.arena, proto_opt) catch null;
            if (obj) |err_obj| {
                const msg_val = val_mod.makeString(self.arena, msg_s) catch Value{};
                const name_val = val_mod.makeString(self.arena, "SyntaxError") catch Value{};
                err_obj.set("message", msg_val) catch {};
                err_obj.set("name", name_val) catch {};
                self.last_exception_value = val_mod.makeObject(self.arena, err_obj) catch Value{};
            }
            self.last_exception_msg = msg_s;
            return EvalError.JsException;
        };
        return regexp_mod.makeRegExpObject(self.arena, cr, rl.pattern, rl.flags) catch return EvalError.OutOfMemory;
    }

    fn evalObjectLiteral(self: *Vm, ol: ast.ObjectLiteral, env: *Environment) EvalError!Value {
        const obj = if (self.heap) |heap|
            JsObject.createOnHeap(heap, self.realm.object_prototype) catch return EvalError.OutOfMemory
        else
            JsObject.create(self.arena, self.realm.object_prototype) catch return EvalError.OutOfMemory;
        for (ol.properties) |prop| {
            const v = try self.evalExpression(prop.value, env);
            obj.set(prop.key, v) catch return EvalError.OutOfMemory;
        }
        return val_mod.makeObject(self.arena, obj) catch return EvalError.OutOfMemory;
    }

    fn evalArrayLiteral(self: *Vm, al: ast.ArrayLiteral, env: *Environment) EvalError!Value {
        const arr = if (self.heap) |heap|
            JsObject.createArrayOnHeap(heap, self.realm.array_prototype) catch return EvalError.OutOfMemory
        else
            JsObject.createArray(self.arena, self.realm.array_prototype) catch return EvalError.OutOfMemory;
        var write_index: usize = 0;
        for (al.elements) |elem| {
            if (elem.kind == .spread_expr) {
                const spread_src = try self.evalExpression(elem.data.spread_expr, env);
                var spread_vals = std.ArrayList(Value){};
                try self.collectSpreadValues(&spread_vals, spread_src);
                for (spread_vals.items) |sv| {
                    const key = std.fmt.allocPrint(self.arena, "{d}", .{write_index}) catch return EvalError.OutOfMemory;
                    arr.set(key, sv) catch return EvalError.OutOfMemory;
                    write_index += 1;
                }
            } else {
                const v = try self.evalExpression(elem, env);
                const key = std.fmt.allocPrint(self.arena, "{d}", .{write_index}) catch return EvalError.OutOfMemory;
                arr.set(key, v) catch return EvalError.OutOfMemory;
                write_index += 1;
            }
        }
        arr.array_length = @intCast(write_index);
        return val_mod.makeObject(self.arena, arr) catch return EvalError.OutOfMemory;
    }

    fn collectSpreadValues(self: *Vm, out: *std.ArrayList(Value), source: Value) EvalError!void {
        if (source.bits == 0) return;
        switch (source.toPtr().*) {
            .object => |obj| {
                if (try self.collectIteratorValues(out, source)) return;
                if (obj.is_array) {
                    const len = obj.getArrayLength();
                    for (0..len) |i| {
                        const key = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return EvalError.OutOfMemory;
                        try out.append(self.arena, obj.get(key) orelse try self.makeUndefined());
                    }
                    return;
                }
                self.last_exception_msg = "TypeError: value is not iterable";
                self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                return EvalError.JsException;
            },
            .string => |s| {
                for (s) |ch| {
                    const one = [_]u8{ch};
                    try out.append(self.arena, try self.makeString(one[0..]));
                }
            },
            else => {},
        }
    }

    fn collectIteratorValues(self: *Vm, out: *std.ArrayList(Value), source: Value) EvalError!bool {
        if (source.bits == 0 or source.toPtr().* != .object) return false;
        const src_obj = source.toPtr().object;

        var iter_obj: ?*JsObject = null;
        var used_iterator_method = false;
        if (src_obj.get("@@iterator")) |iter_fn| {
            used_iterator_method = true;
            if (!isCallable(iter_fn)) {
                self.last_exception_msg = "TypeError: @@iterator is not callable";
                self.last_exception_value = self.makeTypeErrorObject("@@iterator is not callable") catch Value{};
                return EvalError.JsException;
            }
            const iter_val = try self.invokeCallable(source, iter_fn, &[_]Value{});
            if (iter_val.bits == 0 or iter_val.toPtr().* != .object) {
                self.last_exception_msg = "TypeError: iterator() must return object";
                self.last_exception_value = self.makeTypeErrorObject("iterator() must return object") catch Value{};
                return EvalError.JsException;
            }
            iter_obj = iter_val.toPtr().object;
        } else if (src_obj.get("iterator")) |iter_fn| {
            used_iterator_method = true;
            if (!isCallable(iter_fn)) {
                self.last_exception_msg = "TypeError: iterator is not callable";
                self.last_exception_value = self.makeTypeErrorObject("iterator is not callable") catch Value{};
                return EvalError.JsException;
            }
            const iter_val = try self.invokeCallable(source, iter_fn, &[_]Value{});
            if (iter_val.bits == 0 or iter_val.toPtr().* != .object) {
                self.last_exception_msg = "TypeError: iterator() must return object";
                self.last_exception_value = self.makeTypeErrorObject("iterator() must return object") catch Value{};
                return EvalError.JsException;
            }
            iter_obj = iter_val.toPtr().object;
        } else if (src_obj.get("next")) |_| {
            iter_obj = src_obj;
        } else {
            return false;
        }

        const it = iter_obj orelse {
            if (used_iterator_method) {
                self.last_exception_msg = "TypeError: iterator() must return object";
                self.last_exception_value = self.makeTypeErrorObject("iterator() must return object") catch Value{};
                return EvalError.JsException;
            }
            return false;
        };
        const next_fn = it.get("next") orelse {
            self.last_exception_msg = "TypeError: iterator missing next method";
            self.last_exception_value = self.makeTypeErrorObject("iterator missing next method") catch Value{};
            return EvalError.JsException;
        };
        if (!isCallable(next_fn)) {
            self.last_exception_msg = "TypeError: iterator next is not callable";
            self.last_exception_value = self.makeTypeErrorObject("iterator next is not callable") catch Value{};
            return EvalError.JsException;
        }
        var steps: usize = 0;
        while (steps < 100000) : (steps += 1) {
            const iter_this = val_mod.makeObject(self.arena, it) catch return EvalError.OutOfMemory;
            const step_val = self.invokeCallable(iter_this, next_fn, &[_]Value{}) catch |e| {
                self.closeIteratorIfPresent(it) catch {};
                return e;
            };
            if (step_val.bits == 0 or step_val.toPtr().* != .object) {
                self.closeIteratorIfPresent(it) catch {};
                self.last_exception_msg = "TypeError: iterator result is not an object";
                self.last_exception_value = self.makeTypeErrorObject("iterator result is not an object") catch Value{};
                return EvalError.JsException;
            }
            const step_obj = step_val.toPtr().object;
            const done_val = step_obj.get("done") orelse try self.makeBool(false);
            if (isTruthy(done_val)) break;
            const value_val = step_obj.get("value") orelse try self.makeUndefined();
            try out.append(self.arena, value_val);
        }
        if (steps >= 100000) {
            self.closeIteratorIfPresent(it) catch {};
            self.last_exception_msg = "RangeError: iterator exceeded step limit";
            self.last_exception_value = self.makeErrorObject("RangeError", "iterator exceeded step limit") catch Value{};
            return EvalError.JsException;
        }
        return true;
    }

    fn closeIteratorIfPresent(self: *Vm, iter_obj: *JsObject) EvalError!void {
        const return_fn = iter_obj.get("return") orelse return;
        if (!isCallable(return_fn)) return;
        const iter_this = val_mod.makeObject(self.arena, iter_obj) catch return EvalError.OutOfMemory;
        _ = self.invokeCallable(iter_this, return_fn, &[_]Value{}) catch {};
    }

    fn invokeCallable(self: *Vm, this_val: Value, fn_val: Value, args: []const Value) EvalError!Value {
        if (fn_val.bits == 0) return EvalError.JsException;
        switch (fn_val.toPtr().*) {
            .function => |fv| return self.callFunction(fv, @constCast(args), this_val),
            .native_function => |nf| {
                return nf.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) return EvalError.JsException;
                    return EvalError.OutOfMemory;
                };
            },
            else => return EvalError.JsException,
        }
    }

    fn evalMemberExpr(self: *Vm, me: ast.MemberExpr, env: *Environment) EvalError!Value {
        if (me.object.kind == .this_expr) try self.checkThisBeforeSuper();
        const obj_val = try self.evalExpression(me.object, env);
        // Optional chaining: a prior link already short-circuited.
        if (self.optional_short_circuit) return self.makeUndefined();
        // `obj?.prop` / `obj?.[expr]` on a nullish base short-circuits the chain.
        if (me.optional and obj_val.isNullish()) {
            self.optional_short_circuit = true;
            return self.makeUndefined();
        }
        // Resolve property key.
        const key = if (me.computed) blk: {
            const key_val = try self.evalExpression(me.property, env);
            break :blk valueToStringArena(self.arena, key_val) catch return EvalError.OutOfMemory;
        } else blk: {
            // Non-computed: property is an identifier node, use its name.
            break :blk me.property.data.identifier;
        };
        return self.getProperty(obj_val, key);
    }

    fn getProperty(self: *Vm, obj_val: Value, key: []const u8) EvalError!Value {
        if (obj_val.bits == 0) {
            const msg = std.fmt.allocPrint(self.arena, "Cannot read property '{s}' of undefined", .{key}) catch "TypeError";
            self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
            self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
            return EvalError.JsException;
        }
        switch (obj_val.toPtr().*) {
            .object => |obj| {
                // Special case: "length" on arrays.
                if (obj.is_array and std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(obj.getArrayLength())) catch return EvalError.OutOfMemory;
                }
                // ES2015 virtual "size" accessor on Map/Set.
                if (std.mem.eql(u8, key, "size")) {
                    if (@import("../runtime/builtins/es2015_collections.zig").collectionSize(obj)) |n| {
                        return val_mod.makeNumber(self.arena, @floatFromInt(n)) catch return EvalError.OutOfMemory;
                    }
                }
                if (obj.resolveOwnSlot(key)) |slot| {
                    if (obj.getOwnBySlot(obj.shapePtr(), slot)) |v| return v;
                }
                if (obj.get(key)) |v| return v;
                return self.makeUndefined();
            },
            .null_ => {
                const msg = std.fmt.allocPrint(self.arena, "Cannot read property '{s}' of null", .{key}) catch "TypeError";
                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                return EvalError.JsException;
            },
            .string => |s| {
                // Phase 4b: autoboxing for string primitives.
                // Special case: .length (instance-level, not on prototype)
                if (std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(s.len)) catch return EvalError.OutOfMemory;
                }
                // Delegate to String.prototype
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_string_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return self.makeUndefined();
            },
            .function => |fv| {
                if (std.mem.eql(u8, key, "prototype")) {
                    if (fv.prototype_obj) |po| {
                        return val_mod.makeObject(self.arena, po) catch return EvalError.OutOfMemory;
                    }
                    return self.makeUndefined();
                }
                if (std.mem.eql(u8, key, "name")) {
                    return self.makeString(fv.name orelse "");
                }
                if (std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(fv.params.len)) catch return EvalError.OutOfMemory;
                }
                if (fv.own_props) |op| {
                    if (op.get(key)) |v| return v;
                }
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return self.makeUndefined();
            },
            .bc_function, .native_function => {
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return self.makeUndefined();
            },
            else => return self.makeUndefined(),
        }
    }

    fn setProperty(self: *Vm, obj_val: Value, key: []const u8, value: Value) EvalError!void {
        if (obj_val.bits == 0) {
            const msg = std.fmt.allocPrint(self.arena, "TypeError: Cannot set property '{s}' of undefined", .{key}) catch "TypeError";
            self.last_exception_msg = msg;
            return EvalError.JsException;
        }
        switch (obj_val.toPtr().*) {
            .object => |obj| {
                if (obj.is_array and std.mem.eql(u8, key, "length")) {
                    if (value.bits != 0 and value.toPtr().* == .number) {
                        const n = value.toPtr().number;
                        if (n >= 0 and n == @floor(n) and n < 4294967296) {
                            const new_len: u32 = @intFromFloat(n);
                            // Clear indexed slots at or above new length.
                            var i = new_len;
                            while (i < obj.array_length) : (i += 1) {
                                const k = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch break;
                                obj.set(k, self.makeUndefined() catch Value{}) catch {};
                            }
                            obj.array_length = new_len;
                        }
                    }
                    return;
                }
                if (obj.resolveOwnSlot(key)) |slot| {
                    if (obj.setOwnBySlot(obj.shapePtr(), slot, value)) {
                        obj.props.put(obj.arena, key, value) catch return EvalError.OutOfMemory;
                        return;
                    }
                }
                obj.set(key, value) catch return EvalError.OutOfMemory;
            },
            .function => |fv| {
                if (std.mem.eql(u8, key, "prototype")) {
                    if (value.bits != 0 and value.toPtr().* == .object) {
                        fv.prototype_obj = value.toPtr().object;
                    }
                    return;
                }
                if (fv.own_props == null) {
                    fv.own_props = if (self.heap) |heap|
                        JsObject.createOnHeap(heap, null) catch return EvalError.OutOfMemory
                    else
                        JsObject.create(self.arena, null) catch return EvalError.OutOfMemory;
                }
                fv.own_props.?.set(key, value) catch return EvalError.OutOfMemory;
            },
            else => {
                // Silently ignore setting on non-objects (ES5 non-strict).
            },
        }
    }

    fn evalUnary(self: *Vm, u: ast.UnaryExpr, env: *Environment) EvalError!Value {
        switch (u.op) {
            .typeof_ => {
                // Special: typeof on undefined identifier should return "undefined", not throw.
                const v: Value = if (u.operand.kind == .identifier) blk: {
                    const name = u.operand.data.identifier;
                    break :blk env.lookup(name) catch |e| switch (e) {
                        error.NotDefined => try self.makeUndefined(),
                        error.TemporalDeadZone => {
                            const msg = std.fmt.allocPrint(self.arena, "ReferenceError: Cannot access '{s}' before initialization", .{name}) catch "ReferenceError";
                            self.last_exception_msg = msg;
                            return EvalError.JsException;
                        },
                        else => return EvalError.OutOfMemory,
                    };
                } else try self.evalExpression(u.operand, env);
                const type_str = typeofValue(v);
                return self.makeString(type_str);
            },
            .void_ => {
                _ = try self.evalExpression(u.operand, env);
                return self.makeUndefined();
            },
            .delete_ => {
                // Phase 1: always return true (delete has no effect)
                _ = try self.evalExpression(u.operand, env);
                return self.makeBool(true);
            },
            .neg => {
                const v = try self.evalExpression(u.operand, env);
                return self.makeNumber(-toNumber(v));
            },
            .pos => {
                const v = try self.evalExpression(u.operand, env);
                return self.makeNumber(toNumber(v));
            },
            .not => {
                const v = try self.evalExpression(u.operand, env);
                return self.makeBool(!isTruthy(v));
            },
            .bit_not => {
                const v = try self.evalExpression(u.operand, env);
                const n: i32 = toInt32(v);
                return self.makeNumber(@floatFromInt(~n));
            },
            .pre_inc => {
                const v = try self.evalExpression(u.operand, env);
                const n = toNumber(v) + 1.0;
                try self.assignLvalue(u.operand, env, try self.makeNumber(n));
                return self.makeNumber(n);
            },
            .pre_dec => {
                const v = try self.evalExpression(u.operand, env);
                const n = toNumber(v) - 1.0;
                try self.assignLvalue(u.operand, env, try self.makeNumber(n));
                return self.makeNumber(n);
            },
        }
    }

    fn evalBinary(self: *Vm, b: ast.BinaryExpr, env: *Environment) EvalError!Value {
        const left = try self.evalExpression(b.left, env);
        const right = try self.evalExpression(b.right, env);

        switch (b.op) {
            .add => return self.jsAdd(left, right),
            .sub => return self.makeNumber(toNumber(left) - toNumber(right)),
            .mul => return self.makeNumber(toNumber(left) * toNumber(right)),
            .div => return self.makeNumber(toNumber(left) / toNumber(right)),
            .mod => {
                const l = toNumber(left);
                const r = toNumber(right);
                return self.makeNumber(std.math.mod(f64, l, r) catch std.math.nan(f64));
            },
            .exp => return self.makeNumber(std.math.pow(f64, toNumber(left), toNumber(right))),
            .bit_and => return self.makeNumber(@floatFromInt(toInt32(left) & toInt32(right))),
            .bit_or => return self.makeNumber(@floatFromInt(toInt32(left) | toInt32(right))),
            .bit_xor => return self.makeNumber(@floatFromInt(toInt32(left) ^ toInt32(right))),
            .lshift => return self.makeNumber(@floatFromInt(toInt32(left) << @intCast(toUint32(right) & 0x1F))),
            .rshift => return self.makeNumber(@floatFromInt(toInt32(left) >> @intCast(toUint32(right) & 0x1F))),
            .urshift => {
                const u: u32 = @bitCast(toInt32(left));
                const shift: u5 = @intCast(toUint32(right) & 0x1F);
                return self.makeNumber(@floatFromInt(u >> shift));
            },
            .lt => return self.makeBool(jsLessThan(left, right, false) orelse false),
            .lte => {
                // a <= b  ==  !(b < a)
                const r = jsLessThan(right, left, true);
                return self.makeBool(if (r) |v| !v else false);
            },
            .gt => return self.makeBool(jsLessThan(right, left, false) orelse false),
            .gte => {
                const r = jsLessThan(left, right, true);
                return self.makeBool(if (r) |v| !v else false);
            },
            .instanceof => {
                return self.makeBool(jsInstanceof(left, right));
            },
            .in => {
                // Phase 3a: check if property exists in object.
                if (right.bits != 0 and right.toPtr().* == .object) {
                    const obj = right.toPtr().object;
                    const key = valueToStringArena(self.arena, left) catch return EvalError.OutOfMemory;
                    return self.makeBool(obj.get(key) != null);
                }
                return self.makeBool(false);
            },
            .eq => return self.makeBool(jsAbstractEqual(left, right)),
            .neq => return self.makeBool(!jsAbstractEqual(left, right)),
            .strict_eq => return self.makeBool(jsStrictEqual(left, right)),
            .strict_neq => return self.makeBool(!jsStrictEqual(left, right)),
        }
    }

    fn jsAdd(self: *Vm, left: Value, right: Value) EvalError!Value {
        // If either operand is an object, convert to primitive first (simplified: use "[object Object]").
        const ls = isStringOrObject(left);
        const rs = isStringOrObject(right);
        if (ls or rs) {
            const ls_str = try valueToString(self.arena, left);
            const rs_str = try valueToString(self.arena, right);
            const combined = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls_str, rs_str });
            return self.makeString(combined);
        }
        return self.makeNumber(toNumber(left) + toNumber(right));
    }

    fn evalLogical(self: *Vm, l: ast.LogicalExpr, env: *Environment) EvalError!Value {
        const left = try self.evalExpression(l.left, env);
        switch (l.op) {
            .and_ => {
                if (!isTruthy(left)) return left;
                return self.evalExpression(l.right, env);
            },
            .or_ => {
                if (isTruthy(left)) return left;
                return self.evalExpression(l.right, env);
            },
            .nullish => {
                if (!left.isNullish()) return left;
                return self.evalExpression(l.right, env);
            },
        }
    }

    fn evalAssign(self: *Vm, a: ast.AssignExpr, env: *Environment) EvalError!Value {
        if (a.op == .assign) {
            const v = try self.evalExpression(a.value, env);
            try self.assignLvalue(a.target, env, v);
            return v;
        }
        // ES2021 logical assignment: short-circuit — only evaluate RHS and assign
        // when the LHS condition holds. Returns the current LHS otherwise.
        switch (a.op) {
            .logical_and, .logical_or, .logical_nullish => {
                const cur = try self.evalExpression(a.target, env);
                const do_assign = switch (a.op) {
                    .logical_and => isTruthy(cur),
                    .logical_or => !isTruthy(cur),
                    .logical_nullish => cur.isNullish(),
                    else => unreachable,
                };
                if (!do_assign) return cur;
                const v = try self.evalExpression(a.value, env);
                try self.assignLvalue(a.target, env, v);
                return v;
            },
            else => {},
        }
        // Compound assignment: read, apply op, write back.
        const cur_val = try self.evalExpression(a.target, env);
        const rhs = try self.evalExpression(a.value, env);
        const result = switch (a.op) {
            .add => try self.jsAdd(cur_val, rhs),
            .sub => try self.makeNumber(toNumber(cur_val) - toNumber(rhs)),
            .mul => try self.makeNumber(toNumber(cur_val) * toNumber(rhs)),
            .div => try self.makeNumber(toNumber(cur_val) / toNumber(rhs)),
            .mod => try self.makeNumber(std.math.mod(f64, toNumber(cur_val), toNumber(rhs)) catch std.math.nan(f64)),
            .exp => try self.makeNumber(std.math.pow(f64, toNumber(cur_val), toNumber(rhs))),
            .bit_and => try self.makeNumber(@floatFromInt(toInt32(cur_val) & toInt32(rhs))),
            .bit_or => try self.makeNumber(@floatFromInt(toInt32(cur_val) | toInt32(rhs))),
            .bit_xor => try self.makeNumber(@floatFromInt(toInt32(cur_val) ^ toInt32(rhs))),
            .lshift => try self.makeNumber(@floatFromInt(toInt32(cur_val) << @intCast(toUint32(rhs) & 0x1F))),
            .rshift => try self.makeNumber(@floatFromInt(toInt32(cur_val) >> @intCast(toUint32(rhs) & 0x1F))),
            .urshift => blk: {
                const u: u32 = @bitCast(toInt32(cur_val));
                const shift: u5 = @intCast(toUint32(rhs) & 0x1F);
                break :blk try self.makeNumber(@floatFromInt(u >> shift));
            },
            .assign, .logical_and, .logical_or, .logical_nullish => unreachable,
        };
        try self.assignLvalue(a.target, env, result);
        return result;
    }

    fn assignLvalue(self: *Vm, target: *Node, env: *Environment, value: Value) EvalError!void {
        switch (target.kind) {
            .identifier => {
                const name = target.data.identifier;
                env.assign(name, value) catch |e| switch (e) {
                    error.NotDefined => {
                        if (self.is_strict) {
                            // Phase 4d: strict mode — undeclared variable assignment is a ReferenceError.
                            const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
                            self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
                            self.last_exception_value = self.makeReferenceErrorObject(msg) catch Value{};
                            return EvalError.JsException;
                        }
                        // Auto-create global
                        env.defineGlobal(name, value) catch return EvalError.OutOfMemory;
                    },
                    error.ConstAssignment => {
                        const msg = try std.fmt.allocPrint(self.arena, "Assignment to constant variable '{s}'", .{name});
                        self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                        self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                        return EvalError.JsException;
                    },
                    error.TemporalDeadZone => {
                        const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
                        self.last_exception_msg = try std.fmt.allocPrint(self.arena, "ReferenceError: {s}", .{msg});
                        self.last_exception_value = self.makeReferenceErrorObject(msg) catch Value{};
                        return EvalError.JsException;
                    },
                    else => return EvalError.OutOfMemory,
                };
            },
            .member_expr => {
                const me = target.data.member_expr;
                if (me.object.kind == .this_expr) try self.checkThisBeforeSuper();
                const obj_val = try self.evalExpression(me.object, env);
                const key = if (me.computed) blk: {
                    const key_val = try self.evalExpression(me.property, env);
                    break :blk valueToStringArena(self.arena, key_val) catch return EvalError.OutOfMemory;
                } else blk: {
                    break :blk me.property.data.identifier;
                };
                try self.setProperty(obj_val, key, value);
            },
            else => {
                // Non-assignable lvalue is a no-op
            },
        }
    }

    fn evalUpdate(self: *Vm, u: ast.UpdateExpr, env: *Environment) EvalError!Value {
        const old_val = try self.evalExpression(u.operand, env);
        const old_num = toNumber(old_val);
        const new_num = if (u.op == .inc) old_num + 1.0 else old_num - 1.0;
        const new_val = try self.makeNumber(new_num);
        try self.assignLvalue(u.operand, env, new_val);
        if (u.prefix) return new_val;
        return self.makeNumber(old_num);
    }

    fn evalCall(self: *Vm, c: ast.CallExpr, env: *Environment) EvalError!Value {
        if (c.callee.kind == .identifier and std.mem.eql(u8, c.callee.data.identifier, "__yield_star__")) {
            if (self.generator_capture) |capture| {
                if (c.args.len != 1) return self.makeUndefined();
                const delegated = try self.evalExpression(c.args[0], env);
                return self.evalYieldStar(capture, delegated);
            }
            self.last_exception_msg = "SyntaxError: yield* is only valid inside generator functions";
            self.last_exception_value = self.makeErrorObject("SyntaxError", "yield* is only valid inside generator functions") catch Value{};
            return EvalError.JsException;
        }

        // Check if callee is a member expression (method call).
        const is_method = c.callee.kind == .member_expr;
        var this_val: Value = try self.makeUndefined();
        var callee_val: Value = undefined;

        if (is_method) {
            const me = c.callee.data.member_expr;
            const obj_val = try self.evalExpression(me.object, env);
            if (self.optional_short_circuit) return self.makeUndefined();
            if (me.optional and obj_val.isNullish()) {
                self.optional_short_circuit = true;
                return self.makeUndefined();
            }
            this_val = obj_val;
            const key = if (me.computed) blk: {
                const key_val = try self.evalExpression(me.property, env);
                break :blk valueToStringArena(self.arena, key_val) catch return EvalError.OutOfMemory;
            } else blk: {
                break :blk me.property.data.identifier;
            };
            callee_val = try self.getProperty(obj_val, key);
        } else {
            callee_val = try self.evalExpression(c.callee, env);
        }

        // Optional chaining: callee evaluation short-circuited upstream.
        if (self.optional_short_circuit) return self.makeUndefined();
        // `f?.(args)` on a nullish callee short-circuits the chain (args not evaluated).
        if (c.optional and callee_val.isNullish()) {
            self.optional_short_circuit = true;
            return self.makeUndefined();
        }

        if (isSuperCall(c)) self.derived_super_called = true;

        // Evaluate arguments
        var arg_vals = std.ArrayList(Value){};
        for (c.args) |a| {
            if (a.kind == .spread_expr) {
                const spread_src = try self.evalExpression(a.data.spread_expr, env);
                try self.collectSpreadValues(&arg_vals, spread_src);
            } else {
                const av = try self.evalExpression(a, env);
                try arg_vals.append(self.arena, av);
            }
        }

        // Dispatch based on callee type.
        if (callee_val.bits == 0) {
            self.last_exception_msg = "TypeError: undefined is not a function";
            self.last_exception_value = self.makeTypeErrorObject("undefined is not a function") catch Value{};
            return EvalError.JsException;
        }
        const inner = callee_val.toPtr();
        switch (inner.*) {
            .function => {
                return self.callFunction(inner.function, arg_vals.items, this_val);
            },
            .native_function => |fn_ptr| {
                return fn_ptr.invoke(self.arena, this_val, arg_vals.items) catch |e| {
                    if (e == error.JsException) {
                        // Check for pending exception set by native code (e.g. JSON.parse).
                        const realm_mod = @import("../runtime/realm.zig");
                        if (realm_mod.pending_exception.bits != 0) {
                            self.last_exception_value = realm_mod.pending_exception;
                            realm_mod.pending_exception = Value{};
                            const msg = formatExceptionMessage(self.arena, self.last_exception_value) catch "error";
                            self.last_exception_msg = msg;
                        }
                        return EvalError.JsException;
                    }
                    return EvalError.OutOfMemory;
                };
            },
            .object => |obj| {
                // Phase 4d: bound function.
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var combined = try self.arena.alloc(Value, bd.prefix.len + arg_vals.items.len);
                        for (bd.prefix, 0..) |v, i| combined[i] = v;
                        for (arg_vals.items, 0..) |v, i| combined[bd.prefix.len + i] = v;
                        const bound_inner = bd.target.toPtr().*;
                        switch (bound_inner) {
                            .function => |fv| return self.callFunction(fv, combined, bd.this_val),
                            .native_function => |fn_ptr| {
                                return fn_ptr.invoke(self.arena, bd.this_val, combined) catch |e| {
                                    if (e == error.JsException) {
                                        const realm_mod = @import("../runtime/realm.zig");
                                        if (realm_mod.pending_exception.bits != 0) {
                                            self.last_exception_value = realm_mod.pending_exception;
                                            realm_mod.pending_exception = Value{};
                                            const fmsg = formatExceptionMessage(self.arena, self.last_exception_value) catch "error";
                                            self.last_exception_msg = fmsg;
                                        }
                                        return EvalError.JsException;
                                    }
                                    return EvalError.OutOfMemory;
                                };
                            },
                            else => {},
                        }
                    }
                }
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.toPtr().* == .native_function) {
                        const fn_ptr2 = call_val.toPtr().native_function;
                        if (obj.get("prototype") != null) {
                            // Preserve legacy behavior for Error-like constructor objects.
                            return self.doConstruct(callee_val, arg_vals.items);
                        }
                        return fn_ptr2.invoke(self.arena, callee_val, arg_vals.items) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    const fmsg = formatExceptionMessage(self.arena, self.last_exception_value) catch "error";
                                    self.last_exception_msg = fmsg;
                                    realm_mod.pending_exception = Value{};
                                } else if (self.last_exception_value.bits != 0) {
                                    const fmsg = formatExceptionMessage(self.arena, self.last_exception_value) catch "error";
                                    self.last_exception_msg = fmsg;
                                }
                                return EvalError.JsException;
                            }
                            return EvalError.OutOfMemory;
                        };
                    }
                }
                const msg = "object is not a function";
                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                return EvalError.JsException;
            },
            else => {
                const msg = try std.fmt.allocPrint(self.arena, "{s} is not a function", .{typeofValue(callee_val)});
                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                self.last_exception_value = self.makeTypeErrorObject(msg) catch Value{};
                return EvalError.JsException;
            },
        }
    }

    fn evalYieldStar(self: *Vm, capture: *GeneratorCapture, delegated: Value) EvalError!Value {
        const state = capture.state orelse return self.makeUndefined();
        if (capture.yield_star_iter == null and capture.yield_star_array == null) {
            if (delegated.bits != 0 and delegated.toPtr().* == .object) {
                const src_obj = delegated.toPtr().object;
                if (src_obj.is_array) {
                    capture.yield_star_array = src_obj;
                    capture.yield_star_array_index = 0;
                } else {
                    var iter_obj: ?*JsObject = null;
                    if (src_obj.get("@@iterator")) |iter_fn| {
                        const iter_val = try self.invokeCallable(delegated, iter_fn, &[_]Value{});
                        if (iter_val.bits != 0 and iter_val.toPtr().* == .object) iter_obj = iter_val.toPtr().object;
                    } else if (src_obj.get("iterator")) |iter_fn| {
                        const iter_val = try self.invokeCallable(delegated, iter_fn, &[_]Value{});
                        if (iter_val.bits != 0 and iter_val.toPtr().* == .object) iter_obj = iter_val.toPtr().object;
                    } else if (src_obj.get("next")) |_| {
                        iter_obj = src_obj;
                    }
                    if (iter_obj == null) {
                        self.last_exception_msg = "TypeError: value is not iterable";
                        self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                        return EvalError.JsException;
                    }
                    capture.yield_star_iter = iter_obj;
                }
            } else {
                self.last_exception_msg = "TypeError: value is not iterable";
                self.last_exception_value = self.makeTypeErrorObject("value is not iterable") catch Value{};
                return EvalError.JsException;
            }
        }
        if (capture.yield_star_array) |arr| {
            const len = arr.getArrayLength();
            if (capture.yield_star_array_index >= len) {
                capture.yield_star_array = null;
                capture.yield_star_array_index = 0;
                return self.makeUndefined();
            }
            const key = std.fmt.allocPrint(self.arena, "{d}", .{capture.yield_star_array_index}) catch return EvalError.OutOfMemory;
            const value_val = arr.get(key) orelse try self.makeUndefined();
            capture.yield_star_array_index += 1;
            try capture.yields.append(self.arena, value_val);
            capture.suspend_requested = true;
            return value_val;
        }
        const it = capture.yield_star_iter orelse return self.makeUndefined();
        if (it.internal_slot != null) {
            const gen_val = val_mod.makeObject(self.arena, it) catch return EvalError.OutOfMemory;
            const step_val = nativeGeneratorNext(self.arena, gen_val, &[_]Value{}) catch |e| {
                capture.yield_star_iter = null;
                if (e == error.JsException) return EvalError.JsException;
                return EvalError.OutOfMemory;
            };
            if (step_val.bits == 0 or step_val.toPtr().* != .object) {
                capture.yield_star_iter = null;
                self.last_exception_msg = "TypeError: iterator result is not an object";
                self.last_exception_value = self.makeTypeErrorObject("iterator result is not an object") catch Value{};
                return EvalError.JsException;
            }
            const step_obj = step_val.toPtr().object;
            const done_val = step_obj.get("done") orelse try self.makeBool(false);
            const value_val = step_obj.get("value") orelse try self.makeUndefined();
            if (isTruthy(done_val)) {
                capture.yield_star_iter = null;
                const is_undef = value_val.bits == 0 or (value_val.bits != 0 and value_val.toPtr().* == .undefined_);
                if (!is_undef) {
                    state.return_value = value_val;
                    capture.delegate_return = true;
                    capture.suspend_requested = true;
                }
                return value_val;
            }
            try capture.yields.append(self.arena, value_val);
            capture.suspend_requested = true;
            return value_val;
        }
        const next_fn = it.get("next") orelse {
            self.last_exception_msg = "TypeError: iterator missing next method";
            self.last_exception_value = self.makeTypeErrorObject("iterator missing next method") catch Value{};
            return EvalError.JsException;
        };
        if (!isCallable(next_fn)) {
            self.last_exception_msg = "TypeError: iterator next is not callable";
            self.last_exception_value = self.makeTypeErrorObject("iterator next is not callable") catch Value{};
            return EvalError.JsException;
        }
        const iter_this = val_mod.makeObject(self.arena, it) catch return EvalError.OutOfMemory;
        const step_val = self.invokeCallable(iter_this, next_fn, &[_]Value{}) catch |e| {
            capture.yield_star_iter = null;
            self.closeIteratorIfPresent(it) catch {};
            return e;
        };
        if (step_val.bits == 0 or step_val.toPtr().* != .object) {
            capture.yield_star_iter = null;
            self.closeIteratorIfPresent(it) catch {};
            self.last_exception_msg = "TypeError: iterator result is not an object";
            self.last_exception_value = self.makeTypeErrorObject("iterator result is not an object") catch Value{};
            return EvalError.JsException;
        }
        const step_obj = step_val.toPtr().object;
        const done_val = step_obj.get("done") orelse try self.makeBool(false);
        if (isTruthy(done_val)) {
            capture.yield_star_iter = null;
            const return_val = step_obj.get("value") orelse try self.makeUndefined();
            const is_undef = return_val.bits == 0 or (return_val.bits != 0 and return_val.toPtr().* == .undefined_);
            if (!is_undef) {
                state.return_value = return_val;
                capture.delegate_return = true;
                capture.suspend_requested = true;
            }
            return return_val;
        }
        const value_val = step_obj.get("value") orelse try self.makeUndefined();
        try capture.yields.append(self.arena, value_val);
        capture.suspend_requested = true;
        return value_val;
    }

    fn callFunction(self: *Vm, fv: *FuncVal, args: []Value, this_val: Value) EvalError!Value {
        // Reconstruct body from FuncWrapper
        const fw: *FuncWrapper = @ptrCast(@alignCast(fv.body_ptr));
        const body = fw.body;
        const closure_env: *Environment = @ptrCast(@alignCast(fv.closure_env));

        if (fv.is_generator) {
            return createGeneratorObject(self, fv, body, closure_env, args, this_val);
        }

        // Create a new environment for the function call.
        const call_env = Environment.init(self.arena, closure_env) catch return EvalError.OutOfMemory;

        // ES5/ES2015 interop: expose `arguments` as an array-like object.
        const arguments_obj = if (self.heap) |heap|
            JsObject.createArrayOnHeap(heap, self.realm.array_prototype) catch return EvalError.OutOfMemory
        else
            JsObject.createArray(self.arena, self.realm.array_prototype) catch return EvalError.OutOfMemory;
        for (args, 0..) |av, i| {
            const key = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return EvalError.OutOfMemory;
            arguments_obj.set(key, av) catch return EvalError.OutOfMemory;
        }
        arguments_obj.array_length = @intCast(args.len);
        const arguments_val = val_mod.makeObject(self.arena, arguments_obj) catch return EvalError.OutOfMemory;
        call_env.define("arguments", arguments_val) catch return EvalError.OutOfMemory;

        // Bind parameters
        const param_defaults: []?*Node = @as([*]?*Node, @ptrCast(fv.param_defaults.ptr))[0..fv.param_defaults.len];
        for (fv.params, 0..) |param, i| {
            var av = if (i < args.len) args[i] else try self.makeUndefined();
            if (i < param_defaults.len and param_defaults[i] != null) {
                const is_undef = av.bits == 0 or (av.bits != 0 and av.toPtr().* == .undefined_);
                if (is_undef) {
                    av = try self.evalExpression(param_defaults[i].?, call_env);
                }
            }
            call_env.define(param, av) catch return EvalError.OutOfMemory;
        }
        if (fv.rest_param) |rest_name| {
            const rest_arr = if (self.heap) |heap|
                JsObject.createArrayOnHeap(heap, self.realm.array_prototype) catch return EvalError.OutOfMemory
            else
                JsObject.createArray(self.arena, self.realm.array_prototype) catch return EvalError.OutOfMemory;
            const start_index = fv.params.len;
            var write_idx: usize = 0;
            var i = start_index;
            while (i < args.len) : (i += 1) {
                const key = std.fmt.allocPrint(self.arena, "{d}", .{write_idx}) catch return EvalError.OutOfMemory;
                rest_arr.set(key, args[i]) catch return EvalError.OutOfMemory;
                write_idx += 1;
            }
            rest_arr.array_length = @intCast(write_idx);
            const rest_val = val_mod.makeObject(self.arena, rest_arr) catch return EvalError.OutOfMemory;
            call_env.define(rest_name, rest_val) catch return EvalError.OutOfMemory;
        }

        // Named function expression: bind the function name inside the body (ES5 §13).
        // This is what makes recursive NFEs like (function fib(n){...})(20) work.
        if (fv.name) |fname| {
            const self_val = try val_mod.makeFunction(self.arena, fv);
            call_env.define(fname, self_val) catch return EvalError.OutOfMemory;
        }

        // Hoist var/function declarations in the function body.
        self.hoistDeclarations(body, call_env) catch return EvalError.OutOfMemory;
        self.predeclareLexicalsInBlock(body, call_env) catch return EvalError.OutOfMemory;

        // Phase 4d: strict mode this-binding.
        // In strict mode: this is as-is. In non-strict: null/undefined -> global (undefined here).
        const effective_this = if (fv.is_arrow) fv.lexical_this else if (fv.is_strict) this_val else this_val;

        // Save and set current_this and strict mode.
        const prev_this = self.current_this;
        const prev_strict = self.is_strict;
        self.current_this = effective_this;
        self.is_strict = fv.is_strict;
        defer self.current_this = prev_this;
        defer self.is_strict = prev_strict;

        // Track the innermost call env so GC can root locals.
        const prev_call_env = self.current_call_env;
        self.current_call_env = call_env;
        defer self.current_call_env = prev_call_env;

        const prev_super_pending = self.derived_super_pending;
        const prev_super_called = self.derived_super_called;
        self.derived_super_pending = fv.requires_super;
        self.derived_super_called = false;
        defer {
            self.derived_super_pending = prev_super_pending;
            self.derived_super_called = prev_super_called;
        }

        // Execute body
        for (body) |stmt| {
            const r = self.evalStatement(stmt, call_env) catch return EvalError.OutOfMemory;
            switch (r) {
                .value => {},
                .return_ => |rv| return rv,
                .exception => |ex| {
                    self.last_exception_msg = ex.message;
                    self.last_exception_value = ex.value;
                    return EvalError.JsException;
                },
                .break_ => break,
                .continue_ => break,
                .yield_suspend => {
                    self.last_exception_msg = "SyntaxError: yield is only valid inside generator functions";
                    self.last_exception_value = self.makeErrorObject("SyntaxError", "yield is only valid inside generator functions") catch Value{};
                    return EvalError.JsException;
                },
            }
        }
        return self.makeUndefined();
    }

    fn createGeneratorObject(self: *Vm, fv: *FuncVal, body: []*Node, closure_env: *Environment, args: []Value, this_val: Value) EvalError!Value {
        const state = self.arena.create(GeneratorState) catch return EvalError.OutOfMemory;
        state.* = .{
            .vm = self,
            .func = fv,
            .body = body,
            .closure_env = closure_env,
            .args = args,
            .this_val = this_val,
        };

        const gen_obj = if (self.heap) |heap|
            JsObject.createOnHeap(heap, self.realm.object_prototype) catch return EvalError.OutOfMemory
        else
            JsObject.create(self.arena, self.realm.object_prototype) catch return EvalError.OutOfMemory;
        gen_obj.internal_slot = state;

        const next_fn = val_mod.makeNativeFunction(self.arena, nativeGeneratorNext) catch return EvalError.OutOfMemory;
        gen_obj.set("next", next_fn) catch return EvalError.OutOfMemory;
        const return_fn = val_mod.makeNativeFunction(self.arena, nativeGeneratorReturn) catch return EvalError.OutOfMemory;
        gen_obj.set("return", return_fn) catch return EvalError.OutOfMemory;
        const throw_fn = val_mod.makeNativeFunction(self.arena, nativeGeneratorThrow) catch return EvalError.OutOfMemory;
        gen_obj.set("throw", throw_fn) catch return EvalError.OutOfMemory;
        // Existing iterator paths already probe "iterator" / "@@iterator".
        const self_iter_fn = val_mod.makeNativeFunction(self.arena, nativeGeneratorSelfIterator) catch return EvalError.OutOfMemory;
        gen_obj.set("iterator", self_iter_fn) catch return EvalError.OutOfMemory;
        gen_obj.set("@@iterator", self_iter_fn) catch return EvalError.OutOfMemory;

        return val_mod.makeObject(self.arena, gen_obj) catch return EvalError.OutOfMemory;
    }

    fn materializeGenerator(self: *Vm, state: *GeneratorState) EvalError!void {
        state.had_exception = false;
        state.capture.yields.clearRetainingCapacity();
        state.capture.delegate_return = false;
        state.capture.state = state;

        if (!state.suspended) {
            state.capture.loop_stack.clearRetainingCapacity();
        }

        const resume_slot = if (state.sent_values.items.len > 0)
            state.sent_values.items[state.sent_values.items.len - 1]
        else
            try self.makeUndefined();

        if (state.suspended and state.persistent_env != null) {
            const slot = self.arena.alloc(Value, 1) catch return EvalError.OutOfMemory;
            slot[0] = resume_slot;
            state.capture.resume_values = slot[0..1];
            state.capture.resume_index = 0;
            state.capture.skip_yields = if (state.sent_values.items.len > 1) 1 else 0;
        } else {
            state.capture.resume_values = if (state.sent_values.items.len > 1)
                state.sent_values.items[1..]
            else
                &[_]Value{};
            state.capture.resume_index = 0;
            state.capture.skip_yields = 0;
            state.return_value = try self.makeUndefined();
            state.suspended = false;
            state.body_index = 0;
            state.capture.yield_star_iter = null;
            state.capture.yield_star_array = null;
            state.capture.yield_star_array_index = 0;

            const call_env = Environment.init(self.arena, state.closure_env) catch return EvalError.OutOfMemory;

            const arguments_obj = if (self.heap) |heap|
                JsObject.createArrayOnHeap(heap, self.realm.array_prototype) catch return EvalError.OutOfMemory
            else
                JsObject.createArray(self.arena, self.realm.array_prototype) catch return EvalError.OutOfMemory;
            for (state.args, 0..) |av, i| {
                const key = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return EvalError.OutOfMemory;
                arguments_obj.set(key, av) catch return EvalError.OutOfMemory;
            }
            arguments_obj.array_length = @intCast(state.args.len);
            const arguments_val = val_mod.makeObject(self.arena, arguments_obj) catch return EvalError.OutOfMemory;
            call_env.define("arguments", arguments_val) catch return EvalError.OutOfMemory;

            const param_defaults: []?*Node = @as([*]?*Node, @ptrCast(state.func.param_defaults.ptr))[0..state.func.param_defaults.len];
            for (state.func.params, 0..) |param, i| {
                var av = if (i < state.args.len) state.args[i] else try self.makeUndefined();
                if (i < param_defaults.len and param_defaults[i] != null) {
                    const is_undef = av.bits == 0 or (av.bits != 0 and av.toPtr().* == .undefined_);
                    if (is_undef) av = try self.evalExpression(param_defaults[i].?, call_env);
                }
                call_env.define(param, av) catch return EvalError.OutOfMemory;
            }
            if (state.func.rest_param) |rest_name| {
                const rest_arr = if (self.heap) |heap|
                    JsObject.createArrayOnHeap(heap, self.realm.array_prototype) catch return EvalError.OutOfMemory
                else
                    JsObject.createArray(self.arena, self.realm.array_prototype) catch return EvalError.OutOfMemory;
                var write_idx: usize = 0;
                var i = state.func.params.len;
                while (i < state.args.len) : (i += 1) {
                    const key = std.fmt.allocPrint(self.arena, "{d}", .{write_idx}) catch return EvalError.OutOfMemory;
                    rest_arr.set(key, state.args[i]) catch return EvalError.OutOfMemory;
                    write_idx += 1;
                }
                rest_arr.array_length = @intCast(write_idx);
                const rest_val = val_mod.makeObject(self.arena, rest_arr) catch return EvalError.OutOfMemory;
                call_env.define(rest_name, rest_val) catch return EvalError.OutOfMemory;
            }
            if (state.func.name) |fname| {
                const self_val = try val_mod.makeFunction(self.arena, state.func);
                call_env.define(fname, self_val) catch return EvalError.OutOfMemory;
            }
            self.hoistDeclarations(state.body, call_env) catch return EvalError.OutOfMemory;
            self.predeclareLexicalsInBlock(state.body, call_env) catch return EvalError.OutOfMemory;
            state.persistent_env = call_env;
        }

        const call_env = state.persistent_env.?;
        const prev_this = self.current_this;
        const prev_strict = self.is_strict;
        const prev_call_env = self.current_call_env;
        const prev_capture = self.generator_capture;
        self.current_this = if (state.func.is_arrow) state.func.lexical_this else state.this_val;
        self.is_strict = state.func.is_strict;
        self.current_call_env = call_env;
        self.generator_capture = &state.capture;
        defer {
            self.current_this = prev_this;
            self.is_strict = prev_strict;
            self.current_call_env = prev_call_env;
            self.generator_capture = prev_capture;
        }

        if (state.suspended and state.capture.skip_yields > 0 and state.resume_stmt_index < state.body.len and state.capture.yield_star_iter == null and state.capture.yield_star_array == null) {
            const replay = try self.evalStatement(state.body[state.resume_stmt_index], call_env);
            state.capture.skip_yields = 0;
            switch (replay) {
                .yield_suspend => {
                    state.suspended = true;
                    return;
                },
                .return_ => |rv| {
                    state.return_value = rv;
                    state.body_index = state.body.len;
                    state.suspended = false;
                    return;
                },
                .exception => |ex| {
                    state.had_exception = true;
                    state.exception = ex;
                    state.suspended = false;
                    return;
                },
                else => {},
            }
        }

        var i = state.body_index;
        while (i < state.body.len) : (i += 1) {
            const r = try self.evalStatement(state.body[i], call_env);
            if (state.capture.delegate_return) {
                state.capture.delegate_return = false;
                state.body_index = state.body.len;
                state.suspended = false;
                return;
            }
            switch (r) {
                .yield_suspend => {
                    state.resume_stmt_index = i;
                    if (state.capture.yield_star_iter != null or state.capture.yield_star_array != null) {
                        state.body_index = i;
                    } else {
                        state.body_index = i + 1;
                    }
                    state.suspended = true;
                    return;
                },
                .value => {},
                .return_ => |rv| {
                    state.return_value = rv;
                    state.body_index = state.body.len;
                    state.suspended = false;
                    return;
                },
                .exception => |ex| {
                    state.had_exception = true;
                    state.exception = ex;
                    state.suspended = false;
                    return;
                },
                .break_, .continue_ => {
                    state.had_exception = true;
                    state.exception = .{
                        .message = "SyntaxError: unsupported control flow in generator body",
                        .value = self.makeErrorObject("SyntaxError", "unsupported control flow in generator body") catch Value{},
                    };
                    state.suspended = false;
                    return;
                },
            }
        }
        state.return_value = try self.makeUndefined();
        state.body_index = state.body.len;
        state.suspended = false;
    }

    fn evalNewExpr(self: *Vm, ne: ast.NewExpr, env: *Environment) EvalError!Value {
        const callee_val = try self.evalExpression(ne.callee, env);
        var arg_vals = std.ArrayList(Value){};
        for (ne.args) |a| {
            const av = try self.evalExpression(a, env);
            try arg_vals.append(self.arena, av);
        }
        return self.doConstruct(callee_val, arg_vals.items);
    }

    /// [[Construct]]: allocate new object, call constructor with it as `this`.
    fn doConstruct(self: *Vm, callee_val: Value, args: []Value) EvalError!Value {
        if (callee_val.bits == 0) {
            self.last_exception_msg = "TypeError: undefined is not a constructor";
            self.last_exception_value = try self.makeTypeErrorObject("undefined is not a constructor");
            return EvalError.JsException;
        }
        const inner = callee_val.toPtr();
        switch (inner.*) {
            .native_function => |fn_ptr| {
                // Native function called with `new`: create empty object, call fn with it as `this`.
                const proto = self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    JsObject.createOnHeap(heap, proto) catch return EvalError.OutOfMemory
                else
                    JsObject.create(self.arena, proto) catch return EvalError.OutOfMemory;
                const this_val = val_mod.makeObject(self.arena, new_obj) catch return EvalError.OutOfMemory;
                const result = fn_ptr.invoke(self.arena, this_val, args) catch return EvalError.OutOfMemory;
                if (result.bits != 0 and result.toPtr().* == .object) {
                    return result;
                }
                return this_val;
            },
            .function => |fv| {
                const proto = self.getFuncProto(fv) orelse self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    JsObject.createOnHeap(heap, proto) catch return EvalError.OutOfMemory
                else
                    JsObject.create(self.arena, proto) catch return EvalError.OutOfMemory;
                const this_val = val_mod.makeObject(self.arena, new_obj) catch return EvalError.OutOfMemory;
                const result = self.callFunction(fv, args, this_val) catch |e| return e;
                if (result.bits != 0 and result.toPtr().* == .object) {
                    return result;
                }
                return this_val;
            },
            .bc_function => {
                const msg = "TypeError: bc function not supported as constructor in tree mode";
                self.last_exception_msg = msg;
                self.last_exception_value = Value{};
                return EvalError.JsException;
            },
            .object => |obj| {
                // An Error constructor object: has a "__call__" native fn and a "prototype" property.
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.toPtr().* == .native_function) {
                        const fn_ptr = call_val.toPtr().native_function;
                        // Get prototype for the new object.
                        var proto: ?*JsObject = self.realm.object_prototype;
                        if (obj.get("prototype")) |pv| {
                            if (pv.bits != 0 and pv.toPtr().* == .object) {
                                proto = pv.toPtr().object;
                            }
                        }
                        const new_obj = if (self.heap) |heap|
                            JsObject.createOnHeap(heap, proto) catch return EvalError.OutOfMemory
                        else
                            JsObject.create(self.arena, proto) catch return EvalError.OutOfMemory;
                        const this_val = val_mod.makeObject(self.arena, new_obj) catch return EvalError.OutOfMemory;
                        const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_m = @import("../runtime/realm.zig");
                                if (realm_m.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_m.pending_exception;
                                    realm_m.pending_exception = Value{};
                                    const fmt_msg = formatExceptionMessage(self.arena, self.last_exception_value) catch "error";
                                    self.last_exception_msg = fmt_msg;
                                }
                                return EvalError.JsException;
                            }
                            return EvalError.OutOfMemory;
                        };
                        if (result.bits != 0 and result.toPtr().* == .object) {
                            return result;
                        }
                        return this_val;
                    }
                }
                const msg = "object is not a constructor";
                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                self.last_exception_value = try self.makeTypeErrorObject(msg);
                return EvalError.JsException;
            },
            else => {
                const msg = try std.fmt.allocPrint(self.arena, "{s} is not a constructor", .{typeofValue(callee_val)});
                self.last_exception_msg = try std.fmt.allocPrint(self.arena, "TypeError: {s}", .{msg});
                self.last_exception_value = try self.makeTypeErrorObject(msg);
                return EvalError.JsException;
            },
        }
    }

    /// Get the [[Prototype]] that `new fn()` should use:
    /// reads fn.prototype if it is an object; else Object.prototype.
    fn getFuncProto(self: *Vm, fv: *FuncVal) ?*JsObject {
        _ = self;
        return fv.prototype_obj;
    }

    /// Create a TypeError JsObject with the given message, using TypeError.prototype as proto.
    pub fn makeTypeErrorObject(self: *Vm, message: []const u8) !Value {
        return self.makeErrorObject("TypeError", message);
    }

    pub fn makeReferenceErrorObject(self: *Vm, message: []const u8) !Value {
        return self.makeErrorObject("ReferenceError", message);
    }

    pub fn makeErrorObject(self: *Vm, name: []const u8, message: []const u8) !Value {
        // Look up <name>.prototype in global env.
        const proto = self.getErrorProto(name);
        const obj = if (self.heap) |heap|
            JsObject.createOnHeap(heap, proto) catch return EvalError.OutOfMemory
        else
            JsObject.create(self.arena, proto) catch return EvalError.OutOfMemory;
        const msg_val = val_mod.makeString(self.arena, message) catch return EvalError.OutOfMemory;
        const name_val = val_mod.makeString(self.arena, name) catch return EvalError.OutOfMemory;
        obj.set("message", msg_val) catch return EvalError.OutOfMemory;
        obj.set("name", name_val) catch return EvalError.OutOfMemory;
        return val_mod.makeObject(self.arena, obj) catch return EvalError.OutOfMemory;
    }

    fn getErrorProto(self: *Vm, name: []const u8) ?*JsObject {
        const proto_name = std.fmt.allocPrint(self.arena, "__{s}Proto__", .{name}) catch return self.realm.object_prototype;
        const val = self.realm.global_env.lookup(proto_name) catch return self.realm.object_prototype;
        if (val.bits != 0 and val.toPtr().* == .object) return val.toPtr().object;
        return self.realm.object_prototype;
    }

    fn evalTryStmt(self: *Vm, ts: ast.TryStmt, env: *Environment) std.mem.Allocator.Error!StmtResult {
        // Run the try block.
        var try_result = try self.evalStatement(ts.block, env);

        // If exception and there is a catch handler, handle it.
        if (try_result == .exception) {
            if (ts.handler) |handler| {
                const ex = try_result.exception;
                // Create catch env binding the param.
                const catch_env = try Environment.init(self.arena, env);
                // Use ex.value if present, else wrap message as string.
                const caught_val = if (ex.value.bits != 0) ex.value else try self.makeString(ex.message);
                try catch_env.define(handler.param_name, caught_val);
                // Clear exception state.
                self.last_exception_msg = "";
                self.last_exception_value = Value{};
                try_result = try self.evalStatement(handler.body, catch_env);
            }
        }

        // Run finally block (if present).
        if (ts.finalizer) |finally_node| {
            const saved = try_result;
            const finally_result = try self.evalStatement(finally_node, env);
            // If finally throws, that overrides the saved completion.
            if (finally_result == .exception) {
                return finally_result;
            }
            // Otherwise restore the saved completion.
            return saved;
        }

        return try_result;
    }
};

/// Wraps FuncVal with the actual body slice (FuncVal.body_ptr is opaque).
pub const FuncWrapper = struct {
    fv: *FuncVal,
    body: []*Node,
};

const GeneratorCapture = struct {
    yields: std.ArrayList(Value) = .{},
    resume_values: []const Value = &[_]Value{},
    resume_index: usize = 0,
    suspend_requested: bool = false,
    delegate_return: bool = false,
    yield_star_iter: ?*JsObject = null,
    yield_star_array: ?*JsObject = null,
    yield_star_array_index: usize = 0,
    skip_yields: usize = 0,
    state: ?*GeneratorState = null,
    loop_stack: std.ArrayList(GenLoopFrame) = .{},
};

const GenLoopPhase = enum { enter, cond, body, update };

const GenLoopFrame = struct {
    stmt: *Node,
    phase: GenLoopPhase = .enter,
};

const GeneratorState = struct {
    vm: *Vm,
    func: *FuncVal,
    body: []*Node,
    closure_env: *Environment,
    args: []Value,
    this_val: Value,
    capture: GeneratorCapture = .{},
    sent_values: std.ArrayList(Value) = .{},
    index: usize = 0,
    closed: bool = false,
    return_value: Value = Value{},
    had_exception: bool = false,
    exception: EvalException = .{ .message = "" },
    /// Incremental stepping: resume from this statement index with persistent env.
    suspended: bool = false,
    body_index: usize = 0,
    resume_stmt_index: usize = 0,
    persistent_env: ?*Environment = null,
};

fn makeIteratorResult(arena: std.mem.Allocator, vm: *Vm, value: Value, done: bool) !Value {
    const obj = if (vm.heap) |heap|
        JsObject.createOnHeap(heap, vm.realm.object_prototype) catch return error.OutOfMemory
    else
        JsObject.create(arena, vm.realm.object_prototype) catch return error.OutOfMemory;
    obj.set("value", value) catch return error.OutOfMemory;
    const done_val = val_mod.makeBool(arena, done) catch return error.OutOfMemory;
    obj.set("done", done_val) catch return error.OutOfMemory;
    return val_mod.makeObject(arena, obj);
}

fn nativeGeneratorSelfIterator(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

fn nativeGeneratorNext(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return val_mod.makeUndefined(arena);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return val_mod.makeUndefined(arena);
    const state: *GeneratorState = @ptrCast(@alignCast(obj.internal_slot.?));
    const vm = state.vm;
    const resume_arg = if (args.len > 0) args[0] else try vm.makeUndefined();
    state.sent_values.append(vm.arena, resume_arg) catch return error.OutOfMemory;

    if (state.closed) {
        return makeIteratorResult(arena, vm, try vm.makeUndefined(), true);
    }

    vm.materializeGenerator(state) catch |e| switch (e) {
        error.JsException => {
            const realm_mod = @import("../runtime/realm.zig");
            realm_mod.pending_exception = vm.last_exception_value;
            return error.JsException;
        },
        else => return e,
    };

    if (state.had_exception) {
        state.closed = true;
        const realm_mod = @import("../runtime/realm.zig");
        realm_mod.pending_exception = state.exception.value;
        vm.last_exception_value = state.exception.value;
        vm.last_exception_msg = state.exception.message;
        return error.JsException;
    }

    if (state.capture.yields.items.len > 0) {
        const out = state.capture.yields.items[state.capture.yields.items.len - 1];
        return makeIteratorResult(arena, vm, out, false);
    }

    if (!state.suspended) {
        state.closed = true;
        return makeIteratorResult(arena, vm, state.return_value, true);
    }

    return makeIteratorResult(arena, vm, try vm.makeUndefined(), true);
}

fn nativeGeneratorReturn(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return val_mod.makeUndefined(arena);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return val_mod.makeUndefined(arena);
    const state: *GeneratorState = @ptrCast(@alignCast(obj.internal_slot.?));
    const vm = state.vm;
    const rv = if (args.len > 0) args[0] else try vm.makeUndefined();
    state.return_value = rv;
    state.closed = true;
    state.suspended = false;
    return makeIteratorResult(arena, vm, rv, true);
}

fn nativeGeneratorThrow(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.toPtr().* != .object) return val_mod.makeUndefined(arena);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return val_mod.makeUndefined(arena);
    const state: *GeneratorState = @ptrCast(@alignCast(obj.internal_slot.?));
    const vm = state.vm;
    const thrown = if (args.len > 0) args[0] else try vm.makeUndefined();
    state.closed = true;
    state.suspended = false;
    const realm_mod = @import("../runtime/realm.zig");
    realm_mod.pending_exception = thrown;
    vm.last_exception_value = thrown;
    vm.last_exception_msg = "generator throw";
    return error.JsException;
}

/// GC root-scan callback for the tree-walker Vm.
/// Walks current_this and the global env chain (all live bindings).
fn vmScanCallback(ctx: *anyopaque, mark_fn: *const fn (*JsObject) void) void {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    gc_mod.traceValue(vm.current_this, mark_fn);
    // Walk the innermost call env if active (chains to enclosing + global).
    // This roots all locals of an in-progress call.
    if (vm.current_call_env) |env| {
        gc_mod.traceEnvironment(env, mark_fn);
    }
    // Always walk global (covers top-level vars even when no call is active).
    gc_mod.traceEnvironment(vm.realm.global_env, mark_fn);
}

/// Native __gc__ when no heap attached (tree-walker standalone mode).
fn nativeGcNoop(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return val_mod.makeUndefined(arena);
}

/// Native __gc__ when heap is attached.
fn nativeGcCollect(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const realm_mod = @import("../runtime/realm.zig");
    if (realm_mod.active_heap) |heap| {
        _ = heap.collect();
    }
    return val_mod.makeUndefined(arena);
}

// ------------------------------------------------------------------ helpers ---

fn isTruthy(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.toPtr().*) {
        .undefined_ => false,
        .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0.0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .function => true,
        .bc_function => true,
        .object => true,
        .native_function => true,
    };
}

fn isString(v: Value) bool {
    if (v.bits == 0) return false;
    return v.toPtr().* == .string;
}

fn isStringOrObject(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.toPtr().*) {
        .string => true,
        .object => true,
        else => false,
    };
}

fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.toPtr().*) {
        .function, .native_function, .bc_function => true,
        .object => |obj| obj.get("__call__") != null,
        else => false,
    };
}

fn typeofValue(v: Value) []const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.toPtr().*) {
        .undefined_ => "undefined",
        .null_ => "object", // the famous bug — it's in the spec
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .function => "function",
        .bc_function => "function",
        .object => |obj| if (obj.get("__call__") != null) "function" else "object",
        .native_function => "function",
    };
}

fn toNumber(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.toPtr().*) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0.0,
        .boolean => |b| if (b) 1.0 else 0.0,
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\n\r")) catch std.math.nan(f64),
        .function => std.math.nan(f64),
        .bc_function => std.math.nan(f64),
        .object => std.math.nan(f64),
        .native_function => std.math.nan(f64),
    };
}

fn toInt32(v: Value) i32 {
    const n = toNumber(v);
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    // ES5 ToInt32: truncate, take modulo 2^32, reinterpret as signed.
    const m = @mod(@trunc(n), 4294967296.0); // [0, 2^32)
    const u: u32 = @intFromFloat(m);
    return @bitCast(u);
}

fn toUint32(v: Value) u32 {
    return @bitCast(toInt32(v));
}

fn valueToString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.toPtr().*) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try formatNumber(arena, n),
        .string => |s| s,
        .function => |f| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{f.name orelse ""}),
        .bc_function => |c| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{c.func.name orelse ""}),
        .object => |obj| blk: {
            if (obj.is_array) {
                // Array.toString: join elements with comma.
                var buf = std.ArrayList(u8){};
                const len = obj.getArrayLength();
                for (0..len) |i| {
                    const key = std.fmt.allocPrint(arena, "{d}", .{i}) catch break :blk "[object Object]";
                    if (i > 0) buf.append(arena, ',') catch break :blk "[object Object]";
                    if (obj.get(key)) |elem| {
                        const s = valueToString(arena, elem) catch break :blk "[object Object]";
                        buf.appendSlice(arena, s) catch break :blk "[object Object]";
                    }
                }
                break :blk buf.items;
            }
            break :blk "[object Object]";
        },
        .native_function => "function () { [native code] }",
    };
}

/// Like valueToString but returns arena-allocated slice (used for property key coercion).
/// Format a thrown value as a user-facing exception message.
/// Error-like objects (have own `name` and `message` properties) format as
/// "Name: message" instead of the default "[object Object]" coercion.
pub fn formatExceptionMessage(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits != 0) {
        if (v.toPtr().* == .object) {
            const obj = v.toPtr().object;
            const name_v = obj.get("name");
            const msg_v = obj.get("message");
            if (name_v != null and msg_v != null) {
                const name_s = try valueToString(arena, name_v.?);
                const msg_s = try valueToString(arena, msg_v.?);
                return std.fmt.allocPrint(arena, "{s}: {s}", .{ name_s, msg_s });
            }
        }
    }
    return valueToString(arena, v);
}

fn valueToStringArena(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return valueToString(arena, v);
}

pub fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    // Check if it's an integer
    if (n == @trunc(n) and @abs(n) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// ES5 §11.8.6 instanceof operator.
/// Walk lhs's [[Prototype]] chain looking for rhs's "prototype" property.
fn jsInstanceof(lhs: Value, rhs: Value) bool {
    if (lhs.bits == 0) return false;
    if (rhs.bits == 0) return false;
    // lhs must be an object.
    if (lhs.toPtr().* != .object) return false;
    // rhs must be callable. Get rhs.prototype.
    const rhs_proto: ?*JsObject = switch (rhs.toPtr().*) {
        .native_function => null, // bare fn ptr — can't get prototype
        .function => null, // tree-walker function — no attached prototype object
        .object => |obj| blk: {
            // Constructor object wrapping a native function with a .prototype property.
            if (obj.get("prototype")) |pv| {
                if (pv.bits != 0 and pv.toPtr().* == .object) break :blk pv.toPtr().object;
            }
            break :blk null;
        },
        else => null,
    };
    const target_proto = rhs_proto orelse return false;
    // Walk lhs's proto chain.
    var cur: ?*JsObject = lhs.toPtr().object;
    while (cur) |obj| {
        const p = obj.proto;
        if (p) |pp| {
            if (pp == target_proto) return true;
        }
        cur = p;
    }
    return false;
}

/// ES5 §11.8.5 Abstract relational comparison.
/// leftFirst=true: evaluate left<right. leftFirst=false: evaluate right<left
/// but return result for original order.
fn jsLessThan(left: Value, right: Value, _: bool) ?bool {
    // Numeric comparison
    const lstr = if (left.bits != 0) left.toPtr().* == .string else false;
    const rstr = if (right.bits != 0) right.toPtr().* == .string else false;
    if (lstr and rstr) {
        // Lex compare
        const ls = left.toPtr().string;
        const rs = right.toPtr().string;
        return std.mem.lessThan(u8, ls, rs);
    }
    const ln = toNumber(left);
    const rn = toNumber(right);
    if (std.math.isNan(ln) or std.math.isNan(rn)) return null;
    return ln < rn;
}

/// ES5 §11.9.3 Abstract equality.
fn jsAbstractEqual(x: Value, y: Value) bool {
    const tx = typeTag(x);
    const ty = typeTag(y);
    if (tx == ty) return jsStrictEqual(x, y);
    // null == undefined
    if ((tx == .null_ and ty == .undefined_) or (tx == .undefined_ and ty == .null_)) return true;
    // number == string: ToNumber(string)
    if (tx == .number and ty == .string) {
        return toNumber(x) == toNumber(y);
    }
    if (tx == .string and ty == .number) {
        return toNumber(x) == toNumber(y);
    }
    // boolean: convert to number then recurse
    if (tx == .boolean) {
        const bv = x.toPtr().boolean;
        const n = if (bv) @as(f64, 1.0) else @as(f64, 0.0);
        return n == toNumber(y);
    }
    if (ty == .boolean) {
        const bv = y.toPtr().boolean;
        const n = if (bv) @as(f64, 1.0) else @as(f64, 0.0);
        return toNumber(x) == n;
    }
    return false;
}

/// LessThan used by bc_vm.zig (re-exported so both share the same logic surface).
pub fn jsLessThanPub(left: Value, right: Value) ?bool {
    const lstr = if (left.bits != 0) left.toPtr().* == .string else false;
    const rstr = if (right.bits != 0) right.toPtr().* == .string else false;
    if (lstr and rstr) {
        return std.mem.lessThan(u8, left.toPtr().string, right.toPtr().string);
    }
    const ln = toNumber(left);
    const rn = toNumber(right);
    if (std.math.isNan(ln) or std.math.isNan(rn)) return null;
    return ln < rn;
}

/// ES5 §11.9.6 Strict equality.
fn jsStrictEqual(x: Value, y: Value) bool {
    const tx = typeTag(x);
    const ty = typeTag(y);
    if (tx != ty) return false;
    switch (tx) {
        .undefined_ => return true,
        .null_ => return true,
        .number => {
            const xn = toNumber(x);
            const yn = toNumber(y);
            if (std.math.isNan(xn) or std.math.isNan(yn)) return false;
            // -0 === 0
            return xn == yn;
        },
        .string => {
            const xs = x.toPtr().string;
            const ys = y.toPtr().string;
            return std.mem.eql(u8, xs, ys);
        },
        .boolean => {
            return x.toPtr().boolean == y.toPtr().boolean;
        },
        .function => {
            return x.bits == y.bits; // same pointer = same function
        },
        .bc_function => {
            return x.bits == y.bits;
        },
        .object => {
            return x.bits == y.bits; // reference equality
        },
        .native_function => {
            return x.bits == y.bits;
        },
    }
}

const TypeTag = enum { undefined_, null_, boolean, number, string, function, bc_function, object, native_function };

fn typeTag(v: Value) TypeTag {
    if (v.bits == 0) return .undefined_;
    return switch (v.toPtr().*) {
        .undefined_ => .undefined_,
        .null_ => .null_,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .function => .function,
        .bc_function => .bc_function,
        .object => .object,
        .native_function => .native_function,
    };
}

// ------------------------------------------------------------------- tests ---

test "Vm: 1+2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    const parser_mod = @import("../parser/parser.zig");
    var p = parser_mod.Parser.init("1+2", arena.allocator());
    const result = p.parseScript();
    const stmts = switch (result) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const r = try vm.runScript(stmts);
    switch (r) {
        .value => |v| try std.testing.expectEqual(@as(f64, 3), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "Vm: typeof null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try Vm.init(arena.allocator());
    const parser_mod = @import("../parser/parser.zig");
    var p = parser_mod.Parser.init("typeof null", arena.allocator());
    const result = p.parseScript();
    const stmts = switch (result) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const r = try vm.runScript(stmts);
    switch (r) {
        .value => |v| {
            try std.testing.expectEqualStrings("object", v.toPtr().string);
        },
        else => return error.UnexpectedResult,
    }
}
