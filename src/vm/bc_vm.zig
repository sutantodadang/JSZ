// SPDX-License-Identifier: Apache-2.0
//! Bytecode register VM for Phase 2/3a/3b.
//! Semantics must match the tree-walker (vm.zig) exactly.
//! All arithmetic, equality, typeof, etc. delegate to the same
//! helper logic as vm.zig (duplicated here with same logic to avoid
//! circular imports; must be kept in sync).
//! Phase 3b: NEW_OBJECT/NEW_ARRAY allocate on the GC heap when present.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const JsObject = @import("../object/object.zig").JsObject;
const Op = @import("../bytecode/opcodes.zig").Op;
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const build_options = @import("build_options");
const BcClosure = @import("../bytecode/function.zig").BcClosure;
const Environment = @import("../runtime/execution_context.zig").Environment;
const Realm = @import("../runtime/realm.zig").Realm;
const Heap = @import("../gc/heap.zig").Heap;
const gc_mod = @import("../gc/gc.zig");
const ic_mod = @import("./ic.zig");
const jit_mod = @import("../jit/jit.zig");
const loop_jit = @import("../jit/loop_jit.zig");
const coercion = @import("../runtime/builtins/coercion.zig");
const function_proto = @import("../runtime/builtins/function_proto.zig");
const proxy_mod = @import("../runtime/builtins/proxy.zig");

/// Phase 4a: a try entry pushed by PUSH_TRY.
pub const TryEntry = struct {
    /// Register index that receives the caught exception value (0xFF = no catch).
    rexc: u8,
    /// Absolute PC of the catch/finally handler.
    handler_pc: usize,
};

/// Phase 12: key for the per-loop OSR plan cache — a loop is identified by its
/// owning function and the bytecode offset of its back-edge `JMP`.
pub const OsrKey = struct { func: *const BcFunction, pc: u32 };

/// Result of a JIT call attempt: `not_jitted` (interpret it), `completed` (native
/// ran and wrote the result), or `threw` (a re-entrant call threw — the value is
/// in `realm.pending_exception`; the caller must propagate it without re-running).
const JitCallResult = enum { not_jitted, completed, threw };

/// Sentinel stored in `jit_plans` for a function permanently rejected by the JIT
/// analyzer (never dereferenced; distinct from any real `*JitPlan`).
const jit_rejected: *anyopaque = @ptrFromInt(@alignOf(u64));
/// Max `.retry` (cold-IC) compile attempts before a function is rejected.
const jit_warmup_max: u16 = 64;

pub const BcCallFrame = struct {
    func: *const BcFunction,
    pc: usize,
    registers: []Value,
    env: *Environment,
    return_dst: u8,
    caller_idx: ?usize,
    /// Phase 3a: the `this` value for this frame.
    this_val: Value = Value{},
    /// Phase 4a: try stack (pushed by PUSH_TRY, popped by POP_TRY/THROW).
    try_stack: std.ArrayListUnmanaged(TryEntry) = .empty,
    /// W2: when this frame belongs to a generator, links back to its state so
    /// YIELD can save the suspended frame. Null for ordinary frames.
    gen: ?*BcGeneratorState = null,
};

/// W2: suspended-frame state for a bytecode generator. `frame` holds the saved
/// call frame (registers persist across resumes); the generator object stores a
/// pointer to this in its internal_slot.
pub const BcGeneratorState = struct {
    frame: BcCallFrame,
    vm: *BcVm,
    done: bool = false,
    started: bool = false,
    /// Register that receives the value passed to .next(v) on resume.
    resume_reg: u8 = 0,
};

/// W2-async: how to resume a suspended coroutine.
pub const ResumeKind = union(enum) {
    /// Resume normally, writing `next` into the await/yield result register.
    next: Value,
    /// Resume by throwing `throw_` at the suspended await point (rejected await).
    throw_: Value,
};

/// W2-async: result of running a coroutine until its next suspend or completion.
pub const SuspendResult = union(enum) {
    /// Hit a YIELD (an `await` point); carries the awaited value.
    yielded: Value,
    /// Completed normally; carries the return value.
    returned: Value,
    /// An exception escaped the coroutine frame; carries the thrown value.
    threw: Value,
};

/// W2-async: state for one in-flight async function invocation. Drives a
/// suspended coroutine and settles `result` when it completes or throws.
pub const AsyncCtx = struct {
    vm: *BcVm,
    state: *BcGeneratorState,
    /// The pending result promise returned to the caller.
    result: Value,
};

pub const RunOutcome = union(enum) {
    ok: Value,
    exception: []const u8,
    exception_value: struct { msg: []const u8, value: Value },
};

