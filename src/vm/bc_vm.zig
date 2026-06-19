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
const typed_array = @import("../runtime/builtins/typed_array.zig");
const namespace_mod = @import("../runtime/builtins/namespace.zig");
// R2: opcode handlers extracted from runLoop, grouped by category.
const load_ops = @import("ops/load.zig");
const jump_ops = @import("ops/jump.zig");
const object_ops = @import("ops/object.zig");
const compare_ops = @import("ops/compare.zig");
const arith_ops = @import("ops/arith.zig");
const property_ops = @import("ops/property.zig");
const exception_ops = @import("ops/exception.zig");
const call_ops = @import("ops/call.zig");

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
    /// True while this coroutine is actively running — re-entrant `.next()`/
    /// `.throw()` (e.g. a generator resuming itself) must throw, not recurse.
    executing: bool = false,
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
    /// MI15 Phase 4e: re-entrancy floor for exception unwinding. A nested runLoop
    /// entered from a native (bcInvokeJs / constructImpl / generator resume) sets
    /// this to the index of the frame it pushed, so `throwException` does NOT
    /// search the *caller's* (outer) frames for a try handler. Without it an
    /// uncaught throw inside a re-entrant native call (e.g. a derived-class super
    /// to a throwing native ctor during species construction) would unwind into
    /// the outer JS `try`, corrupting control flow and leaking a stale exception.
    /// Default 0 = the top-level run searches all frames.
    frame_floor: usize = 0,
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
    /// W3: a resource-limit interrupt that fired inside a nested `bcInvokeJs`
    /// run (e.g. a sort comparator). It must NOT become a catchable JS throw —
    /// the message is stashed here so the outer `runLoop`/`raisePendingException`
    /// re-surfaces it as an interrupt outcome, bypassing any JS try/catch.
    interrupt_pending: ?[]const u8 = null,
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
        const realm_nt = @import("../runtime/realm.zig");
        realm_nt.active_constructing = false;
        // Capture+consume NewTarget threaded by the construct paths (doConstruct /
        // constructImpl set `pending_new_target` immediately before invoking). Bound
        // into the callee's env as `__new_target__` below so a derived ctor's
        // `Reflect.construct(Super, arguments, __new_target__)` desugaring propagates
        // the ORIGINAL new.target down a multi-level super chain. Cleared here so an
        // ordinary call/callback sees new.target = undefined.
        const captured_nt = realm_nt.pending_new_target;
        realm_nt.pending_new_target = Value{};
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
                try call_env.define("__new_target__", if (captured_nt.bits != 0) captured_nt else try val_mod.makeUndefined(self.arena));
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }
                try self.defineArguments(call_env, fn_ptr, args);
                try self.bindRestParam(call_env, fn_ptr, args);
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
                // Re-entrancy boundary: an uncaught throw inside this nested run
                // must not unwind into the native caller's outer frames.
                const saved_floor = self.frame_floor;
                self.frame_floor = frames_before;
                defer self.frame_floor = saved_floor;
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
                            // A resource-limit interrupt is NOT a catchable throw:
                            // stash it so the outer loop re-surfaces it as an
                            // interrupt outcome instead of `throw undefined`.
                            if (std.mem.startsWith(u8, msg, "interrupted:")) {
                                self.interrupt_pending = msg;
                                return error.JsException;
                            }
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
                // Built-in callable objects (Array, %TypedArray%, Error, …) carry a
                // `__call__` native slot. Dispatch to it and propagate its real
                // exception. A derived class doing `super(a,b,c)` to such a native
                // parent reaches here; returning a blank exception (the old
                // behaviour) silently dropped a genuine throw (e.g. a RangeError
                // from a TypedArray ctor when a resizable buffer shrank mid-call).
                if (obj.get("__call__")) |cv| {
                    if (cv.bits != 0 and cv.unbox() == .native_function) {
                        return cv.toPtr().native_function.invoke(self.arena, this_val, args) catch |e| {
                            if (e == error.JsException) return error.JsException;
                            return error.OutOfMemory;
                        };
                    }
                }
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a function");
                return error.JsException;
            },
            else => {
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a function");
                return error.JsException;
            },
        }
    }

    /// Construct `ctor` with `args` (native-friendly: throws JsException on
    /// failure, setting realm pending_exception). Used by Reflect.construct and
    /// Proxy. Mirrors doConstruct's per-callee logic.
    pub fn constructFromArgs(self: *BcVm, ctor: Value, args: []const Value) anyerror!Value {
        return self.constructImpl(ctor, args, ctor);
    }

    /// GetPrototypeFromConstructor(newTarget, default): `? Get(newTarget,"prototype")`
    /// (fires accessor getters / proxy traps, abrupt throws propagate); falls back
    /// to `default` when the result is not an object.
    fn protoFromNewTarget(self: *BcVm, new_target: Value, default_proto: ?*JsObject) anyerror!?*JsObject {
        if (new_target.bits == 0) return default_proto;
        const pv = try self.getProp(new_target, "prototype");
        if (pv.bits != 0 and pv.unbox() == .object) return pv.toPtr().object;
        return default_proto;
    }

    /// Construct with an explicit NewTarget (Reflect.construct / subclassing).
    /// `new_target` supplies `[[Prototype]]` via GetPrototypeFromConstructor.
    pub fn constructImpl(self: *BcVm, ctor: Value, args: []const Value, new_target: Value) anyerror!Value {
        const realm_m = @import("../runtime/realm.zig");
        if (ctor.bits == 0) {
            realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
            return error.JsException;
        }
        switch (ctor.unbox()) {
            .bc_function => {
                const proto = try self.protoFromNewTarget(new_target, self.realm.object_prototype);
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                // Thread NewTarget into the ctor frame (captured by bcInvokeJs as
                // `__new_target__`) so a derived ctor's super() forwards it unchanged.
                realm_m.pending_new_target = new_target;
                const result = try bcInvokeJs(self, self.arena, this_val, ctor, args);
                return if (result.bits != 0 and result.unbox() == .object) result else this_val;
            },
            .native_function => {
                // A bare native_function is a built-in *method* (Math.max,
                // %TypedArray%.prototype.map, …): callable but NOT a constructor.
                // Built-in constructors (Array, Number, TypedArray, …) are JsObjects
                // carrying a `__call__` slot and are handled by the `.object` arm.
                // Per IsConstructor, `new <method>()` must throw TypeError.
                realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
                return error.JsException;
            },
            .object => |o| {
                if (o.internal_kind == .proxy) return try self.proxyConstruct(o, args, ctor);
                if (o.get("__call__")) |cv| {
                    if (cv.bits != 0 and cv.unbox() == .native_function) {
                        // Default proto = ctor's own .prototype (the intrinsic per-kind
                        // prototype). Create with this provisional proto; the real proto
                        // comes from GetPrototypeFromConstructor(newTarget), applied either
                        // by the ctor at its spec-precise point (consuming pending_new_target,
                        // so e.g. ToIndex on a primitive arg can throw FIRST) or post-hoc here.
                        var default_proto: ?*JsObject = self.realm.object_prototype;
                        if (o.get("prototype")) |pv| {
                            if (pv.bits != 0 and pv.unbox() == .object) default_proto = pv.toPtr().object;
                        }
                        const new_obj = if (self.heap) |heap|
                            try JsObject.createOnHeap(heap, default_proto)
                        else
                            try JsObject.create(self.arena, default_proto);
                        const this_val = try val_mod.makeObject(self.arena, new_obj);
                        const saved_nt = realm_m.pending_new_target;
                        realm_m.pending_new_target = new_target;
                        realm_m.active_constructing = true;
                        const result = cv.toPtr().native_function.invoke(self.arena, this_val, args) catch |e| {
                            realm_m.active_constructing = false;
                            realm_m.pending_new_target = saved_nt;
                            return e;
                        };
                        realm_m.active_constructing = false;
                        // [[Construct]] adopts an Object return; in our split value
                        // model functions are objects too (e.g. `new Function(body)`).
                        const ret = if (result.bits != 0 and switch (result.unbox()) {
                            .object, .bc_function, .native_function, .function => true,
                            else => false,
                        }) result else this_val;
                        // Ctor didn't consume the NewTarget → apply prototype now.
                        if (realm_m.pending_new_target.bits != 0) {
                            const p = self.protoFromNewTarget(new_target, null) catch |e| {
                                realm_m.pending_new_target = saved_nt;
                                return e;
                            };
                            if (p) |pp| {
                                if (ret.bits != 0 and ret.unbox() == .object) ret.toPtr().object.proto = pp;
                            }
                        }
                        realm_m.pending_new_target = saved_nt;
                        return ret;
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

    /// Context bridge: full [[Get]] of a string-keyed property (fires accessors /
    /// Proxy traps, walks the prototype chain). Used by native builtins that must
    /// observe getters (e.g. %TypedArray%.prototype.set / from).
    fn bcGetProp(ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        return self.getProp(obj_val, key);
    }

    fn bcGetPropSym(ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, sym_key: Value) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        return self.getPropSym(obj_val, sym_key);
    }

    fn bcSetProp(ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        return self.setProp(obj_val, key, value);
    }

    fn bcSetProto(ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, proto: ?*JsObject) anyerror!void {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        if (obj_val.bits == 0) return;
        switch (obj_val.unbox()) {
            .object => |o| o.proto = proto,
            // bc_function ctor: set the backing object's proto so static members
            // resolve along the constructor chain (class subclassing).
            .bc_function => |c| {
                const bo = try self.closureBackingObj(c);
                bo.proto = proto;
            },
            else => {},
        }
    }

    fn bcBackingObj(ptr: *anyopaque, arena: std.mem.Allocator, val: Value) anyerror!?*JsObject {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        if (val.bits == 0) return null;
        return switch (val.unbox()) {
            .object => |o| o,
            .bc_function => |c| try self.closureBackingObj(c),
            else => null,
        };
    }

    fn bcConstructNt(ptr: *anyopaque, arena: std.mem.Allocator, ctor_val: Value, args: []const Value, new_target: Value) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        return self.constructImpl(ctor_val, args, new_target);
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
        const prog = ast_mod.Program{ .body = stmts, .is_strict = parser_mod.hasUseStrict(stmts) };
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
            .get_fn = bcGetProp,
            .construct_nt_fn = bcConstructNt,
            .get_sym_fn = bcGetPropSym,
            .set_fn = bcSetProp,
            .set_proto_fn = bcSetProto,
            .backing_obj_fn = bcBackingObj,
        };
        realm_mod.active_context = &self.context;
    }

    fn deactivateContext(_: *BcVm) void {
        @import("../runtime/realm.zig").active_context = null;
    }

    /// Phase 9: record a loop back-edge as a hot-site signal. Returns true when
    /// this site just crossed the hot threshold AND the JIT is in experimental
    /// mode — the caller may then attempt a native fast-forward. No-op when off.
    pub inline fn noteBackedge(self: *BcVm, func: *const BcFunction, op_pc: usize) bool {
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
            // W3: an interrupt that fired in a nested re-entrant run propagates
            // here past any JS try/catch (checked before instruction dispatch).
            if (self.interrupt_pending) |m| {
                self.interrupt_pending = null;
                return RunOutcome{ .exception = m };
            }
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
                .LOAD_K => if (try load_ops.opLoadK(self, frame)) |o| return o,
                .LOAD_TRUE => if (try load_ops.opLoadTrue(self, frame)) |o| return o,
                .LOAD_FALSE => if (try load_ops.opLoadFalse(self, frame)) |o| return o,
                .LOAD_NULL => if (try load_ops.opLoadNull(self, frame)) |o| return o,
                .LOAD_UNDEF => if (try load_ops.opLoadUndef(self, frame)) |o| return o,
                .MOVE => if (try load_ops.opMove(self, frame)) |o| return o,
                .GET_GLOBAL => if (try load_ops.opGetGlobal(self, frame)) |o| return o,
                .GET_GLOBAL_OPT => if (try load_ops.opGetGlobalOpt(self, frame)) |o| return o,
                .HOIST_VAR => if (try load_ops.opHoistVar(self, frame)) |o| return o,
                .HOIST_LEX => if (try load_ops.opHoistLexical(self, frame)) |o| return o,
                .INIT_LEX => if (try load_ops.opInitLexical(self, frame)) |o| return o,
                .SET_GLOBAL => if (try load_ops.opSetGlobal(self, frame)) |o| return o,
                .DEFINE_GLOBAL => if (try load_ops.opDefineGlobal(self, frame)) |o| return o,
                .GET_LOCAL => if (try load_ops.opGetLocal(self, frame)) |o| return o,
                .SET_LOCAL => if (try load_ops.opSetLocal(self, frame)) |o| return o,
                .ADD => if (try arith_ops.opAdd(self, frame)) |o| return o,
                .SUB => if (try arith_ops.opSub(self, frame)) |o| return o,
                .MUL => if (try arith_ops.opMul(self, frame)) |o| return o,
                .DIV => if (try arith_ops.opDiv(self, frame)) |o| return o,
                .MOD => if (try arith_ops.opMod(self, frame)) |o| return o,
                .EXP => if (try arith_ops.opExp(self, frame)) |o| return o,
                .NEG => if (try arith_ops.opNeg(self, frame)) |o| return o,
                .BIT_AND => if (try arith_ops.opBitAnd(self, frame)) |o| return o,
                .BIT_OR => if (try arith_ops.opBitOr(self, frame)) |o| return o,
                .BIT_XOR => if (try arith_ops.opBitXor(self, frame)) |o| return o,
                .SHL => if (try arith_ops.opShl(self, frame)) |o| return o,
                .SHR => if (try arith_ops.opShr(self, frame)) |o| return o,
                .USHR => if (try arith_ops.opUshr(self, frame)) |o| return o,
                .BIT_NOT => if (try arith_ops.opBitNot(self, frame)) |o| return o,
                .INC => if (try arith_ops.opInc(self, frame)) |o| return o,
                .DEC => if (try arith_ops.opDec(self, frame)) |o| return o,
                .EQ => if (try compare_ops.opEq(self, frame)) |o| return o,
                .NEQ => if (try compare_ops.opNeq(self, frame)) |o| return o,
                .SEQ => if (try compare_ops.opSeq(self, frame)) |o| return o,
                .SNEQ => if (try compare_ops.opSneq(self, frame)) |o| return o,
                .LT => if (try compare_ops.opLt(self, frame)) |o| return o,
                .LE => if (try compare_ops.opLe(self, frame)) |o| return o,
                .GT => if (try compare_ops.opGt(self, frame)) |o| return o,
                .GE => if (try compare_ops.opGe(self, frame)) |o| return o,
                .NOT => if (try compare_ops.opNot(self, frame)) |o| return o,
                .TYPEOF => if (try compare_ops.opTypeof(self, frame)) |o| return o,
                .JMP => if (try jump_ops.opJmp(self, frame)) |o| return o,
                .JMP_IF_TRUE => if (try jump_ops.opJmpIfTrue(self, frame)) |o| return o,
                .JMP_IF_FALSE => if (try jump_ops.opJmpIfFalse(self, frame)) |o| return o,
                .JMP_IF_NULLISH => if (try jump_ops.opJmpIfNullish(self, frame)) |o| return o,
                .JMP_IF_NOT_NULLISH => if (try jump_ops.opJmpIfNotNullish(self, frame)) |o| return o,
                .JSEQ => if (try jump_ops.opJseq(self, frame)) |o| return o,
                .JGE => if (try jump_ops.opJge(self, frame)) |o| return o,
                .NEW_CLOSURE => if (try call_ops.opNewClosure(self, frame)) |o| return o,
                .CALL => if (try call_ops.opCall(self, frame)) |o| return o,
                .TAIL_CALL => if (try call_ops.opTailCall(self, frame)) |o| return o,
                .METHOD_CALL => if (try call_ops.opMethodCall(self, frame)) |o| return o,
                .TAIL_METHOD_CALL => if (try call_ops.opTailMethodCall(self, frame)) |o| return o,
                .CALL_SPREAD => if (try call_ops.opCallSpread(self, frame)) |o| return o,
                .RETURN => if (try call_ops.opReturn(self, frame)) |o| return o,
                .RETURN_UNDEF => if (try call_ops.opReturnUndef(self, frame)) |o| return o,
                .HALT => if (try call_ops.opHalt(self, frame)) |o| return o,
                .YIELD => if (try call_ops.opYield(self, frame)) |o| return o,
                .DEBUGGER => if (try call_ops.opDebugger(self, frame)) |o| return o,
                .NEW_OBJECT => if (try object_ops.opNewObject(self, frame)) |o| return o,
                .NEW_ARRAY => if (try object_ops.opNewArray(self, frame)) |o| return o,
                .ARRAY_APPEND => if (try object_ops.opArrayAppend(self, frame)) |o| return o,
                .ARRAY_SPREAD => if (try object_ops.opArraySpread(self, frame)) |o| return o,
                .GET_PROP => if (try property_ops.opGetProp(self, frame)) |o| return o,
                .GET_PROP_DYN => if (try property_ops.opGetPropDyn(self, frame)) |o| return o,
                .SET_PROP => if (try property_ops.opSetProp(self, frame)) |o| return o,
                .SET_PROP_DYN => if (try property_ops.opSetPropDyn(self, frame)) |o| return o,
                .DEFINE_ACCESSOR => if (try property_ops.opDefineAccessor(self, frame)) |o| return o,
                .GET_THIS => if (try property_ops.opGetThis(self, frame)) |o| return o,
                .IN => if (try property_ops.opIn(self, frame)) |o| return o,
                .DELETE_PROP => if (try property_ops.opDeleteProp(self, frame)) |o| return o,
                .GET_KEYS => if (try property_ops.opGetKeys(self, frame)) |o| return o,
                .THROW => if (try exception_ops.opThrow(self, frame)) |o| return o,
                .PUSH_TRY => if (try exception_ops.opPushTry(self, frame)) |o| return o,
                .POP_TRY => if (try exception_ops.opPopTry(self, frame)) |o| return o,
                .INSTANCEOF => if (try exception_ops.opInstanceof(self, frame)) |o| return o,
                .NEW_INSTANCE => if (try exception_ops.opNewInstance(self, frame)) |o| return o,
            }
        }
        return RunOutcome{ .ok = try val_mod.makeUndefined(self.arena) };
    }

    /// Route a caught native `error.JsException` into the VM's try/catch
    /// machinery. Returns a `RunOutcome` the caller must return (no handler
    /// found), or null when a handler was found (caller continues dispatch).
    pub fn raisePendingException(self: *BcVm, fallback_msg: []const u8) !?RunOutcome {
        // A nested-run interrupt bypasses try/catch: surface it directly.
        if (self.interrupt_pending) |m| {
            self.interrupt_pending = null;
            return RunOutcome{ .exception = m };
        }
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
    pub fn throwException(self: *BcVm, thrown_val: Value) !bool {
        var fi: usize = self.frames.items.len;
        // Stop at `frame_floor`: never unwind into the frames of a native caller
        // that re-entered the VM (see `frame_floor`). An uncaught throw at/above
        // the floor returns `false` so the re-entrant runLoop surfaces it to its
        // native caller as `error.JsException`, instead of jumping into an outer
        // JS `try` that belongs to a different invocation.
        while (fi > self.frame_floor) {
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
    pub fn doConstruct(self: *BcVm, callee_val: Value, base: u8, nargs: u8, rdst: u8) !?[]const u8 {
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
                // Top-level `new X()`: NewTarget is the callee. Thread it so a
                // derived ctor's super() chain propagates it (captured as
                // `__new_target__` by bcInvokeJs).
                @import("../runtime/realm.zig").pending_new_target = callee_val;
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
                if (self.frames.items.len > 0) {
                    self.frames.items[self.frames.items.len - 1].registers[rdst] = final;
                }
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
            .native_function => {
                // A bare native_function is a built-in *method* (Math.max,
                // %TypedArray%.prototype.map, …): callable but NOT a constructor.
                // Built-in constructors are JsObjects with a `__call__` slot, handled
                // by the `.object` arm below. `new <method>()` must throw TypeError.
                self.last_exception_value = try self.makeErrorObjectBc("TypeError", "value is not a constructor");
                return "__js_exception__";
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
                        // Adopt an Object return; functions are objects too
                        // (`new Function(body)` returns a compiled function).
                        const final_r = if (result.bits != 0 and switch (result.unbox()) {
                            .object, .bc_function, .native_function, .function => true,
                            else => false,
                        }) result else this_val;
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
                try self.defineArguments(call_env, fn_ptr, frame.registers[@as(usize, base) + 1 ..][0..@as(usize, nargs)]);
                try self.bindRestParam(call_env, fn_ptr, frame.registers[@as(usize, base) + 1 ..][0..@as(usize, nargs)]);
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
    pub fn captureStackBc(self: *BcVm, err_obj: *JsObject) void {
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

    pub fn makeErrorObjectBc(self: *BcVm, name: []const u8, message: []const u8) !Value {
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
    pub fn getPropSym(self: *BcVm, obj_val: Value, sym_key: Value) !Value {
        if (obj_val.bits == 0) return val_mod.makeUndefined(self.arena);
        const root_obj = switch (obj_val.unbox()) {
            .object => |o| o,
            .bc_function => |c| try self.closureBackingObj(c),
            else => return val_mod.makeUndefined(self.arena),
        };
        if (root_obj.internal_kind == .proxy) {
            return try self.proxyGet(obj_val, root_obj, sym_key);
        }
        var cur: ?*JsObject = root_obj;
        var depth: usize = 0;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            if (o.getOwnSymEntry(sym_key)) |sp| {
                if (sp.attr.is_accessor) {
                    const getter = accessorMember(sp.value, "get");
                    if (!isCallable(getter)) return val_mod.makeUndefined(self.arena);
                    return try self.callAccessor(getter, obj_val, &[_]Value{});
                }
                return sp.value;
            }
            cur = o.proto;
        }
        return val_mod.makeUndefined(self.arena);
    }

    /// Set a symbol-keyed own property. Functions are objects: a bc_function
    /// stores symbol props on its backing object (e.g. `fn[Symbol.iterator]=…`).
    pub fn setPropSym(self: *BcVm, obj_val: Value, sym_key: Value, value: Value) !void {
        if (obj_val.bits == 0) return;
        const obj = switch (obj_val.unbox()) {
            .object => |o| o,
            .bc_function => |c| try self.closureBackingObj(c),
            else => return,
        };
        if (obj.internal_kind == .proxy) {
            _ = try self.proxySet(obj_val, obj, sym_key, value, obj_val);
            return;
        }
        // M16: Module Namespace exotic [[Set]] always fails.
        if (obj.internal_kind == .module_namespace) {
            const realm_m = @import("../runtime/realm.zig");
            realm_m.pending_exception = try self.makeErrorObjectBc("TypeError", "Cannot set property on module namespace object");
            return error.JsException;
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
    fn proxySet(self: *BcVm, proxy_val: Value, proxy_obj: *JsObject, key: Value, value: Value, receiver: Value) anyerror!bool {
        _ = proxy_val;
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return true;
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return true;
        if (proxy_mod.trap(handler, "set")) |trap_fn| {
            const res = try self.callAccessor(trap_fn, handler, &[_]Value{ target, key, value, receiver });
            return isTruthy(res);
        }
        // No trap: default [[Set]] forwards to the target, preserving Receiver
        // (spec: OrdinarySet(target, P, V, Receiver) — the write lands on Receiver,
        // not the target). Threading Receiver lets a TypedArray's exotic [[Set]]
        // in the target's proto chain route CreateDataProperty back to the proxy.
        if (key.bits != 0 and key.unbox() == .symbol) {
            try self.setPropSym(target, key, value);
            return true;
        }
        const key_str = try valueToStringArena(self.arena, key);
        return try self.setPropR(target, key_str, value, receiver);
    }

    /// HasProperty(obj, key) for the `in` operator: prototype-chain walk over
    /// string and symbol keys, with Proxy `has` trap dispatch.
    pub fn hasProperty(self: *BcVm, obj_val: Value, key_v: Value) anyerror!bool {
        // native_function: own props are "length"/"name" (unless deleted); walk Function.prototype chain.
        if (obj_val.bits != 0 and obj_val.unbox() == .native_function) {
            const realm_mod = @import("../runtime/realm.zig");
            const key = try valueToStringArena(self.arena, key_v);
            const entry = obj_val.unbox().native_function;
            if (std.mem.eql(u8, key, "length") and !entry.length_deleted) return true;
            if (std.mem.eql(u8, key, "name")   and !entry.name_deleted)   return true;
            // Walk Function.prototype chain for inherited props (e.g. "call", "bind", "apply").
            var cur: ?*JsObject = if (realm_mod.active_function_proto) |p| p else null;
            var depth: usize = 0;
            while (cur) |o| {
                if (depth >= 64) break;
                depth += 1;
                if (o.hasOwn(key)) return true;
                cur = o.proto;
            }
            return false;
        }
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
        // M15: TypedArray [[HasProperty]] — integer-indexed exotic.
        if (root_obj.internal_kind == .typed_array) {
            const key_str = try valueToStringArena(self.arena, key_v);
            if (typed_array.canonicalNumericIndexString(key_str)) |idx_f| {
                const td = typed_array.getTd(obj_val).?;
                return typed_array.isValidIntegerIndex(td, idx_f);
            }
            // Non-canonical-numeric key: fall through to ordinary prototype walk.
        }
        // Symbol key.
        if (key_v.bits != 0 and key_v.unbox() == .symbol) {
            var cur: ?*JsObject = root_obj;
            var depth: usize = 0;
            while (cur) |o| {
                if (depth >= 64) break;
                depth += 1;
                // A Proxy in the prototype chain has its own [[HasProperty]];
                // recurse so the `has` trap (or target walk) is dispatched.
                if (o != root_obj and o.internal_kind == .proxy) {
                    return try self.hasProperty(try val_mod.makeObject(self.arena, o), key_v);
                }
                if (o.getOwnSym(key_v) != null) return true;
                cur = o.proto;
            }
            return false;
        }
        // String key.
        const key = try valueToStringArena(self.arena, key_v);
        // M16: Module Namespace exotic [[HasProperty]] — string keys are exactly
        // the exported names (null prototype, so no inherited keys).
        if (root_obj.internal_kind == .module_namespace) {
            return namespace_mod.hasExport(root_obj, key);
        }
        var cur: ?*JsObject = root_obj;
        var depth: usize = 0;
        while (cur) |o| {
            if (depth >= 64) break;
            depth += 1;
            // A Proxy in the prototype chain has its own [[HasProperty]];
            // recurse so the `has` trap (or target walk) is dispatched.
            if (o != root_obj and o.internal_kind == .proxy) {
                return try self.hasProperty(try val_mod.makeObject(self.arena, o), key_v);
            }
            if (o.is_array and std.mem.eql(u8, key, "length")) return true;
            if (o.hasOwn(key)) return true;
            cur = o.proto;
        }
        return false;
    }

    /// Delete own property for the `delete` operator, returning the boolean
    /// result. Dispatches the Proxy `deleteProperty` trap; deleting from a
    /// non-object is a no-op that yields `true`.
    pub fn deleteProperty(self: *BcVm, obj_val: Value, key_v: Value) anyerror!bool {
        // native_function: "length" and "name" are configurable — mark deleted.
        if (obj_val.bits != 0 and obj_val.unbox() == .native_function) {
            if (obj_val.isHeapPtr()) {
                const key = try valueToStringArena(self.arena, key_v);
                const entry: *val_mod.NativeFnEntry = &obj_val.toPtr().native_function;
                if (std.mem.eql(u8, key, "length")) { entry.length_deleted = true; return true; }
                if (std.mem.eql(u8, key, "name"))   { entry.name_deleted   = true; return true; }
            }
            return true; // non-own key — no-op, return true
        }
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
        // M15: TypedArray [[Delete]] — integer-indexed exotic. Symbol keys are
        // ordinary (never integer indices) → skip straight to deleteOwnSym.
        if (obj.internal_kind == .typed_array and !(key_v.bits != 0 and key_v.unbox() == .symbol)) {
            const key_str2 = try valueToStringArena(self.arena, key_v);
            if (typed_array.canonicalNumericIndexString(key_str2)) |idx_f| {
                const td2 = typed_array.getTd(obj_val).?;
                // Valid index: cannot delete → return false (strict caller throws).
                if (typed_array.isValidIntegerIndex(td2, idx_f)) return false;
                // Out-of-range or non-integer canonical numeric: return true (absent).
                return true;
            }
            // Non-canonical key: fall through to ordinary deleteOwn.
        }
        if (key_v.bits != 0 and key_v.unbox() == .symbol) {
            return obj.deleteOwnSym(key_v);
        }
        const key = try valueToStringArena(self.arena, key_v);
        // M16: Module Namespace exotic [[Delete]] — an exported name cannot be
        // deleted (false → strict caller throws); a non-export "succeeds".
        if (obj.internal_kind == .module_namespace) {
            return !namespace_mod.hasExport(obj, key);
        }
        return obj.deleteOwn(key);
    }

    /// Abstract equality (`==`) with object↔primitive ToPrimitive coercion.
    /// When exactly one side is an object (and the other is neither null nor
    /// undefined), the object is converted via ToPrimitive(default) — honoring
    /// `Symbol.toPrimitive`/`valueOf`/`toString` — then re-compared. Everything
    /// else delegates to the pure `jsAbstractEqual`.
    pub fn abstractEqual(self: *BcVm, x: Value, y: Value) anyerror!bool {
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
        // BigInt cross-type comparisons (spec §7.2.15 steps 6-9) — jsAbstractEqual
        // is allocation-free and can't build the comparison BigInt, so handle here.
        const x_big = x.bits != 0 and x.unbox() == .bigint;
        const y_big = y.bits != 0 and y.unbox() == .bigint;
        if (x_big != y_big) {
            const big = if (x_big) x else y;
            const other = if (x_big) y else x;
            if (other.bits == 0) return false;
            switch (other.unbox()) {
                .number => |n| return bigIntEqualsNumber(self.arena, big, n),
                .boolean => |b| return bigIntEqualsNumber(self.arena, big, if (b) 1.0 else 0.0),
                .string => |s| return bigIntEqualsString(self.arena, big, s),
                else => return false, // null/undefined/symbol
            }
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

    pub fn getProp(self: *BcVm, obj_val: Value, key: []const u8) !Value {
        if (obj_val.bits == 0) return val_mod.makeUndefined(self.arena);
        switch (obj_val.unbox()) {
            .object => |obj| {
                if (obj.internal_kind == .proxy) {
                    const key_v = try val_mod.makeString(self.arena, key);
                    return try self.proxyGet(obj_val, obj, key_v);
                }
                // M15: integer-indexed TypedArray element read (exotic). A canonical
                // index past the end (or on a detached buffer) yields undefined and
                // never falls through to ordinary property lookup.
                if (obj.internal_kind == .typed_array) {
                    // Any canonical numeric index string ("0","0.1","-0","5") is
                    // handled by the exotic [[Get]]: valid index → element; invalid
                    // (non-integer, -0, OOB, detached) → undefined; NEVER falls
                    // through to ordinary property lookup. Non-numeric keys do.
                    if (typed_array.canonicalNumericIndexString(key)) |idx_f| {
                        const td: *typed_array.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
                        if (!typed_array.isValidIntegerIndex(td, idx_f)) return val_mod.makeUndefined(self.arena);
                        return typed_array.taLoad(self.arena, td, @intFromFloat(idx_f));
                    }
                }
                // M16: Module Namespace exotic [[Get]] — a string key resolves to
                // the named export's *current* value (live), throwing ReferenceError
                // for uninitialized (TDZ) bindings.
                if (obj.internal_kind == .module_namespace) {
                    // M16 Phase 5: "__ns__" is a synthetic key used by `import * as ns`
                    // live binding rewriting so that reads of `ns` return the namespace
                    // object itself while writes (`ns = x`) invoke namespace [[Set]]
                    // and throw TypeError in strict mode.
                    if (std.mem.eql(u8, key, "__ns__")) return obj_val;
                    const b = namespace_mod.backing(obj) orelse return val_mod.makeUndefined(self.arena);
                    if (namespace_mod.isTDZ(obj, key)) {
                        const realm_m = @import("../runtime/realm.zig");
                        const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{key});
                        realm_m.pending_exception = try self.makeErrorObjectBc("ReferenceError", msg);
                        return error.JsException;
                    }
                    if (!b.hasOwn(key)) return val_mod.makeUndefined(self.arena);
                    return try self.getProp(try val_mod.makeObject(self.arena, b), key);
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
                // String exotic own indexed properties: a canonical integer index in
                // [0, length) reads the code unit (byte) at that position as a
                // 1-char string. ToString-round-trip ensures only canonical indices
                // (no leading zeros / "+1" / "1.0") match.
                if (asArrayIndex(key)) |i| {
                    if (i < s.len) return val_mod.makeString(self.arena, s[i .. i + 1]);
                    return val_mod.makeUndefined(self.arena);
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
                // Own `name`/`length` for user functions (spec: non-writable,
                // configurable). `length` = declared arity; `name` = the bound
                // function name ("" when anonymous and not named-evaluated).
                if (std.mem.eql(u8, key, "name")) {
                    return val_mod.makeString(self.arena, closure.func.name orelse "");
                }
                if (std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(closure.func.arity));
                }
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .function, .native_function => {
                // `.length` = declared arity (native_function carries it inline).
                // Respect deletion flag: if deleted, skip own-prop and fall through.
                if (std.mem.eql(u8, key, "length")) {
                    const deleted = obj_val.unbox() == .native_function and
                        obj_val.unbox().native_function.length_deleted;
                    if (!deleted) {
                        const len: u8 = switch (obj_val.unbox()) {
                            .native_function => |e| e.length,
                            else => 0,
                        };
                        return val_mod.makeNumber(self.arena, @floatFromInt(len));
                    }
                    // deleted — fall through to Function.prototype
                }
                // `.name` = function name stored inline on NativeFnEntry.
                if (std.mem.eql(u8, key, "name")) {
                    if (obj_val.unbox() == .native_function) {
                        const entry = obj_val.unbox().native_function;
                        if (!entry.name_deleted) {
                            const n = entry.name orelse "";
                            return val_mod.makeString(self.arena, n);
                        }
                        // deleted — fall through to Function.prototype
                    } else {
                        return val_mod.makeUndefined(self.arena);
                    }
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
            .bigint => {
                // Autoboxing for bigint primitives → BigInt.prototype.
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_bigint_proto) |proto| {
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

    pub fn setProp(self: *BcVm, obj_val: Value, key: []const u8, value: Value) !void {
        _ = try self.setPropR(obj_val, key, value, obj_val);
    }

    /// SameValue between a Value and a raw JsObject pointer (object identity).
    fn sameObject(v: Value, ptr: *JsObject) bool {
        return v.bits != 0 and v.unbox() == .object and v.toPtr().object == ptr;
    }

    /// [[Set]](P, V, Receiver) with an explicit Receiver. Returns true when the
    /// set succeeded (or is a spec no-op that must not throw); false when it is a
    /// failed assignment whose strict-mode caller must raise a TypeError.
    ///
    /// Receiver threading matters for TypedArray exotic [[Set]] reached through a
    /// prototype chain (e.g. `Object.create(ta)[i] = v` or a Proxy of such): the
    /// exotic method intercepts canonical numeric indices, and for a valid index
    /// with a different Receiver, OrdinarySet writes onto the Receiver instead.
    pub fn setPropR(self: *BcVm, obj_val: Value, key: []const u8, value: Value, receiver: Value) anyerror!bool {
        if (obj_val.bits == 0) return true;
        switch (obj_val.unbox()) {
            .object => |obj| {
                if (obj.internal_kind == .proxy) {
                    const key_v = try val_mod.makeString(self.arena, key);
                    return try self.proxySet(obj_val, obj, key_v, value, receiver);
                }
                // M16: Module Namespace exotic [[Set]] always fails (the strict
                // module caller turns the false return into a TypeError).
                if (obj.internal_kind == .module_namespace) return false;
                // M15: integer-indexed TypedArray element write (exotic). Coerce the
                // value (ToNumber/ToBigInt) then store; out-of-bounds is a silent
                // no-op and indexed keys never create ordinary properties.
                if (obj.internal_kind == .typed_array) {
                    // Any canonical numeric index string routes to the exotic
                    // [[Set]]: when SameValue(O, Receiver), ToNumber/ToBigInt always
                    // runs (valueOf side effects + abrupt throws propagate) and the
                    // element stores only for a valid index; invalid indices
                    // ("0.1","-0",OOB) are a no-op and NEVER create an ordinary
                    // property. A different Receiver short-circuits before coercion.
                    if (typed_array.canonicalNumericIndexString(key)) |idx_f| {
                        const td: *typed_array.TypedArrayData = @ptrCast(@alignCast(obj.internal_slot.?));
                        if (receiver.bits == obj_val.bits) {
                            try typed_array.setElementThrowing(self.arena, td, idx_f, value);
                            return true;
                        }
                        if (!typed_array.isValidIntegerIndex(td, idx_f)) return true;
                        return try self.ordinarySetReceiverWrite(receiver, key, value);
                    }
                } else if (typed_array.canonicalNumericIndexString(key)) |idx_f| {
                    // Prototype-chain dispatch: a canonical numeric index may be
                    // intercepted by a TypedArray's exotic [[Set]] sitting in the
                    // proto chain (OrdinarySet delegates to parent.[[Set]] when O
                    // lacks an own property). Walk from O; whichever comes first —
                    // an ordinary own property or a TypedArray — wins. A TypedArray
                    // intercepts the index before any accessor behind it.
                    var cur: ?*JsObject = obj;
                    var depth: usize = 0;
                    while (cur) |c| {
                        if (depth >= 64) break;
                        depth += 1;
                        if (c.internal_kind == .typed_array) {
                            const td: *typed_array.TypedArrayData = @ptrCast(@alignCast(c.internal_slot.?));
                            if (sameObject(receiver, c)) {
                                try typed_array.setElementThrowing(self.arena, td, idx_f, value);
                                return true;
                            }
                            if (!typed_array.isValidIntegerIndex(td, idx_f)) return true;
                            return try self.ordinarySetReceiverWrite(receiver, key, value);
                        }
                        // Ordinary own property at this level: let the existing
                        // findProperty logic below handle accessors/data/shadowing.
                        if (c.resolveOwnSlot(key) != null) break;
                        cur = c.proto;
                    }
                }
                if (obj.findProperty(key)) |loc| {
                    const a = loc.holder.attrAt(loc.slot);
                    if (a.is_accessor) {
                        const raw = if (loc.slot < loc.holder.slots.items.len) loc.holder.slots.items[loc.slot] else Value{};
                        const setter = accessorMember(raw, "set");
                        // Only invoke if setter is an actual callable (not undefined/null).
                        if (isCallable(setter)) _ = try self.callAccessor(setter, obj_val, &[_]Value{value});
                        return true; // accessor with no setter: sloppy no-op
                    }
                    if (loc.holder == obj) {
                        if (loc.slot < obj.attrs.items.len and !obj.attrs.items[loc.slot].writable) return true;
                        _ = obj.setOwnBySlot(obj.shapePtr(), loc.slot, value);
                        return true;
                    }
                    // inherited data property: fall through to create an own (shadow).
                }
                try obj.set(key, value);
                return true;
            },
            // W2 unification: bc functions store own properties (incl.
            // `C.prototype = ...`) on their backing object.
            .bc_function => |closure| {
                const o = try self.closureBackingObj(closure);
                try o.set(key, value);
                return true;
            },
            else => return true,
        }
    }

    /// OrdinarySet's receiver-write step: CreateDataProperty(Receiver, P, V) when
    /// the Receiver has no own P, or a value update when it owns a writable data
    /// property. Returns false (failed assignment) for an own accessor, a
    /// non-writable own data property, or a non-extensible Receiver lacking P.
    /// A Proxy Receiver routes through its [[DefineOwnProperty]] trap; a
    /// TypedArray Receiver validates the integer index and coerces+stores.
    fn ordinarySetReceiverWrite(self: *BcVm, receiver: Value, key: []const u8, value: Value) anyerror!bool {
        if (receiver.bits == 0 or receiver.unbox() != .object) return false;
        const robj = receiver.toPtr().object;
        if (robj.internal_kind == .proxy) {
            return try self.proxyDefineDataProperty(robj, key, value);
        }
        if (robj.internal_kind == .typed_array) {
            if (typed_array.canonicalNumericIndexString(key)) |idx_f| {
                const td: *typed_array.TypedArrayData = @ptrCast(@alignCast(robj.internal_slot.?));
                if (!typed_array.isValidIntegerIndex(td, idx_f)) return false;
                try typed_array.setElementThrowing(self.arena, td, idx_f, value);
                return true;
            }
        }
        if (robj.resolveOwnSlot(key)) |slot| {
            const a = robj.attrAt(slot);
            if (a.is_accessor) return false;
            if (!a.writable) return false;
            _ = robj.setOwnBySlot(robj.shapePtr(), slot, value);
            return true;
        }
        if (!robj.extensible) return false;
        try robj.set(key, value); // CreateDataProperty (updates array length too)
        return true;
    }

    /// CreateDataProperty on a Proxy Receiver: dispatch the `defineProperty` trap
    /// with a full data descriptor, or forward to the target when no trap exists.
    fn proxyDefineDataProperty(self: *BcVm, proxy_obj: *JsObject, key: []const u8, value: Value) anyerror!bool {
        const handler = proxy_mod.proxyHandler(proxy_obj) orelse return false;
        const target = proxy_mod.proxyTarget(proxy_obj) orelse return false;
        if (proxy_mod.trap(handler, "defineProperty")) |trap_fn| {
            const key_v = try val_mod.makeString(self.arena, key);
            const desc = try self.makeDataDescriptor(value);
            const res = try self.callAccessor(trap_fn, handler, &[_]Value{ target, key_v, desc });
            return isTruthy(res);
        }
        return try self.ordinarySetReceiverWrite(target, key, value);
    }

    /// Build `{ value, writable: true, enumerable: true, configurable: true }`.
    fn makeDataDescriptor(self: *BcVm, value: Value) !Value {
        const o = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        const t = try val_mod.makeBool(self.arena, true);
        try o.set("value", value);
        try o.set("writable", t);
        try o.set("enumerable", t);
        try o.set("configurable", t);
        return val_mod.makeObject(self.arena, o);
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
        const saved_floor = self.frame_floor;
        self.frame_floor = frames_before;
        defer self.frame_floor = saved_floor;
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
    pub fn tryOsrLoop(self: *BcVm, func: *const BcFunction, jmp_pc: usize, env: *Environment, registers: []Value) !?usize {
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

    pub fn doCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
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
                try self.defineArguments(call_env, fn_ptr, frame.registers[@as(usize, base) + 1 ..][0..@as(usize, nargs)]);
                try self.bindRestParam(call_env, fn_ptr, frame.registers[@as(usize, base) + 1 ..][0..@as(usize, nargs)]);

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
                if (self.frames.items.len > 0) {
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                }
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
                        // Re-entrant entry (a native invoked us with no caller frame on
                        // the stack) → route the result back through `self.result`,
                        // which `bcInvokeJs` returns; avoids a `len - 1` underflow.
                        if (self.frames.items.len > 0) {
                            self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        } else {
                            self.result = res;
                        }
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
                            const result = fn_ptr.invoke(self.arena, this_val_call, args) catch |e| {
                                // Propagate a real JS throw (e.g. BigInt(1.5) → RangeError)
                                // instead of masking it with a generic TypeError.
                                if (e == error.JsException) {
                                    const realm_mod = @import("../runtime/realm.zig");
                                    if (realm_mod.pending_exception.bits != 0) {
                                        self.last_exception_value = realm_mod.pending_exception;
                                        realm_mod.pending_exception = Value{};
                                    }
                                    return "__js_exception__";
                                }
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
    pub fn doMethodCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
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
                try self.defineArguments(call_env, fn_ptr, frame.registers[@as(usize, base) + 2 ..][0..@as(usize, nargs)]);
                try self.bindRestParam(call_env, fn_ptr, frame.registers[@as(usize, base) + 2 ..][0..@as(usize, nargs)]);

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
                if (self.frames.items.len > 0) {
                    self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                }
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
                        // Re-entrant entry (a native invoked us with no caller frame on
                        // the stack) → route the result back through `self.result`,
                        // which `bcInvokeJs` returns; avoids a `len - 1` underflow.
                        if (self.frames.items.len > 0) {
                            self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        } else {
                            self.result = res;
                        }
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

    /// M14: materialize an `arguments` array-like object in the call env when the
    /// callee references `arguments` (and is not an arrow). Unmapped form: a plain
    /// object with indexed elements 0..n-1, a `length`, and an `@@iterator` so
    /// `for (x of arguments)` works. Skipped when a parameter is literally named
    /// `arguments` (that binding wins per spec). No-op for the common case.
    pub fn defineArguments(self: *BcVm, env: *Environment, fn_ptr: *const BcFunction, args: []const Value) !void {
        if (!fn_ptr.uses_arguments) return;
        for (fn_ptr.param_names) |p| {
            if (std.mem.eql(u8, p, "arguments")) return;
        }
        const obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        for (args, 0..) |a, i| {
            const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
            try obj.set(key, a);
        }
        try obj.set("length", try val_mod.makeNumber(self.arena, @floatFromInt(args.len)));
        // for-of over arguments: the Array iterator works on any array-like
        // (reads length + indexed). Install it under the real @@iterator symbol.
        const realm_mod = @import("../runtime/realm.zig");
        if (realm_mod.active_sym_iterator) |symv| {
            const coll = @import("../runtime/builtins/es2015_collections.zig");
            try obj.setSym(symv, try val_mod.makeNativeFunction(self.arena, coll.nativeArrayValues));
        }
        try env.define("arguments", try val_mod.makeObject(self.arena, obj));
    }

    /// Bind a rest parameter (`function f(a, ...rest)`) to an Array of the
    /// arguments past the declared (non-rest) parameter count.
    pub fn bindRestParam(self: *BcVm, env: *Environment, fn_ptr: *const BcFunction, args: []const Value) !void {
        const rest_name = fn_ptr.rest_param orelse return;
        const n = fn_ptr.param_names.len;
        const arr = if (self.heap) |heap|
            try JsObject.createArrayOnHeap(heap, self.realm.array_prototype)
        else
            try JsObject.createArray(self.arena, self.realm.array_prototype);
        arr.is_array = true;
        if (args.len > n) {
            var i: usize = n;
            while (i < args.len) : (i += 1) {
                const key = try std.fmt.allocPrint(self.arena, "{d}", .{i - n});
                try arr.set(key, args[i]);
            }
            arr.array_length = @intCast(args.len - n);
        } else {
            arr.array_length = 0;
        }
        try env.define(rest_name, try val_mod.makeObject(self.arena, arr));
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
        try self.defineArguments(call_env, fn_ptr, args);
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
        // Re-entrant resume (generator resuming itself) → TypeError, not recursion.
        if (state.executing) {
            return SuspendResult{ .threw = try self.makeErrorObjectBc("TypeError", "Generator is already running") };
        }
        state.executing = true;
        defer state.executing = false;
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
        // Re-entrancy boundary: an uncaught throw inside the coroutine surfaces
        // to the .next()/.throw() caller, not into the resumer's outer frames.
        const saved_floor = self.frame_floor;
        self.frame_floor = base;
        defer self.frame_floor = saved_floor;
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

    pub fn jsAdd(self: *BcVm, left: Value, right: Value) !Value {
        // ES2015 11.6.1: lprim = ToPrimitive(left), rprim = ToPrimitive(right),
        // both with the "default" hint, before deciding string vs numeric.
        const lp = (try self.coerceToPrimitive(left, .default)) orelse left;
        const rp = (try self.coerceToPrimitive(right, .default)) orelse right;
        const ls = isStringOrObject(lp);
        const rs = isStringOrObject(rp);
        if (ls or rs) {
            // String branch: ? ToString(lprim) / ? ToString(rprim). Unlike the
            // explicit String() constructor, implicit ToString throws on a Symbol.
            if (isSymbol(lp) or isSymbol(rp))
                return self.throwTypeErr("Cannot convert a Symbol value to a string");
            const ls_str = try valueToString(self.arena, lp);
            const rs_str = try valueToString(self.arena, rp);
            const combined = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls_str, rs_str });
            return val_mod.makeString(self.arena, combined);
        }
        // BigInt + BigInt → BigInt add; one BigInt mixed with a non-BigInt
        // (and non-string, handled above) → TypeError.
        const lbig = isBigOperand(lp);
        const rbig = isBigOperand(rp);
        if (lbig or rbig) {
            if (lbig != rbig) return self.throwTypeErr("Cannot mix BigInt and other types, use explicit conversions");
            return val_mod.bigIntBinary(self.arena, lp, rp, .add);
        }
        // Numeric branch: ? ToNumber on each operand, which throws on a Symbol.
        if (isSymbol(lp) or isSymbol(rp))
            return self.throwTypeErr("Cannot convert a Symbol value to a number");
        return val_mod.makeNumber(self.arena, toNumber(lp) + toNumber(rp));
    }

    /// True when `v` is a Symbol value.
    fn isSymbol(v: Value) bool {
        return v.bits != 0 and v.unbox() == .symbol;
    }

    /// True when `v` is a BigInt value.
    pub fn isBigOperand(v: Value) bool {
        return v.bits != 0 and v.unbox() == .bigint;
    }

    /// SUB/MUL/DIV/MOD on BigInt operands (at least one is a BigInt). Both BigInt →
    /// result; mixed with a non-BigInt → TypeError; zero divisor → RangeError.
    pub fn bigIntArithChecked(self: *BcVm, lv: Value, rv: Value, op: val_mod.BigOp) !Value {
        if (isBigOperand(lv) != isBigOperand(rv))
            return self.throwTypeErr("Cannot mix BigInt and other types, use explicit conversions");
        return val_mod.bigIntBinary(self.arena, lv, rv, op) catch |e| {
            if (e == error.DivisionByZero) return self.throwRangeErr("Division by zero");
            return e;
        };
    }

    /// Bitwise/shift on BigInt operands. Both BigInt → result; mixed → TypeError;
    /// over-large shift count → RangeError.
    pub fn bigIntBitChecked(self: *BcVm, lv: Value, rv: Value, op: val_mod.BigBitOp) !Value {
        if (isBigOperand(lv) != isBigOperand(rv))
            return self.throwTypeErr("Cannot mix BigInt and other types, use explicit conversions");
        return val_mod.bigIntBitwise(self.arena, lv, rv, op) catch |e| {
            if (e == error.Overflow) return self.throwRangeErr("BigInt shift count is too large");
            return e;
        };
    }

    /// ToNumber that honors user-defined ToPrimitive(number) on objects.
    /// For non-objects this is exactly `toNumber`.
    pub fn toNumberCoerced(self: *BcVm, v: Value) !f64 {
        const p = (try self.coerceToPrimitive(v, .number)) orelse v;
        return toNumber(p);
    }

    /// ToPrimitive(number) for relational comparison; returns `v` unchanged
    /// when no user hook applies.
    pub fn coerceForRelational(self: *BcVm, v: Value) !Value {
        return (try self.coerceToPrimitive(v, .number)) orelse v;
    }

    /// ToInt32 honoring user-defined ToPrimitive(number) on objects.
    pub fn toInt32Coerced(self: *BcVm, v: Value) !i32 {
        const p = (try self.coerceToPrimitive(v, .number)) orelse v;
        return toInt32(p);
    }

    /// ToUint32 honoring user-defined ToPrimitive(number) on objects.
    pub fn toUint32Coerced(self: *BcVm, v: Value) !u32 {
        return @bitCast(try self.toInt32Coerced(v));
    }

    /// Throw a `TypeError` (sets pending_exception, returns error.JsException).
    pub fn throwTypeErr(self: *BcVm, msg: []const u8) anyerror {
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
    pub fn expOp(self: *BcVm, lv: Value, rv: Value) !Value {
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

/// Parse `key` as a canonical array index (the decimal form of a non-negative
/// integer, no sign / leading zeros / decimal point). Returns null otherwise.
/// "0" → 0; "00", "+1", "1.0", "01" → null.
fn asArrayIndex(key: []const u8) ?usize {
    if (key.len == 0) return null;
    if (key.len > 1 and key[0] == '0') return null; // no leading zeros
    var v: usize = 0;
    for (key) |c| {
        if (c < '0' or c > '9') return null;
        v = std.math.mul(usize, v, 10) catch return null;
        v = std.math.add(usize, v, c - '0') catch return null;
    }
    return v;
}

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

pub fn isNumberValue(v: Value) bool {
    return v.bits != 0 and v.unbox() == .number;
}

/// True when `v` is an operand kind that may carry a user-defined ToPrimitive
/// hook needing a slow, JS-reentrant coercion path: a plain object, or a bc
/// function (callable object whose own props + Function.prototype.toString are
/// reachable via its backing object).
pub fn isObjectOperand(v: Value) bool {
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

pub fn classifyTypeof(v: Value) struct {
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

pub fn jsInstanceofWithTarget(lhs: Value, target_proto: ?*JsObject) bool {
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

pub fn valueToStringArena(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return valueToString(arena, v);
}

/// Format a thrown value as a user-facing exception message.
/// Error-like objects (have own `name` and `message` properties) format as
/// "Name: message" instead of the default "[object Object]" coercion.
pub fn formatExceptionMessage(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits != 0) {
        if (v.unbox() == .object) {
            const obj = v.toPtr().object;
            const name_v = obj.get("name") orelse (if (obj.proto) |p| p.get("name") else null);
            const msg_v = obj.get("message") orelse (if (obj.proto) |p| p.get("message") else null);
            if (name_v != null and msg_v != null) {
                const name_s = try valueToString(arena, name_v.?);
                const msg_s = try valueToString(arena, msg_v.?);
                return std.fmt.allocPrint(arena, "{s}: {s}", .{ name_s, msg_s });
            }
            // Error-like with only a message (e.g. Test262Error): surface it.
            if (msg_v != null) {
                const ctor_name = if (obj.proto) |p| (if (p.get("constructor")) |c|
                    (if (c.bits != 0 and c.unbox() == .object) (c.toPtr().object.get("name") orelse Value{}) else Value{})
                else Value{}) else Value{};
                const msg_s = try valueToString(arena, msg_v.?);
                if (ctor_name.bits != 0 and ctor_name.unbox() == .string)
                    return std.fmt.allocPrint(arena, "{s}: {s}", .{ ctor_name.unbox().string, msg_s });
                return msg_s;
            }
        }
    }
    return valueToString(arena, v);
}

pub fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    // Delegate to the canonical ECMAScript Number::toString (value.zig).
    return val_mod.formatNumber(arena, n);
}

pub fn jsLessThan(left: Value, right: Value) ?bool {
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

/// BigInt == Number (spec): equal iff the Number is a finite integer whose
/// mathematical value equals the BigInt. NaN/±Inf/non-integers are never equal.
fn bigIntEqualsNumber(arena: std.mem.Allocator, big: Value, num: f64) bool {
    if (!std.math.isFinite(num) or num != @trunc(num)) return false;
    const yb = if (num >= -9.0e18 and num <= 9.0e18)
        (val_mod.makeBigIntFromI64(arena, @intFromFloat(num)) catch return false)
    else blk: {
        const s = std.fmt.allocPrint(arena, "{d}", .{num}) catch return false;
        break :blk (val_mod.makeBigIntFromLiteral(arena, s) catch return false);
    };
    return val_mod.bigIntEql(big, yb);
}

/// BigInt == String (spec): StringToBigInt(string); equal iff it parses to a
/// BigInt mathematically equal to `big`. Unparseable strings are never equal.
fn bigIntEqualsString(arena: std.mem.Allocator, big: Value, s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
    const body = if (t.len > 0 and t[0] == '+') t[1..] else t;
    const yb = if (body.len == 0)
        (val_mod.makeBigIntFromI64(arena, 0) catch return false)
    else
        (val_mod.makeBigIntFromLiteral(arena, body) catch return false);
    return val_mod.bigIntEql(big, yb);
}

pub fn jsAbstractEqual(x: Value, y: Value) bool {
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

pub fn jsStrictEqual(x: Value, y: Value) bool {
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