pub const BcVm = struct {
    arena: std.mem.Allocator,
    realm: *Realm,
    /// Phase 3b: optional GC heap.
    heap: ?*Heap = null,
    frames: std.ArrayListUnmanaged(BcCallFrame) = .empty,
    /// Phase 8: high-water mark of the call-frame stack depth across this run.
    /// Used to verify proper tail calls keep stack growth O(1).
    frame_high_water: usize = 0,
    result: Value = Value{},
    exception: ?[]const u8 = null,
    /// Phase 4a: the last thrown JS value (for catch binding).
    last_exception_value: Value = Value{},
    /// Phase 4d: context for re-entry from native callbacks.
    context: @import("../runtime/realm.zig").Context = undefined,
    /// Phase 9: optional JIT profiler. Null = no profiling (zero hot-path cost).
    jit: ?*jit_mod.JitCompiler = null,
    /// Phase 12: per-function JIT plan cache (built lazily on the first hot call
    /// under `-Djit=true` + `.experimental`). Value is a `*int_fn_jit.JitPlan`
    /// stored opaque (null = analyzed and NOT JIT-able). Empty/unused by default.
    jit_plans: std.AutoHashMapUnmanaged(*const BcFunction, ?*anyopaque) = .empty,
    /// Phase 12: per-loop OSR plan cache, keyed by (function, back-edge pc). Built
    /// lazily on the first hot back-edge under `-Djit=true` + `.experimental`;
    /// value is a `*osr_jit.OsrPlan` stored opaque (null = not OSR-able). Default: empty.
    osr_plans: std.AutoHashMapUnmanaged(OsrKey, ?*anyopaque) = .empty,
    /// Phase 12 boxed tier: per-function count of failed JIT-compile attempts while
    /// a property site's inline cache is still cold (`analyze` returned `.retry`).
    /// After `jit_warmup_max` the function is permanently rejected. Lets ICs warm
    /// over the first few interpreted calls before we bake them into native code.
    jit_attempts: std.AutoHashMapUnmanaged(*const BcFunction, u16) = .empty,
    /// W3: resource limits. 0 = unlimited. Enforced in the dispatch loop and
    /// surfaced as an uncatchable interrupt (returns past any JS try/catch).
    gas_limit: u64 = 0,
    gas_used: u64 = 0,
    deadline_ns: i128 = 0,
    /// W2: set by the YIELD handler so the generator driver distinguishes a
    /// suspension from a normal return.
    gen_yielded: bool = false,
    /// W2: all generator states created in this run (kept live for GC scanning
    /// of their suspended frames; freed with the eval arena).
    generators: std.ArrayListUnmanaged(*BcGeneratorState) = .empty,
    /// W2-async: all async invocation contexts (kept live for GC scanning of
    /// their result promises; suspended frames are scanned via `generators`).
    async_ctxs: std.ArrayListUnmanaged(*AsyncCtx) = .empty,
    /// Phase 11: IC hit-rate instrumentation. Counted only when enabled.
    ic_stats_enabled: bool = false,
    ic_own_hits: u64 = 0,
    ic_proto_hits: u64 = 0,
    ic_misses: u64 = 0,

    pub fn init(arena: std.mem.Allocator, realm: *Realm) BcVm {
        return BcVm{
            .arena = arena,
            .realm = realm,
        };
    }

    /// Init with an attached GC heap. Object/array allocations go to heap.
    /// NOTE: After calling this, call registerHeapCallback(heap) once you have
    /// the final stack address of the BcVm (i.e., after assignment to a named var).
    pub fn initWithHeap(arena: std.mem.Allocator, realm: *Realm, heap: *Heap) BcVm {
        return BcVm{
            .arena = arena,
            .realm = realm,
            .heap = heap,
        };
    }

    /// Register this BcVm as a GC root-scan source.
    /// Call once, after the BcVm is in its final stack location.
    pub fn registerHeapCallback(self: *BcVm, heap: *Heap) !void {
        try heap.addScanCallback(.{
            .ctx = self,
            .scan = bcVmScanCallback,
        });
    }

    pub fn unregisterHeapCallback(self: *BcVm, heap: *Heap) void {
        heap.removeScanCallback(self);
    }

    /// Phase 4d: Context re-entry — called by invokeCallback for JS functions.
    fn bcInvokeJs(ptr: *anyopaque, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
        _ = arena;
        @import("../runtime/realm.zig").active_constructing = false;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
        if (fn_val.bits == 0) return error.JsException;
        const inner = fn_val.unbox();
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));
                if (fn_ptr.is_async) return try self.buildAsyncFunction(fn_ptr, def_env, this_val, args);
                if (fn_ptr.is_generator) return try self.buildGenerator(fn_ptr, def_env, this_val, args);
                const call_env = try Environment.init(self.arena, def_env);
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        new_regs[i] = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
                    }
                }
                const caller_idx = if (self.frames.items.len > 0) self.frames.items.len - 1 else 0;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = 255,
                    .caller_idx = if (self.frames.items.len > 0) caller_idx else null,
                    .this_val = this_val,
                });
                // Run until this frame returns.
                const frames_before = self.frames.items.len - 1;
                while (self.frames.items.len > frames_before) {
                    const outcome = try self.runLoop();
                    switch (outcome) {
                        .ok => |v| return v,
                        .exception => |msg| {
                            // Unwind this invocation's frames. runLoop returns an
                            // uncaught throw without popping the throwing frame; since
                            // re-entrant callbacks (e.g. microtask reaction handlers)
                            // share this VM's frame stack, a leaked dead frame would
                            // poison the next re-entrant call. Restore to frames_before.
                            while (self.frames.items.len > frames_before) _ = self.frames.pop();
                            const realm_mod = @import("../runtime/realm.zig");
                            realm_mod.pending_exception = self.last_exception_value;
                            _ = msg;
                            return error.JsException;
                        },
                        .exception_value => |ev| {
                            while (self.frames.items.len > frames_before) _ = self.frames.pop();
                            const realm_mod = @import("../runtime/realm.zig");
                            realm_mod.pending_exception = ev.value;
                            return error.JsException;
                        },
                    }
                }
                return self.result;
            },
            .native_function => |fn_ptr| {
                return fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) return error.JsException;
                    return error.OutOfMemory;
                };
            },
            .object => |obj| {
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var combined = try self.arena.alloc(Value, bd.prefix.len + args.len);
                        for (bd.prefix, 0..) |v, i| combined[i] = v;
                        for (args, 0..) |v, i| combined[bd.prefix.len + i] = v;
                        return bcInvokeJs(ptr, self.arena, bd.this_val, bd.target, combined);
                    }
                }
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = Value{};
                return error.JsException;
            },
            else => {
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = Value{};
                return error.JsException;
            },
        }
    }

    /// Construct `ctor` with `args` (native-friendly: throws JsException on
    /// failure, setting realm pending_exception). Used by Reflect.construct and
    /// Proxy. Mirrors doConstruct's per-callee logic.
    pub fn constructFromArgs(self: *BcVm, ctor: Value, args: []const Value) anyerror!Value {
        const realm_m = @import("../runtime/realm.zig");
        if (ctor.bits == 0) {
            realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
            return error.JsException;
        }
        switch (ctor.unbox()) {
            .bc_function => {
                const proto_v = try self.getProp(ctor, "prototype");
                const proto: ?*JsObject = if (proto_v.bits != 0 and proto_v.unbox() == .object)
                    proto_v.toPtr().object
                else
                    self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                const result = try bcInvokeJs(self, self.arena, this_val, ctor, args);
                return if (result.bits != 0 and result.unbox() == .object) result else this_val;
            },
            .native_function => |fn_ptr| {
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, self.realm.object_prototype)
                else
                    try JsObject.create(self.arena, self.realm.object_prototype);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                realm_m.active_constructing = true;
                const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    realm_m.active_constructing = false;
                    return e;
                };
                realm_m.active_constructing = false;
                return if (result.bits != 0 and result.unbox() == .object) result else this_val;
            },
            .object => |o| {
                if (o.internal_kind == .proxy) return try self.proxyConstruct(o, args, ctor);
                if (o.get("__call__")) |cv| {
                    if (cv.bits != 0 and cv.unbox() == .native_function) {
                        var proto: ?*JsObject = self.realm.object_prototype;
                        if (o.get("prototype")) |pv| {
                            if (pv.bits != 0 and pv.unbox() == .object) proto = pv.toPtr().object;
                        }
                        const new_obj = if (self.heap) |heap|
                            try JsObject.createOnHeap(heap, proto)
                        else
                            try JsObject.create(self.arena, proto);
                        const this_val = try val_mod.makeObject(self.arena, new_obj);
                        realm_m.active_constructing = true;
                        const result = cv.toPtr().native_function.invoke(self.arena, this_val, args) catch |e| {
                            realm_m.active_constructing = false;
                            return e;
                        };
                        realm_m.active_constructing = false;
                        return if (result.bits != 0 and result.unbox() == .object) result else this_val;
                    }
                }
                realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
                return error.JsException;
            },
            else => {
                realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
                return error.JsException;
            },
        }
    }

    fn bcConstruct(ptr: *anyopaque, arena: std.mem.Allocator, ctor_val: Value, args: []const Value) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        return self.constructFromArgs(ctor_val, args);
    }

    /// Phase 13: global `eval(source)` — compile + run `source` against the
    /// global environment, returning its completion value (the value of the last
    /// expression, which `compileProgram` emits as an implicit return). Reachable
    /// from `nativeEval` via the Context bridge.
    fn bcEval(ptr: *anyopaque, arena: std.mem.Allocator, source: []const u8) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        const realm_mod = @import("../runtime/realm.zig");
        const parser_mod = @import("../parser/parser.zig");
        const compiler_mod = @import("../bytecode/compiler.zig");
        const ast_mod = @import("../parser/ast.zig");
        const isolate_mod = @import("./isolate.zig");

        const transformed = isolate_mod.rewriteTemplateLiterals(self.arena, source) catch source;
        var p = parser_mod.Parser.init(transformed, self.arena);
        const parse_result = p.parseScript();
        const stmts = switch (parse_result) {
            .ok => |s| s,
            .err => |e| {
                realm_mod.pending_exception = try self.makeErrorObjectBc("SyntaxError", e.message);
                return error.JsException;
            },
        };
        const prog = ast_mod.Program{ .body = stmts };
        const main_func = try compiler_mod.compileProgram(self.arena, &prog, "<eval>");
        // An undefined `break`/`continue` label is an early SyntaxError; the
        // compiler records it (it can't unwind), and eval surfaces it as a throw.
        if (compiler_mod.last_label_error) |msg| {
            compiler_mod.last_label_error = null;
            realm_mod.pending_exception = try self.makeErrorObjectBc("SyntaxError", msg);
            return error.JsException;
        }
        const closure = try self.arena.create(BcClosure);
        closure.* = .{ .func = main_func, .env = @ptrCast(self.realm.global_env) };
        const closure_val = try val_mod.makeBcFunction(self.arena, closure);
        const undef = try val_mod.makeUndefined(self.arena);
        return bcInvokeJs(self, self.arena, undef, closure_val, &[_]Value{});
    }

    fn activateContext(self: *BcVm) void {
        const realm_mod = @import("../runtime/realm.zig");
        self.context = realm_mod.Context{
            .ptr = self,
            .invoke_fn = bcInvokeJs,
            .construct_fn = bcConstruct,
            .eval_fn = bcEval,
        };
        realm_mod.active_context = &self.context;
    }

    fn deactivateContext(_: *BcVm) void {
        @import("../runtime/realm.zig").active_context = null;
    }

    /// Phase 9: record a loop back-edge as a hot-site signal. Returns true when
    /// this site just crossed the hot threshold AND the JIT is in experimental
    /// mode — the caller may then attempt a native fast-forward. No-op when off.
    inline fn noteBackedge(self: *BcVm, func: *const BcFunction, op_pc: usize) bool {
        if (self.jit) |jc| {
            const ev = jc.notePcHit(@intFromPtr(func), @intCast(op_pc)) catch return false;
            if (jc.mode != .experimental) return false;
            // Retry hot sites on every back-edge (catches loop re-entry and late
            // type stabilization) until the site is blacklisted by noteDeopt.
            if (ev == .not_hot) return false;
            return !jc.isBlacklisted(@intFromPtr(func), @intCast(op_pc));
        }
        return false;
    }

    pub fn run(
        self: *BcVm,
        main_func: *const BcFunction,
        captured_env: *anyopaque,
    ) !RunOutcome {
        self.activateContext();
        defer self.deactivateContext();

        // Create top-level frame.
        const global_env: *Environment = @ptrCast(@alignCast(captured_env));
        const regs = try self.arena.alloc(Value, if (main_func.num_regs > 0) main_func.num_regs else 1);
        for (regs) |*r| r.* = Value{};

        try self.frames.append(self.arena, BcCallFrame{
            .func = main_func,
            .pc = 0,
            .registers = regs,
            .env = global_env,
            .return_dst = 0,
            .caller_idx = null,
            .this_val = Value{}, // global this = undefined
        });

        return self.runLoop();
    }

    fn runLoop(self: *BcVm) !RunOutcome {
        while (self.frames.items.len > 0) {
            // W3: resource limits. Gas is checked per instruction; the wall-clock
            // deadline every 16K instructions (nanoTimestamp is too costly per-op).
            // Returns directly (past any JS try/catch) so scripts can't trap it.
            if (self.gas_limit != 0 or self.deadline_ns != 0) {
                self.gas_used += 1;
                if (self.gas_limit != 0 and self.gas_used > self.gas_limit)
                    return RunOutcome{ .exception = "interrupted: gas limit exceeded" };
                if (self.deadline_ns != 0 and (self.gas_used & 0x3FFF) == 0 and std.time.nanoTimestamp() >= self.deadline_ns)
                    return RunOutcome{ .exception = "interrupted: time limit exceeded" };
            }
            if (self.frames.items.len > self.frame_high_water) {
                self.frame_high_water = self.frames.items.len;
            }
            const frame = &self.frames.items[self.frames.items.len - 1];
            const code = frame.func.chunk.code;
            const op: Op = @enumFromInt(code[frame.pc]);
            frame.pc += 1;

            switch (op) {
                .LOAD_K => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    frame.registers[rdst] = frame.func.chunk.constants[kidx];
                },
                .LOAD_TRUE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, true);
                },
                .LOAD_FALSE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, false);
                },
                .LOAD_NULL => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeNull(self.arena);
                },
                .LOAD_UNDEF => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeUndefined(self.arena);
                },
                .MOVE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = frame.registers[rsrc];
                },
                .GET_GLOBAL => {
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
                },
                .GET_GLOBAL_OPT => {
                    // Tolerant load for `typeof <identifier>`: undeclared => undefined.
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
                },
                .HOIST_VAR => {
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const name = frame.func.chunk.constants[kidx].toPtr().string;
                    const undef = try val_mod.makeUndefined(self.arena);
                    frame.env.hoistVar(name, undef) catch return error.OutOfMemory;
                },
                .SET_GLOBAL => {
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
                },
                .DEFINE_GLOBAL => {
                    // Phase 4d: always define (never throws ReferenceError in strict mode).
                    // Used for var declarations, catch-variable bindings, function declarations.
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
                },
                .GET_LOCAL => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const slot = code[frame.pc];
                    frame.pc += 1;
                    // GET_LOCAL reads from registers[slot]. Also sync from env if defined there.
                    frame.registers[rdst] = frame.registers[slot];
                },
                .SET_LOCAL => {
                    const slot = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[slot] = frame.registers[rsrc];
                },
                .ADD => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (val_mod.smiArith(lv, rv, '+')) |s| {
                        frame.registers[rdst] = s;
                        ac.mode = .number_pair;
                    } else if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv)) {
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, lv.unbox().number + rv.unbox().number);
                    } else {
                        const sum = try self.jsAdd(lv, rv);
                        // jsAdd may invoke user ToPrimitive hooks, which can
                        // reallocate self.frames; re-fetch the current frame.
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = sum;
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    }
                },
                .SUB => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const ln = try self.toNumberCoerced(lv);
                        const rn = try self.toNumberCoerced(rv);
                        ac.mode = .unknown;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln - rn);
                    } else if (val_mod.smiArith(lv, rv, '-')) |s| {
                        frame.registers[rdst] = s;
                        ac.mode = .number_pair;
                    } else {
                        const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            lv.unbox().number - rv.unbox().number
                        else
                            toNumber(lv) - toNumber(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                    }
                },
                .MUL => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const ln = try self.toNumberCoerced(lv);
                        const rn = try self.toNumberCoerced(rv);
                        ac.mode = .unknown;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln * rn);
                    } else if (val_mod.smiArith(lv, rv, '*')) |s| {
                        frame.registers[rdst] = s;
                        ac.mode = .number_pair;
                    } else {
                        const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            lv.unbox().number * rv.unbox().number
                        else
                            toNumber(lv) * toNumber(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                    }
                },
                .DIV => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        ac.mode = .unknown;
                        const ln = self.toNumberCoerced(lv) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
                            continue;
                        };
                        const rn = self.toNumberCoerced(rv) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
                            continue;
                        };
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, ln / rn);
                    } else {
                        const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            lv.unbox().number / rv.unbox().number
                        else
                            toNumber(lv) / toNumber(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                    }
                },
                .MOD => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const l = try self.toNumberCoerced(lv);
                        const r = try self.toNumberCoerced(rv);
                        ac.mode = .unknown;
                        const res = jsRemainder(l, r);
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, res);
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            lv.unbox().number
                        else
                            toNumber(lv);
                        const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            rv.unbox().number
                        else
                            toNumber(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const res = jsRemainder(l, r);
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, res);
                    }
                },
                .EXP => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    // ToNumeric both operands (may reenter JS via valueOf → frame realloc),
                    // then dispatch BigInt vs Number exponentiation. Throws route through
                    // the VM try/catch machinery.
                    const result = self.expOp(lv, rv) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in exponentiation")) |oc| return oc;
                        continue;
                    };
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = result;
                },
                .NEG => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const sv = frame.registers[rsrc];
                    if (sv.bits != 0 and sv.unbox() == .bigint) {
                        frame.registers[rdst] = try val_mod.bigIntNegate(self.arena, sv);
                    } else if (isObjectOperand(sv)) {
                        const n = try self.toNumberCoerced(sv);
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, -n);
                    } else {
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, -toNumber(sv));
                    }
                },
                .BIT_AND => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lo = try self.toInt32Coerced(lv);
                        const ro = try self.toInt32Coerced(rv);
                        ac.mode = .unknown;
                        const r: i32 = lo & ro;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toInt32(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: i32 = l & r0;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .BIT_OR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lo = try self.toInt32Coerced(lv);
                        const ro = try self.toInt32Coerced(rv);
                        ac.mode = .unknown;
                        const r: i32 = lo | ro;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toInt32(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: i32 = l | r0;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .BIT_XOR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lo = try self.toInt32Coerced(lv);
                        const ro = try self.toInt32Coerced(rv);
                        ac.mode = .unknown;
                        const r: i32 = lo ^ ro;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toInt32(rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: i32 = l ^ r0;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .SHL => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const l = try self.toInt32Coerced(lv);
                        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
                        ac.mode = .unknown;
                        const r: i32 = l << shift;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toUint32(rv)) & 0x1F);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: i32 = l << shift;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .SHR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const l = try self.toInt32Coerced(lv);
                        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
                        ac.mode = .unknown;
                        const r: i32 = l >> shift;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toUint32(rv)) & 0x1F);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: i32 = l >> shift;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .USHR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const l = try self.toInt32Coerced(lv);
                        const u: u32 = @bitCast(l);
                        const shift: u5 = @intCast((try self.toUint32Coerced(rv)) & 0x1F);
                        ac.mode = .unknown;
                        const r: u32 = u >> shift;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(i32, @intFromFloat(@trunc(lv.unbox().number)))
                        else
                            toInt32(lv);
                        const u: u32 = @bitCast(l);
                        const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                            @as(u32, @intFromFloat(@trunc(rv.unbox().number)))
                        else
                            toUint32(rv)) & 0x1F);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                        const r: u32 = u >> shift;
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .BIT_NOT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const sv = frame.registers[rsrc];
                    if (isObjectOperand(sv)) {
                        const r: i32 = ~(try self.toInt32Coerced(sv));
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    } else {
                        const r: i32 = ~toInt32(sv);
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                    }
                },
                .INC => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const sv = frame.registers[rsrc];
                    if (isObjectOperand(sv)) {
                        const n = try self.toNumberCoerced(sv);
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, n + 1.0);
                    } else {
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, toNumber(sv) + 1.0);
                    }
                },
                .DEC => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const sv = frame.registers[rsrc];
                    if (isObjectOperand(sv)) {
                        const n = try self.toNumberCoerced(sv);
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeNumber(self.arena, n - 1.0);
                    } else {
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, toNumber(sv) - 1.0);
                    }
                },
                .EQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const r = self.abstractEqual(lv, rv) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
                            continue;
                        };
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
                    } else {
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, jsAbstractEqual(lv, rv));
                    }
                },
                .NEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const r = self.abstractEqual(lv, rv) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in ToPrimitive")) |oc| return oc;
                            continue;
                        };
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, !r);
                    } else {
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, !jsAbstractEqual(lv, rv));
                    }
                },
                .SEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .SNEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = !jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .LT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lp = try self.coerceForRelational(lv);
                        const rp = try self.coerceForRelational(rv);
                        const r = jsLessThan(lp, rp) orelse false;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
                    } else {
                        const r = jsLessThan(lv, rv) orelse false;
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                    }
                },
                .LE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    // a <= b == !(b < a)
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lp = try self.coerceForRelational(lv);
                        const rp = try self.coerceForRelational(rv);
                        const r2 = jsLessThan(rp, lp);
                        const r = if (r2) |v| !v else false;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
                    } else {
                        const r2 = jsLessThan(rv, lv);
                        const r = if (r2) |v| !v else false;
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                    }
                },
                .GT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lp = try self.coerceForRelational(lv);
                        const rp = try self.coerceForRelational(rv);
                        const r = jsLessThan(rp, lp) orelse false;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
                    } else {
                        const r = jsLessThan(rv, lv) orelse false;
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                    }
                },
                .GE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    // a >= b == !(a < b)
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    if (isObjectOperand(lv) or isObjectOperand(rv)) {
                        const lp = try self.coerceForRelational(lv);
                        const rp = try self.coerceForRelational(rv);
                        const r2 = jsLessThan(lp, rp);
                        const r = if (r2) |v| !v else false;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, r);
                    } else {
                        const r2 = jsLessThan(lv, rv);
                        const r = if (r2) |v| !v else false;
                        frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                    }
                },
                .NOT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, !isTruthy(frame.registers[rsrc]));
                },
                .TYPEOF => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const tv = frame.registers[rsrc];
                    const info = classifyTypeof(tv);
                    const cache = &@constCast(frame.func.typeof_ic_table)[site_pc];
                    const hit = cache.initialized and cache.tag == info.tag and
                        (info.shape == null or cache.shape == info.shape);
                    const ts = if (hit) cache.result else info.result;
                    if (!hit) {
                        cache.initialized = true;
                        cache.tag = info.tag;
                        cache.shape = info.shape;
                        cache.result = info.result;
                    }
                    frame.registers[rdst] = try val_mod.makeString(self.arena, ts);
                },
                .JMP => {
                    const op_site = frame.pc - 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    const new_pc: i64 = @intCast(frame.pc);
                    frame.pc = @intCast(new_pc + offset);
                    if (offset < 0 and self.noteBackedge(frame.func, op_site)) {
                        // Hot loop back-edge in experimental mode. First try general
                        // OSR (the whole loop body compiled to native code — handles
                        // arbitrary control flow); fall back to the closed-form
                        // template recognizer; then deopt. On success jump straight
                        // to the loop exit, else keep interpreting (graceful deopt).
                        if (try self.tryOsrLoop(frame.func, op_site, frame.env, frame.registers)) |exit_pc| {
                            frame.pc = exit_pc;
                        } else if (loop_jit.tryFastForwardLoop(
                            self.arena,
                            code,
                            frame.func.chunk.constants,
                            frame.env,
                            frame.registers,
                            op_site,
                        )) |exit_pc| {
                            frame.pc = exit_pc;
                            if (self.jit) |jc| jc.compiled += 1;
                        } else if (self.jit) |jc| {
                            _ = jc.noteDeopt(@intFromPtr(frame.func), @intCast(op_site)) catch {};
                        }
                    }
                },
                .JMP_IF_TRUE => {
                    const op_site = frame.pc - 1;
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (isTruthy(frame.registers[rcond])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
                    }
                },
                .JMP_IF_FALSE => {
                    const op_site = frame.pc - 1;
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (!isTruthy(frame.registers[rcond])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
                    }
                },
                .JMP_IF_NULLISH => {
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (frame.registers[rcond].isNullish()) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .JMP_IF_NOT_NULLISH => {
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (!frame.registers[rcond].isNullish()) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .JSEQ => {
                    const op_site = frame.pc - 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
                    }
                },
                .JGE => {
                    const op_site = frame.pc - 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    const lt = jsLessThan(frame.registers[rlhs], frame.registers[rrhs]);
                    const ge = if (lt) |v| !v else false;
                    if (ge) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                        if (offset < 0) _ = self.noteBackedge(frame.func, op_site);
                    }
                },
                .NEW_CLOSURE => {
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
                    };
                    const jsv = try self.arena.create(JsValue);
                    jsv.* = JsValue{ .bc_function = closure };
                    frame.registers[rdst] = Value.fromPtr(jsv);
                },
                .CALL => {
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
                        if (std.mem.eql(u8, msg, "__js_exception__")) {
                            // Native threw a JS exception; last_exception_value already set.
                            const exc_val = self.last_exception_value;
                            const found = try self.throwException(exc_val);
                            const exc_msg = try formatExceptionMessage(self.arena, exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
                        } else {
                            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                            self.last_exception_value = exc_val;
                            const found = try self.throwException(exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        }
                    }
                },
                .TAIL_CALL => {
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
                        const call_env = try Environment.init(self.arena, def_env);

                        for (fn_ptr.param_names, 0..) |pname, i| {
                            const av: Value = if (i < nargs)
                                frame.registers[base + 1 + @as(u8, @intCast(i))]
                            else
                                try val_mod.makeUndefined(self.arena);
                            try call_env.define(pname, av);
                        }
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
                        frame.this_val = this_val;
                        frame.try_stack = .empty;
                    } else {
                        // Fallback: native/bound/object callee. Do a normal call,
                        // then return its result to our caller (no frame reuse).
                        const outcome = try self.doCall(callee_val, this_val, base, nargs, ret_dst);
                        if (outcome) |msg| {
                            if (std.mem.eql(u8, msg, "__js_exception__")) {
                                const exc_val = self.last_exception_value;
                                const found = try self.throwException(exc_val);
                                const exc_msg = try formatExceptionMessage(self.arena, exc_val);
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
                },
                .METHOD_CALL => {
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
                        if (std.mem.eql(u8, msg, "__js_exception__")) {
                            const exc_val = self.last_exception_value;
                            const found = try self.throwException(exc_val);
                            const exc_msg = try formatExceptionMessage(self.arena, exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
                        } else {
                            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                            self.last_exception_value = exc_val;
                            const found = try self.throwException(exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        }
                    }
                },
                .TAIL_METHOD_CALL => {
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
                        const call_env = try Environment.init(self.arena, def_env);

                        for (fn_ptr.param_names, 0..) |pname, i| {
                            const av: Value = if (i < nargs)
                                frame.registers[base + 2 + @as(u8, @intCast(i))]
                            else
                                try val_mod.makeUndefined(self.arena);
                            try call_env.define(pname, av);
                        }
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
                        frame.this_val = this_val;
                        frame.try_stack = .empty;
                    } else {
                        // Fallback: native/bound/getter/generator/async callee. Do a
                        // normal method call, then return its result to our caller.
                        const outcome = try self.doMethodCall(callee_val, this_val, base, nargs, ret_dst);
                        if (outcome) |msg| {
                            if (std.mem.eql(u8, msg, "__js_exception__")) {
                                const exc_val = self.last_exception_value;
                                const found = try self.throwException(exc_val);
                                const exc_msg = try formatExceptionMessage(self.arena, exc_val);
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
                },
                .RETURN => {
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
                },
                .RETURN_UNDEF => {
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
                },
                .HALT => {
                    return RunOutcome{ .ok = self.result };
                },
                .YIELD => {
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const yielded = frame.registers[rsrc];
                    // The frame must belong to a generator (compiler only emits
                    // YIELD inside generator bodies). Save the suspended frame.
                    const state = frame.gen.?;
                    state.resume_reg = rsrc;
                    state.frame = frame.*; // pc already advanced past YIELD
                    _ = self.frames.pop();
                    self.result = yielded;
                    self.gen_yielded = true;
                    return RunOutcome{ .ok = yielded };
                },
                .DEBUGGER => {
                    // Phase 8: fire the installed debug hook (no-op if none).
                    const debugger_mod = @import("../runtime/debugger.zig");
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
                },
                // -------------------------------------------------------- Phase 3a/3b ---
                .NEW_OBJECT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const obj = if (self.heap) |heap|
                        try JsObject.createOnHeap(heap, self.realm.object_prototype)
                    else
                        try JsObject.create(self.arena, self.realm.object_prototype);
                    frame.registers[rdst] = try val_mod.makeObject(self.arena, obj);
                },
                .NEW_ARRAY => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    _ = code[frame.pc];
                    frame.pc += 1; // length hint (unused in runtime)
                    const arr = if (self.heap) |heap|
                        try JsObject.createArrayOnHeap(heap, self.realm.array_prototype)
                    else
                        try JsObject.createArray(self.arena, self.realm.array_prototype);
                    frame.registers[rdst] = try val_mod.makeObject(self.arena, arr);
                },
                .ARRAY_APPEND => {
                    const rarr = code[frame.pc];
                    frame.pc += 1;
                    const rval = code[frame.pc];
                    frame.pc += 1;
                    const arr_val = frame.registers[rarr];
                    const val = frame.registers[rval];
                    if (arr_val.bits != 0 and arr_val.unbox() == .object) {
                        const arr = arr_val.toPtr().object;
                        const idx = arr.getArrayLength();
                        const key = try std.fmt.allocPrint(self.arena, "{d}", .{idx});
                        try arr.set(key, val);
                    }
                },
                .ARRAY_SPREAD => {
                    const rarr = code[frame.pc];
                    frame.pc += 1;
                    const riter = code[frame.pc];
                    frame.pc += 1;
                    const arr_val = frame.registers[rarr];
                    const iter_src = frame.registers[riter];
                    if (arr_val.bits != 0 and arr_val.unbox() == .object) {
                        const arr = arr_val.toPtr().object;
                        const iter_mod = @import("../runtime/builtins/es2015_collections.zig");
                        const it = iter_mod.nativeGetIterator(self.arena, Value{}, &[_]Value{iter_src}) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("is not iterable")) |oc| return oc;
                            continue;
                        };
                        while (true) {
                            const step = iter_mod.nativeIterStep(self.arena, Value{}, &[_]Value{it}) catch |e| {
                                if (e != error.JsException) return e;
                                if (try self.raisePendingException("iterator error")) |oc| return oc;
                                break;
                            };
                            if (step.bits == 0 or step.unbox() != .object) break;
                            const done_v = step.toPtr().object.get("done") orelse break;
                            if (isTruthy(done_v)) break;
                            const v = step.toPtr().object.get("value") orelse try val_mod.makeUndefined(self.arena);
                            const idx = arr.getArrayLength();
                            const key = try std.fmt.allocPrint(self.arena, "{d}", .{idx});
                            try arr.set(key, v);
                        }
                    }
                },
                .GET_PROP => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const key_val = frame.func.chunk.constants[kidx];
                    const key = key_val.toPtr().string;
                    const obj_val = frame.registers[robj];
                    const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length") and !std.mem.eql(u8, key, "size")) {
                            if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                                if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                                    if (self.ic_stats_enabled) self.ic_own_hits += 1;
                                    frame.registers[rdst] = cached;
                                    continue;
                                }
                            }
                            // Proto-chain cache: method dispatch fast path (depth <= PROTO_IC_DEPTH).
                            if (site_cache.protoKeyMatches(key) and site_cache.proto_recv_shape == obj.shapePtr()) {
                                var cur: *JsObject = obj;
                                var ok = true;
                                var n: u8 = 0;
                                while (n < site_cache.proto_chain_len) : (n += 1) {
                                    const nxt = cur.proto orelse {
                                        ok = false;
                                        break;
                                    };
                                    const g = site_cache.proto_chain[n];
                                    if (@as(*anyopaque, @ptrCast(nxt)) != g.obj or nxt.shapePtr() != g.shape) {
                                        ok = false;
                                        break;
                                    }
                                    cur = nxt;
                                }
                                if (ok) {
                                    const hshape = site_cache.proto_chain[site_cache.proto_chain_len - 1].shape;
                                    if (cur.getOwnBySlot(hshape, site_cache.proto_slot)) |cached| {
                                        if (self.ic_stats_enabled) self.ic_proto_hits += 1;
                                        frame.registers[rdst] = cached;
                                        continue;
                                    }
                                }
                            }
                        }
                    }

                    if (self.ic_stats_enabled and obj_val.bits != 0 and obj_val.unbox() == .object) self.ic_misses += 1;
                    const frame_idx = self.frames.items.len - 1;
                    const result = self.getProp(obj_val, key) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in getter")) |oc| return oc;
                        continue;
                    };
                    // Re-fetch frame: getProp may invoke a getter via bcInvokeJs which
                    // appends to self.frames and potentially reallocates the backing slice.
                    const frame2 = &self.frames.items[frame_idx];
                    frame2.registers[rdst] = result;
                    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length") and !std.mem.eql(u8, key, "size")) {
                            if (obj.resolveOwnSlot(key)) |slot| {
                                if (!obj.attrAt(slot).is_accessor) site_cache.record(self.arena, key, obj.shapePtr(), slot);
                            } else {
                                // Walk proto chain; cache a hit within PROTO_IC_DEPTH links.
                                var guards: [ic_mod.PROTO_IC_DEPTH]ic_mod.ProtoGuard = undefined;
                                var cur = obj.proto;
                                var n: usize = 0;
                                while (cur) |c| {
                                    if (n >= ic_mod.PROTO_IC_DEPTH) break;
                                    guards[n] = .{ .obj = @ptrCast(c), .shape = c.shapePtr() };
                                    if (c.resolveOwnSlot(key)) |pslot| {
                                        if (!c.attrAt(pslot).is_accessor) site_cache.protoRecord(key, obj.shapePtr(), guards[0 .. n + 1], pslot);
                                        break;
                                    }
                                    cur = c.proto;
                                    n += 1;
                                }
                            }
                        }
                    }
                },
                .GET_PROP_DYN => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const key_val = frame.registers[rkey];
                    if (key_val.bits != 0 and key_val.unbox() == .string) {
                        const key = key_val.toPtr().string;
                        const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                                    if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                                        if (self.ic_stats_enabled) self.ic_own_hits += 1;
                                        frame.registers[rdst] = cached;
                                        continue;
                                    }
                                }
                                if (site_cache.protoKeyMatches(key) and site_cache.proto_recv_shape == obj.shapePtr()) {
                                    var cur: *JsObject = obj;
                                    var ok = true;
                                    var n: u8 = 0;
                                    while (n < site_cache.proto_chain_len) : (n += 1) {
                                        const nxt = cur.proto orelse {
                                            ok = false;
                                            break;
                                        };
                                        const g = site_cache.proto_chain[n];
                                        if (@as(*anyopaque, @ptrCast(nxt)) != g.obj or nxt.shapePtr() != g.shape) {
                                            ok = false;
                                            break;
                                        }
                                        cur = nxt;
                                    }
                                    if (ok) {
                                        const hshape = site_cache.proto_chain[site_cache.proto_chain_len - 1].shape;
                                        if (cur.getOwnBySlot(hshape, site_cache.proto_slot)) |cached| {
                                            if (self.ic_stats_enabled) self.ic_proto_hits += 1;
                                            frame.registers[rdst] = cached;
                                            continue;
                                        }
                                    }
                                }
                            }
                        }
                        if (self.ic_stats_enabled and obj_val.bits != 0 and obj_val.unbox() == .object) self.ic_misses += 1;
                        const frame_idx_dyn = self.frames.items.len - 1;
                        const result = self.getProp(obj_val, key) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in getter")) |oc| return oc;
                            continue;
                        };
                        // Re-fetch frame after getProp: accessor getter dispatch via
                        // bcInvokeJs may have appended frames and reallocated the slice.
                        const frame2_dyn = &self.frames.items[frame_idx_dyn];
                        frame2_dyn.registers[rdst] = result;
                        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (obj.resolveOwnSlot(key)) |slot| {
                                    if (!obj.attrAt(slot).is_accessor) site_cache.record(self.arena, key, obj.shapePtr(), slot);
                                } else {
                                    var guards: [ic_mod.PROTO_IC_DEPTH]ic_mod.ProtoGuard = undefined;
                                    var cur = obj.proto;
                                    var n: usize = 0;
                                    while (cur) |c| {
                                        if (n >= ic_mod.PROTO_IC_DEPTH) break;
                                        guards[n] = .{ .obj = @ptrCast(c), .shape = c.shapePtr() };
                                        if (c.resolveOwnSlot(key)) |pslot| {
                                            if (!c.attrAt(pslot).is_accessor) site_cache.protoRecord(key, obj.shapePtr(), guards[0 .. n + 1], pslot);
                                            break;
                                        }
                                        cur = c.proto;
                                        n += 1;
                                    }
                                }
                            }
                        }
                    } else if (key_val.bits != 0 and key_val.unbox() == .symbol) {
                        const fidx_sym = self.frames.items.len - 1;
                        const sym_res = self.getPropSym(obj_val, key_val) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in getter")) |oc| return oc;
                            continue;
                        };
                        self.frames.items[fidx_sym].registers[rdst] = sym_res;
                    } else {
                        const frame_idx_dyn2 = self.frames.items.len - 1;
                        const key = try valueToStringArena(self.arena, key_val);
                        const result_dyn2 = self.getProp(obj_val, key) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in getter")) |oc| return oc;
                            continue;
                        };
                        self.frames.items[frame_idx_dyn2].registers[rdst] = result_dyn2;
                    }
                },
                .SET_PROP => {
                    const site_pc = frame.pc - 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const rval = code[frame.pc];
                    frame.pc += 1;
                    const key_val = frame.func.chunk.constants[kidx];
                    const key = key_val.toPtr().string;
                    const obj_val = frame.registers[robj];
                    const val = frame.registers[rval];
                    // Save func pointer before setProp: a setter dispatch via bcInvokeJs
                    // may reallocate self.frames, invalidating the `frame` pointer.
                    const set_func = frame.func;
                    self.setProp(obj_val, key, val) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in setter")) |oc| return oc;
                        continue;
                    };
                    const site_cache = &@constCast(set_func.ic_table)[site_pc];
                    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                            if (obj.resolveOwnSlot(key)) |slot| {
                                site_cache.record(self.arena, key, obj.shapePtr(), slot);
                            }
                        }
                    }
                },
                .SET_PROP_DYN => {
                    const site_pc = frame.pc - 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const rval = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const key_val = frame.registers[rkey];
                    const val = frame.registers[rval];
                    if (key_val.bits != 0 and key_val.unbox() == .string) {
                        const key = key_val.toPtr().string;
                        const set_dyn_func = frame.func;
                        self.setProp(obj_val, key, val) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in setter")) |oc| return oc;
                            continue;
                        };
                        const site_cache = &@constCast(set_dyn_func.ic_table)[site_pc];
                        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (obj.resolveOwnSlot(key)) |slot| {
                                    site_cache.record(self.arena, key, obj.shapePtr(), slot);
                                }
                            }
                        }
                    } else if (key_val.bits != 0 and key_val.unbox() == .symbol) {
                        self.setPropSym(obj_val, key_val, val) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in setter")) |oc| return oc;
                            continue;
                        };
                    } else {
                        const key = try valueToStringArena(self.arena, key_val);
                        self.setProp(obj_val, key, val) catch |e| {
                            if (e != error.JsException) return e;
                            if (try self.raisePendingException("error in setter")) |oc| return oc;
                            continue;
                        };
                    }
                },
                .DEFINE_ACCESSOR => {
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const kind = code[frame.pc];
                    frame.pc += 1;
                    const rfn = code[frame.pc];
                    frame.pc += 1;
                    const key = frame.func.chunk.constants[kidx].toPtr().string;
                    const obj_val = frame.registers[robj];
                    const fn_val = frame.registers[rfn];
                    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
                        const obj = obj_val.toPtr().object;
                        const member: []const u8 = if (kind == 0) "get" else "set";
                        if (obj.ownAccessorHolder(key)) |hv| {
                            // Merge into the existing accessor holder for this key.
                            try hv.toPtr().object.set(member, fn_val);
                        } else {
                            const holder_obj = if (self.heap) |heap|
                                try JsObject.createOnHeap(heap, self.realm.object_prototype)
                            else
                                try JsObject.create(self.arena, self.realm.object_prototype);
                            try holder_obj.set(member, fn_val);
                            const holder_val = try val_mod.makeObject(self.arena, holder_obj);
                            _ = try obj.defineOwnAccessor(key, holder_val, .{ .enumerable = true, .configurable = true });
                        }
                    }
                },
                .GET_THIS => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = frame.this_val;
                },
                // -------------------------------------------------------- Phase 4a ---
                .THROW => {
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
                        const msg = try formatExceptionMessage(self.arena, thrown_val);
                        return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown_val } };
                    }
                },
                .PUSH_TRY => {
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
                },
                .POP_TRY => {
                    if (frame.try_stack.items.len > 0) {
                        _ = frame.try_stack.pop();
                    }
                },
                .NEW_INSTANCE => {
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
                },
                .INSTANCEOF => {
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
                        result = jsInstanceofWithTarget(lhs, target_proto);
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
                        result = jsInstanceofWithTarget(lhs, target_proto);
                    } else {
                        result = false;
                    }
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, result);
                },
                .IN => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const key_v = frame.registers[rkey];
                    const obj_v = frame.registers[robj];
                    if (obj_v.bits == 0 or obj_v.unbox() != .object) {
                        const exc = try self.makeErrorObjectBc("TypeError", "Cannot use 'in' operator to search for key in a non-object");
                        self.last_exception_value = exc;
                        const found = try self.throwException(exc);
                        if (!found) return RunOutcome{ .exception_value = .{ .msg = "Cannot use 'in' operator on a non-object", .value = exc } };
                        continue;
                    }
                    const has = self.hasProperty(obj_v, key_v) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in proxy has trap")) |oc| return oc;
                        continue;
                    };
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, has);
                },
                .DELETE_PROP => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const obj_v = frame.registers[robj];
                    const key_v = frame.registers[rkey];
                    const ok = self.deleteProperty(obj_v, key_v) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in proxy deleteProperty trap")) |oc| return oc;
                        continue;
                    };
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, ok);
                },
                .CALL_SPREAD => {
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
                    const fp = @import("../runtime/builtins/function_proto.zig");
                    const result = fp.invokeCallback(self.arena, this_v, callee_v, args_list.items) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in spread call")) |oc| return oc;
                        continue;
                    };
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = result;
                },
                // Phase 4d
                .GET_KEYS => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const arr_obj = if (self.heap) |heap|
                        try JsObject.createOnHeap(heap, self.realm.array_prototype)
                    else
                        try JsObject.create(self.arena, self.realm.array_prototype);
                    arr_obj.is_array = true;
                    var count: u32 = 0;
                    if (obj_val.bits != 0) {
                        const iv = obj_val.unbox();
                        if (iv == .object and iv.object.internal_kind == .proxy) {
                            if (try proxy_mod.proxyOwnKeys(self.arena, iv.object)) |keys| {
                                for (keys) |kv| {
                                    if (kv.bits != 0 and kv.unbox() == .string) {
                                        const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                                        arr_obj.set(idx_str, kv) catch {};
                                        count += 1;
                                    }
                                }
                            }
                        } else if (iv == .object) {
                            for (iv.object.ownKeys()) |k| {
                                if (!iv.object.isEnumerable(k)) continue;
                                const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                                const key_val = try val_mod.makeString(self.arena, k);
                                arr_obj.set(idx_str, key_val) catch {};
                                count += 1;
                            }
                        }
                    }
                    const len_val = try val_mod.makeNumber(self.arena, @floatFromInt(count));
                    arr_obj.set("length", len_val) catch {};
                    // Re-fetch frame: a proxy ownKeys trap may have run user code.
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeObject(self.arena, arr_obj);
                },
            }
        }
        return RunOutcome{ .ok = try val_mod.makeUndefined(self.arena) };
    }

    /// Route a caught native `error.JsException` into the VM's try/catch
    /// machinery. Returns a `RunOutcome` the caller must return (no handler
    /// found), or null when a handler was found (caller continues dispatch).
    fn raisePendingException(self: *BcVm, fallback_msg: []const u8) !?RunOutcome {
        const realm_mod = @import("../runtime/realm.zig");
        const exc_val = if (realm_mod.pending_exception.bits != 0)
            realm_mod.pending_exception
        else
            try self.makeErrorObjectBc("TypeError", fallback_msg);
        realm_mod.pending_exception = Value{};
        self.last_exception_value = exc_val;
        const found = try self.throwException(exc_val);
        if (!found) {
            const exc_msg = try formatExceptionMessage(self.arena, exc_val);
            return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
        }
        return null;
    }

    /// Throw helper: walk frame stack for a try entry and dispatch. Returns true if handled.
    fn throwException(self: *BcVm, thrown_val: Value) !bool {
        var fi: usize = self.frames.items.len;
        while (fi > 0) {
            fi -= 1;
            const f = &self.frames.items[fi];
            if (f.try_stack.items.len > 0) {
                const entry = f.try_stack.pop().?;
                f.pc = entry.handler_pc;
                if (entry.rexc != 0xFF) {
                    f.registers[entry.rexc] = thrown_val;
                }
                while (self.frames.items.len > fi + 1) {
                    _ = self.frames.pop();
                }
                return true;
            }
        }
        return false;
    }

    /// [[Construct]]: R[base] = constructor, R[base+1..base+nargs] = args.
    fn doConstruct(self: *BcVm, callee_val: Value, base: u8, nargs: u8, rdst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return "undefined is not a constructor";
        }
        switch (callee_val.unbox()) {
            .bc_function => {
                // W2 unification: real [[Construct]] for bc functions. The new
                // object's prototype is the constructor's `.prototype`; the ctor
                // runs synchronously with `this` bound to it; the result is the
                // ctor's return value if it is an object, else the new object.
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const proto_v = try self.getProp(callee_val, "prototype");
                const proto: ?*JsObject = if (proto_v.bits != 0 and proto_v.unbox() == .object)
                    proto_v.toPtr().object
                else
                    self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                const result = bcInvokeJs(self, self.arena, this_val, callee_val, args) catch |e| {
                    if (e == error.JsException) {
                        const realm_m = @import("../runtime/realm.zig");
                        if (realm_m.pending_exception.bits != 0) {
                            self.last_exception_value = realm_m.pending_exception;
                            realm_m.pending_exception = Value{};
                        }
                        return "__js_exception__";
                    }
                    return "constructor threw";
                };
                const final = if (result.bits != 0 and result.unbox() == .object) result else this_val;
                self.frames.items[self.frames.items.len - 1].registers[rdst] = final;
                return null;
            },
            .function => {
                // Tree-mode FuncVal (not produced by the bc compiler). Best-effort:
                // run with a fresh `this`; caller gets the ctor's return value.
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, self.realm.object_prototype)
                else
                    try JsObject.create(self.arena, self.realm.object_prototype);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                const err = try self.doCallWithThis(callee_val, this_val, base, nargs, rdst);
                if (err != null) return err;
                return null;
            },
            .native_function => |fn_ptr| {
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const proto = self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                @import("../runtime/realm.zig").active_constructing = true;
                const result = fn_ptr.invoke(self.arena, this_val, args) catch {
                    @import("../runtime/realm.zig").active_constructing = false;
                    return "native constructor threw";
                };
                @import("../runtime/realm.zig").active_constructing = false;
                frame.registers[rdst] = if (result.bits != 0 and result.unbox() == .object) result else this_val;
                return null;
            },
            .object => |obj| {
                // Phase 13: Proxy construct trap (or forward to target).
                if (obj.internal_kind == .proxy) {
                    var pargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| pargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const res = self.proxyConstruct(obj, pargs, callee_val) catch |e| {
                        if (e == error.JsException) {
                            const realm_m = @import("../runtime/realm.zig");
                            if (realm_m.pending_exception.bits != 0) {
                                self.last_exception_value = realm_m.pending_exception;
                                realm_m.pending_exception = Value{};
                            }
                            return "__js_exception__";
                        }
                        return "TypeError: proxy is not a constructor";
                    };
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = res;
                    return null;
                }
                // Error constructor object: has __call__ and prototype.
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.unbox() == .native_function) {
                        const fn_ptr = call_val.toPtr().native_function;
                        var proto: ?*JsObject = self.realm.object_prototype;
                        if (obj.get("prototype")) |pv| {
                            if (pv.bits != 0 and pv.unbox() == .object) {
                                proto = pv.toPtr().object;
                            }
                        }
                        var args = try self.arena.alloc(Value, nargs);
                        for (0..nargs) |i| {
                            args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        const new_obj = if (self.heap) |heap|
                            try JsObject.createOnHeap(heap, proto)
                        else
                            try JsObject.create(self.arena, proto);
                        const this_val = try val_mod.makeObject(self.arena, new_obj);
                        const realm_c = @import("../runtime/realm.zig");
                        realm_c.active_constructing = true;
                        const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                            realm_c.active_constructing = false;
                            if (e == error.JsException) {
                                const realm_m = @import("../runtime/realm.zig");
                                if (realm_m.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_m.pending_exception;
                                    realm_m.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return "native constructor threw";
                        };
                        realm_c.active_constructing = false;
                        const final_r = if (result.bits != 0 and result.unbox() == .object) result else this_val;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = final_r;
                        return null;
                    }
                }
                return "object is not a constructor";
            },
            else => return try std.fmt.allocPrint(self.arena, "{s} is not a constructor", .{typeofValue(callee_val)}),
        }
    }

    fn doCallWithThis(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        switch (callee_val.unbox()) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));
                if (fn_ptr.is_async) {
                    var aargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| aargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const p = try self.buildAsyncFunction(fn_ptr, def_env, this_val, aargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = p;
                    return null;
                }
                if (fn_ptr.is_generator) {
                    var gargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| gargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const g = try self.buildGenerator(fn_ptr, def_env, this_val, gargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = g;
                    return null;
                }
                const call_env = try Environment.init(self.arena, def_env);
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 1 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};
                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            else => return "not a callable",
        }
    }

    /// Read an own string property, or a fallback. Used by stack capture.
    fn ownStr(obj: *JsObject, key: []const u8, fallback: []const u8) []const u8 {
        if (obj.getOwn(key)) |v| {
            if (v.bits != 0 and v.unbox() == .string) return v.unbox().string;
        }
        return fallback;
    }

    /// Best-effort synchronous stack trace for an Error-like object: builds a
    /// V8-style "Name: message\n    at fn\n    at async fn" string from the live
    /// call frames (innermost first) and stores it as the object's own `stack`.
    /// Frames belonging to a generator/async coroutine are marked `at async`.
    /// No-op if a `stack` is already present. Async-boundary detail is coarse
    /// (per-frame marker only); cross-await caller chains are not yet linked.
    fn captureStackBc(self: *BcVm, err_obj: *JsObject) void {
        if (err_obj.getOwn("stack") != null) return;
        const name = ownStr(err_obj, "name", "Error");
        const msg = ownStr(err_obj, "message", "");
        var buf = std.ArrayListUnmanaged(u8){};
        const hdr = if (msg.len > 0)
            std.fmt.allocPrint(self.arena, "{s}: {s}", .{ name, msg }) catch return
        else
            self.arena.dupe(u8, name) catch return;
        buf.appendSlice(self.arena, hdr) catch return;
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.frames.items[i];
            const fname = f.func.name orelse "<anonymous>";
            buf.appendSlice(self.arena, if (f.gen != null) "\n    at async " else "\n    at ") catch return;
            buf.appendSlice(self.arena, fname) catch return;
        }
        const stack_str = val_mod.makeString(self.arena, buf.items) catch return;
        err_obj.set("stack", stack_str) catch {};
    }

    fn makeErrorObjectBc(self: *BcVm, name: []const u8, message: []const u8) !Value {
        const proto_name = try std.fmt.allocPrint(self.arena, "__{s}Proto__", .{name});
        var proto: ?*JsObject = self.realm.object_prototype;
        if (self.realm.global_env.lookup(proto_name)) |pv| {
            if (pv.bits != 0 and pv.unbox() == .object) proto = pv.toPtr().object;
        } else |_| {}
        const obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, proto)
        else
            try JsObject.create(self.arena, proto);
        const msg_val = try val_mod.makeString(self.arena, message);
        const name_val = try val_mod.makeString(self.arena, name);
        try obj.set("message", msg_val);
        try obj.set("name", name_val);
        self.captureStackBc(obj);
        return val_mod.makeObject(self.arena, obj);
    }

    /// Read a member ("get"/"set") off an accessor holder Value.
    fn accessorMember(holder_val: Value, name: []const u8) Value {
        if (holder_val.bits == 0 or holder_val.unbox() != .object) return Value{};
        return holder_val.toPtr().object.getOwn(name) orelse Value{};
    }

    /// True if `v` is a callable value (function, native, bc_function, bound).
    fn isCallable(v: Value) bool {
        if (v.bits == 0) return false;
        return switch (v.unbox()) {
            .function, .native_function, .bc_function => true,
            .object => |obj| obj.internal_kind == .bound_function,
            else => false,
        };
    }

    /// Invoke a getter/setter callable with the given receiver.
    fn callAccessor(self: *BcVm, fn_val: Value, this_val: Value, args: []const Value) !Value {
        const fp = @import("../runtime/builtins/function_proto.zig");
        return fp.invokeCallback(self.arena, this_val, fn_val, args);
    }

    /// Read a symbol-keyed property, walking the prototype chain (own first).
    fn getPropSym(self: *BcVm, obj_val: Value, sym_key: Value) !Value {
        if (obj_val.bits == 0 or obj_val.unbox() != .object) return val_mod.makeUndefined(self.arena);
        const root_obj = obj_val.toPtr().object;
        if (root_obj.internal_kind == .proxy) {
            return try self.proxyGet(obj_val, root_obj, sym_key);
        }
        var cur: ?*JsObject = root_obj;
        var depth: usize = 0;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            if (o.getOwnSym(sym_key)) |v| return v;
            cur = o.proto;
        }
        return val_mod.makeUndefined(self.arena);
    }

    /// Set a symbol-keyed own property.
    fn setPropSym(self: *BcVm, obj_val: Value, sym_key: Value, value: Value) !void {
        if (obj_val.bits == 0 or obj_val.unbox() != .object) return;
        const obj = obj_val.toPtr().object;
        if (obj.internal_kind == .proxy) {
            try self.proxySet(obj_val, obj, sym_key, value);
            return;
        }
        try obj.setSym(sym_key, value);
    }

    /// Proxy `get` trap dispatch: `handler.get(target, key, receiver)`, falling
    /// back to a plain read on the target when no trap is defined.
    fn proxyGet(self: *BcVm, proxy_val: Value, proxy_obj: *JsObject, key: Value) anyerror!Value {
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return val_mod.makeUndefined(self.arena);
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return val_mod.makeUndefined(self.arena);
        if (proxy_mod.trap(handler, "get")) |trap_fn| {
            return try self.callAccessor(trap_fn, handler, &[_]Value{ target, key, proxy_val });
        }
        // No trap: forward to the target.
        if (key.bits != 0 and key.unbox() == .symbol) return try self.getPropSym(target, key);
        const key_str = try valueToStringArena(self.arena, key);
        return try self.getProp(target, key_str);
    }

    /// Proxy `set` trap dispatch: `handler.set(target, key, value, receiver)`,
    /// falling back to a plain write on the target when no trap is defined.
    fn proxySet(self: *BcVm, proxy_val: Value, proxy_obj: *JsObject, key: Value, value: Value) anyerror!void {
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return;
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return;
        if (proxy_mod.trap(handler, "set")) |trap_fn| {
            _ = try self.callAccessor(trap_fn, handler, &[_]Value{ target, key, value, proxy_val });
            return;
        }
        // No trap: forward to the target.
        if (key.bits != 0 and key.unbox() == .symbol) {
            try self.setPropSym(target, key, value);
            return;
        }
        const key_str = try valueToStringArena(self.arena, key);
        try self.setProp(target, key_str, value);
    }

    /// HasProperty(obj, key) for the `in` operator: prototype-chain walk over
    /// string and symbol keys, with Proxy `has` trap dispatch.
    fn hasProperty(self: *BcVm, obj_val: Value, key_v: Value) anyerror!bool {
        if (obj_val.bits == 0 or obj_val.unbox() != .object) return false;
        const root_obj = obj_val.toPtr().object;
        if (root_obj.internal_kind == .proxy) {
            const handler = proxy_mod.proxyHandler(root_obj) orelse return false;
            const target = proxy_mod.proxyTarget(root_obj) orelse return false;
            if (proxy_mod.trap(handler, "has")) |trap_fn| {
                const res = try self.callAccessor(trap_fn, handler, &[_]Value{ target, key_v });
                return isTruthy(res);
            }
            return try self.hasProperty(target, key_v);
        }
        // Symbol key.
        if (key_v.bits != 0 and key_v.unbox() == .symbol) {
            var cur: ?*JsObject = root_obj;
            var depth: usize = 0;
            while (cur) |o| {
                if (depth >= 64) break;
                depth += 1;
                if (o.getOwnSym(key_v) != null) return true;
                cur = o.proto;
            }
            return false;
        }
        // String key.
        const key = try valueToStringArena(self.arena, key_v);
        var cur: ?*JsObject = root_obj;
        var depth: usize = 0;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            if (o.is_array and std.mem.eql(u8, key, "length")) return true;
            if (o.hasOwn(key)) return true;
            cur = o.proto;
        }
        return false;
    }

    /// Delete own property for the `delete` operator, returning the boolean
    /// result. Dispatches the Proxy `deleteProperty` trap; deleting from a
    /// non-object is a no-op that yields `true`.
    fn deleteProperty(self: *BcVm, obj_val: Value, key_v: Value) anyerror!bool {
        if (obj_val.bits == 0 or obj_val.unbox() != .object) return true;
        const obj = obj_val.toPtr().object;
        if (obj.internal_kind == .proxy) {
            const handler = proxy_mod.proxyHandler(obj) orelse return false;
            const target = proxy_mod.proxyTarget(obj) orelse return false;
            if (proxy_mod.trap(handler, "deleteProperty")) |trap_fn| {
                const res = try self.callAccessor(trap_fn, handler, &[_]Value{ target, key_v });
                return isTruthy(res);
            }
            return try self.deleteProperty(target, key_v);
        }
        if (key_v.bits != 0 and key_v.unbox() == .symbol) {
            return obj.deleteOwnSym(key_v);
        }
        const key = try valueToStringArena(self.arena, key_v);
        return obj.deleteOwn(key);
    }

    /// Abstract equality (`==`) with object↔primitive ToPrimitive coercion.
    /// When exactly one side is an object (and the other is neither null nor
    /// undefined), the object is converted via ToPrimitive(default) — honoring
    /// `Symbol.toPrimitive`/`valueOf`/`toString` — then re-compared. Everything
    /// else delegates to the pure `jsAbstractEqual`.
    fn abstractEqual(self: *BcVm, x: Value, y: Value) anyerror!bool {
        const x_obj = isObjectOperand(x);
        const y_obj = isObjectOperand(y);
        if (x_obj and !y_obj) {
            if (y.bits == 0) return false; // object == undefined
            if (y.unbox() == .null_ or y.unbox() == .undefined_) return false;
            const xp = (try self.coerceToPrimitive(x, .default)) orelse
                try val_mod.makeString(self.arena, try valueToString(self.arena, x));
            return try self.abstractEqual(xp, y);
        }
        if (y_obj and !x_obj) {
            if (x.bits == 0) return false;
            if (x.unbox() == .null_ or x.unbox() == .undefined_) return false;
            const yp = (try self.coerceToPrimitive(y, .default)) orelse
                try val_mod.makeString(self.arena, try valueToString(self.arena, y));
            return try self.abstractEqual(x, yp);
        }
        return jsAbstractEqual(x, y);
    }

    /// Build a JS array from a slice of values (used to pass an argument list to
    /// Proxy `apply`/`construct` traps).
    fn arrayFromSlice(self: *BcVm, items: []const Value) !Value {
        const arr = if (self.heap) |heap|
            try JsObject.createArrayOnHeap(heap, self.realm.array_prototype)
        else
            try JsObject.createArray(self.arena, self.realm.array_prototype);
        for (items, 0..) |it, i| {
            const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
            try arr.set(key, it);
        }
        return val_mod.makeObject(self.arena, arr);
    }

    /// Proxy `apply` trap: `handler.apply(target, thisArg, argsArray)`, forwarding
    /// to a plain call on the target when no trap is defined.
    fn proxyApply(self: *BcVm, proxy_obj: *JsObject, this_val: Value, args: []const Value) anyerror!Value {
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return error.JsException;
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return error.JsException;
        if (proxy_mod.trap(handler, "apply")) |trap_fn| {
            const args_arr = try self.arrayFromSlice(args);
            return try self.callAccessor(trap_fn, handler, &[_]Value{ target, this_val, args_arr });
        }
        const fp = @import("../runtime/builtins/function_proto.zig");
        return try fp.invokeCallback(self.arena, this_val, target, args);
    }

    /// Proxy `construct` trap: `handler.construct(target, argsArray, newTarget)`,
    /// forwarding to a plain construct on the target when no trap is defined.
    /// A present trap must return an object (else TypeError).
    fn proxyConstruct(self: *BcVm, proxy_obj: *JsObject, args: []const Value, new_target: Value) anyerror!Value {
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return error.JsException;
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return error.JsException;
        if (proxy_mod.trap(handler, "construct")) |trap_fn| {
            const args_arr = try self.arrayFromSlice(args);
            const res = try self.callAccessor(trap_fn, handler, &[_]Value{ target, args_arr, new_target });
            if (res.bits != 0 and res.unbox() == .object) return res;
            const realm_m = @import("../runtime/realm.zig");
            realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "proxy [[Construct]] must return an object");
            return error.JsException;
        }
        return try self.constructFromArgs(target, args);
    }

    fn getProp(self: *BcVm, obj_val: Value, key: []const u8) !Value {
        if (obj_val.bits == 0) return val_mod.makeUndefined(self.arena);
        switch (obj_val.unbox()) {
            .object => |obj| {
                if (obj.internal_kind == .proxy) {
                    const key_v = try val_mod.makeString(self.arena, key);
                    return try self.proxyGet(obj_val, obj, key_v);
                }
                if (obj.is_array and std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(obj.getArrayLength()));
                }
                if (std.mem.eql(u8, key, "size")) {
                    if (@import("../runtime/builtins/es2015_collections.zig").collectionSize(obj)) |n| {
                        return val_mod.makeNumber(self.arena, @floatFromInt(n));
                    }
                }
                if (obj.findProperty(key)) |loc| {
                    const a = loc.holder.attrAt(loc.slot);
                    const raw = if (loc.slot < loc.holder.slots.items.len) loc.holder.slots.items[loc.slot] else Value{};
                    if (a.is_accessor) {
                        const getter = accessorMember(raw, "get");
                        // Only invoke if getter is an actual callable (not undefined/null).
                        if (!isCallable(getter)) return val_mod.makeUndefined(self.arena);
                        return try self.callAccessor(getter, obj_val, &[_]Value{});
                    }
                    if (raw.bits != 0) return raw;
                    return val_mod.makeUndefined(self.arena);
                }
                return val_mod.makeUndefined(self.arena);
            },
            .string => |s| {
                // Phase 4b: autoboxing for string primitives.
                if (std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(s.len));
                }
                // Delegate to String.prototype
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_string_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .bc_function => |closure| {
                // W2 unification: bc functions are objects. `prototype` is
                // materialized lazily; other own props live on the backing
                // object; everything else delegates to Function.prototype.
                if (std.mem.eql(u8, key, "prototype")) {
                    return try self.closurePrototype(obj_val, closure);
                }
                if (closure.obj) |op| {
                    const o: *JsObject = @ptrCast(@alignCast(op));
                    if (o.get(key)) |v| return v;
                }
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .function, .native_function => {
                // `.length` = declared arity (native_function carries it inline).
                if (std.mem.eql(u8, key, "length")) {
                    const len: u8 = switch (obj_val.unbox()) {
                        .native_function => |e| e.length,
                        else => 0,
                    };
                    return val_mod.makeNumber(self.arena, @floatFromInt(len));
                }
                // Phase 4d: delegate to Function.prototype (call, apply, bind).
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .symbol => {
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_symbol_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .number => {
                // Phase 13: autoboxing for number primitives → Number.prototype.
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_number_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .boolean => {
                // Phase 13: autoboxing for boolean primitives → Boolean.prototype.
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_boolean_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            else => return val_mod.makeUndefined(self.arena),
        }
    }

    /// W2 unification: the lazily-created backing object for a bc function's own
    /// properties. Proto is Function.prototype so call/apply/bind resolve too.
    fn closureBackingObj(self: *BcVm, closure: *BcClosure) !*JsObject {
        if (closure.obj) |op| return @ptrCast(@alignCast(op));
        const o = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.function_prototype)
        else
            try JsObject.create(self.arena, self.realm.function_prototype);
        closure.obj = o;
        return o;
    }

    /// W2 unification: a bc function's `.prototype` value, lazily creating a plain
    /// object with a `constructor` back-reference on first access (matches the
    /// implicit prototype every JS function carries).
    fn closurePrototype(self: *BcVm, fn_val: Value, closure: *BcClosure) !Value {
        const o = try self.closureBackingObj(closure);
        if (o.get("prototype")) |p| return p;
        const proto_obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        const pv = try val_mod.makeObject(self.arena, proto_obj);
        try proto_obj.set("constructor", fn_val);
        try o.set("prototype", pv);
        return pv;
    }

    fn setProp(self: *BcVm, obj_val: Value, key: []const u8, value: Value) !void {
        if (obj_val.bits == 0) return;
        switch (obj_val.unbox()) {
            .object => |obj| {
                if (obj.internal_kind == .proxy) {
                    const key_v = try val_mod.makeString(self.arena, key);
                    try self.proxySet(obj_val, obj, key_v, value);
                    return;
                }
                if (obj.findProperty(key)) |loc| {
                    const a = loc.holder.attrAt(loc.slot);
                    if (a.is_accessor) {
                        const raw = if (loc.slot < loc.holder.slots.items.len) loc.holder.slots.items[loc.slot] else Value{};
                        const setter = accessorMember(raw, "set");
                        // Only invoke if setter is an actual callable (not undefined/null).
                        if (isCallable(setter)) _ = try self.callAccessor(setter, obj_val, &[_]Value{value});
                        return; // accessor with no setter: sloppy no-op
                    }
                    if (loc.holder == obj) {
                        if (loc.slot < obj.attrs.items.len and !obj.attrs.items[loc.slot].writable) return;
                        _ = obj.setOwnBySlot(obj.shapePtr(), loc.slot, value);
                        return;
                    }
                    // inherited data property: fall through to create an own (shadow).
                }
                try obj.set(key, value);
            },
            // W2 unification: bc functions store own properties (incl.
            // `C.prototype = ...`) on their backing object.
            .bc_function => |closure| {
                const o = try self.closureBackingObj(closure);
                try o.set(key, value);
            },
            else => {},
        }
    }

    /// S8: re-entrant property bridges for the boxed JIT's GET_PROP/SET_PROP
    /// helpers (`int_fn_jit.jsz_jit_get_prop`/`jsz_jit_set_own` slow paths).
    /// They run the interpreter's FULL property machinery — accessors, proxies,
    /// arrays, autoboxing, shape transitions — exactly once, while the calling
    /// region stays native. Throws error.JsException (realm.pending_exception
    /// set) when a getter/setter/trap throws.
    pub fn jitGetPropSlow(self: *BcVm, recv: Value, key: []const u8) anyerror!Value {
        return self.getProp(recv, key);
    }

    pub fn jitSetPropSlow(self: *BcVm, recv: Value, key: []const u8, value: Value) anyerror!void {
        return self.setProp(recv, key, value);
    }

    /// Execute a regular CALL: reads callee from R[base], args from R[base+1..base+1+nargs].
    /// Phase 12: try to satisfy a call to a pure-int leaf bytecode function with
    /// natively-compiled code. Returns true (and writes `ret_dst`) when handled;
    /// false to fall back to the interpreter. Entirely comptime-elided unless the
    /// binary was built with `-Djit=true` — default builds never reference the
    /// native backend.
    fn tryJitCall(self: *BcVm, fn_ptr: *const BcFunction, def_env: *Environment, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !JitCallResult {
        // The whole body is inside a comptime-known `if`, so when the binary is
        // built WITHOUT -Djit the branch is never analyzed — the `@import` of the
        // native backend is not evaluated and nothing links the Cranelift cdylib.
        if (comptime build_options.jit_enabled) {
            const jc = self.jit orelse return .not_jitted;
            if (jc.mode != .experimental) return .not_jitted;
            if (nargs != fn_ptr.arity or nargs > 16) return .not_jitted;

            const ifj = @import("../jit/int_fn_jit.zig");
            const frame = &self.frames.items[self.frames.items.len - 1];

            // Boxed leaf: arguments flow in as raw boxed Values (any type). The
            // native code guards numericity per arithmetic op and deopts (→ the
            // interpreter) on a non-number operand or a >2^53 result.
            var args_buf: [16]Value = undefined;
            var i: usize = 0;
            while (i < nargs) : (i += 1) {
                args_buf[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
            }

            // Compile lazily, cached per function. `null` = not compiled yet (may
            // retry while a property IC warms); `jit_rejected` = permanently not
            // JIT-able. Pure-arithmetic leaves compile on the first call; functions
            // with property reads compile once their site ICs reach monomorphic.
            const gop = try self.jit_plans.getOrPut(self.arena, fn_ptr);
            if (!gop.found_existing) gop.value_ptr.* = null;
            if (gop.value_ptr.* == jit_rejected) return .not_jitted;
            if (gop.value_ptr.* == null) {
                const call_helper: u64 = @intFromPtr(&jsz_jit_call);
                // ABI slot kept for compatibility; boxed NEW_CLOSURE fine-deopts.
                const closure_helper: u64 = 0;
                // After `jit_warmup_max` interpreted calls a still-cold property
                // IC will never warm (e.g. an accessor-only site, which the data
                // IC never caches) — compile anyway; the re-entrant property
                // helper serves such sites natively via the interpreter's full
                // get/set machinery.
                const ag = try self.jit_attempts.getOrPut(self.arena, fn_ptr);
                if (!ag.found_existing) ag.value_ptr.* = 0;
                const allow_cold = ag.value_ptr.* >= jit_warmup_max;
                switch (try ifj.analyze(self.arena, fn_ptr, true, call_helper, closure_helper, allow_cold)) {
                    .ok => |p| {
                        gop.value_ptr.* = @ptrCast(p);
                        jc.compiled += 1;
                    },
                    .never => {
                        gop.value_ptr.* = jit_rejected;
                        return .not_jitted;
                    },
                    .retry => {
                        ag.value_ptr.* += 1;
                        return .not_jitted; // interpret this call (warms the property IC)
                    },
                }
            }
            const plan: *ifj.JitPlan = @ptrCast(@alignCast(gop.value_ptr.*.?));

            switch (try ifj.run(self.arena, plan, args_buf[0..nargs], self)) {
                .deopt => return .not_jitted,
                .threw => return .threw,
                .resumed => |st| {
                    // S2 fine deopt: the region already committed side effects up
                    // to st.pc — never re-run it. Push a real interpreter frame
                    // seeded from the exact native state and run it to return.
                    const result = self.resumeJitFrame(fn_ptr, def_env, this_val, st.regs, plan.local_names, st.locals, st.pc) catch |e| {
                        if (e == error.JsException) return .threw;
                        return e;
                    };
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                    return .completed;
                },
                .value => |result| {
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                    return .completed;
                },
            }
        }
        return .not_jitted;
    }

    /// S2/S8 fine-deopt resume: a JITed call for `fn_ptr` stopped at bytecode
    /// `resume_pc` after possibly committing side effects (stores / calls). Push
    /// a REAL interpreter frame whose registers come from the native register
    /// file, whose env-locals are rebuilt from the native `locals` buffer
    /// (`local_names` is the slot→name map, params first), and run it to
    /// completion — mirroring `bcInvokeJs`'s run-until-return discipline.
    /// Throws error.JsException (realm.pending_exception set) on an uncaught
    /// throw inside the resumed code.
    pub fn resumeJitFrame(
        self: *BcVm,
        fn_ptr: *const BcFunction,
        def_env: *Environment,
        this_val: Value,
        regs_bits: []const i64,
        local_names: []const []const u8,
        locals_bits: []const i64,
        resume_pc: u32,
    ) anyerror!Value {
        const call_env = try Environment.init(self.arena, def_env);
        const n_loc = @min(local_names.len, locals_bits.len);
        for (0..n_loc) |i| {
            try call_env.define(local_names[i], Value{ .bits = @bitCast(locals_bits[i]) });
        }
        const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
        const new_regs = try self.arena.alloc(Value, num_regs);
        for (new_regs) |*r| r.* = Value{};
        const n_regs = @min(num_regs, regs_bits.len);
        for (0..n_regs) |i| new_regs[i] = Value{ .bits = @bitCast(regs_bits[i]) };
        const caller_idx = if (self.frames.items.len > 0) self.frames.items.len - 1 else 0;
        try self.frames.append(self.arena, BcCallFrame{
            .func = fn_ptr,
            .pc = resume_pc,
            .registers = new_regs,
            .env = call_env,
            .return_dst = 255,
            .caller_idx = if (self.frames.items.len > 0) caller_idx else null,
            .this_val = this_val,
        });
        const frames_before = self.frames.items.len - 1;
        while (self.frames.items.len > frames_before) {
            const outcome = try self.runLoop();
            switch (outcome) {
                .ok => |v| return v,
                .exception => {
                    while (self.frames.items.len > frames_before) _ = self.frames.pop();
                    const realm_mod = @import("../runtime/realm.zig");
                    realm_mod.pending_exception = self.last_exception_value;
                    return error.JsException;
                },
                .exception_value => |ev| {
                    while (self.frames.items.len > frames_before) _ = self.frames.pop();
                    const realm_mod = @import("../runtime/realm.zig");
                    realm_mod.pending_exception = ev.value;
                    return error.JsException;
                },
            }
        }
        return self.result;
    }

    /// S4 CALL trampoline: a JITed region's native `CALL` re-enters the interpreter
    /// here. Reads the callee from `regs[base]` and args from `regs[base+1..]` (raw
    /// boxed Values), invokes the call, writes the result to `regs[ret_dst]`, and
    /// sets `deopt.* = 2` if it threw (the value is in `realm.pending_exception`).
    /// callconv(.c): its address is baked into the native code. The active region's
    /// buffers are GC roots (see `int_fn_jit.active_jit_frame`) while this runs.
    /// (The former `jsz_jit_make_closure` trampoline is gone: boxed `NEW_CLOSURE`
    /// now fine-deopts unconditionally — a natively created closure cannot share
    /// the region's private mutable locals, and at the call boundary there is no
    /// callee frame to resolve `child_functions` against.)
    fn jsz_jit_call(regs: [*]i64, base: u32, nargs: u32, ret_dst: u32, deopt: *i32) callconv(.c) void {
        const ifj = @import("../jit/int_fn_jit.zig");
        const vmptr = ifj.active_jit_vm.?;
        const vm: *BcVm = @ptrCast(@alignCast(vmptr));
        const callee = Value{ .bits = @bitCast(regs[base]) };
        const args: []const Value = @as([*]const Value, @ptrCast(regs + base + 1))[0..nargs];

        // S6 fast path: when the callee is an already-JIT-compiled bytecode function
        // of matching arity, run its native code DIRECTLY — no interpreter frame,
        // no dispatch loop. A fully-JIT call chain then stays in native code. On a
        // deopt (the callee hit overflow / a non-number / a property miss — all
        // before any commit, so re-running is sound) fall through to the
        // interpreter; a throw propagates.
        if (callee.bits != 0) {
            const inner = callee.unbox();
            if (inner == .bc_function) {
                const func = inner.bc_function.func;
                if (vm.jit_plans.get(func)) |maybe| {
                    if (maybe) |plan_ptr| direct: {
                        if (plan_ptr == jit_rejected) break :direct;
                        const plan: *ifj.JitPlan = @ptrCast(@alignCast(plan_ptr));
                        if (plan.arity != nargs) break :direct;
                        const out = ifj.run(vm.arena, plan, args, vmptr) catch break :direct;
                        switch (out) {
                            .value => |res| {
                                regs[ret_dst] = @bitCast(res.bits);
                                if (vm.jit) |jc| jc.direct_calls += 1;
                                deopt.* = 0;
                                return;
                            },
                            .threw => {
                                deopt.* = 2;
                                return;
                            },
                            .resumed => |st| {
                                // Fine deopt mid-callee: side effects may have
                                // committed — resume the callee in the
                                // interpreter from the exact native state (never
                                // re-run / fall through to bcInvokeJs).
                                const cl_env: *Environment = @ptrCast(@alignCast(inner.bc_function.env));
                                const res = vm.resumeJitFrame(func, cl_env, Value{}, st.regs, plan.local_names, st.locals, st.pc) catch {
                                    deopt.* = 2;
                                    return;
                                };
                                regs[ret_dst] = @bitCast(res.bits);
                                if (vm.jit) |jc| jc.direct_calls += 1;
                                deopt.* = 0;
                                return;
                            },
                            .deopt => break :direct,
                        }
                    }
                }
            }
        }

        // Fallback: re-enter the interpreter (handles native/bound/async/generator
        // callees, cold/non-JITable bc functions, arity mismatch, and JIT deopts).
        const result = bcInvokeJs(vmptr, vm.arena, Value{}, callee, args) catch {
            deopt.* = 2; // threw — realm.pending_exception holds the value
            return;
        };
        regs[ret_dst] = @bitCast(result.bits);
        deopt.* = 0;
    }

    /// Phase 12: attempt general loop OSR at a hot back-edge `JMP` (op at
    /// `jmp_pc`). On success the loop has run to completion natively and the live
    /// integer vars were written back; returns the absolute exit PC to resume at.
    /// Returns null to keep interpreting (not OSR-able, a live value wasn't an
    /// integer, or an overflow deopt — in all cases the env is left untouched).
    /// Entirely comptime-elided unless built with `-Djit=true`.
    fn tryOsrLoop(self: *BcVm, func: *const BcFunction, jmp_pc: usize, env: *Environment, registers: []Value) !?usize {
        if (comptime build_options.jit_enabled) {
            const jc = self.jit orelse return null;
            if (jc.mode != .experimental) return null;
            const osr = @import("../jit/osr_jit.zig");
            const key = OsrKey{ .func = func, .pc = @intCast(jmp_pc) };
            const gop = try self.osr_plans.getOrPut(self.arena, key);
            if (!gop.found_existing) {
                const plan = try osr.analyze(self.arena, func, jmp_pc);
                gop.value_ptr.* = if (plan) |p| @as(?*anyopaque, @ptrCast(p)) else null;
            }
            const plan_ptr = gop.value_ptr.* orelse return null;
            const plan: *osr.OsrPlan = @ptrCast(@alignCast(plan_ptr));
            if (osr.run(self.arena, plan, env, registers)) |exit_pc| {
                jc.compiled += 1;
                return exit_pc;
            }
            return null;
        }
        return null;
    }

    fn doCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        @import("../runtime/realm.zig").active_constructing = false;
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return try std.fmt.allocPrint(self.arena, "TypeError: undefined is not a function", .{});
        }
        const inner = callee_val.unbox();
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));

                // W2-async: an async function call runs as a coroutine and
                // returns a pending Promise.
                if (fn_ptr.is_async) {
                    var aargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| aargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const p = try self.buildAsyncFunction(fn_ptr, def_env, this_val, aargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = p;
                    return null;
                }
                // W2: a generator function call produces a generator object.
                if (fn_ptr.is_generator) {
                    var gargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| gargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const g = try self.buildGenerator(fn_ptr, def_env, this_val, gargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = g;
                    return null;
                }

                // Phase 12: native fast path for hot leaf/boxed functions
                // (comptime-elided unless built with -Djit=true).
                switch (try self.tryJitCall(fn_ptr, def_env, this_val, base, nargs, ret_dst)) {
                    .completed => return null,
                    .threw => {
                        // A re-entrant CALL inside the JITed function threw; the
                        // value is in realm.pending_exception. Route it exactly like
                        // an interpreted call's throw (the `__js_exception__` path).
                        const realm_mod = @import("../runtime/realm.zig");
                        self.last_exception_value = realm_mod.pending_exception;
                        realm_mod.pending_exception = Value{};
                        return "__js_exception__";
                    },
                    .not_jitted => {},
                }

                // Create call environment.
                const call_env = try Environment.init(self.arena, def_env);

                // Bind parameters.
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 1 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }

                // NFE self-binding.
                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        call_env.define(fname, callee_val) catch {};
                    }
                }

                // Allocate registers for new frame.
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};

                // Copy param values into register slots.
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        const av: Value = if (i < nargs)
                            frame.registers[base + 1 + @as(u8, @intCast(i))]
                        else
                            try val_mod.makeUndefined(self.arena);
                        new_regs[i] = av;
                    }
                }

                // NFE slot.
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
                        if (nfe_slot < num_regs) {
                            new_regs[nfe_slot] = callee_val;
                        }
                    }
                }

                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            .native_function => |fn_ptr| {
                // Collect args.
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) {
                        // Phase 4b: check pending_exception (e.g. JSON.parse).
                        const realm_mod = @import("../runtime/realm.zig");
                        if (realm_mod.pending_exception.bits != 0) {
                            self.last_exception_value = realm_mod.pending_exception;
                            realm_mod.pending_exception = Value{};
                        }
                        // Use sentinel: return "__js_exception__" to tell caller
                        // to use last_exception_value rather than build a new TypeError.
                        return "__js_exception__";
                    }
                    return try std.fmt.allocPrint(self.arena, "TypeError: native function threw", .{});
                };
                // Re-read frame after native call (may have triggered re-entrant frames + realloc).
                self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                return null;
            },
            .function => {
                // Tree-walker function called from bc mode — not supported in Phase 2.
                return "TypeError: cannot call tree-walker function from bc mode";
            },
            .object => |obj| {
                // Phase 13: callable Proxy — apply trap (or forward to target).
                if (obj.internal_kind == .proxy) {
                    var pargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| pargs[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                    const res = self.proxyApply(obj, this_val, pargs) catch |e| {
                        if (e == error.JsException) {
                            const realm_mod = @import("../runtime/realm.zig");
                            if (realm_mod.pending_exception.bits != 0) {
                                self.last_exception_value = realm_mod.pending_exception;
                                realm_mod.pending_exception = Value{};
                            }
                            return "__js_exception__";
                        }
                        return "TypeError: proxy is not a function";
                    };
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                    return null;
                }
                // Phase 4d: bound function.
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var args = try self.arena.alloc(Value, bd.prefix.len + nargs);
                        for (bd.prefix, 0..) |v, i| args[i] = v;
                        for (0..nargs) |i| {
                            args[bd.prefix.len + i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        const res = bcInvokeJs(self, self.arena, bd.this_val, bd.target, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return try std.fmt.allocPrint(self.arena, "TypeError: bound call threw", .{});
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        return null;
                    }
                }
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.unbox() == .native_function) {
                        const fn_ptr = call_val.toPtr().native_function;
                        // Collect args.
                        var args = try self.arena.alloc(Value, nargs);
                        for (0..nargs) |i| {
                            args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        if (obj.get("prototype") != null) {
                            // Preserve legacy behavior for Error-like constructor objects.
                            var proto: ?*JsObject = self.realm.object_prototype;
                            if (obj.get("prototype")) |pv| {
                                if (pv.bits != 0 and pv.unbox() == .object) proto = pv.toPtr().object;
                            }
                            const new_obj = if (self.heap) |heap|
                                try JsObject.createOnHeap(heap, proto)
                            else
                                try JsObject.create(self.arena, proto);
                            const this_val_call = try val_mod.makeObject(self.arena, new_obj);
                            const result = fn_ptr.invoke(self.arena, this_val_call, args) catch {
                                return "TypeError: Error constructor threw";
                            };
                            // If the factory returned a primitive non-null/undefined value
                            // (e.g. a Symbol), honour that return value directly (factory pattern).
                            const final_result = if (result.bits != 0 and result.unbox() != .undefined_ and result.unbox() != .null_ and result.unbox() != .object)
                                result
                            else if (result.bits != 0 and result.unbox() == .object)
                                result
                            else
                                this_val_call;
                            self.frames.items[self.frames.items.len - 1].registers[ret_dst] = final_result;
                            return null;
                        }
                        const result = fn_ptr.invoke(self.arena, callee_val, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return "TypeError: object call threw";
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                        return null;
                    }
                }
                return try std.fmt.allocPrint(self.arena, "TypeError: object is not a function", .{});
            },
            else => {
                return try std.fmt.allocPrint(self.arena, "TypeError: {s} is not a function", .{typeofValue(callee_val)});
            },
        }
    }

    /// Execute a METHOD_CALL: R[base]=this, R[base+1]=fn, args from R[base+2..base+1+nargs].
    fn doMethodCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        @import("../runtime/realm.zig").active_constructing = false;
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return try std.fmt.allocPrint(self.arena, "TypeError: undefined is not a function", .{});
        }
        const inner = callee_val.unbox();
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));

                if (fn_ptr.is_async) {
                    var aargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| aargs[i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                    const p = try self.buildAsyncFunction(fn_ptr, def_env, this_val, aargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = p;
                    return null;
                }
                if (fn_ptr.is_generator) {
                    var gargs = try self.arena.alloc(Value, nargs);
                    for (0..nargs) |i| gargs[i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                    const g = try self.buildGenerator(fn_ptr, def_env, this_val, gargs);
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = g;
                    return null;
                }

                const call_env = try Environment.init(self.arena, def_env);

                // Bind parameters. Args are at R[base+2..base+1+nargs].
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 2 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }

                // NFE self-binding.
                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        call_env.define(fname, callee_val) catch {};
                    }
                }

                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};

                // Copy param values into register slots.
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        const av: Value = if (i < nargs)
                            frame.registers[base + 2 + @as(u8, @intCast(i))]
                        else
                            try val_mod.makeUndefined(self.arena);
                        new_regs[i] = av;
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
                        if (nfe_slot < num_regs) {
                            new_regs[nfe_slot] = callee_val;
                        }
                    }
                }

                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            .native_function => |fn_ptr| {
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                }
                const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) {
                        // Phase 4b: check pending_exception.
                        const realm_mod = @import("../runtime/realm.zig");
                        if (realm_mod.pending_exception.bits != 0) {
                            self.last_exception_value = realm_mod.pending_exception;
                            realm_mod.pending_exception = Value{};
                        }
                        return "__js_exception__";
                    }
                    return try std.fmt.allocPrint(self.arena, "TypeError: native function threw", .{});
                };
                // Re-read frame after native call (may have triggered re-entrant frames + realloc).
                self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                return null;
            },
            .function => {
                return "TypeError: cannot call tree-walker function from bc mode";
            },
            .object => |obj| {
                // Phase 4d: bound function in method call context.
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var args = try self.arena.alloc(Value, bd.prefix.len + nargs);
                        for (bd.prefix, 0..) |v, i| args[i] = v;
                        for (0..nargs) |i| {
                            args[bd.prefix.len + i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                        }
                        const res = bcInvokeJs(self, self.arena, bd.this_val, bd.target, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return try std.fmt.allocPrint(self.arena, "TypeError: bound call threw", .{});
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        return null;
                    }
                }
                return try std.fmt.allocPrint(self.arena, "TypeError: object is not a function", .{});
            },
            else => {
                return try std.fmt.allocPrint(self.arena, "TypeError: {s} is not a function", .{typeofValue(callee_val)});
            },
        }
    }

    // ---------------------------------------------------------- W2 generators ---

    fn makeGenIterResult(self: *BcVm, value: Value, done: bool) !Value {
        const obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        try obj.set("value", value);
        try obj.set("done", try val_mod.makeBool(self.arena, done));
        return val_mod.makeObject(self.arena, obj);
    }

    /// Build the suspended-frame state shared by generators and async functions:
    /// a fresh call env with params bound, register file with params seeded, and
    /// a BcGeneratorState registered for GC scanning. The frame starts at pc 0.
    fn buildGenState(self: *BcVm, fn_ptr: *const BcFunction, def_env: *Environment, this_val: Value, args: []const Value) !*BcGeneratorState {
        const call_env = try Environment.init(self.arena, def_env);
        for (fn_ptr.param_names, 0..) |pname, i| {
            const av: Value = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
            try call_env.define(pname, av);
        }
        const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
        const regs = try self.arena.alloc(Value, num_regs);
        for (regs) |*r| r.* = Value{};
        for (fn_ptr.param_names, 0..) |_, i| {
            if (i < num_regs) regs[i] = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
        }
        const state = try self.arena.create(BcGeneratorState);
        state.* = .{
            .vm = self,
            .frame = .{
                .func = fn_ptr,
                .pc = 0,
                .registers = regs,
                .env = call_env,
                .return_dst = 0xFF,
                .caller_idx = 0,
                .this_val = this_val,
            },
        };
        try self.generators.append(self.arena, state);
        return state;
    }

    /// Create a generator object for a `function*` call instead of running it.
    fn buildGenerator(self: *BcVm, fn_ptr: *const BcFunction, def_env: *Environment, this_val: Value, args: []const Value) !Value {
        const state = try self.buildGenState(fn_ptr, def_env, this_val, args);

        const obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        obj.internal_kind = .generator;
        obj.internal_slot = state;
        try obj.set("next", try val_mod.makeNativeFunction(self.arena, nativeGenNext));
        try obj.set("return", try val_mod.makeNativeFunction(self.arena, nativeGenReturn));
        try obj.set("throw", try val_mod.makeNativeFunction(self.arena, nativeGenThrow));
        try obj.set("@@iterator", try val_mod.makeNativeFunction(self.arena, nativeGenSelfIter));
        return val_mod.makeObject(self.arena, obj);
    }

    /// Resume a suspended coroutine (generator or async fn) until its next YIELD
    /// (await/yield point) or completion. Uses the scoped-runLoop pattern of
    /// native re-entry (return_dst == 0xFF). `kind` selects normal resume vs.
    /// throwing at the suspended point (rejected await / generator.throw).
    fn runSuspendable(self: *BcVm, state: *BcGeneratorState, kind: ResumeKind) !SuspendResult {
        if (state.done) {
            return switch (kind) {
                .next => SuspendResult{ .returned = try val_mod.makeUndefined(self.arena) },
                .throw_ => |e| SuspendResult{ .threw = e },
            };
        }
        const base = self.frames.items.len;
        var frame_copy = state.frame;
        frame_copy.gen = state;
        frame_copy.return_dst = 0xFF;
        frame_copy.caller_idx = if (base > 0) base - 1 else null;
        try self.frames.append(self.arena, frame_copy);
        const top = &self.frames.items[self.frames.items.len - 1];

        switch (kind) {
            .next => |sent| {
                if (state.started) top.registers[state.resume_reg] = sent;
            },
            .throw_ => |err| {
                // Inject the exception at the suspended point: walk this frame's
                // try stack for a handler (the YIELD was inside the async fn's
                // own frame). If none, the exception escapes the coroutine.
                self.last_exception_value = err;
                if (top.try_stack.items.len > 0) {
                    const entry = top.try_stack.pop().?;
                    top.pc = entry.handler_pc;
                    if (entry.rexc != 0xFF) top.registers[entry.rexc] = err;
                } else {
                    _ = self.frames.pop();
                    state.done = true;
                    return SuspendResult{ .threw = err };
                }
            },
        }
        state.started = true;
        self.gen_yielded = false;
        while (self.frames.items.len > base) {
            const outcome = try self.runLoop();
            switch (outcome) {
                .ok => break,
                .exception => {
                    while (self.frames.items.len > base) _ = self.frames.pop();
                    state.done = true;
                    return SuspendResult{ .threw = self.last_exception_value };
                },
                .exception_value => |ev| {
                    while (self.frames.items.len > base) _ = self.frames.pop();
                    state.done = true;
                    return SuspendResult{ .threw = ev.value };
                },
            }
        }
        if (self.gen_yielded) {
            self.gen_yielded = false;
            return SuspendResult{ .yielded = self.result };
        }
        state.done = true;
        return SuspendResult{ .returned = self.result };
    }

    /// Resume a generator and wrap the outcome as an iterator result object.
    /// Exceptions propagate to the `.next()`/`.throw()` caller as before.
    fn resumeGenerator(self: *BcVm, state: *BcGeneratorState, sent: Value) !Value {
        const res = try self.runSuspendable(state, .{ .next = sent });
        return switch (res) {
            .yielded => |v| self.makeGenIterResult(v, false),
            .returned => |v| self.makeGenIterResult(v, true),
            .threw => |e| blk: {
                @import("../runtime/realm.zig").pending_exception = e;
                break :blk error.JsException;
            },
        };
    }

    // ---------------------------------------------------------- W2-async driver ---

    /// Start an `async function` call: build the coroutine, create its pending
    /// result promise, and drive it synchronously up to the first `await`.
    /// Returns the result promise immediately.
    fn buildAsyncFunction(self: *BcVm, fn_ptr: *const BcFunction, def_env: *Environment, this_val: Value, args: []const Value) !Value {
        const promise_mod = @import("../runtime/builtins/promise.zig");
        const state = try self.buildGenState(fn_ptr, def_env, this_val, args);
        const result = try promise_mod.newPendingPromise(self.arena);
        const actx = try self.arena.create(AsyncCtx);
        actx.* = .{ .vm = self, .state = state, .result = result };
        try self.async_ctxs.append(self.arena, actx);
        try self.driveAsync(actx, .{ .next = try val_mod.makeUndefined(self.arena) });
        return result;
    }

    /// Run one step of an async coroutine: resume it, then either settle the
    /// result promise (completion/throw) or subscribe to the awaited value so a
    /// microtask resumes the coroutine when it settles.
    fn driveAsync(self: *BcVm, actx: *AsyncCtx, kind: ResumeKind) anyerror!void {
        const promise_mod = @import("../runtime/builtins/promise.zig");
        const res = try self.runSuspendable(actx.state, kind);
        switch (res) {
            .returned => |v| promise_mod.settleResult(self.arena, actx.result, v, true),
            .threw => |e| promise_mod.settleResult(self.arena, actx.result, e, false),
            .yielded => |awaited| {
                const on_f = try val_mod.makeNativeFunctionData(self.arena, asyncOnFulfill, actx);
                const on_r = try val_mod.makeNativeFunctionData(self.arena, asyncOnReject, actx);
                try promise_mod.subscribeAwait(self.arena, awaited, on_f, on_r);
            },
        }
    }

    /// ToPrimitive that also coerces function operands. Functions are callable
    /// objects: their own props (e.g. a user-assigned `valueOf`) plus
    /// Function.prototype.toString live on a lazily-materialized backing object,
    /// so coercion runs OrdinaryToPrimitive against that. Returns null when `v`
    /// is already primitive or no user hook applies (caller uses `v`).
    fn coerceToPrimitive(self: *BcVm, v: Value, hint: coercion.Hint) anyerror!?Value {
        if (v.bits == 0) return null;
        switch (v.unbox()) {
            .object => return coercion.toPrimitive(self.arena, v, hint),
            .bc_function => |closure| {
                // OrdinaryToPrimitive against the function's backing object, but
                // invoking valueOf/toString with `this` = the function value (so
                // Function.prototype.toString reports the real name).
                const obj = try self.closureBackingObj(closure);
                const names: [2][]const u8 = if (hint == .string)
                    .{ "toString", "valueOf" }
                else
                    .{ "valueOf", "toString" };
                for (names) |name| {
                    const method = obj.get(name) orelse continue;
                    if (!isCallableValue(method)) continue;
                    const res = try function_proto.invokeCallback(self.arena, v, method, &[_]Value{});
                    if (coercion.isPrimitive(res)) return res;
                }
                return self.throwTypeErr("Cannot convert function to primitive value");
            },
            else => return null,
        }
    }

    fn jsAdd(self: *BcVm, left: Value, right: Value) !Value {
        // ES2015 11.6.1: lprim = ToPrimitive(left), rprim = ToPrimitive(right),
        // both with the "default" hint, before deciding string vs numeric.
        const lp = (try self.coerceToPrimitive(left, .default)) orelse left;
        const rp = (try self.coerceToPrimitive(right, .default)) orelse right;
        const ls = isStringOrObject(lp);
        const rs = isStringOrObject(rp);
        if (ls or rs) {
            const ls_str = try valueToString(self.arena, lp);
            const rs_str = try valueToString(self.arena, rp);
            const combined = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls_str, rs_str });
            return val_mod.makeString(self.arena, combined);
        }
        return val_mod.makeNumber(self.arena, toNumber(lp) + toNumber(rp));
    }

    /// ToNumber that honors user-defined ToPrimitive(number) on objects.
    /// For non-objects this is exactly `toNumber`.
    fn toNumberCoerced(self: *BcVm, v: Value) !f64 {
        const p = (try self.coerceToPrimitive(v, .number)) orelse v;
        return toNumber(p);
    }

    /// ToPrimitive(number) for relational comparison; returns `v` unchanged
    /// when no user hook applies.
    fn coerceForRelational(self: *BcVm, v: Value) !Value {
        return (try self.coerceToPrimitive(v, .number)) orelse v;
    }

    /// ToInt32 honoring user-defined ToPrimitive(number) on objects.
    fn toInt32Coerced(self: *BcVm, v: Value) !i32 {
        const p = (try self.coerceToPrimitive(v, .number)) orelse v;
        return toInt32(p);
    }

    /// ToUint32 honoring user-defined ToPrimitive(number) on objects.
    fn toUint32Coerced(self: *BcVm, v: Value) !u32 {
        return @bitCast(try self.toInt32Coerced(v));
    }

    /// Throw a `TypeError` (sets pending_exception, returns error.JsException).
    fn throwTypeErr(self: *BcVm, msg: []const u8) anyerror {
        const realm_mod = @import("../runtime/realm.zig");
        const obj = if (realm_mod.active_heap) |h|
            try JsObject.createOnHeap(h, realm_mod.error_proto_TypeError)
        else
            try JsObject.create(self.arena, realm_mod.error_proto_TypeError);
        try obj.set("name", try val_mod.makeString(self.arena, "TypeError"));
        try obj.set("message", try val_mod.makeString(self.arena, msg));
        realm_mod.pending_exception = try val_mod.makeObject(self.arena, obj);
        return error.JsException;
    }

    /// Throw a `RangeError` (sets pending_exception, returns error.JsException).
    fn throwRangeErr(self: *BcVm, msg: []const u8) anyerror {
        const realm_mod = @import("../runtime/realm.zig");
        const obj = if (realm_mod.active_heap) |h|
            try JsObject.createOnHeap(h, realm_mod.error_proto_RangeError)
        else
            try JsObject.create(self.arena, realm_mod.error_proto_RangeError);
        try obj.set("name", try val_mod.makeString(self.arena, "RangeError"));
        try obj.set("message", try val_mod.makeString(self.arena, msg));
        realm_mod.pending_exception = try val_mod.makeObject(self.arena, obj);
        return error.JsException;
    }

    /// ToNumeric (ES 7.1.3): ToPrimitive(number) then keep BigInt as-is, throw on
    /// Symbol, else ToNumber. Returns a `.bigint` or `.number` Value.
    fn toNumeric(self: *BcVm, v: Value) !Value {
        const prim = (try self.coerceToPrimitive(v, .number)) orelse v;
        if (prim.bits != 0 and prim.unbox() == .bigint) return prim;
        if (prim.bits != 0 and prim.unbox() == .symbol)
            return self.throwTypeErr("Cannot convert a Symbol value to a number");
        return val_mod.makeNumber(self.arena, toNumber(prim));
    }

    /// Exponentiation runtime semantics (ES sec-exp-operator). ToNumeric both
    /// operands; if their types differ → TypeError; BigInt::exponentiate throws
    /// RangeError on a negative exponent; otherwise Number::exponentiate.
    fn expOp(self: *BcVm, lv: Value, rv: Value) !Value {
        const base = try self.toNumeric(lv);
        const exp = try self.toNumeric(rv);
        const base_big = base.unbox() == .bigint;
        const exp_big = exp.unbox() == .bigint;
        if (base_big != exp_big)
            return self.throwTypeErr("Cannot mix BigInt and other types, use explicit conversions");
        if (base_big) {
            if (val_mod.bigIntIsNegative(exp))
                return self.throwRangeErr("Exponent must be non-negative");
            return val_mod.bigIntPow(self.arena, base, exp) catch |e| switch (e) {
                error.Overflow => self.throwRangeErr("Maximum BigInt size exceeded"),
                else => e,
            };
        }
        return val_mod.makeNumber(self.arena, jsExp(toNumber(base), toNumber(exp)));
    }
};

// ---------------------------------------------------------------- W2 generator natives ---

fn genStateFrom(this_val: Value) ?*BcGeneratorState {
    if (this_val.bits == 0 or this_val.unbox() != .object) return null;
    const obj = this_val.toPtr().object;
    if (obj.internal_kind != .generator) return null;
    if (obj.internal_slot) |slot| return @ptrCast(@alignCast(slot));
    return null;
}

fn nativeGenNext(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const state = genStateFrom(this_val) orelse return error.JsException;
    const sent = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return state.vm.resumeGenerator(state, sent);
}

fn nativeGenReturn(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const state = genStateFrom(this_val) orelse return error.JsException;
    state.done = true;
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return state.vm.makeGenIterResult(v, true);
}

fn nativeGenThrow(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const state = genStateFrom(this_val) orelse return error.JsException;
    state.done = true;
    @import("../runtime/realm.zig").pending_exception = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    return error.JsException;
}

fn nativeGenSelfIter(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

// ---------------------------------------------------------------- W2-async natives ---
// Promise-reaction continuations bound (via makeNativeFunctionData) to an
// AsyncCtx pointer. Recovered through the active-native-data slot, which the
// native dispatcher sets immediately before the call.

fn asyncCtxFromActive() ?*AsyncCtx {
    const slot = val_mod.g_active_native_data orelse return null;
    return @ptrCast(@alignCast(slot));
}

/// Awaited promise fulfilled: resume the coroutine with the resolved value.
fn asyncOnFulfill(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const actx = asyncCtxFromActive() orelse return val_mod.makeUndefined(arena);
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try actx.vm.driveAsync(actx, .{ .next = v });
    return val_mod.makeUndefined(arena);
}

/// Awaited promise rejected: throw the reason at the suspended await point.
fn asyncOnReject(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const actx = asyncCtxFromActive() orelse return val_mod.makeUndefined(arena);
    const e = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    try actx.vm.driveAsync(actx, .{ .throw_ = e });
    return val_mod.makeUndefined(arena);
}

// ---------------------------------------------------------------- GC scan callback ---

/// GC root-scan callback for the bytecode VM.
/// Walks all register arrays and env chains in open call frames.
fn bcVmScanCallback(ctx: *anyopaque, mark_fn: *const fn (*JsObject) void) void {
    const vm: *BcVm = @ptrCast(@alignCast(ctx));
    for (vm.frames.items) |*frame| {
        // Registers
        for (frame.registers) |reg| {
            gc_mod.traceValue(reg, mark_fn);
        }
        // this_val
        gc_mod.traceValue(frame.this_val, mark_fn);
        // Environment chain
        gc_mod.traceEnvironment(frame.env, mark_fn);
    }
    // W2: suspended generator frames are off the active stack but still live.
    for (vm.generators.items) |state| {
        if (state.done) continue;
        for (state.frame.registers) |reg| gc_mod.traceValue(reg, mark_fn);
        gc_mod.traceValue(state.frame.this_val, mark_fn);
        gc_mod.traceEnvironment(state.frame.env, mark_fn);
    }
    // W2-async: keep each in-flight async function's result promise alive while
    // it is pending (its suspended frame is scanned via `generators` above).
    for (vm.async_ctxs.items) |actx| {
        gc_mod.traceValue(actx.result, mark_fn);
    }
    // Phase 12 S4: boxed JIT regions on the stack hold live cell pointers in their
    // native register/local buffers (e.g. across a re-entrant CALL whose callee may
    // trigger `__gc__()`). Mark them — the collector is non-moving, so this is
    // sufficient. Comptime-elided in default builds (the chain is never populated).
    if (comptime build_options.jit_enabled) {
        const ifj = @import("../jit/int_fn_jit.zig");
        var rf = ifj.active_jit_frame;
        while (rf) |f| {
            for (f.regs) |bits| gc_mod.traceValue(Value{ .bits = @bitCast(bits) }, mark_fn);
            for (f.locals) |bits| gc_mod.traceValue(Value{ .bits = @bitCast(bits) }, mark_fn);
            rf = f.parent;
        }
    }
}

// ---------------------------------------------------------------- semantics helpers ---
// Mirror vm.zig exactly. These MUST stay in sync.

fn isNumberValue(v: Value) bool {
    return v.bits != 0 and v.unbox() == .number;
}

/// True when `v` is an operand kind that may carry a user-defined ToPrimitive
/// hook needing a slow, JS-reentrant coercion path: a plain object, or a bc
/// function (callable object whose own props + Function.prototype.toString are
/// reachable via its backing object).
fn isObjectOperand(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .bc_function => true,
        else => false,
    };
}

/// True when `v` is callable (function-like): a native/bc/legacy function, or a
/// bound-function object.
fn isCallableValue(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |obj| obj.internal_kind == .bound_function or obj.get("__call__") != null,
        else => false,
    };
}

fn classifyTypeof(v: Value) struct {
    tag: ic_mod.TypeofTag,
    shape: ?*anyopaque,
    result: []const u8,
} {
    if (v.bits == 0) return .{ .tag = .undefined_, .shape = null, .result = "undefined" };
    return switch (v.unbox()) {
        .undefined_ => .{ .tag = .undefined_, .shape = null, .result = "undefined" },
        .null_ => .{ .tag = .null_, .shape = null, .result = "object" },
        .boolean => .{ .tag = .boolean, .shape = null, .result = "boolean" },
        .number => .{ .tag = .number, .shape = null, .result = "number" },
        .string => .{ .tag = .string, .shape = null, .result = "string" },
        .symbol => .{ .tag = .symbol, .shape = null, .result = "symbol" },
        .bigint => .{ .tag = .bigint, .shape = null, .result = "bigint" },
        .function, .bc_function, .native_function => .{ .tag = .function_like, .shape = null, .result = "function" },
        .object => |obj| blk: {
            const callable = obj.get("__call__") != null;
            break :blk .{
                .tag = if (callable) .function_like else .object_like,
                .shape = obj.shapePtr(),
                .result = if (callable) "function" else "object",
            };
        },
    };
}

fn jsInstanceofWithTarget(lhs: Value, target_proto: ?*JsObject) bool {
    if (lhs.bits == 0 or target_proto == null) return false;
    if (lhs.unbox() != .object) return false;
    var cur: ?*JsObject = lhs.toPtr().object;
    while (cur) |obj| {
        if (obj == target_proto.?) return true;
        cur = obj.proto;
    }
    return false;
}

pub fn isTruthy(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_ => false,
        .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0.0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .function => true,
        .bc_function => true,
        .object => true,
        .native_function => true,
        .symbol => true,
        .bigint => |b| !b.toConst().eqlZero(),
    };
}

fn isString(v: Value) bool {
    if (v.bits == 0) return false;
    return v.unbox() == .string;
}

fn isStringOrObject(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .string => true,
        .object => true,
        else => false,
    };
}

pub fn typeofValue(v: Value) []const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .undefined_ => "undefined",
        .null_ => "object",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .symbol => "symbol",
        .function => "function",
        .bc_function => "function",
        .object => |obj| if (obj.get("__call__") != null) "function" else "object",
        .native_function => "function",
        .bigint => "bigint",
    };
}

pub fn toInt32(v: Value) i32 {
    const n = toNumber(v);
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const m = @mod(@trunc(n), 4294967296.0); // [0, 2^32)
    const u: u32 = @intFromFloat(m);
    return @bitCast(u);
}

pub fn toUint32(v: Value) u32 {
    return @bitCast(toInt32(v));
}

/// ES `StringNumericValue`: a trimmed empty string is 0, `Infinity` forms and
/// `0x`/`0o`/`0b` radix prefixes are recognized, everything else falls back to a
/// decimal float parse (NaN on failure). Diverges from a bare `parseFloat`, which
/// maps "" to NaN and does not accept radix prefixes.
pub fn jsStringToNumber(s: []const u8) f64 {
    const t = std.mem.trim(u8, s, " \t\n\r\x0B\x0C");
    if (t.len == 0) return 0;
    if (std.mem.eql(u8, t, "Infinity") or std.mem.eql(u8, t, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, t, "-Infinity")) return -std.math.inf(f64);
    if (t.len > 2 and t[0] == '0') {
        const radix: ?u8 = switch (t[1]) {
            'x', 'X' => @as(u8, 16),
            'o', 'O' => @as(u8, 8),
            'b', 'B' => @as(u8, 2),
            else => null,
        };
        if (radix) |r| {
            const v = std.fmt.parseInt(u64, t[2..], r) catch return std.math.nan(f64);
            return @floatFromInt(v);
        }
    }
    // A valid decimal literal starts with a digit, sign, or dot. Reject letter
    // leads up front so `std.fmt.parseFloat` does not accept "inf"/"infinity"/
    // "nan" (ES ToNumber maps "INFINITY", "inf", etc. to NaN; only exact
    // "Infinity"/"+Infinity"/"-Infinity", handled above, are special).
    const c0 = t[0];
    if (!(std.ascii.isDigit(c0) or c0 == '.' or c0 == '+' or c0 == '-')) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
}

/// ES `Number::remainder` (the `%` operator): truncated remainder taking the sign
/// of the dividend (C `fmod`), unlike `std.math.mod` which floors toward the
/// divisor's sign.
pub fn jsRemainder(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b) or std.math.isInf(a) or b == 0) return std.math.nan(f64);
    if (std.math.isInf(b)) return a; // finite a % ±Inf = a
    if (a == 0) return a; // ±0 % finite = ±0
    return @rem(a, b);
}

/// ES `Number::exponentiate` (the `**` operator): `std.math.pow` plus the JS-only
/// rule that `(±1) ** ±Infinity` is NaN (C `pow` returns 1).
pub fn jsExp(base: f64, exp: f64) f64 {
    if (std.math.isInf(exp) and (base == 1 or base == -1)) return std.math.nan(f64);
    return std.math.pow(f64, base, exp);
}

pub fn toNumber(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0.0,
        .boolean => |b| if (b) 1.0 else 0.0,
        .number => |n| n,
        .string => |s| jsStringToNumber(s),
        .function => std.math.nan(f64),
        .bc_function => std.math.nan(f64),
        .object => std.math.nan(f64),
        .native_function => std.math.nan(f64),
        .symbol => std.math.nan(f64),
        .bigint => v.toF64(),
    };
}

fn valueToString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try formatNumber(arena, n),
        .string => |s| s,
        .function => |f| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{f.name orelse ""}),
        .bc_function => |c| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{c.func.name orelse ""}),
        .object => |obj| blk: {
            if (obj.is_array) {
                var buf = std.ArrayList(u8){};
                const len = obj.getArrayLength();
                for (0..len) |i| {
                    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                    if (i > 0) try buf.append(arena, ',');
                    if (obj.get(key)) |elem| {
                        const s = valueToString(arena, elem) catch break :blk "[object Object]";
                        try buf.appendSlice(arena, s);
                    }
                }
                break :blk buf.items;
            }
            break :blk "[object Object]";
        },
        .native_function => "function () { [native code] }",
        .symbol => |sd| try std.fmt.allocPrint(arena, "Symbol({s})", .{sd.description orelse ""}),
        .bigint => |b| try std.fmt.allocPrint(arena, "{s}n", .{try val_mod.bigIntToString(arena, b)}),
    };
}

fn valueToStringArena(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return valueToString(arena, v);
}

/// Format a thrown value as a user-facing exception message.
/// Error-like objects (have own `name` and `message` properties) format as
/// "Name: message" instead of the default "[object Object]" coercion.
pub fn formatExceptionMessage(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits != 0) {
        if (v.unbox() == .object) {
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

pub fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == @trunc(n) and @abs(n) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn jsLessThan(left: Value, right: Value) ?bool {
    const lstr = if (left.bits != 0) left.unbox() == .string else false;
    const rstr = if (right.bits != 0) right.unbox() == .string else false;
    if (lstr and rstr) {
        return std.mem.lessThan(u8, left.toPtr().string, right.toPtr().string);
    }
    const ln = toNumber(left);
    const rn = toNumber(right);
    if (std.math.isNan(ln) or std.math.isNan(rn)) return null;
    return ln < rn;
}

fn jsAbstractEqual(x: Value, y: Value) bool {
    const tx = typeTag(x);
    const ty = typeTag(y);
    if (tx == ty) return jsStrictEqual(x, y);
    // `null` and `undefined` are loosely equal only to each other — never to a
    // boolean, number, or string (e.g. `null == false` is false).
    const x_nullish = tx == .null_ or tx == .undefined_;
    const y_nullish = ty == .null_ or ty == .undefined_;
    if (x_nullish or y_nullish) return x_nullish and y_nullish;
    if (tx == .number and ty == .string) return toNumber(x) == toNumber(y);
    if (tx == .string and ty == .number) return toNumber(x) == toNumber(y);
    if (tx == .boolean) {
        const bv = x.unbox().boolean;
        const n: f64 = if (bv) 1.0 else 0.0;
        return n == toNumber(y);
    }
    if (ty == .boolean) {
        const bv = y.unbox().boolean;
        const n: f64 = if (bv) 1.0 else 0.0;
        return toNumber(x) == n;
    }
    return false;
}

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
            return xn == yn;
        },
        .string => {
            return std.mem.eql(u8, x.toPtr().string, y.toPtr().string);
        },
        .boolean => {
            return x.unbox().boolean == y.unbox().boolean;
        },
        .function => return x.bits == y.bits,
        .bc_function => return x.bits == y.bits,
        .object => return x.toPtr().object == y.toPtr().object,
        .native_function => return x.bits == y.bits,
        .symbol => return x.toPtr().symbol == y.toPtr().symbol,
        .bigint => return val_mod.bigIntEql(x, y),
    }
}

const TypeTag = enum { undefined_, null_, boolean, number, string, symbol, function, bc_function, object, native_function, bigint };

fn typeTag(v: Value) TypeTag {
    if (v.bits == 0) return .undefined_;
    return switch (v.unbox()) {
        .undefined_ => .undefined_,
        .null_ => .null_,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .function => .function,
        .bc_function => .bc_function,
        .object => .object,
        .native_function => .native_function,
        .bigint => .bigint,
    };
}

/// Phase 4a: instanceof — walks lhs.__proto__ chain looking for rhs.prototype.
fn jsInstanceof(lhs: Value, rhs: Value) bool {
    // lhs must be an object.
    if (lhs.bits == 0) return false;
    if (lhs.unbox() != .object) return false;

    // rhs must be an object (or object-with-__call__) with a .prototype property.
    if (rhs.bits == 0) return false;
    const rhs_inner = rhs.unbox();
    const target_proto: *JsObject = switch (rhs_inner) {
        .object => |obj| blk: {
            const pv = obj.get("prototype") orelse return false;
            if (pv.bits == 0) return false;
            if (pv.unbox() != .object) return false;
            break :blk pv.toPtr().object;
        },
        else => return false,
    };

    // Walk prototype chain of lhs.
    var cur: ?*JsObject = lhs.toPtr().object;
    while (cur) |obj| {
        if (obj == target_proto) return true;
        cur = obj.proto;
    }
    return false;
}

// ---------------------------------------------------------------- tests ---

test "BcVm: isTruthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const t = try val_mod.makeBool(alloc, true);
    const f = try val_mod.makeBool(alloc, false);
    try std.testing.expect(isTruthy(t));
    try std.testing.expect(!isTruthy(f));
    const undef = try val_mod.makeUndefined(alloc);
    try std.testing.expect(!isTruthy(undef));
}

test "Phase 9: hot loop registers a hot back-edge" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "var i = 0; while (i < 5000) { i = i + 1; } i;";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();

    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .count);
    defer jc.deinit();
    jc.hot_threshold = 100;

    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    _ = try vm.run(main_func, @ptrCast(realm.global_env));
    try std.testing.expect(jc.hotCount() > 0);
}

test "Phase 12: JIT experimental runs a pure-int function (interp/native parity)" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Pure-int leaf function: JIT-able (no calls/property access/closures).
    const src = "function sum(n){ var s=0; var i=0; while(i<n){ s=s+i; i=i+1; } return s; } sum(100);";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();

    // `.experimental` engages the native fast path (only when built -Djit=true;
    // otherwise the call site is comptime-elided and the interpreter runs).
    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();

    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    // sum(100) = 0+1+...+99 = 4950, identical whether interpreted or JITed.
    try std.testing.expectEqual(@as(f64, 4950), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        // Under -Djit=true the analyzer must have compiled `sum` to native code.
        try std.testing.expect(jc.compiled > 0);
    }
}

test "Phase 12: general loop OSR runs a branchy pure-int loop natively" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `f` is NOT a JIT-able leaf (the string `var junk` makes the whole-function
    // analyzer bail), so it runs interpreted — and its hot loop back-edge triggers
    // general OSR. The loop body contains an `if`, which the closed-form template
    // recognizer cannot fast-forward, so a native compile here proves OSR fired.
    // s counts i in [0,1000) over i in [0,2000) → 1000.
    const src =
        "function f(n){ var junk=\"x\"; var s=0; var i=0;" ++
        " while(i<n){ if(i<1000){ s=s+1; } i=i+1; } return s+junk.length-1; }" ++
        " f(2000);";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();

    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    jc.hot_threshold = 50; // fire OSR early so most iterations run natively.

    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    // s = 1000; junk.length-1 = 0 → 1000, identical interpreted or OSR-compiled.
    try std.testing.expectEqual(@as(f64, 1000), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        // Under -Djit=true the branchy loop must have been OSR-compiled to native
        // code (the template recognizer cannot handle the in-loop `if`).
        try std.testing.expect(jc.compiled > 0);
    }
}

test "Phase 12: loop OSR handles an early break (loop-exit edge)" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Hot loop with a `break` — exercises the OSR loop-exit machinery (a forward
    // out-of-region edge). `junk` forces the non-leaf path so OSR (not the leaf
    // analyzer) compiles the loop. Counts to the break at i==1500 → s = 1500.
    const src =
        "function g(n){ var junk=\"x\"; var s=0; var i=0;" ++
        " while(i<n){ if(i==1500){ break; } s=s+1; i=i+1; } return s+junk.length-1; }" ++
        " g(5000);";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();

    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    jc.hot_threshold = 50;

    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    try std.testing.expectEqual(@as(f64, 1500), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        try std.testing.expect(jc.compiled > 0);
    }
}

test "Phase 12 boxed leaf: JITs double args + non-number passthrough (capability gain)" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    // `mul` is called with a DOUBLE arg (the old SMI-only int leaf would bail);
    // `id` returns a non-number (string) straight through the boxed registers.
    // Both must JIT under -Djit and give the interpreter's result.
    const cases = [_]struct { src: []const u8, want: f64, str: ?[]const u8 }{
        .{ .src = "function mul(a,b){ return a*b; } mul(1.5, 4);", .want = 6, .str = null },
        .{ .src = "function id(x){ return x; } id(\"hello\").length;", .want = 5, .str = null },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var p = parser_mod.Parser.init(case.src, arena);
        const pr = p.parseScript();
        const stmts = switch (pr) {
            .ok => |s| s,
            .err => return error.ParseFailed,
        };
        const prog = ast_mod.Program{ .body = stmts };
        const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

        var realm = try Realm.init(arena);
        defer realm.deinit();
        var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
        defer jc.deinit();
        var vm = BcVm.init(arena, &realm);
        vm.jit = &jc;
        const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
        const result = switch (outcome) {
            .ok => |v| v,
            else => return error.DidNotComplete,
        };
        try std.testing.expectEqual(case.want, result.unbox().number);
        if (comptime build_options.jit_enabled) {
            try std.testing.expect(jc.compiled > 0);
        }
    }
}

test "Phase 12 boxed S3: JITs a monomorphic property read (GET_PROP)" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `getx` reads an own data property. Called in a loop so its property inline
    // cache warms to monomorphic; the boxed JIT then bakes (shape, slot) and reads
    // the slot natively via the fast-path helper. obj.x = 42, 200 iters → 8400.
    const src =
        "function getx(o){ return o.x; }" ++
        " var obj = { x: 42 }; var s = 0;" ++
        " for (var i = 0; i < 200; i = i + 1) { s = s + getx(obj); } s;";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();
    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    try std.testing.expectEqual(@as(f64, 8400), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        // `getx` must have been JIT-compiled with its native GET_PROP fast path.
        try std.testing.expect(jc.compiled > 0);
    }
}

test "Phase 12 boxed S3d: JITs a polymorphic property read" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `getx` is called with two DIFFERENT shapes (x at different slots), so its
    // site goes polymorphic — which S3c's monomorphic-only helper could not JIT.
    // The S3d helper reads the live IC (mono/poly/mega) and resolves both.
    // 300 * (3 + 5) = 2400.
    const src =
        "function getx(o){ return o.x; }" ++
        " var a = { x: 3 }; var b = { y: 9, x: 5 }; var s = 0;" ++
        " for (var i = 0; i < 300; i = i + 1) { s = s + getx(a) + getx(b); } s;";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();
    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    try std.testing.expectEqual(@as(f64, 2400), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        try std.testing.expect(jc.compiled > 0);
    }
}

test "Phase 12 boxed S3e: JITs an own-data property store (SET_PROP)" {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `setx` writes an existing own data property — a single terminal store with
    // no fallible op after it (sound under coarse deopt). Called in a loop so its
    // IC warms; the boxed JIT then stores the slot natively. Final o.x = 199.
    const src =
        "function setx(o, v){ o.x = v; }" ++
        " var o = { x: 0 }; for (var i = 0; i < 200; i = i + 1) { setx(o, i); } o.x;";
    var p = parser_mod.Parser.init(src, arena);
    const pr = p.parseScript();
    const stmts = switch (pr) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");

    var realm = try Realm.init(arena);
    defer realm.deinit();
    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    const result = switch (outcome) {
        .ok => |v| v,
        else => return error.DidNotComplete,
    };
    try std.testing.expectEqual(@as(f64, 199), result.unbox().number);
    if (comptime build_options.jit_enabled) {
        try std.testing.expect(jc.compiled > 0);
    }
}

fn runJitScript(src: []const u8) !Value {
    const compiler_mod = @import("../bytecode/compiler.zig");
    const ast_mod = @import("../parser/ast.zig");
    const parser_mod = @import("../parser/parser.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = parser_mod.Parser.init(src, arena);
    const stmts = switch (p.parseScript()) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast_mod.Program{ .body = stmts };
    const main_func = try compiler_mod.compileProgram(arena, &prog, "<test>");
    var realm = try Realm.init(arena);
    defer realm.deinit();
    var jc = jit_mod.JitCompiler.initMode(std.testing.allocator, .experimental);
    defer jc.deinit();
    var vm = BcVm.init(arena, &realm);
    vm.jit = &jc;
    const outcome = try vm.run(main_func, @ptrCast(realm.global_env));
    return switch (outcome) {
        .ok => |v| v,
        else => error.DidNotComplete,
    };
}

test "Phase 12 boxed S4: JITs a call (delegation, nested native call)" {
    // `callAdd` re-enters via a native CALL to `add` (which itself JITs as a leaf)
    // — exercising the S4 trampoline + a nested JIT region + GC root frames.
    // sum over i in [0,100) of (i + 10) = 4950 + 1000 = 5950.
    const src =
        "function add(a, b){ return a + b; }" ++
        " function callAdd(x){ return add(x, 10); }" ++
        " var s = 0; for (var i = 0; i < 100; i = i + 1) { s = s + callAdd(i); } s;";
    const r = try runJitScript(src);
    try std.testing.expectEqual(@as(f64, 5950), r.unbox().number);
}

test "Phase 12 boxed S4: a thrown exception propagates through a JITed call" {
    // `caller` JITs and re-enters `thrower`, which throws. The exception must
    // propagate out of the native region (NOT re-run the call) and be caught.
    const src =
        "var caught = 0;" ++
        " function thrower(){ throw 7; }" ++
        " function caller(){ return thrower(); }" ++
        " try { caller(); } catch (e) { caught = e; } caught;";
    const r = try runJitScript(src);
    try std.testing.expectEqual(@as(f64, 7), r.unbox().number);
}

test "Phase 12 boxed S6: self-recursion runs native-to-native (direct dispatch)" {
    // `count` recurses in tail position (the arg `n-1` is computed before the
    // call, the result returned after) so it JITs; once its plan is cached, each
    // recursive CALL is dispatched directly to native code (no interpreter frame).
    // 50 levels deep, bottoming out at the base case → 5.
    const src =
        "function count(n){ if (n <= 0) return 5; return count(n - 1); } count(50);";
    const r = try runJitScript(src);
    try std.testing.expectEqual(@as(f64, 5), r.unbox().number);
}
