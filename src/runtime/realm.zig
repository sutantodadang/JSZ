// SPDX-License-Identifier: Apache-2.0
//! Phase 3a/3b/4a/4b Realm: holds global Environment, Object.prototype, Array.prototype,
//! the Object constructor, Error constructors, Math, JSON, String/Array/Object builtins,
//! and (Phase 3b) the GC Heap.
const std = @import("std");
const Environment = @import("./execution_context.zig").Environment;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const obj_mod = @import("../object/object.zig");
const JsObject = @import("../object/object.zig").JsObject;
const Heap = @import("../gc/heap.zig").Heap;
// Milestone 16 (ESM) — Phase 1 module records.
const module_mod = @import("./module.zig");
pub const ModuleRecord = module_mod.ModuleRecord;
pub const ModuleRegistry = module_mod.ModuleRegistry;
pub const ModuleStatus = module_mod.ModuleStatus;

// Phase 4b builtin modules
const string_proto_mod = @import("./builtins/string_proto.zig");
const array_proto_mod = @import("./builtins/array_proto.zig");
const math_mod = @import("./builtins/math.zig");
const json_mod = @import("./builtins/json.zig");
const obj_methods_mod = @import("./builtins/object_methods.zig");
// Phase 4c
const regexp_mod = @import("./builtins/regexp.zig");
// Phase 4d
const function_proto_mod = @import("./builtins/function_proto.zig");
const date_mod = @import("./builtins/date.zig");
const temporal_mod = @import("./builtins/temporal/temporal.zig");
const es2015_collections_mod = @import("./builtins/es2015_collections.zig");
const typed_array_mod = @import("./builtins/typed_array.zig");
const intrinsics = @import("./builtins/intrinsics.zig");
const promise_mod = @import("./builtins/promise.zig");
const console_mod = @import("./builtins/console.zig");
// ES2015 Symbol
const symbol_mod = @import("./builtins/symbol.zig");
// ES2015 Reflect
const reflect_mod = @import("./builtins/reflect.zig");
// Phase 13 ToPrimitive (Symbol.toPrimitive / valueOf / toString)
const coercion_mod = @import("./builtins/coercion.zig");
// Phase 13 Proxy
const proxy_mod = @import("./builtins/proxy.zig");
// M16 Phase 4 ShadowRealm
const shadow_realm_mod = @import("./builtins/shadow_realm.zig");
const disposable_stack_mod = @import("./builtins/disposable_stack.zig");
// Phase 13 Intl
const intl_mod = @import("./builtins/intl.zig");
const segmenter_mod = @import("./builtins/segmenter.zig");
const builtinLength = @import("./builtins/builtin_lengths.zig").builtinLength;

// ---------------------------------------------------------------- Context interface ---

/// Opaque context that allows native callbacks to re-enter the JS interpreter.
/// Set by both VMs at their eval entry point, cleared on exit.
pub const Context = struct {
    /// Opaque pointer to the VM instance.
    ptr: *anyopaque,
    /// Invoke a JS function value with given this/args. Returns Value or sets
    /// pending_exception + returns error.JsException.
    invoke_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value,
    /// Construct a value with given args. Returns Value or sets pending_exception
    /// and returns error.JsException.
    construct_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, ctor_val: Value, args: []const Value) anyerror!Value,
    /// Compile + run `source` in the global scope and return its completion value
    /// (the value of the last expression). Sets pending_exception + returns
    /// error.JsException on a parse error or an uncaught throw.
    eval_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, source: []const u8) anyerror!Value,
    /// Read a property by string key, firing accessor getters / Proxy traps and
    /// walking the prototype chain (full [[Get]]). Propagates JS throws.
    get_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value,
    /// Construct `ctor` with an explicit NewTarget (supplies `[[Prototype]]` via
    /// GetPrototypeFromConstructor). Used by Reflect.construct.
    construct_nt_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, ctor_val: Value, args: []const Value, new_target: Value) anyerror!Value,
    /// Read a SYMBOL-keyed property, firing accessor getters / Proxy traps and
    /// walking the prototype chain (full [[Get]]). Propagates JS throws.
    get_sym_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, sym_key: Value) anyerror!Value,
    /// Write a property by string key, firing accessor setters / Proxy traps /
    /// TypedArray integer-index exotic [[Set]] (full [[Set]]). Propagates throws.
    set_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void,
    /// [[Set]](O, key, value) with Throw=true: like `set_fn` but a failed
    /// assignment (non-writable data, accessor without setter, Proxy `set` trap
    /// returning false, non-extensible add) raises a TypeError instead of being a
    /// silent no-op. Mirrors a strict-mode assignment.
    set_throw_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void,
    /// HasProperty(O, key): own-or-inherited existence check firing Proxy `has`
    /// traps. Used by array methods to skip holes (absent indices).
    has_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool,

    /// [[Delete]] returning the boolean result (Proxy trap aware).
    delete_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool,
    /// Set [[Prototype]] of an object OR bc_function (materializing the closure's
    /// backing object). Used by Object.setPrototypeOf for class static inheritance.
    set_proto_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, proto: ?*JsObject) anyerror!void,
    /// Resolve a value to its property-bearing JsObject: an object returns
    /// itself; a bc_function materializes (lazily creates) its backing object;
    /// non-property-bearing values (primitives, native_function) return null.
    /// Lets generic object ops (defineProperty, getOwnPropertyDescriptor) treat
    /// functions as the objects they are.
    backing_obj_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, val: Value) anyerror!?*JsObject,
    /// ShadowRealm: compile + run `source` as Script code in the supplied global
    /// `Environment` (a shadow realm's global env, passed as an opaque pointer),
    /// returning its completion value. A parse failure of `source` sets
    /// pending_exception (a SyntaxError) and returns `error.ShadowParseError` so
    /// the caller can distinguish it from a runtime throw (`error.JsException`).
    shadow_eval_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, source: []const u8, global_env: *anyopaque) anyerror!Value,

    /// Per-realm generator chain hook: build the lazily-created generator/async-generator
    /// intrinsic chain for `realm` (an opaque *Realm). No-op if already built.
    ensure_gen_chain_fn: *const fn (ptr: *anyopaque, realm: *anyopaque) anyerror!void,
    /// Cross-realm (`$262.createRealm`): build a fully independent secondary Realm
    /// sharing the isolate's heap, and return a JS record `{global, evalScript}`
    /// (a `*JsObject` Value). The host owns the realm lifetime (isolate arena).
    create_realm_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator) anyerror!Value,

    pub fn ensureGenChain(self: *Context, realm: *anyopaque) anyerror!void {
        return self.ensure_gen_chain_fn(self.ptr, realm);
    }

    pub fn createRealm(self: *Context, arena: std.mem.Allocator) anyerror!Value {
        return self.create_realm_fn(self.ptr, arena);
    }

    pub fn backingObject(self: *Context, arena: std.mem.Allocator, val: Value) anyerror!?*JsObject {
        return self.backing_obj_fn(self.ptr, arena, val);
    }

    pub fn invokeJs(self: *Context, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
        if (stackExhausted()) return throwStackOverflow(arena);
        return self.invoke_fn(self.ptr, arena, this_val, fn_val, args);
    }

    pub fn construct(self: *Context, arena: std.mem.Allocator, ctor_val: Value, args: []const Value) anyerror!Value {
        if (stackExhausted()) return throwStackOverflow(arena);
        return self.construct_fn(self.ptr, arena, ctor_val, args);
    }

    pub fn evalSource(self: *Context, arena: std.mem.Allocator, source: []const u8) anyerror!Value {
        return self.eval_fn(self.ptr, arena, source);
    }

    pub fn getProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value {
        return self.get_fn(self.ptr, arena, obj_val, key);
    }

    pub fn constructNewTarget(self: *Context, arena: std.mem.Allocator, ctor_val: Value, args: []const Value, new_target: Value) anyerror!Value {
        if (stackExhausted()) return throwStackOverflow(arena);
        return self.construct_nt_fn(self.ptr, arena, ctor_val, args, new_target);
    }

    pub fn getPropSym(self: *Context, arena: std.mem.Allocator, obj_val: Value, sym_key: Value) anyerror!Value {
        return self.get_sym_fn(self.ptr, arena, obj_val, sym_key);
    }

    pub fn setProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void {
        return self.set_fn(self.ptr, arena, obj_val, key, value);
    }

    pub fn setPropThrow(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void {
        return self.set_throw_fn(self.ptr, arena, obj_val, key, value);
    }

    pub fn hasProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool {
        return self.has_fn(self.ptr, arena, obj_val, key);
    }

    pub fn deleteProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool {
        return self.delete_fn(self.ptr, arena, obj_val, key);
    }

    pub fn setProto(self: *Context, arena: std.mem.Allocator, obj_val: Value, proto: ?*JsObject) anyerror!void {
        return self.set_proto_fn(self.ptr, arena, obj_val, proto);
    }

    pub fn shadowEval(self: *Context, arena: std.mem.Allocator, source: []const u8, global_env: *anyopaque) anyerror!Value {
        return self.shadow_eval_fn(self.ptr, arena, source, global_env);
    }
};

/// Milestone 16 (ESM) — Phase 1: evaluate a registered module through the
/// active VM `Context`, driving the spec resolve→link→evaluate lifecycle on its
/// `ModuleRecord`.
///
/// Phase 1 reuses the import/export → CommonJS `require`/`exports` desugaring
/// already produced by `Parser.parseModule`, so "linking" is whatever the
/// `__modules__` registry + `require()` resolver perform at runtime; this
/// function owns the record's status transitions, dedup (an already-`evaluated`
/// record returns its cached namespace), cyclic-import guarding (a re-entered
/// `.evaluating` record returns its partial namespace rather than re-running),
/// and error capture. `rec.source` is evaluated as module code via the host
/// `Context.evalSource` re-entry point.
pub fn evalModule(
    ctx: *Context,
    arena: std.mem.Allocator,
    registry: *ModuleRegistry,
    entry_id: []const u8,
) anyerror!Value {
    const rec = registry.get(entry_id) orelse return error.ModuleNotFound;
    switch (rec.status) {
        .evaluated => return rec.namespace,
        // Cyclic re-entry: hand back the in-progress namespace (partial exports).
        .evaluating => return rec.namespace,
        .errored => {
            pending_exception = rec.eval_error;
            return error.JsException;
        },
        else => {},
    }
    rec.status = .evaluating;
    const result = ctx.evalSource(arena, rec.source) catch |err| {
        rec.status = .errored;
        rec.eval_error = pending_exception;
        return err;
    };
    rec.namespace = result;
    rec.status = .evaluated;
    return result;
}

/// Thread-local pointer to the currently active Context (set by VMs at eval entry).
pub var active_context: ?*Context = null;

/// Wall-clock deadline (ns, `std.time.nanoTimestamp` epoch) for the current eval,
/// mirrored from the bc VM so long native loops (e.g. Array.prototype methods over
/// a huge/sparse length) can be interrupted just like bytecode loops. 0 = no limit.
pub var native_deadline_ns: i128 = 0;

/// Cheap periodic deadline check for hot native loops. Only samples the clock
/// every 8192 calls (clock reads are relatively expensive); returns true once the
/// eval's wall-clock deadline has passed. Callers return `error.OutOfMemory` (the
/// Test262 runner treats both "out of memory" and "interrupted:" as skip), which
/// unwinds the native loop instead of letting it run for billions of iterations.
var native_deadline_counter: u32 = 0;
pub fn nativeDeadlineExceeded() bool {
    if (native_deadline_ns == 0) return false;
    native_deadline_counter +%= 1;
    if (native_deadline_counter & 0x1FFF != 0) return false;
    return std.time.nanoTimestamp() >= native_deadline_ns;
}

/// Thread-local reentrant callback depth counter.
pub var callback_depth: u32 = 0;

/// Highest C-stack address seen inside the engine — an approximation of where
/// the stack began. The bytecode VM keeps its call frames on the heap, so plain
/// JS recursion costs no C stack; but every native round trip back into JS (a
/// `Reflect.construct` driving `super()`, a Proxy trap, an accessor) costs real
/// frames, and 8 MiB runs out well before `callback_depth` reaches its cap.
var stack_base: usize = 0;

/// Refuse re-entry once this much C stack has been consumed, leaving room for
/// the throw path itself to unwind on the default 8 MiB thread stack.
const stack_budget_bytes: usize = 5 * 1024 * 1024;

/// True when a further native → JS re-entry would risk overflowing the C stack.
pub fn stackExhausted() bool {
    const sp = @frameAddress();
    if (sp > stack_base) {
        stack_base = sp;
        return false;
    }
    return stack_base - sp > stack_budget_bytes;
}

fn throwStackOverflow(arena: std.mem.Allocator) anyerror {
    const obj = if (active_heap) |heap|
        JsObject.createOnHeap(heap, rangeErrorProto()) catch null
    else
        JsObject.create(arena, rangeErrorProto()) catch null;
    if (obj) |err_obj| {
        err_obj.set("message", val_mod.makeString(arena, "Maximum call stack size exceeded") catch Value{}) catch {};
        err_obj.set("name", val_mod.makeString(arena, "RangeError") catch Value{}) catch {};
        pending_exception = val_mod.makeObject(arena, err_obj) catch Value{};
    }
    return error.JsException;
}

// ---------------------------------------------------------------- natives ---

/// Object.create(proto): creates a new object with the given prototype.
/// Phase 3b: allocates on the GC heap so the object participates in mark-sweep.
fn nativeObjectCreate(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // We cannot access the Heap from here without threading it through.
    // Workaround: use a thread-local reference to the active heap.
    // This is safe because native functions are only called during eval,
    // when exactly one Realm (and heap) is live per thread.
    // ES §20.1.2.2: the prototype argument must be an Object or null; any other
    // value (including undefined / a missing argument) is a TypeError.
    var proto: ?*JsObject = null;
    if (args.len == 0 or args[0].bits == 0) {
        return throwTypeError(arena, "Object prototype may only be an Object or null");
    }
    switch (args[0].unbox()) {
        .object => |obj| proto = obj,
        .null_ => proto = null,
        // A callable IS an Object; it just isn't a `.object` value here. Resolve
        // it to its backing object so `Object.create(someFunction)` links the
        // chain instead of throwing (mirrors Object.setPrototypeOf).
        .bc_function, .function, .native_function => proto = if (active_context) |ctx|
            (try ctx.backingObject(arena, args[0]))
        else
            null,
        else => return throwTypeError(arena, "Object prototype may only be an Object or null"),
    }
    // Allocate on the active heap if available, otherwise fallback to arena.
    // Always use `arena` for the JsValue wrapper (it's eval-arena-lifetime).
    const obj_val = if (active_heap) |heap|
        try val_mod.makeObject(arena, try JsObject.createOnHeap(heap, proto))
    else
        // Fallback: arena (when heap not yet wired, e.g., tree-walker path).
        try val_mod.makeObject(arena, try JsObject.create(arena, proto));

    // ES §20.1.2.2 step 3: if Properties is present (not undefined), apply
    // ObjectDefineProperties. Reuse the tested defineProperties implementation.
    if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) {
        _ = try obj_methods_mod.nativeObjectDefineProperties(arena, Value{}, &.{ obj_val, args[1] });
    }
    return obj_val;
}

/// Minimal CommonJS-style host shim:
/// require(name) reads from global __modules__[name] when present.
fn nativeRequire(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return val_mod.makeUndefined(arena);
    }
    const name = args[0].toPtr().string;
    if (std.process.hasEnvVarConstant("JSZ_DBG")) std.debug.print("REQUIRE {s}\n", .{name});
    const env = active_global_env orelse return val_mod.makeUndefined(arena);
    if (std.mem.eql(u8, name, "module")) {
        return env.lookup("module") catch return val_mod.makeUndefined(arena);
    }
    if (std.mem.eql(u8, name, "exports")) {
        if (env.lookup("module")) |m| {
            if (m.bits != 0 and m.unbox() == .object) {
                if (m.toPtr().object.get("exports")) |e| return e;
            }
        } else |_| {}
        return val_mod.makeUndefined(arena);
    }
    const registry = env.lookup("__modules__") catch return throwModuleNotFound(arena, name);
    if (registry.bits == 0 or registry.unbox() != .object) return throwModuleNotFound(arena, name);
    const modules_obj = registry.toPtr().object;
    const resolved_name = resolveModuleName(arena, env, name) catch name;
    const lookup_name = if (modules_obj.get(resolved_name) != null) resolved_name else name;
    // Eager resolution error: a module whose static-import closure reaches a
    // missing file fails to load before it is ever evaluated.
    if (moduleIsUnresolvable(env, lookup_name) or moduleIsUnresolvable(env, resolved_name))
        return throwModuleNotFound(arena, name);
    if (modules_obj.get(lookup_name)) |entry| {
        if (entry.bits != 0 and entry.unbox() == .object) {
            const mod_obj = entry.toPtr().object;
            if (mod_obj.get("exports")) |exports_val| {
                // A module that threw during evaluation stays errored: re-require
                // re-throws the SAME error value (so an import-defer trigger, a
                // dynamic import(), and an eager import all observe one error).
                if (mod_obj.get("__evalError__")) |ev| {
                    if (ev.bits != 0) {
                        pending_exception = ev;
                        return error.JsException;
                    }
                }
                try syncRequireCache(env, lookup_name, entry);
                return exports_val;
            }
        }
        if (isCallableValue(entry)) {
            // CommonJS-style factory module: factory(require, module, exports)
            const module_obj = if (active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
            const exports_obj = if (active_heap) |h| try JsObject.createOnHeap(h, null) else try JsObject.create(arena, null);
            const exports_val = try val_mod.makeObject(arena, exports_obj);
            try module_obj.set("exports", exports_val);
            try module_obj.set("id", try val_mod.makeString(arena, lookup_name));
            try module_obj.set("loaded", try val_mod.makeBool(arena, false));
            const module_val = try val_mod.makeObject(arena, module_obj);
            // Cache BEFORE invoking the factory so cyclic require() sees the partial exports.
            try modules_obj.set(lookup_name, module_val);
            if (!std.mem.eql(u8, lookup_name, name)) {
                try modules_obj.set(name, module_val);
            }
            try syncRequireCache(env, lookup_name, module_val);
            const require_fn = env.lookup("require") catch try val_mod.makeUndefined(arena);
            const factory_ret = function_proto_mod.invokeCallback(
                arena,
                exports_val,
                entry,
                &[_]Value{ require_fn, module_val, exports_val },
            ) catch |err| {
                // Module evaluation threw: record the error on the module record so
                // a later require() (eager re-import or import-defer trigger)
                // re-throws the same value, and propagate it to this importer.
                if (err == error.JsException and pending_exception.bits != 0)
                    module_obj.set("__evalError__", pending_exception) catch {};
                return err;
            };
            // M16 TLA: an async-module factory returns its evaluation-completion
            // Promise (resolves when the module body, including top-level await,
            // finishes). Stash it so importers/`__awaitDeps__`/dynamic `import()`
            // can wait for the module to fully evaluate.
            const is_pending_async = factory_ret.bits != 0 and factory_ret.unbox() == .object and
                factory_ret.toPtr().object.internal_kind == .promise and
                promise_mod.isPending(factory_ret);
            if (factory_ret.bits != 0 and factory_ret.unbox() == .object and
                factory_ret.toPtr().object.internal_kind == .promise)
            {
                try module_obj.set("__evalPromise__", factory_ret);
            }
            const final_exports = module_obj.get("exports") orelse exports_val;
            // An async factory that suspended at an `await` is still ~evaluating-
            // async~: its body has not finished, so its record must NOT be marked
            // `loaded` yet (a deferred-namespace access of this still-running module
            // must throw — see EnsureDeferredNamespaceEvaluation / readyForSync).
            // Defer the flag to when the evaluation promise settles. A factory whose
            // promise is already settled (a fully synchronous-drained body) is done,
            // so mark it loaded right away.
            if (is_pending_async) {
                const setter = try val_mod.makeNativeFunction(arena, nativeSetModuleLoaded);
                const bound = try promise_mod.bindValueAsPrefix(arena, setter, module_val);
                _ = try promise_mod.nativePromiseThen(arena, factory_ret, &[_]Value{ bound, bound });
            } else {
                try module_obj.set("loaded", try val_mod.makeBool(arena, true));
            }
            return final_exports;
        }
        try syncRequireCache(env, lookup_name, entry);
        return entry;
    }
    return throwModuleNotFound(arena, name);
}

/// Mark a module record as `loaded` once its async evaluation promise settles.
/// `args[0]` is the module record bound as the reaction prefix; the second arg
/// (the settlement value/reason) is ignored — the record is `evaluated` whether
/// the body fulfilled or rejected.
fn nativeSetModuleLoaded(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len >= 1 and args[0].bits != 0 and args[0].unbox() == .object) {
        try args[0].toPtr().object.set("loaded", try val_mod.makeBool(arena, true));
    }
    return val_mod.makeUndefined(arena);
}

/// M16 Phase 2: wrap an imported module's live `exports` object in a Module
/// Namespace exotic object (ES §10.4.6). Emitted by the `import * as ns`
/// desugar as `var ns = __makeNamespace__(require('m'))`. A non-object argument
/// (a malformed/absent module) is returned unchanged.
pub fn nativeMakeNamespace(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) {
        if (args.len == 0) return val_mod.makeUndefined(arena);
        return args[0];
    }
    const exports_obj = args[0].toPtr().object;
    // Idempotent: a namespace passed back in stays the same namespace.
    if (exports_obj.internal_kind == .module_namespace) return args[0];
    // GetModuleNamespace: return the cached namespace for this module if one was
    // already created (stored under a private symbol on the live exports object,
    // invisible to the namespace's own string keys).
    if (active_sym_module_ns) |ns_sym| {
        if (exports_obj.getOwnSym(ns_sym)) |cached| return cached;
    }
    const ns = if (active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    ns.internal_kind = .module_namespace;
    ns.internal_slot = @ptrCast(exports_obj);
    // @@toStringTag = "Module" (non-writable, non-enumerable, non-configurable),
    // set before sealing so the append is permitted.
    if (active_sym_to_string_tag) |tag| {
        try ns.setSymAttr(tag, try val_mod.makeString(arena, "Module"), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
    }
    ns.extensible = false;
    const ns_val = try val_mod.makeObject(arena, ns);
    // Cache on the exports object so subsequent imports observe the same object.
    if (active_sym_module_ns) |ns_sym| try exports_obj.setSym(ns_sym, ns_val);
    return ns_val;
}

/// Deferred import: `import defer * as ns from 'm'` desugars to
/// `var ns = __importDefer__('m')`. Build a Module Namespace exotic object whose
/// backing module is NOT yet evaluated: it carries the canonical module id under
/// `active_sym_deferred_id` and an empty backing. A later triggering operation
/// (`[[Get]]`/`[[HasProperty]]`/`[[Delete]]`/`[[DefineOwnProperty]]`/
/// `[[GetOwnProperty]]`/`[[OwnPropertyKeys]]` on a non-symbol-like key) evaluates
/// the module and wires the live exports in. Symbol keys (and the deferred `then`)
/// never trigger evaluation.
pub fn nativeImportDefer(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string)
        return val_mod.makeUndefined(arena);
    const spec = args[0].toPtr().string;
    // Resolve to the canonical registry id NOW (we are in the importing module's
    // scope, so `__module_id__` is correct); the trigger then requires it directly.
    const env = active_global_env;
    const canonical = if (env) |e| (resolveModuleName(arena, e, spec) catch spec) else spec;
    // Import-defer × TLA: eagerly evaluate the deferred module's asynchronous
    // transitive dependencies (its top-level-await frontier, precomputed by the
    // bundler in `__deferGather__`). Per InnerModuleEvaluation these run eagerly,
    // in source order, while the deferred module itself stays unevaluated. Each
    // such module is an async factory, so requiring it kicks off (and suspends
    // at) its top-level await; the importer's `__awaitDeps__` barrier awaits them.
    if (env) |e| {
        if (e.lookup("__deferGather__")) |gv| {
            if (gv.bits != 0 and gv.unbox() == .object) {
                if (gv.toPtr().object.get(canonical)) |list_val| {
                    if (list_val.bits != 0 and list_val.unbox() == .object) {
                        const arr = list_val.toPtr().object;
                        const len = arr.getArrayLength();
                        var i: u32 = 0;
                        var buf: [16]u8 = undefined;
                        while (i < len) : (i += 1) {
                            const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
                            const id_val = arr.get(key) orelse continue;
                            if (id_val.bits == 0 or id_val.unbox() != .string) continue;
                            _ = try nativeRequire(arena, Value{}, &[_]Value{id_val});
                        }
                    }
                }
            }
        } else |_| {}
    }
    return getOrMakeDeferredNamespace(arena, canonical);
}

/// ImportCall step 4: `Let specifierString be ? ToString(specifier)`. The
/// argument is an arbitrary value, so an object's `toString`/`valueOf` runs
/// here and may throw — the caller turns that into a rejection (the spec's
/// IfAbruptRejectPromise), which is why this returns error.JsException with
/// `pending_exception` set rather than a canned TypeError.
fn importSpecifierString(arena: std.mem.Allocator, args: []const Value) anyerror![]const u8 {
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits != 0 and v.unbox() == .string) return v.toPtr().string;
    return array_proto_mod.valueToJsString(arena, v);
}

/// Reject a fresh promise with the exception a coercion just raised. The value
/// is whatever was thrown — `throw 'custom error'` rejects with that string, not
/// with an Error wrapping it.
fn rejectWithPending(arena: std.mem.Allocator) anyerror!Value {
    const exc = if (pending_exception.bits != 0) pending_exception else try val_mod.makeUndefined(arena);
    pending_exception = Value{};
    return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{exc});
}

/// Dynamic deferred import: `import.defer(spec)` returns a promise that fulfils
/// with the module's deferred namespace exotic object WITHOUT evaluating it (the
/// module body runs lazily on first triggering access). Loading is synchronous in
/// the bundler model, so the promise resolves immediately with the (cached)
/// deferred namespace — identical to the static `import defer` object.
pub fn nativeImportDeferDynamic(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const spec = importSpecifierString(arena, args) catch |e| {
        if (e != error.JsException) return e;
        return rejectWithPending(arena);
    };
    const env = active_global_env;
    const canonical = if (env) |e| (resolveModuleName(arena, e, spec) catch spec) else spec;
    const ns = try getOrMakeDeferredNamespace(arena, canonical);
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{ns});
}

/// Dynamic source-phase import: `import.source(spec)` (source-phase-imports).
/// EvaluateImportCall with phase=source still coerces the specifier first (an
/// abrupt ToString rejects with that exception), then asks the loaded module for
/// its [[ModuleSource]]. A Source Text Module Record's GetModuleSource always
/// throws a SyntaxError (§16.2.1.7.2) — and every module JSZ can load is a
/// source text module — so the promise rejects with a SyntaxError.
pub fn nativeImportSourceDynamic(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    _ = importSpecifierString(arena, args) catch |e| {
        if (e != error.JsException) return e;
        return rejectWithPending(arena);
    };
    const err_obj = if (active_heap) |h|
        try JsObject.createOnHeap(h, syntaxErrorProto())
    else
        try JsObject.create(arena, syntaxErrorProto());
    try err_obj.set("message", try val_mod.makeString(arena, "source phase imports are not available for source text modules"));
    const err = try val_mod.makeObject(arena, err_obj);
    return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{err});
}

/// GetModuleNamespace for the deferred phase: return the *single* deferred
/// namespace exotic object for a given canonical module id, creating it on first
/// request and caching it so static `import defer`, re-exported deferred
/// namespaces, and dynamic `import.defer()` of the same module all observe the
/// SAME object (identity per the proposal). The object is distinct from the
/// module's eager namespace (`__makeNamespace__`).
pub fn getOrMakeDeferredNamespace(arena: std.mem.Allocator, canonical: []const u8) anyerror!Value {
    // Identity cache, keyed by canonical id.
    if (active_deferred_ns_registry) |reg_val| {
        if (reg_val.bits != 0 and reg_val.unbox() == .object) {
            if (reg_val.toPtr().object.get(canonical)) |cached| return cached;
        }
    }
    const ns = if (active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    ns.internal_kind = .module_namespace;
    ns.internal_slot = null; // not yet evaluated
    // A deferred namespace's @@toStringTag is "Deferred Module" (not "Module"),
    // distinguishing it from an eager namespace; it persists after evaluation.
    if (active_sym_to_string_tag) |tag| {
        try ns.setSymAttr(tag, try val_mod.makeString(arena, "Deferred Module"), .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
    }
    if (active_sym_deferred_id) |sym|
        try ns.setSym(sym, try val_mod.makeString(arena, canonical));
    ns.extensible = false;
    const ns_val = try val_mod.makeObject(arena, ns);
    if (active_deferred_ns_registry) |reg_val| {
        if (reg_val.bits != 0 and reg_val.unbox() == .object) {
            try reg_val.toPtr().object.set(canonical, ns_val);
        }
    }
    return ns_val;
}

/// True when `o` is a deferred (not-yet-evaluated) module namespace.
pub fn isDeferredNamespace(o: *JsObject) bool {
    if (o.internal_kind != .module_namespace) return false;
    const sym = active_sym_deferred_id orelse return false;
    return o.getOwnSym(sym) != null;
}

/// True when module `id` is currently mid-evaluation: its record exists in
/// `__modules__` (cache-before-invoke) as a module object whose `loaded` flag is
/// still false (the factory is on the stack and has not returned). Used to detect
/// a deferred-namespace access of a self/cyclic module that is not yet finished.
fn moduleIsEvaluating(arena: std.mem.Allocator, id: []const u8) bool {
    const env = active_global_env orelse return false;
    const registry = env.lookup("__modules__") catch return false;
    if (registry.bits == 0 or registry.unbox() != .object) return false;
    const modules_obj = registry.toPtr().object;
    const resolved = resolveModuleName(arena, env, id) catch id;
    const entry = modules_obj.get(resolved) orelse modules_obj.get(id) orelse return false;
    if (entry.bits == 0 or entry.unbox() != .object) return false; // still a factory → not started
    const mod_obj = entry.toPtr().object;
    // A module record with exports but loaded===false is executing right now.
    if (mod_obj.get("exports") == null) return false;
    const loaded = mod_obj.get("loaded") orelse return false;
    return loaded.bits != 0 and loaded.unbox() == .boolean and loaded.unbox().boolean == false;
}

/// ReadyForSyncExecution (sec-EnsureDeferredNamespaceEvaluation): true when the
/// module identified by `id` may be evaluated synchronously right now — no module
/// in its transitive synchronous frontier is currently ~evaluating~ and none has
/// top-level await. Implemented by the bundle-emitted `__readyForSync__` helper,
/// which walks `__moduleGraph__` (resolved dep ids + [[HasTLA]]) and reads each
/// module's [[Status]] from its `__modules__` record without evaluating anything.
/// When the helper is absent (no relative-import bundle) we conservatively report
/// ready so an ordinary deferred access still evaluates.
fn readyForSyncExecution(arena: std.mem.Allocator, id: []const u8) bool {
    const env = active_global_env orelse return true;
    const helper = env.lookup("__readyForSync__") catch return true;
    if (!isCallableValue(helper)) return true;
    const id_val = val_mod.makeString(arena, id) catch return true;
    const ret = function_proto_mod.invokeCallback(arena, Value{}, helper, &[_]Value{id_val}) catch return true;
    return ret.bits != 0 and ret.unbox() == .boolean and ret.unbox().boolean;
}

/// True when module `id`'s record carries an `__evalPromise__` — i.e. it
/// evaluated as an async factory (top-level await, or a transitive async dep).
/// Used to decide whether a deferred trigger must drain microtasks to complete
/// the module body synchronously.
fn moduleHasEvalPromise(arena: std.mem.Allocator, id: []const u8) bool {
    const env = active_global_env orelse return false;
    const registry = env.lookup("__modules__") catch return false;
    if (registry.bits == 0 or registry.unbox() != .object) return false;
    const modules_obj = registry.toPtr().object;
    const resolved = resolveModuleName(arena, env, id) catch id;
    const entry = modules_obj.get(resolved) orelse modules_obj.get(id) orelse return false;
    if (entry.bits == 0 or entry.unbox() != .object) return false;
    const ep = entry.toPtr().object.get("__evalPromise__") orelse return false;
    return ep.bits != 0;
}

/// Evaluate a deferred namespace's module (EvaluateSync) and wire its live
/// exports as the backing, clearing the deferred marker so subsequent operations
/// see an ordinary, evaluated namespace. Idempotent / no-op for non-deferred.
pub fn triggerDeferredNamespace(arena: std.mem.Allocator, o: *JsObject) anyerror!void {
    const sym = active_sym_deferred_id orelse return;
    const id_val = o.getOwnSym(sym) orelse return;
    if (id_val.bits == 0 or id_val.unbox() != .string) return;
    // EvaluateSync / ReadyForSyncExecution: a deferred namespace whose module (or
    // any module in its transitive synchronous frontier) is currently mid-
    // evaluation — a cyclic/self access before the body has finished — or has
    // top-level await is NOT ready for synchronous execution, so the trigger
    // throws a TypeError instead of evaluating. The walk only inspects [[Status]]
    // and never evaluates a dependency (so e.g. a not-yet-reached module stays
    // unevaluated when the access throws). The stored id is already the canonical
    // registry id (resolved at `__importDefer__` time), matching __moduleGraph__.
    if (!readyForSyncExecution(arena, id_val.toPtr().string))
        return throwTypeError(arena, "Cannot access a deferred module namespace while the module is being evaluated");
    // We do NOT delete the marker before evaluating: the deferred namespace is
    // non-extensible, so we could not re-add it if evaluation throws. Instead the
    // marker is cleared only on SUCCESS (deleteOwnSym works on a non-extensible
    // object). A re-entrant access during the module body is safe — require()
    // caches the module before invoking its factory, so the nested trigger gets
    // the partial exports and returns without re-invoking. If evaluation throws,
    // the marker stays, so a later access re-triggers and require() re-throws the
    // SAME cached module error.
    const exports_val = try nativeRequire(arena, Value{}, &[_]Value{id_val});
    // Import-defer × TLA: an async deferred module (one with top-level await, or
    // that imports such a module) evaluates as an async factory whose body runs
    // across microtasks. Its asynchronous transitive dependencies were already
    // evaluated eagerly at `__importDefer__` time, so its remaining body has no
    // truly-pending work — draining the microtask queue here completes it
    // synchronously, so the triggering access observes a fully-evaluated module
    // (spec EvaluateSync / ReadyForSyncExecution). For a synchronous module the
    // require already ran the whole body and the queue holds nothing relevant.
    if (moduleHasEvalPromise(arena, id_val.toPtr().string))
        promise_mod.runMicrotasks(arena);
    if (exports_val.bits != 0 and exports_val.unbox() == .object) {
        // Wire the live exports as the backing. We do NOT register this object as
        // the module's eager namespace (active_sym_module_ns): a deferred namespace
        // is a distinct exotic object from the eager `import * as` namespace.
        o.internal_slot = @ptrCast(exports_val.toPtr().object);
        _ = o.deleteOwnSym(sym); // success: no longer deferred
    }
}

/// Trigger gate for a string-keyed operation: a deferred namespace evaluates for
/// any string key except the deferred-`then` (treated symbol-like by spec).
pub fn maybeTriggerDeferredStr(arena: std.mem.Allocator, o: *JsObject, key: []const u8) anyerror!void {
    if (!isDeferredNamespace(o)) return;
    if (std.mem.eql(u8, key, "then")) return;
    // Private names (`#x`) never trigger deferred evaluation: PrivateGet/PrivateSet
    // and the `#x in obj` brand check operate on private elements via
    // PrivateElementFind, which bypasses the namespace exotic [[Get]]/[[Has]]/etc.
    // JSZ models a private element as the property key "#x", so guard it here.
    if (key.len > 0 and key[0] == '#') return;
    try triggerDeferredNamespace(arena, o);
}

/// M16 Phase 5: define a live re-export getter on the exports object.
/// `__liveReexport__(exports, 'name', sourceObj, 'prop')` creates a getter
/// that reads `sourceObj.prop` at access time, making the re-export a live
/// binding to the source module's export. Used by `export { X as Y } from './mod'`.
pub fn nativeLiveReexport(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 4) return val_mod.makeUndefined(arena);
    if (args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeUndefined(arena);
    if (args[1].bits == 0 or args[1].unbox() != .string) return val_mod.makeUndefined(arena);
    if (args[2].bits == 0 or args[2].unbox() != .object) return val_mod.makeUndefined(arena);
    if (args[3].bits == 0 or args[3].unbox() != .string) return val_mod.makeUndefined(arena);

    const exports_obj = args[0].toPtr().object;
    const name = args[1].toPtr().string;
    const source_obj = args[2].toPtr().object;
    const prop = args[3].toPtr().string;

    // Create a getter holder object: { get: nativeFn, source: sourceObj, prop: propName }
    // The getter reads source[prop] at access time.
    const getter_holder = try JsObject.create(arena, null);
    // Store the source and prop as hidden properties for the getter to use.
    // We need a native getter function that reads source[prop].
    // Since we can't create closures in native code, store source+prop on the holder
    // and use a generic getter that reads them back.
    try getter_holder.set("__source__", args[2]);
    try getter_holder.set("__prop__", args[3]);
    try getter_holder.set("get", try val_mod.makeNativeFunctionNamed(arena, liveReexportGetter, "get", 0));
    const holder_val = try val_mod.makeObject(arena, getter_holder);

    const ok = try exports_obj.defineOwnAccessor(name, holder_val, .{
        .enumerable = true,
        .configurable = true,
    });
    if (!ok) {
        // If define fails (non-configurable), fall back to direct assignment
        const val = source_obj.get(prop) orelse try val_mod.makeUndefined(arena);
        try exports_obj.set(name, val);
    }
    return val_mod.makeUndefined(arena);
}

/// Getter function for live re-exports: reads `this.__source__[this.__prop__]`.
fn liveReexportGetter(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return val_mod.makeUndefined(arena);
    const holder = this_val.toPtr().object;
    const source = holder.get("__source__") orelse return val_mod.makeUndefined(arena);
    const prop_val = holder.get("__prop__") orelse return val_mod.makeUndefined(arena);
    if (source.bits == 0 or source.unbox() != .object) return val_mod.makeUndefined(arena);
    if (prop_val.bits == 0 or prop_val.unbox() != .string) return val_mod.makeUndefined(arena);
    const prop = prop_val.toPtr().string;
    return source.toPtr().object.get(prop) orelse try val_mod.makeUndefined(arena);
}

/// M16 Phase 4: store a module's export names on its live exports object so the
/// namespace exotic can detect TDZ (known exports missing from the backing).
/// Called ONCE per module, immediately before the module body executes:
/// `__initExports__(exports, ["name1", "name2", ...])`
///   or: `__initExports__(exports, ["all", "names"], ["tdz", "names"])`
///
/// Stores the full export names list under a private symbol for hasExport and
/// sortedNames. When a third argument (TDZ-only names) is provided, only those
/// names get TDZ markers on the backing object (let/const/class are uninitialized
/// during instantiation; var/function are hoisted and NOT in TDZ). When only
/// two arguments are provided, all names get TDZ markers (backwards compat).
pub fn nativeInitExports(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len < 2) return val_mod.makeUndefined(arena);
    if (args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeUndefined(arena);
    if (args[1].bits == 0 or args[1].unbox() != .object) return val_mod.makeUndefined(arena);
    const exports_obj = args[0].toPtr().object;
    const names_arr = args[1].toPtr().object;
    // Store the export names array on the exports object as a symbol-keyed property
    // so the namespace exotic can read it to distinguish "known but uninitialized"
    // exports from non-exports.
    if (active_sym_export_names) |sym| {
        try exports_obj.setSym(sym, args[1]);
    }
    // When a third argument (TDZ-only names) is provided, store it separately
    // and only set TDZ markers for those names. Otherwise (backwards compat),
    // set markers for ALL names.
    var has_tdz_list = false;
    if (args.len >= 3 and args[2].bits != 0 and args[2].unbox() == .object) {
        const tdz_arr = args[2].toPtr().object;
        if (active_sym_tdz_export_names) |sym| {
            try exports_obj.setSym(sym, args[2]);
        }
        // Set TDZ markers only for names in the TDZ list
        const marker = tdz_marker orelse return val_mod.makeUndefined(arena);
        const n = tdz_arr.getArrayLength();
        var i: u32 = 0;
        var buf: [32]u8 = undefined;
        while (i < n) : (i += 1) {
            const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
            if (tdz_arr.get(idx_key)) |name_val| {
                if (name_val.bits != 0 and name_val.unbox() == .string) {
                    const name_str = name_val.toPtr().string;
                    try exports_obj.set(name_str, marker);
                }
            }
        }
        has_tdz_list = true;
        // Also set non-TDZ export names to undefined so they appear as own
        // properties on the exports object immediately.  This is critical for
        // circular `export * from` — __exportStar__ uses Object.keys(s) to
        // discover names, and var exports (hoisted to undefined) must be
        // visible before the module body runs.  Function exports are overwritten
        // by the pre-hoist (exports.NAME = NAME) that follows __initExports__.
        const undef = try val_mod.makeUndefined(arena);
        const nn = names_arr.getArrayLength();
        var ii: u32 = 0;
        var buf2: [32]u8 = undefined;
        // Build a set of TDZ names for quick lookup.
        var tdz_set = std.StringHashMap(void).init(arena);
        const tdz_n = tdz_arr.getArrayLength();
        var ti: u32 = 0;
        var tbuf: [32]u8 = undefined;
        while (ti < tdz_n) : (ti += 1) {
            const tkey = std.fmt.bufPrint(&tbuf, "{d}", .{ti}) catch break;
            if (tdz_arr.get(tkey)) |tv| {
                if (tv.bits != 0 and tv.unbox() == .string) {
                    tdz_set.put(tv.toPtr().string, {}) catch {};
                }
            }
        }
        while (ii < nn) : (ii += 1) {
            const idx_key = std.fmt.bufPrint(&buf2, "{d}", .{ii}) catch break;
            if (names_arr.get(idx_key)) |name_val| {
                if (name_val.bits != 0 and name_val.unbox() == .string) {
                    const name_str = name_val.toPtr().string;
                    if (!tdz_set.contains(name_str)) {
                        exports_obj.set(name_str, undef) catch {};
                    }
                }
            }
        }
    }
    // Backwards compat (no TDZ list): mark ALL names as TDZ
    if (!has_tdz_list) {
        const marker = tdz_marker orelse return val_mod.makeUndefined(arena);
        const n = names_arr.getArrayLength();
        var i: u32 = 0;
        var buf: [32]u8 = undefined;
        while (i < n) : (i += 1) {
            const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
            if (names_arr.get(idx_key)) |name_val| {
                if (name_val.bits != 0 and name_val.unbox() == .string) {
                    const name_str = name_val.toPtr().string;
                    try exports_obj.set(name_str, marker);
                }
            }
        }
    }
    return val_mod.makeUndefined(arena);
}

/// Context block for a deferred dynamic import: carries the module specifier
/// and the pending result promise that the microtask will resolve/reject.
const DeferredImportCtx = struct {
    name: []const u8, // resolved module id (canonical specifier)
    result: Value, // pending promise to settle once evaluated
};

/// Microtask body for a deferred dynamic `import()`. Runs after the current
/// synchronous evaluation chain (static-import DFS) completes, so the module's
/// factory will have already been invoked through the static-import hoist by
/// the time this fires. Settles `result` with the module namespace (or rejects
/// if require throws).
fn deferredImportResolve(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const slot = val_mod.g_active_native_data orelse return val_mod.makeUndefined(arena);
    const ctx: *DeferredImportCtx = @ptrCast(@alignCast(slot));
    if (std.process.hasEnvVarConstant("JSZ_DBG")) std.debug.print("deferredImportResolve name={s} result_bits={x}\n", .{ ctx.name, ctx.result.bits });
    const name_val = val_mod.makeString(arena, ctx.name) catch return val_mod.makeUndefined(arena);
    const exports_val = nativeRequire(arena, Value{}, &[_]Value{name_val}) catch |err| {
        if (err == error.JsException) {
            const reason = pending_exception;
            pending_exception = Value{};
            promise_mod.settleResult(arena, ctx.result, reason, false);
            return val_mod.makeUndefined(arena);
        }
        return err;
    };
    const ns = nativeMakeNamespace(arena, Value{}, &[_]Value{exports_val}) catch exports_val;
    // Handle async modules: chain onto their eval promise so this import only
    // fulfills once the module's top-level-await body finishes.
    if (lookupEvalPromise(arena, ctx.name)) |eval_promise| {
        const ns_box = arena.create(Value) catch {
            promise_mod.settleResult(arena, ctx.result, ns, true);
            return val_mod.makeUndefined(arena);
        };
        ns_box.* = ns;
        const returner = val_mod.makeNativeFunctionData(arena, importNsReturner, ns_box) catch {
            promise_mod.settleResult(arena, ctx.result, ns, true);
            return val_mod.makeUndefined(arena);
        };
        // .then(returner) on the eval promise produces a chained promise whose
        // value is the namespace; adopt it as the resolution of our result.
        const chained = promise_mod.nativePromiseThen(arena, eval_promise, &[_]Value{ returner, Value{} }) catch {
            promise_mod.settleResult(arena, ctx.result, ns, true);
            return val_mod.makeUndefined(arena);
        };
        promise_mod.settleResult(arena, ctx.result, chained, true); // thenable adoption
        return val_mod.makeUndefined(arena);
    }
    promise_mod.settleResult(arena, ctx.result, ns, true);
    return val_mod.makeUndefined(arena);
}

/// M16 Phase 3: dynamic `import(specifier)`. Desugared by the parser to a call
/// `__import__(specifier)`. Resolves and loads the module through the same
/// `__modules__` registry + `require()` resolver used by static imports, wraps
/// the resulting live `exports` in a Module Namespace exotic object, and hands
/// back a Promise (ES §16.2.1.8 ImportCall): fulfilled with the namespace, or
/// rejected with whatever the resolve/evaluation threw. The specifier argument
/// is already evaluated by the VM before this native runs, so an abrupt
/// specifier expression propagates synchronously (never as a rejection).
///
/// DFS-ordering guarantee: when the target module is a not-yet-evaluated
/// factory (it will be invoked by the static-import hoist of the calling
/// module's entry), evaluation is deferred to a microtask. This ensures that
/// the static DFS chain (A's body → entry's B require) runs before the dynamic
/// import's side-effects, matching the spec's InnerModuleEvaluation order.
pub fn nativeImport(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (std.process.hasEnvVarConstant("JSZ_DBG") and args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) std.debug.print("IMPORT {s}\n", .{args[0].toPtr().string});
    const spec_str = importSpecifierString(arena, args) catch |e| {
        if (e != error.JsException) return e;
        return rejectWithPending(arena);
    };
    // EvaluateImportCall steps 9-10: validate the second argument and read its
    // `with` import attributes. An abrupt options-object / `with` getter / non
    // -string attribute value rejects the promise. A `with: { type: '...' }`
    // attribute selects a typed (JSON/text) module: fold the type into the
    // specifier so it keys the same synthetic module record the static-import
    // desugar registers (`spec\x00type`).
    const type_attr = importReadTypeAttr(arena, if (args.len > 1) args[1] else Value{}) catch |e| {
        if (e != error.JsException) return e;
        return rejectWithPending(arena);
    };
    const folded_spec = if (type_attr) |ty|
        try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ spec_str, ty })
    else
        spec_str;
    const args2 = try arena.alloc(Value, 1);
    args2[0] = try val_mod.makeString(arena, folded_spec);
    const raw_name = args2[0].toPtr().string;
    // Resolve the specifier to the canonical id used in __modules__.
    const env = active_global_env orelse {
        // No environment — fall through to synchronous load.
        return nativeImportSync(arena, args2);
    };
    const registry = env.lookup("__modules__") catch {
        return nativeImportSync(arena, args2);
    };
    if (registry.bits == 0 or registry.unbox() != .object) return nativeImportSync(arena, args2);
    const modules_obj = registry.toPtr().object;
    const resolved = resolveModuleName(arena, env, raw_name) catch raw_name;
    const lookup_name = if (modules_obj.get(resolved) != null) resolved else raw_name;
    // Eager resolution error: a module whose static-import closure reaches a
    // missing file fails to load, so import() rejects before any evaluation.
    if (moduleIsUnresolvable(env, lookup_name) or moduleIsUnresolvable(env, resolved)) {
        return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{
            try val_mod.makeString(arena, try std.fmt.allocPrint(arena, "Error: Cannot find module '{s}'", .{raw_name})),
        });
    }
    // Check the current state of the module in the registry.
    if (modules_obj.get(lookup_name)) |entry| {
        if (entry.bits != 0 and entry.unbox() == .object) {
            const mod_obj = entry.toPtr().object;
            if (mod_obj.get("exports") != null) {
                // Already evaluated (module object cached) — resolve immediately.
                return nativeImportSync(arena, args2);
            }
        }
        if (isCallableValue(entry)) {
            // Factory not yet invoked: defer evaluation to a microtask so the
            // calling module's static-import DFS runs first (spec §16.2.1.5.1
            // step 11.c.iv — pending-dependency ordering).
            const result_p = try promise_mod.newPendingPromise(arena);
            if (std.process.hasEnvVarConstant("JSZ_DBG")) std.debug.print("nativeImport deferred name={s} result_bits={x}\n", .{ lookup_name, result_p.bits });
            const ctx = try arena.create(DeferredImportCtx);
            ctx.* = .{ .name = lookup_name, .result = result_p };
            const resolve_fn = try val_mod.makeNativeFunctionData(arena, deferredImportResolve, ctx);
            // Enqueue via Promise.resolve(undefined).then(resolve_fn) so
            // resolve_fn fires as the next microtask after the sync chain.
            const trigger = try promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{
                try val_mod.makeUndefined(arena),
            });
            _ = try promise_mod.nativePromiseThen(arena, trigger, &[_]Value{ resolve_fn, Value{} });
            return result_p;
        }
    }
    // Module not in registry (bare specifier, external, etc.) — synchronous load.
    return nativeImportSync(arena, args2);
}

/// True when `v` is an Object (ordinary object, callable, or Proxy) — the
/// spec's `Type(v) is Object` for a value box.
fn valueIsObjectLike(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .function, .native_function, .bc_function => true,
        else => false,
    };
}

/// Process `import(spec, options)`'s second argument per EvaluateImportCall
/// steps 9-10 (import-attributes). Returns the `type` attribute string (or null
/// when `options`/`with`/`type` is absent). Abrupt cases — a non-object
/// `options`, a `with` value that is not an Object, or an attribute value that
/// is not a String — raise a TypeError; an observable `with` getter,
/// [[OwnPropertyKeys]] trap, or attribute [[Get]] propagates its own exception.
/// The caller turns any `error.JsException` into a promise rejection.
fn importReadTypeAttr(arena: std.mem.Allocator, options: Value) anyerror!?[]const u8 {
    // step 9: options undefined ⇒ no attributes.
    if (options.bits == 0 or options.unbox() == .undefined_) return null;
    // step 9.a: Type(options) must be Object.
    if (!valueIsObjectLike(options)) return throwTypeError(arena, "import() options argument must be an object");
    const ctx = active_context orelse return null;
    // step 9.b: attributesObj = ? Get(options, "with") — an accessor may throw.
    const with_val = try ctx.getProp(arena, options, "with");
    if (with_val.bits == 0 or with_val.unbox() == .undefined_) return null;
    // step 9.d.i: the `with` value must itself be an Object.
    if (!valueIsObjectLike(with_val)) return throwTypeError(arena, "import() 'with' option must be an object");
    // step 9.d.ii: EnumerableOwnProperties(attributesObj, key) — observable
    // [[OwnPropertyKeys]] + per-key [[GetOwnProperty]] enumerable filter (routed
    // through Object.keys, so a Proxy's traps run and their throws propagate).
    const keys_val = try obj_methods_mod.nativeObjectKeys(arena, Value{}, &[_]Value{with_val});
    var type_attr: ?[]const u8 = null;
    if (keys_val.bits != 0 and keys_val.unbox() == .object) {
        const keys_obj = keys_val.toPtr().object;
        const n = keys_obj.array_length;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx_key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const k = keys_obj.get(idx_key) orelse continue;
            if (k.bits == 0 or k.unbox() != .string) continue;
            const key_str = k.toPtr().string;
            // step 9.d.iv: value = ? Get(attributesObj, key); must be a String.
            const v = try ctx.getProp(arena, with_val, key_str);
            if (v.bits == 0 or v.unbox() != .string)
                return throwTypeError(arena, "import attribute value must be a string");
            if (std.mem.eql(u8, key_str, "type") and v.toPtr().string.len != 0)
                type_attr = v.toPtr().string;
        }
    }
    return type_attr;
}

/// Synchronous path for `nativeImport`: evaluate the module immediately and
/// return a (possibly deferred) promise for its namespace. Used when the module
/// is already evaluated (cached) or when the deferred path is unavailable.
fn nativeImportSync(arena: std.mem.Allocator, args: []const Value) anyerror!Value {
    // Load the module like `require()`. A resolution/evaluation throw is captured
    // and turned into a rejected promise rather than propagated synchronously.
    const exports_val = nativeRequire(arena, Value{}, args) catch |err| {
        if (err == error.JsException) {
            const reason = pending_exception;
            pending_exception = Value{};
            return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{reason});
        }
        return err;
    };
    const ns = try nativeMakeNamespace(arena, Value{}, &[_]Value{exports_val});
    // M16 TLA: if the imported module is async (its factory returned an
    // evaluation-completion promise), the dynamic import must fulfil only once
    // the module has finished evaluating (including top-level await), and reject
    // if its evaluation rejects. Chain the namespace onto the eval promise.
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) {
        if (lookupEvalPromise(arena, args[0].toPtr().string)) |eval_promise| {
            const ns_box = try arena.create(Value);
            ns_box.* = ns;
            const returner = try val_mod.makeNativeFunctionData(arena, importNsReturner, ns_box);
            return promise_mod.nativePromiseThen(arena, eval_promise, &[_]Value{returner});
        }
    }
    // A fresh promise per call (ImportCall NewPromiseCapability) fulfilled with
    // the namespace. `nativePromiseResolve` only short-circuits for a promise
    // argument; a namespace is an ordinary object, so a new promise is created.
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{ns});
}

/// Promise `then` reaction (dynamic import): ignore the eval result, return the
/// bound module namespace value (carried as native data).
fn importNsReturner(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const slot = val_mod.g_active_native_data orelse return val_mod.makeUndefined(arena);
    const ns_box: *Value = @ptrCast(@alignCast(slot));
    return ns_box.*;
}

/// Look up a (resolved) module's evaluation-completion promise, if it is an
/// async module that stashed one during `require()`. `name` is the raw specifier.
fn lookupEvalPromise(arena: std.mem.Allocator, name: []const u8) ?Value {
    const env = active_global_env orelse return null;
    const registry = env.lookup("__modules__") catch return null;
    if (registry.bits == 0 or registry.unbox() != .object) return null;
    const modules_obj = registry.toPtr().object;
    const resolved = resolveModuleName(arena, env, name) catch name;
    const lookup_name = if (modules_obj.get(resolved) != null) resolved else name;
    const mod_val = modules_obj.get(lookup_name) orelse return null;
    if (mod_val.bits == 0 or mod_val.unbox() != .object) return null;
    const ep = mod_val.toPtr().object.get("__evalPromise__") orelse return null;
    if (ep.bits == 0 or ep.unbox() != .object) return null;
    if (ep.toPtr().object.internal_kind != .promise) return null;
    return ep;
}

/// M16 TLA: `__awaitDeps__([id, ...])` — the async-dependency barrier. Returns a
/// Promise that settles when every listed module's evaluation-completion promise
/// settles (Promise.all), so an async-module body resumes only after all of its
/// async dependencies have finished evaluating. Ids whose module has no eval
/// promise (already evaluated / synchronous) are treated as resolved.
pub fn nativeAwaitDeps(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const undef = try val_mod.makeUndefined(arena);
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object)
        return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{undef});
    const env = active_global_env orelse return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{undef});
    const registry = env.lookup("__modules__") catch return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{undef});
    if (registry.bits == 0 or registry.unbox() != .object)
        return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{undef});
    const modules_obj = registry.toPtr().object;
    const ids_arr = args[0].toPtr().object;
    const promises = try JsObject.createArray(arena, active_array_proto);
    var n: u32 = 0;
    const len = ids_arr.getArrayLength();
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i < len) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
        const id_val = ids_arr.get(key) orelse continue;
        if (id_val.bits == 0 or id_val.unbox() != .string) continue;
        const mod_val = modules_obj.get(id_val.toPtr().string) orelse continue;
        if (mod_val.bits == 0 or mod_val.unbox() != .object) continue;
        const ep = mod_val.toPtr().object.get("__evalPromise__") orelse continue;
        const idx_key = try std.fmt.allocPrint(arena, "{d}", .{n});
        try promises.set(idx_key, ep);
        n += 1;
    }
    promises.array_length = n;
    if (n == 0) return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{undef});
    return promise_mod.nativePromiseAll(arena, Value{}, &[_]Value{try val_mod.makeObject(arena, promises)});
}

// M16 TLA: completion tracking for `[module, async]` tests. With true async
// module evaluation, `$DONE` may be invoked from a microtask after the
// synchronous run returns, and an assertion that throws inside a promise
// reaction is otherwise swallowed. The harness `$DONE` is wired to these
// natives so the host can detect success (signaled, no error) vs. failure (an
// error value) vs. never-completed (not signaled) after draining microtasks.
pub var async_done_signaled: bool = false;
pub var async_done_error: Value = .{};
/// Set when the entry module's async evaluation (the async IIFE / top-level
/// async body) rejects — the spec's `Evaluate()` promise rejection. Surfaced as
/// the eval outcome's exception so negative module tests and uncaught async
/// module errors are observable even though the synchronous run returned `.ok`.
pub var module_eval_error: Value = .{};

/// Reset async-test completion state at the start of an evaluation.
pub fn resetAsyncDone() void {
    async_done_signaled = false;
    async_done_error = Value{};
    module_eval_error = Value{};
}

/// `__jszModuleReject__(err)` — records the entry module's evaluation rejection.
pub fn nativeModuleReject(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (module_eval_error.bits == 0)
        module_eval_error = if (args.len > 0 and args[0].bits != 0) args[0] else try val_mod.makeString(arena, "module evaluation failed");
    return val_mod.makeUndefined(arena);
}

/// Best-effort message string for a thrown/rejected value (Error object's
/// name+message, a raw string, else a generic). Used to report async failures.
pub fn errorValueMessage(arena: std.mem.Allocator, v: Value) []const u8 {
    if (v.bits == 0) return "async test failed";
    switch (v.unbox()) {
        .string => |s| return s,
        .object => |obj| {
            const name = if (obj.get("name")) |nv|
                (if (nv.bits != 0 and nv.unbox() == .string) nv.toPtr().string else "Error")
            else
                "Error";
            const msg = if (obj.get("message")) |mv|
                (if (mv.bits != 0 and mv.unbox() == .string) mv.toPtr().string else "")
            else
                "";
            return std.fmt.allocPrint(arena, "{s}: {s}", .{ name, msg }) catch "async test failed";
        },
        else => return "async test failed",
    }
}

/// `__jszAsyncDone__()` — the test signalled successful async completion.
pub fn nativeAsyncDone(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    async_done_signaled = true;
    return val_mod.makeUndefined(arena);
}

/// `__jszAsyncFail__(err)` — the test signalled async failure with `err`.
pub fn nativeAsyncFail(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    async_done_signaled = true;
    async_done_error = if (args.len > 0 and args[0].bits != 0) args[0] else try val_mod.makeString(arena, "async test failed");
    return val_mod.makeUndefined(arena);
}

/// M16 Phase 3: the `import.meta` object (ES §16.2.1.10). Created once per realm
/// as an ordinary object with a null [[Prototype]] (extensible) carrying the
/// host `url` property; the parser desugars every `import.meta` to a reference
/// to the module-scoped `__import_meta__` binding holding this object, so all
/// references within a module observe the same object. `evalModule` updates
/// `url` to the active module's specifier before evaluation.
pub fn makeImportMeta(arena: std.mem.Allocator, url: []const u8) !Value {
    const obj = if (active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    try obj.set("url", try val_mod.makeString(arena, url));
    return val_mod.makeObject(arena, obj);
}

fn throwModuleNotFound(arena: std.mem.Allocator, name: []const u8) !Value {
    const msg = try std.fmt.allocPrint(arena, "Cannot find module '{s}'", .{name});
    const err_obj = if (active_heap) |h|
        try JsObject.createOnHeap(h, plainErrorProto())
    else
        try JsObject.create(arena, plainErrorProto());
    try err_obj.set("message", try val_mod.makeString(arena, msg));
    try err_obj.set("name", try val_mod.makeString(arena, "Error"));
    pending_exception = try val_mod.makeObject(arena, err_obj);
    return error.JsException;
}

/// Eager resolution-error gate: true when `id` (a canonical registry id) is in
/// the bundle's `__moduleUnresolved__` set — it transitively, via static import
/// edges, imports a module missing from disk. Such a module fails to load (spec
/// LoadRequestedModules), so `require`/`import()` of it throws/rejects before any
/// evaluation, even when the missing module sits behind an `import defer`.
fn moduleIsUnresolvable(env: *Environment, id: []const u8) bool {
    const set = env.lookup("__moduleUnresolved__") catch return false;
    if (set.bits == 0 or set.unbox() != .object) return false;
    return set.toPtr().object.get(id) != null;
}

fn syncRequireCache(env: *Environment, id: []const u8, module_val: Value) !void {
    const cache_val = env.lookup("__require_cache__") catch return;
    if (cache_val.bits == 0 or cache_val.unbox() != .object) return;
    try cache_val.toPtr().object.set(id, module_val);
}

fn nativeRequireResolve(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return val_mod.makeUndefined(arena);
    }
    const name = args[0].toPtr().string;
    const env = active_global_env orelse return val_mod.makeUndefined(arena);
    const resolved = resolveModuleName(arena, env, name) catch name;
    const registry = env.lookup("__modules__") catch return throwModuleNotFound(arena, name);
    if (registry.bits == 0 or registry.unbox() != .object) return throwModuleNotFound(arena, name);
    const modules_obj = registry.toPtr().object;
    if (modules_obj.get(resolved) != null) return val_mod.makeString(arena, resolved);
    if (modules_obj.get(name) != null) return val_mod.makeString(arena, name);
    return throwModuleNotFound(arena, name);
}

fn isCallableValue(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .native_function, .bc_function => true,
        .object => |o| o.is_callable_intrinsic or o.get("__call__") != null,
        else => false,
    };
}

fn resolveModuleName(arena: std.mem.Allocator, env: *Environment, name: []const u8) ![]const u8 {
    if (!(std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../"))) return name;
    const cur_id = env.lookup("__module_id__") catch return name;
    if (cur_id.bits == 0 or cur_id.unbox() != .string) return name;
    const base = std.fs.path.dirname(cur_id.toPtr().string) orelse "";
    const joined = try std.fs.path.join(arena, &[_][]const u8{ base, name });
    return normalizePath(arena, joined);
}

fn normalizePath(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    const unix_like = try std.mem.replaceOwned(u8, arena, p, "\\", "/");
    var parts = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, unix_like, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    return std.mem.join(arena, "/", parts.items);
}

/// Thread-local pointer to the currently active Heap.
/// Set by Realm.activateHeap(), cleared on deinit.
pub var active_heap: ?*Heap = null;
pub var active_global_env: ?*Environment = null;
/// The `globalThis` object for the running realm. A top-level `var` binding lives
/// in `active_global_env`, but per the global environment record it must alias an
/// own property of this object — so writes through `globalThis.x = …` mirror back
/// into the env binding (see BcVm.setPropR).
pub var active_global_object: ?*JsObject = null;

/// Phase 4b: thread-locals for prototype access from builtin fns.
pub var active_array_proto: ?*JsObject = null;
/// %Array% of the running realm — ArraySpeciesCreate compares a cross-realm
/// species constructor against its OWN realm's %Array% (ES 23.1.3.4 step 3.b).
pub var active_array_ctor: ?*JsObject = null;
pub var active_object_ctor: ?*JsObject = null;
pub var active_object_proto: ?*JsObject = null;
/// Phase 4b: thread-local for String.prototype (autoboxing lookup).
pub var active_string_proto: ?*JsObject = null;
/// Phase 13: thread-locals for Number/Boolean.prototype (autoboxing lookup).
pub var active_number_proto: ?*JsObject = null;
pub var active_boolean_proto: ?*JsObject = null;
/// BigInt.prototype (autoboxing lookup for bigint primitives).
pub var active_bigint_proto: ?*JsObject = null;
/// Phase 13: set true by the VM immediately before invoking a native constructor
/// via `new` (or Reflect.construct); reset false at every plain-call entry. Lets
/// the Boolean/Number/String factories return a wrapper object under `new` but a
/// primitive under a plain call — the synthesized `this` is identical in both
/// paths, so prototype identity cannot distinguish them.
pub var active_constructing: bool = false;
/// Cross-realm: monotonic counter handing out Realm.realm_id values. 0 is
/// reserved for the primary realm, so secondary realms start at 1.
pub var next_realm_id: u32 = 1;
/// Cross-realm: while a secondary realm's evalScript is running, this holds
/// the secondary Realm pointer so bcEvalInEnv can temporarily switch self.realm
/// and tag closures created in the eval'd code with the correct realm identity.
pub var active_shadow_realm: ?*Realm = null;

/// M15: pending NewTarget for an in-flight native construction. A ctor that must
/// run GetPrototypeFromConstructor at a spec-precise point (e.g. %TypedArray%,
/// ArrayBuffer, DataView — after ToIndex on a primitive length arg) reads this,
/// applies the prototype, and CONSUMES it (sets it back to `Value{}`). The
/// constructor dispatcher applies the prototype post-hoc for any ctor that did
/// not consume it. Saved/restored around each native construct for re-entrancy.
pub var pending_new_target: Value = Value{};
/// Phase 4c: thread-local for RegExp.prototype.
pub var active_regexp_proto: ?*JsObject = null;
/// Phase 4d: thread-local for Function.prototype.
pub var active_function_proto: ?*JsObject = null;
/// The shared %ThrowTypeError% intrinsic (poison-pill for caller/arguments).
pub var active_throw_type_error: ?Value = null;
pub var active_promise_proto: ?*JsObject = null;
/// %GeneratorFunction%: [[Prototype]] of generator function objects.
pub var active_function_ctor: ?*JsObject = null;
/// ES2015 Symbol.prototype (autoboxing lookup for symbol primitives).
pub var active_symbol_proto: ?*JsObject = null;
/// ES2015 Symbol.iterator well-known symbol value.
pub var active_sym_iterator: ?Value = null;
/// ES2015 Symbol.toPrimitive well-known symbol value (ToPrimitive hook).
pub var active_sym_to_primitive: ?Value = null;
/// ES2015 Symbol.toStringTag well-known symbol value.
pub var active_sym_to_string_tag: ?Value = null;
/// ES2015 Symbol.species well-known symbol value.
pub var active_sym_species: ?Value = null;
/// ES2015 Symbol.hasInstance well-known symbol value (instanceof dispatch).
pub var active_sym_has_instance: ?Value = null;
/// %Intl%.[[FallbackSymbol]] (ECMA-402 §8.1): the private key under which a
/// `new`-less `Intl.NumberFormat(existingInstance)` stashes the real formatter.
pub var active_sym_intl_fallback: ?Value = null;
/// ES2015 Symbol.isConcatSpreadable well-known symbol value.
pub var active_sym_is_concat_spreadable: ?Value = null;
/// ES2023 Symbol.asyncIterator well-known symbol value.
pub var active_sym_async_iterator: ?Value = null;
/// Symbol.asyncDispose (explicit resource management); used by
/// %AsyncIteratorPrototype%[@@asyncDispose].
pub var active_sym_async_dispose: ?Value = null;
/// Symbol.dispose (explicit resource management); used by DisposableStack and
/// `using` declarations.
pub var active_sym_dispose: ?Value = null;
/// Symbol.unscopables well-known symbol; a `with`-object's @@unscopables map
/// hides listed names from the with-scope (HasBinding returns false for them).
pub var active_sym_unscopables: ?Value = null;
/// Well-known RegExp-related symbols (@@match/@@replace/@@search/@@split/@@matchAll).
pub var active_sym_match: ?Value = null;
pub var active_sym_replace: ?Value = null;
pub var active_sym_search: ?Value = null;
pub var active_sym_split: ?Value = null;
pub var active_sym_match_all: ?Value = null;
/// Phase 13: private symbols storing a Proxy's [[ProxyTarget]]/[[ProxyHandler]]
/// as GC-traced symbol-keyed own properties.
pub var active_sym_proxy_target: ?Value = null;
pub var active_sym_proxy_handler: ?Value = null;
/// M16: private symbol caching a module's namespace exotic object on its live
/// exports object, so GetModuleNamespace returns the *same* object each time
/// (`import * as a` and `import * as b` of one module compare ===).
pub var active_sym_module_ns: ?Value = null;
/// Deferred import: private symbol storing the canonical module id of a not-yet-
/// evaluated `import defer * as ns` namespace, on the namespace object itself.
/// Its presence marks the namespace as deferred; a triggering operation reads it,
/// evaluates the module via `require`, wires the backing exports, and removes it.
pub var active_sym_deferred_id: ?Value = null;
/// Deferred import: a null-prototype object mapping canonical module id → its
/// single deferred namespace exotic object, so repeated `import defer` (and
/// dynamic `import.defer()`) of one module observe the same object (identity).
pub var active_deferred_ns_registry: ?Value = null;
/// M16 Phase 4: private symbol storing a module's export names array on its
/// live exports object, so the namespace exotic can check TDZ for uninitialized
/// exports even before the module body runs (self-imports).
pub var active_sym_export_names: ?Value = null;

/// M16 Phase 4: private symbol storing a module's TDZ-only export names array
/// on its live exports object. This is a subset of export_names — only the
/// names from `let`, `const`, and `class` declarations that are uninitialized
/// during instantiation. Used by the namespace exotic to distinguish TDZ
/// bindings from hoisted (var/function) bindings.
pub var active_sym_tdz_export_names: ?Value = null;

/// M16 Phase 4: shared TDZ marker — a symbol pre-populated on every export
/// property before its module body runs. The namespace [[Get]] checks for this
/// symbol and throws ReferenceError when found.
pub var tdz_marker: ?Value = null;

/// Phase 4b: pending JS exception Value (set by JSON.parse on error).
/// VMs check this after catching error.JsException from a native call.
pub var pending_exception: Value = Value{};

// ---------------------------------------------------------------- Error constructors ---

/// Build a native constructor for the given error kind.
/// Returns a NativeFn that creates an error object with the right prototype.
/// The prototype is retrieved via a thread-local pointer set during realm init.
/// We use a comptime function to specialize per error kind.
pub var error_proto_Error: ?*JsObject = null;
pub var error_proto_TypeError: ?*JsObject = null;
pub var error_proto_SyntaxError: ?*JsObject = null;
pub var error_proto_RangeError: ?*JsObject = null;
pub var error_proto_ReferenceError: ?*JsObject = null;
pub var error_proto_AggregateError: ?*JsObject = null;
pub var error_proto_URIError: ?*JsObject = null;
pub var error_proto_EvalError: ?*JsObject = null;
pub var error_proto_SuppressedError: ?*JsObject = null;

/// The error prototypes an error thrown *right now* should use. A built-in
/// function throws with its own realm's intrinsics (GetFunctionRealm, §10.2.5),
/// not the caller's, so `otherRealm.RegExp.prototype.global` called on a
/// primary-realm receiver must produce an `otherRealm.TypeError`. The thread-local
/// `error_proto_*` still track the *running* realm; these accessors override them
/// while a native tagged with a secondary realm is on the stack.
pub fn activeNativeRealm() ?*Realm {
    const rp = val_mod.g_active_native_realm orelse return null;
    return @ptrCast(@alignCast(rp));
}

pub fn typeErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.type_error_prototype;
    return error_proto_TypeError;
}

pub fn rangeErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.range_error_prototype;
    return error_proto_RangeError;
}

pub fn referenceErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.reference_error_prototype;
    return error_proto_ReferenceError;
}

pub fn plainErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.error_prototype;
    return error_proto_Error;
}

/// %RegExp.prototype% as seen by the built-in currently running. The flag getters
/// tolerate exactly one non-RegExp receiver — *their own* realm's
/// %RegExp.prototype% (§22.2.6 step 3) — so another realm's prototype must throw.
pub fn regexpProtoForActiveNative() ?*JsObject {
    if (activeNativeRealm()) |r| return r.regexp_prototype;
    return active_regexp_proto;
}

pub fn syntaxErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.syntax_error_prototype;
    return error_proto_SyntaxError;
}

pub fn aggregateErrorProto() ?*JsObject {
    if (activeNativeRealm()) |r| return r.aggregate_error_prototype;
    return error_proto_AggregateError;
}

/// Attributes shared by the own data properties an Error constructor installs on
/// its instance (message / cause / errors / error / suppressed): every one is
/// { [[Writable]]: true, [[Enumerable]]: false, [[Configurable]]: true }.
const error_prop_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };

/// OrdinaryCreateFromConstructor result for an Error subclass: mark the incoming
/// `this` (already built by the VM with the newTarget-derived prototype) as an
/// [[ErrorData]] object. Error instances carry NO own "name"/"message" — those
/// inherit from the prototype; a "message" own slot is only added when a message
/// argument is supplied (see `defineErrorMessage`). The `proto` fallback covers
/// the constructor being *called* (no `new`) or with a non-object `this`.
fn populateErrorThis(arena: std.mem.Allocator, this_val: Value, proto: ?*JsObject) !Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const obj = this_val.toPtr().object;
        obj.is_error = true;
        return this_val;
    }
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    obj.is_error = true;
    return val_mod.makeObject(arena, obj);
}

/// If a message argument is present (not undefined/absent), CreateNonEnumerable-
/// DataPropertyOrThrow(O, "message", ToString(message)). ToString goes through
/// ToPrimitive (so an object's `toString` runs and may throw) and raises a
/// TypeError for a Symbol — matching Error(message) step 3.
fn defineErrorMessage(arena: std.mem.Allocator, result: Value, msg_arg: Value) !void {
    if (result.bits == 0 or result.unbox() != .object) return;
    if (msg_arg.bits == 0 or msg_arg.unbox() == .undefined_) return;
    const msg = try uriToString(arena, msg_arg);
    _ = try result.toPtr().object.defineOwnData("message", try val_mod.makeString(arena, msg), error_prop_attr);
}

/// InstallErrorCause (ES §20.5.8.1): if `options` is an Object and
/// ? HasProperty(options, "cause") is true, set `error.cause` to ? Get(options,
/// "cause") as a non-enumerable data property. HasProperty / Get run through the
/// full [[HasProperty]] / [[Get]] so a Proxy trap or accessor can throw (abrupt
/// completions propagate).
fn installErrorCause(arena: std.mem.Allocator, result: Value, options: Value) !void {
    if (result.bits == 0 or result.unbox() != .object) return;
    if (options.bits == 0 or options.unbox() != .object) return;
    const has = if (active_context) |c| try c.hasProp(arena, options, "cause") else options.toPtr().object.hasOwn("cause");
    if (!has) return;
    const cause = if (active_context) |c| try c.getProp(arena, options, "cause") else (options.toPtr().object.getOwn("cause") orelse Value{});
    _ = try result.toPtr().object.defineOwnData("cause", cause, error_prop_attr);
}

fn errorCtorWithCause(arena: std.mem.Allocator, this_val: Value, proto: ?*JsObject, args: []const Value) anyerror!Value {
    const result = try populateErrorThis(arena, this_val, proto);
    // Step order (Error): ToString(message) → define "message", then cause.
    try defineErrorMessage(arena, result, if (args.len > 0) args[0] else Value{});
    try installErrorCause(arena, result, if (args.len > 1) args[1] else Value{});
    return result;
}

fn nativeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, plainErrorProto(), args);
}

fn nativeTypeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, typeErrorProto(), args);
}

fn nativeSyntaxErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, syntaxErrorProto(), args);
}

fn nativeRangeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, rangeErrorProto(), args);
}

fn nativeReferenceErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, referenceErrorProto(), args);
}

fn nativeEvalErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, error_proto_EvalError, args);
}

fn nativeUriErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, error_proto_URIError, args);
}

/// CreateArrayFromList over the IteratorToList of `errs_arg` → an Array on
/// %Array.prototype%. Throws if `errs_arg` is not iterable (GetIterator step).
fn errorsListToArray(arena: std.mem.Allocator, errs_arg: Value) anyerror!Value {
    var items = std.ArrayList(Value){};
    const iterable = errs_arg.bits != 0 and errs_arg.unbox() != .undefined_ and errs_arg.unbox() != .null_;
    if (!iterable or !try arrayFromIterate(arena, errs_arg, &items))
        return throwTypeError(arena, "AggregateError: errors argument is not iterable");
    const arr = if (active_heap) |h|
        try JsObject.createOnHeap(h, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    arr.is_array = true;
    for (items.items, 0..) |v, i| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(key, v);
    }
    arr.array_length = @intCast(items.items.len);
    return val_mod.makeObject(arena, arr);
}

fn nativeAggregateErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // AggregateError(errors, message, options). Step order: define "message"
    // (if provided), InstallErrorCause, then IteratorToList(errors) → "errors".
    const result = try populateErrorThis(arena, this_val, aggregateErrorProto());
    try defineErrorMessage(arena, result, if (args.len > 1) args[1] else Value{});
    try installErrorCause(arena, result, if (args.len > 2) args[2] else Value{});
    const errors_arr = try errorsListToArray(arena, if (args.len > 0) args[0] else Value{});
    _ = try result.toPtr().object.defineOwnData("errors", errors_arr, error_prop_attr);
    return result;
}

fn nativeSuppressedErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // SuppressedError(error, suppressed, message). Superclass-then-subclass order:
    // define "message" (if provided) first, then always "error" and "suppressed"
    // as non-enumerable data properties.
    const result = try populateErrorThis(arena, this_val, error_proto_SuppressedError);
    try defineErrorMessage(arena, result, if (args.len > 2) args[2] else Value{});
    const obj = result.toPtr().object;
    _ = try obj.defineOwnData("error", if (args.len > 0) args[0] else try val_mod.makeUndefined(arena), error_prop_attr);
    _ = try obj.defineOwnData("suppressed", if (args.len > 1) args[1] else try val_mod.makeUndefined(arena), error_prop_attr);
    return result;
}

// ---- Phase 4: Array/String/Number constructors ----

fn nativeObjectCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // §20.1.1.1 step 1: if NewTarget is neither undefined nor the active function
    // (Object itself) — i.e. a subclass is being constructed — ignore `value` and
    // build a fresh object from NewTarget's prototype. The VM synthesized
    // `this_val` with that prototype and applies GetPrototypeFromConstructor
    // post-return, so returning it here yields OrdinaryCreateFromConstructor.
    if (active_constructing) {
        const nt = pending_new_target;
        const is_subclass = nt.bits != 0 and !(nt.bits != 0 and active_object_ctor != null and
            nt.isHeapPtr() and nt.unbox() == .object and nt.toPtr().object == active_object_ctor.?);
        if (is_subclass and this_val.bits != 0 and this_val.unbox() == .object) {
            active_constructing = false;
            return this_val;
        }
    }
    // new Object() / Object(): if arg is an object return it, else create new.
    // Functions are objects too — `Object(f) === f` must hold, and testing only
    // for `.object` boxed them into a fresh plain object instead.
    if (args.len > 0 and isObjectLike(args[0])) {
        return args[0];
    }
    // ToObject for a primitive arg: box it in a wrapper carrying [[PrimitiveValue]]
    // (the prototype valueOf/ToPrimitive then unboxes it). null/undefined fall
    // through to a fresh plain object.
    if (args.len > 0 and args[0].bits != 0) {
        const proto: ?*JsObject = switch (args[0].unbox()) {
            .number => active_number_proto,
            .boolean => active_boolean_proto,
            // Box each primitive against its own wrapper prototype so
            // `Object(s) instanceof String` (etc.) holds and the prototype's
            // valueOf/toString unwrap [[PrimitiveValue]] correctly.
            .string => active_string_proto orelse active_object_proto,
            .symbol => active_symbol_proto orelse active_object_proto,
            .bigint => active_bigint_proto orelse active_object_proto,
            else => null,
        };
        if (proto) |p| {
            const w = if (active_heap) |heap|
                try JsObject.createOnHeap(heap, p)
            else
                try JsObject.create(arena, p);
            try w.set("[[PrimitiveValue]]", args[0]);
            // StringCreate: a boxed String is a String exotic object.
            if (args[0].unbox() == .string) try installStringExotic(arena, w, args[0].unbox().string);
            return val_mod.makeObject(arena, w);
        }
    }
    if (this_val.bits != 0 and this_val.unbox() == .object) return this_val;
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_object_proto)
    else
        try JsObject.create(arena, active_object_proto);
    return val_mod.makeObject(arena, obj);
}

/// ToObject applied to a `this` value for OrdinaryCallBindThis in sloppy mode:
/// objects/callables pass through, primitives box against their wrapper
/// prototype (carrying [[PrimitiveValue]]). undefined/null are handled by the
/// caller (they map to the global object), so they pass through unchanged here.
pub fn toObjectForThis(arena: std.mem.Allocator, v: Value) !Value {
    if (v.bits == 0) return v;
    const proto: ?*JsObject = switch (v.unbox()) {
        .number => active_number_proto,
        .boolean => active_boolean_proto,
        .string => active_string_proto orelse active_object_proto,
        .symbol => active_symbol_proto orelse active_object_proto,
        .bigint => active_bigint_proto orelse active_object_proto,
        else => return v, // objects/callables/null/undefined: unchanged
    };
    if (proto) |p| {
        const w = if (active_heap) |heap|
            try JsObject.createOnHeap(heap, p)
        else
            try JsObject.create(arena, p);
        try w.set("[[PrimitiveValue]]", v);
        // NOTE: deliberately NOT installing the String exotic index properties
        // here. This runs on every sloppy-mode call with a primitive `this`, and
        // materialising one property per code unit would make
        // `hugeString.someSloppyMethod()` allocate proportionally to the string.
        // The explicit boxing paths (Object(str), new String(str), and
        // array_proto's ToObject) do install them.
        return val_mod.makeObject(arena, w);
    }
    return v;
}

/// Define a String exotic object's index properties and `length` on `obj`.
pub fn installStringExotic(arena: std.mem.Allocator, obj: *JsObject, s: []const u8) !void {
    const string_proto = @import("./builtins/string_proto.zig");
    const cu_len = string_proto.cuLen(s);
    var i: usize = 0;
    while (i < cu_len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const unit = string_proto.cuUnitAt(s, i).?;
        _ = try obj.defineOwnData(key, try val_mod.makeString(arena, try string_proto.cuToString(arena, unit)), .{ .writable = false, .enumerable = true, .configurable = false });
    }
    _ = try obj.defineOwnData("length", try val_mod.makeNumber(arena, @floatFromInt(cu_len)), .{ .writable = false, .enumerable = false, .configurable = false });
}

fn nativeArrayCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // The Array constructor ALWAYS builds a fresh array (OrdinaryCreateFrom-
    // Constructor); it never installs into the `this` binding. Only reuse the
    // caller-supplied object when it is the construct target the VM synthesized
    // for `new Array(...)` (active_constructing) — a plain call such as
    // `Array.apply(obj, args)` must not mutate `obj`.
    const is_construct = active_constructing;
    active_constructing = false;
    const obj = if (is_construct and this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    if (args.len == 1 and args[0].bits != 0 and args[0].unbox() == .number) {
        const len = args[0].unbox().number;
        // `new Array(len)`: len must be a valid Uint32 (ES §23.1.1.1 step 8c),
        // else RangeError. Negative, fractional, NaN and >= 2^32 all throw.
        if (len >= 0 and len == @floor(len) and len < 4294967296) {
            obj.array_length = @intFromFloat(len);
        } else {
            return throwRangeError(arena, "Invalid array length");
        }
    } else {
        for (args, 0..) |arg, i| {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            try obj.set(key, arg);
        }
        obj.array_length = @intCast(args.len);
    }
    return val_mod.makeObject(arena, obj);
}

fn nativeArrayIsArray(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object) {
        // IsArray (§7.2.2) recurses through Proxy targets, and a REVOKED proxy is
        // a TypeError rather than `false`.
        var o = args[0].toPtr().object;
        var depth: usize = 0;
        while (o.internal_kind == .proxy and depth < 64) : (depth += 1) {
            const target = proxy_mod.proxyTarget(o) orelse return proxy_mod.throwRevoked(arena);
            if (target.bits == 0 or target.unbox() != .object) return val_mod.makeBool(arena, false);
            o = target.toPtr().object;
        }
        return val_mod.makeBool(arena, o.is_array);
    }
    return val_mod.makeBool(arena, false);
}

/// ES2015 Array.from(arrayLike [, mapFn [, thisArg]])
/// Converts any array-like (length + indexed) or iterable to a real Array.
/// ArrayCreate(len) — a fresh real Array with [[ArrayLength]] = len and the
/// current realm's %Array.prototype%. A length past the array index limit is a
/// RangeError (§10.4.2.2 step 1).
fn arrayCreate(arena: std.mem.Allocator, len: usize) anyerror!Value {
    if (len > 4294967295) return throwRangeError(arena, "Invalid array length");
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    obj.array_length = @intCast(len);
    return val_mod.makeObject(arena, obj);
}

/// ArrayCreate(len) unless `C` is a constructor, in which case Construct(C, args)
/// — the "which object do I fill in" step shared by Array.from and Array.of.
fn arrayFromCtor(arena: std.mem.Allocator, ctx: *Context, c: Value, len: usize, pass_len: bool) anyerror!Value {
    if (!reflect_mod.isConstructorVal(c)) return arrayCreate(arena, len);
    if (pass_len) {
        return ctx.construct(arena, c, &[_]Value{try val_mod.makeNumber(arena, @floatFromInt(len))});
    }
    return ctx.construct(arena, c, &[_]Value{});
}

/// ES2015 Array.from(items, mapfn, thisArg) — §23.1.2.1. `this` is the
/// constructor to build with (subclass-aware), elements are installed with
/// CreateDataPropertyOrThrow, and `length` is written with a throwing [[Set]].
fn nativeArrayFrom(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = active_context orelse return throwTypeError(arena, "no active context");
    const items = if (args.len > 0) args[0] else Value{};
    const mapfn = if (args.len > 1) args[1] else Value{};
    const this_arg = if (args.len > 2) args[2] else try val_mod.makeUndefined(arena);

    // Step 2: mapfn is validated BEFORE `items` is touched at all.
    var mapping = false;
    if (!(mapfn.bits == 0 or mapfn.unbox() == .undefined_)) {
        if (!isCallableVal(mapfn)) return throwTypeError(arena, "Array.from: mapfn is not a function");
        mapping = true;
    }

    // Step 3: GetMethod(items, @@iterator) — this is what makes Array.from(null)
    // a TypeError (GetV does ToObject on the base first).
    if (items.bits == 0 or items.unbox() == .undefined_ or items.unbox() == .null_)
        return throwTypeError(arena, "Array.from: items is null or undefined");
    var using_iterator = Value{};
    if (active_sym_iterator) |sym| {
        const m = try ctx.getPropSym(arena, items, sym);
        if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
            if (!isCallableVal(m)) return throwTypeError(arena, "Array.from: Symbol.iterator is not a function");
            using_iterator = m;
        }
    }

    if (using_iterator.bits != 0) {
        const a = try arrayFromCtor(arena, ctx, this_val, 0, false);
        const iterator = try function_proto_mod.invokeCallback(arena, items, using_iterator, &[_]Value{});
        if (iterator.bits == 0 or iterator.unbox() != .object)
            return throwTypeError(arena, "[Symbol.iterator]() returned a non-object");
        const next_fn = try ctx.getProp(arena, iterator, "next");
        if (!isCallableVal(next_fn)) return throwTypeError(arena, "iterator.next is not a function");
        var k: usize = 0;
        while (true) : (k += 1) {
            const res = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
            if (res.bits == 0 or res.unbox() != .object)
                return throwTypeError(arena, "iterator.next() returned a non-object");
            if (isTruthyVal(try ctx.getProp(arena, res, "done"))) break;
            const v = try ctx.getProp(arena, res, "value");
            // A throw from mapfn or from installing the element closes the
            // iterator before propagating (IteratorClose, §23.1.2.1 steps 5.g/5.i).
            const mapped = if (mapping)
                function_proto_mod.invokeCallback(arena, this_arg, mapfn, &[_]Value{ v, try val_mod.makeNumber(arena, @floatFromInt(k)) }) catch |e| {
                    es2015_collections_mod.closeIterator(arena, iterator);
                    return e;
                }
            else
                v;
            array_proto_mod.genCreate(arena, a, k, mapped) catch |e| {
                es2015_collections_mod.closeIterator(arena, iterator);
                return e;
            };
        }
        try ctx.setPropThrow(arena, a, "length", try val_mod.makeNumber(arena, @floatFromInt(k)));
        return a;
    }

    // Array-like path.
    const len = try toLengthValue(arena, try ctx.getProp(arena, items, "length"));
    const a = try arrayFromCtor(arena, ctx, this_val, len, true);
    var k: usize = 0;
    while (k < len) : (k += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{k});
        const kv = try ctx.getProp(arena, items, key);
        const mapped = if (mapping)
            try function_proto_mod.invokeCallback(arena, this_arg, mapfn, &[_]Value{ kv, try val_mod.makeNumber(arena, @floatFromInt(k)) })
        else
            kv;
        try array_proto_mod.genCreate(arena, a, k, mapped);
    }
    try ctx.setPropThrow(arena, a, "length", try val_mod.makeNumber(arena, @floatFromInt(len)));
    return a;
}

/// Consume `src` via the @@iterator protocol into `items`. Returns false when
/// `src` is not iterable (no callable @@iterator) so the caller can fall back to
/// the array-like path. Used by Array.from for Set/Map/generators/custom iterables.
pub fn arrayFromIterate(arena: std.mem.Allocator, src: Value, items: *std.ArrayList(Value)) anyerror!bool {
    // Drive the @@iterator protocol via the hardened re-entrant invoke bridge
    // (the same one TA.map/sort use). Returns false (→ array-like fallback) only
    // when the source is not iterable.
    const sym = active_sym_iterator orelse return false;
    const ctx = active_context orelse return false;
    const iter_fn = try ctx.getPropSym(arena, src, sym);
    if (iter_fn.bits == 0 or iter_fn.unbox() == .undefined_ or iter_fn.unbox() == .null_) return false;
    if (!isCallableVal(iter_fn)) return false;
    const iterator = try function_proto_mod.invokeCallback(arena, src, iter_fn, &[_]Value{});
    if (iterator.bits == 0 or iterator.unbox() != .object) return throwTypeError(arena, "[Symbol.iterator]() returned a non-object");
    const next_fn = try ctx.getProp(arena, iterator, "next");
    if (!isCallableVal(next_fn)) return throwTypeError(arena, "iterator.next is not a function");
    var guard: usize = 0;
    while (true) {
        guard += 1;
        if (guard > 100_000_000) break;
        const res = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
        if (res.bits == 0 or res.unbox() != .object) return throwTypeError(arena, "iterator.next() returned a non-object");
        const done = try ctx.getProp(arena, res, "done");
        if (isTruthyVal(done)) break;
        const val = try ctx.getProp(arena, res, "value");
        try items.append(arena, val);
    }
    return true;
}

fn isCallableVal(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .native_function, .bc_function, .function => true,
        .object => |o| o.is_callable_intrinsic or o.internal_kind == .bound_function or o.get("__call__") != null,
        else => false,
    };
}

fn isTruthyVal(v: Value) bool {
    return val_mod.toBoolean(v);
}

fn isTruthyValue(v: Value) bool {
    return val_mod.toBoolean(v);
}

/// ES2015 Array.of(...items) — §23.1.2.3. Like Array.from, `this` is the
/// constructor to build with, elements go in via CreateDataPropertyOrThrow, and
/// `length` is written with a throwing [[Set]].
fn nativeArrayOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ctx = active_context orelse return throwTypeError(arena, "no active context");
    const a = try arrayFromCtor(arena, ctx, this_val, args.len, true);
    for (args, 0..) |v, i| try array_proto_mod.genCreate(arena, a, i, v);
    try ctx.setPropThrow(arena, a, "length", try val_mod.makeNumber(arena, @floatFromInt(args.len)));
    return a;
}

/// ES2023 Array.fromAsync(items, mapFn?, thisArg?) → Promise<Array>
/// Drives async/sync iterables and array-likes; each element is awaited
/// so thenables are unwrapped. Always returns a Promise.
fn nativeArrayFromAsync(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // not-a-constructor guard (§23.1.2.2 step 1)
    if (active_constructing) {
        active_constructing = false;
        return throwTypeError(arena, "Array.fromAsync is not a constructor");
    }
    const result = arrayFromAsyncWork(arena, this_val, args) catch |e| {
        if (e == error.JsException) {
            const ex = pending_exception;
            pending_exception = Value{};
            return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{ex});
        }
        return e;
    };
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{result});
}

/// IsConstructor(C): the this-value used as A's constructor by Array.fromAsync.
fn faIsConstructor(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => true,
        .object => |o| o.is_callable_intrinsic or o.get("__call__") != null or
            o.internal_kind == .bound_function or
            o.internal_kind == .proxy,
        else => false,
    };
}

/// GetMethod(V, key): returns `.undefined` (bits==0 sentinel via Value{}) when the
/// property is undefined or null, the callable when present-and-callable, and
/// throws a TypeError when present-but-not-callable (§7.3.11).
fn faGetMethod(arena: std.mem.Allocator, ctx: *Context, target: Value, sym: Value) anyerror!Value {
    const m = try ctx.getPropSym(arena, target, sym);
    if (m.bits == 0) return Value{};
    switch (m.unbox()) {
        .undefined_, .null_ => return Value{},
        else => {},
    }
    if (!isCallableVal(m)) return throwTypeError(arena, "Array.fromAsync: iterator method is not callable");
    return m;
}

/// CreateDataPropertyOrThrow(A, Pk, value) for the fromAsync result. Ordinary
/// objects go through [[DefineOwnProperty]] directly (so non-configurable
/// clashes throw); anything exotic falls back to a throwing [[Set]].
fn faCreateDataProperty(arena: std.mem.Allocator, ctx: *Context, a: Value, key: []const u8, value: Value) anyerror!void {
    if (a.bits != 0 and a.unbox() == .object) {
        const o = a.toPtr().object;
        if (o.internal_kind != .proxy) {
            const ok = try o.defineOwnData(key, value, .{ .writable = true, .enumerable = true, .configurable = true });
            if (!ok) return throwTypeError(arena, "Array.fromAsync: cannot define result element");
            return;
        }
    }
    try ctx.setPropThrow(arena, a, key, value);
}

/// ArrayCreate(len) for the non-constructor path. `len` must be a valid array
/// length (< 2³²) or a RangeError is thrown (§10.4.2.2).
fn faArrayCreate(arena: std.mem.Allocator, len: usize) !Value {
    if (len > 4294967295) return throwRangeError(arena, "Invalid array length");
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    obj.array_length = @intCast(len);
    return val_mod.makeObject(arena, obj);
}

/// Allocate a fresh ordinary Array (ArrayCreate(0)) for the iterator path.
fn faNewArray(arena: std.mem.Allocator) !Value {
    return faArrayCreate(arena, 0);
}

fn arrayFromAsyncWork(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const src = if (args.len > 0) args[0] else Value{};
    const map_fn_raw = if (args.len > 1) args[1] else Value{};
    const this_arg = if (args.len > 2) args[2] else try val_mod.makeUndefined(arena);

    // mapping is true unless mapfn is undefined; a present-but-not-callable mapfn
    // (including null) is a TypeError (§23.1.2.1 step 3.a-b).
    const map_undefined = map_fn_raw.bits == 0 or map_fn_raw.unbox() == .undefined_;
    const has_map = !map_undefined;
    if (has_map and !isCallableVal(map_fn_raw))
        return throwTypeError(arena, "Array.fromAsync: mapFn is not callable");

    const ctx = active_context orelse return faNewArray(arena);

    // GetMethod(asyncItems, @@asyncIterator) coerces null/undefined via GetV, which
    // throws — so reject for a null/undefined source (§23.1.2.1 step 3.c).
    if (src.bits == 0 or src.unbox() == .undefined_ or src.unbox() == .null_)
        return throwTypeError(arena, "Array.fromAsync: items is null or undefined");

    // Read-target: objects are used as-is (preserve identity for observable
    // property access); primitives coerce to a wrapper (GetV/ToObject semantics).
    const read_target = if (src.unbox() == .object or isCallableVal(src)) src else try toObjectForThis(arena, src);

    const is_ctor = faIsConstructor(this_val);

    // Resolve async → sync iterator method with GetMethod semantics.
    var using_async = Value{};
    if (active_sym_async_iterator) |async_sym|
        using_async = try faGetMethod(arena, ctx, read_target, async_sym);
    var using_sync = Value{};
    if (using_async.bits == 0) {
        if (active_sym_iterator) |iter_sym|
            using_sync = try faGetMethod(arena, ctx, read_target, iter_sym);
    }

    if (using_async.bits != 0 or using_sync.bits != 0) {
        const is_async = using_async.bits != 0;
        const iter_fn = if (is_async) using_async else using_sync;
        const iterator = try function_proto_mod.invokeCallback(arena, read_target, iter_fn, &[_]Value{});
        if (iterator.bits == 0 or iterator.unbox() != .object)
            return throwTypeError(arena, "Array.fromAsync: iterator method did not return an object");
        const next_fn = try ctx.getProp(arena, iterator, "next");
        if (!isCallableVal(next_fn))
            return throwTypeError(arena, "Array.fromAsync: iterator.next is not a function");

        // If IsConstructor(C): A = Construct(C); else ArrayCreate(0).
        const a = if (is_ctor) try ctx.construct(arena, this_val, &[_]Value{}) else try faNewArray(arena);

        var buf: [32]u8 = undefined;
        var k: usize = 0;
        while (k < 9007199254740991) : (k += 1) {
            const raw = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
            // Sync iterables are adapted through CreateAsyncFromSyncIterator, which
            // awaits the next() result; async iterables already return a promise.
            const step = try promise_mod.awaitValue(arena, raw);
            if (step.bits == 0 or step.unbox() != .object)
                return throwTypeError(arena, "Array.fromAsync: iterator result is not an object");
            const done_v = try ctx.getProp(arena, step, "done");
            if (isTruthyVal(done_v)) {
                try ctx.setPropThrow(arena, a, "length", try val_mod.makeNumber(arena, @floatFromInt(k)));
                return a;
            }
            var val = try ctx.getProp(arena, step, "value");
            // Spec: async-iterator values are used directly (already settled by
            // CreateAsyncFromSyncIterator / the async generator's own AsyncGeneratorYield
            // Await). Our async generators do not yet pre-await yielded operands, so we
            // await here to compensate — matching observable behaviour for every case
            // except `does-not-await-input` (tracked as a known async-generator gap).
            val = try promise_mod.awaitValue(arena, val);
            if (has_map) {
                const idx_v = try val_mod.makeNumber(arena, @floatFromInt(k));
                const mapped = faMapValue(arena, map_fn_raw, this_arg, val, idx_v) catch |e|
                    return faCloseOnAbrupt(arena, ctx, iterator, e);
                val = promise_mod.awaitValue(arena, mapped) catch |e|
                    return faCloseOnAbrupt(arena, ctx, iterator, e);
            }
            const key = try std.fmt.bufPrint(&buf, "{d}", .{k});
            faCreateDataProperty(arena, ctx, a, key, val) catch |e|
                return faCloseOnAbrupt(arena, ctx, iterator, e);
        }
        return throwTypeError(arena, "Array.fromAsync: iterator produced too many values");
    }

    // Array-like branch: length then elements by index (each awaited).
    const len_v = try ctx.getProp(arena, read_target, "length");
    const len_awaited = try promise_mod.awaitValue(arena, len_v);
    // LengthOfArrayLike = ToLength(ToNumber(length)); ToNumber throws on
    // BigInt/Symbol and propagates a throwing valueOf.
    const len_n = try toNumberCheckedRealm(arena, len_awaited);
    const len: usize = if (std.math.isNan(len_n) or len_n <= 0)
        0
    else
        @min(@as(usize, @intFromFloat(@trunc(len_n))), 9007199254740991);

    // If IsConstructor(C): A = Construct(C, «len»); else ArrayCreate(len)
    // (which rejects len ≥ 2³² with a RangeError).
    const a = if (is_ctor)
        try ctx.construct(arena, this_val, &[_]Value{try val_mod.makeNumber(arena, @floatFromInt(len))})
    else
        try faArrayCreate(arena, len);

    var buf: [32]u8 = undefined;
    var k: usize = 0;
    while (k < len) : (k += 1) {
        const key = try std.fmt.bufPrint(&buf, "{d}", .{k});
        var val = try ctx.getProp(arena, read_target, key);
        val = try promise_mod.awaitValue(arena, val);
        if (has_map) {
            const idx_v = try val_mod.makeNumber(arena, @floatFromInt(k));
            const mapped = try faMapValue(arena, map_fn_raw, this_arg, val, idx_v);
            val = try promise_mod.awaitValue(arena, mapped);
        }
        try faCreateDataProperty(arena, ctx, a, key, val);
    }
    try ctx.setPropThrow(arena, a, "length", try val_mod.makeNumber(arena, @floatFromInt(len)));
    return a;
}

/// Call(mapfn, thisArg, «value, 𝔽(k)»).
fn faMapValue(arena: std.mem.Allocator, map_fn: Value, this_arg: Value, value: Value, idx: Value) anyerror!Value {
    return function_proto_mod.invokeCallback(arena, this_arg, map_fn, &[_]Value{ value, idx });
}

/// IfAbruptCloseAsyncIterator: on an abrupt completion inside the iterator loop,
/// invoke the iterator's `return` method (ignoring its result/errors), then
/// re-raise the original completion.
fn faCloseOnAbrupt(arena: std.mem.Allocator, ctx: *Context, iterator: Value, err: anyerror) anyerror {
    if (err != error.JsException) return err;
    const saved = pending_exception;
    const ret_fn = ctx.getProp(arena, iterator, "return") catch Value{};
    if (ret_fn.bits != 0 and isCallableVal(ret_fn)) {
        const r = function_proto_mod.invokeCallback(arena, iterator, ret_fn, &[_]Value{}) catch Value{};
        _ = promise_mod.awaitValue(arena, r) catch {};
    }
    pending_exception = saved;
    return error.JsException;
}

/// Cycle-detection context for structuredClone — O(n) list scan is fine for
/// typical object graphs; avoids a HashMap dependency in this file.
const StructuredCloneCtx = struct {
    seen_keys: std.ArrayListUnmanaged(*JsObject) = .empty,
    seen_vals: std.ArrayListUnmanaged(Value) = .empty,

    fn lookup(self: *StructuredCloneCtx, obj: *JsObject) ?Value {
        for (self.seen_keys.items, 0..) |k, i| {
            if (k == obj) return self.seen_vals.items[i];
        }
        return null;
    }

    fn record(self: *StructuredCloneCtx, alloc: std.mem.Allocator, obj: *JsObject, val: Value) !void {
        try self.seen_keys.append(alloc, obj);
        try self.seen_vals.append(alloc, val);
    }
};

fn structuredCloneInner(arena: std.mem.Allocator, v: Value, ctx: *StructuredCloneCtx) anyerror!Value {
    if (v.bits == 0) return v; // undefined (zero Value)
    switch (v.unbox()) {
        // Primitives pass through as-is.
        .undefined_, .null_, .boolean, .number, .string, .bigint => return v,
        .symbol => return throwTypeError(arena, "structuredClone: Symbol values cannot be cloned"),
        .native_function, .bc_function, .function => return throwTypeError(arena, "structuredClone: Function values cannot be cloned"),
        .object => |obj| {
            // Reject uncloneable internal kinds.
            switch (obj.internal_kind) {
                .bound_function,
                .promise,
                .generator,
                .proxy,
                .weakmap,
                .weakset,
                .weakref,
                .finalization_registry,
                .shadow_realm,
                .module_namespace,
                .wrapped_function,
                => return throwTypeError(arena, "structuredClone: value could not be cloned"),
                else => {},
            }
            // Callable plain objects (native ctor-objects etc.) are function-like.
            if (obj.internal_kind == .none and obj.get("__call__") != null)
                return throwTypeError(arena, "structuredClone: Function values cannot be cloned");

            // Cycle / identity preservation.
            if (ctx.lookup(obj)) |existing| return existing;

            switch (obj.internal_kind) {
                .date => {
                    const ms = date_mod.getDateMs(v) orelse 0;
                    const new_obj = if (active_heap) |h|
                        try JsObject.createOnHeap(h, date_mod.active_date_proto)
                    else
                        try JsObject.create(arena, date_mod.active_date_proto);
                    new_obj.internal_kind = .date;
                    const dd = try arena.create(date_mod.DateData);
                    dd.* = .{ .ms = ms };
                    new_obj.internal_slot = dd;
                    const cloned = try val_mod.makeObject(arena, new_obj);
                    try ctx.record(arena, obj, cloned);
                    return cloned;
                },
                .regexp => {
                    // Shallow-clone: share the compiled pattern (read-only).
                    const new_obj = if (active_heap) |h|
                        try JsObject.createOnHeap(h, active_regexp_proto)
                    else
                        try JsObject.create(arena, active_regexp_proto);
                    new_obj.internal_kind = .regexp;
                    new_obj.internal_slot = obj.internal_slot; // share compiled regex
                    for (obj.ownKeys()) |k| {
                        if (obj.getOwn(k)) |pv| try new_obj.set(k, pv);
                    }
                    const cloned = try val_mod.makeObject(arena, new_obj);
                    try ctx.record(arena, obj, cloned);
                    return cloned;
                },
                .map => {
                    const new_obj = if (active_heap) |h|
                        try JsObject.createOnHeap(h, es2015_collections_mod.active_map_proto)
                    else
                        try JsObject.create(arena, es2015_collections_mod.active_map_proto);
                    new_obj.internal_kind = .map;
                    const new_data = try arena.create(es2015_collections_mod.MapData);
                    new_data.* = .{};
                    new_obj.internal_slot = new_data;
                    const cloned = try val_mod.makeObject(arena, new_obj);
                    try ctx.record(arena, obj, cloned);
                    if (obj.internal_slot) |s| {
                        const orig: *es2015_collections_mod.MapData = @ptrCast(@alignCast(s));
                        for (orig.keys.items, 0..) |mk, i| {
                            const mv = orig.values.items[i];
                            const ck = try structuredCloneInner(arena, mk, ctx);
                            const cv = try structuredCloneInner(arena, mv, ctx);
                            try new_data.keys.append(arena, ck);
                            try new_data.values.append(arena, cv);
                        }
                    }
                    return cloned;
                },
                .set => {
                    const new_obj = if (active_heap) |h|
                        try JsObject.createOnHeap(h, es2015_collections_mod.active_set_proto)
                    else
                        try JsObject.create(arena, es2015_collections_mod.active_set_proto);
                    new_obj.internal_kind = .set;
                    const new_data = try arena.create(es2015_collections_mod.SetData);
                    new_data.* = .{};
                    new_obj.internal_slot = new_data;
                    const cloned = try val_mod.makeObject(arena, new_obj);
                    try ctx.record(arena, obj, cloned);
                    if (obj.internal_slot) |s| {
                        const orig: *es2015_collections_mod.SetData = @ptrCast(@alignCast(s));
                        for (orig.values.items) |sv| {
                            const csv = try structuredCloneInner(arena, sv, ctx);
                            try new_data.values.append(arena, csv);
                        }
                    }
                    return cloned;
                },
                .array_buffer, .typed_array, .data_view, .shared_array_buffer => {
                    // Pragmatic: return same object (transfer semantics not implemented).
                    return v;
                },
                else => {
                    // Plain object, array, Error, wrapper — deep-clone own enumerable props.
                    const is_array = obj.is_array;
                    const proto: ?*JsObject = if (is_array) active_array_proto else active_object_proto;
                    const new_obj = if (active_heap) |h|
                        try JsObject.createOnHeap(h, proto)
                    else
                        try JsObject.create(arena, proto);
                    new_obj.is_array = is_array;
                    if (is_array) new_obj.array_length = obj.array_length;
                    const cloned = try val_mod.makeObject(arena, new_obj);
                    try ctx.record(arena, obj, cloned);
                    // Deep-clone own enumerable string-keyed properties.
                    for (obj.ownKeys()) |k| {
                        if (!obj.isEnumerable(k)) continue;
                        const pv = obj.getOwn(k) orelse continue;
                        const cv = try structuredCloneInner(arena, pv, ctx);
                        try new_obj.set(k, cv);
                    }
                    // Deep-clone own enumerable symbol-keyed properties.
                    for (obj.sym_props.items) |sp| {
                        if (!sp.attr.enumerable) continue;
                        const cs = try structuredCloneInner(arena, sp.value, ctx);
                        try new_obj.setSym(sp.key, cs);
                    }
                    return cloned;
                },
            }
        },
    }
}

/// ES2022 structuredClone(value, options?) — deep structural clone with
/// circular-reference identity preservation. Throws TypeError for uncloneable
/// types (functions, symbols). options.transfer is not implemented (stub).
fn nativeStructuredClone(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else try val_mod.makeUndefined(arena);
    if (v.bits == 0) return v;
    var sctx = StructuredCloneCtx{};
    return structuredCloneInner(arena, v, &sctx);
}

/// ES ToNumber with ToPrimitive(number) for objects (invokes valueOf/toString),
/// so a `{valueOf(){...}}` receiver's hook fires. BigInt yields NaN here (callers
/// that must reject BigInt do so separately).
pub fn toNumberValue(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        .null_ => 0,
        .undefined_ => std.math.nan(f64),
        .string => |s| val_mod.jsStringToNumber(s),
        .object => blk: {
            if (try coercion_mod.toPrimitive(arena, v, .number)) |prim| {
                if (prim.bits != 0 and prim.unbox() == .object) break :blk std.math.nan(f64);
                break :blk try toNumberValue(arena, prim);
            }
            break :blk std.math.nan(f64);
        },
        else => std.math.nan(f64),
    };
}

/// ES ToLength: ToInteger(ToNumber(v)) clamped to [0, 2^53-1].
pub fn toLengthValue(arena: std.mem.Allocator, v: Value) anyerror!usize {
    const n = try toNumberValue(arena, v);
    if (std.math.isNan(n) or n <= 0) return 0;
    const capped = @min(std.math.trunc(n), 9007199254740991.0);
    return @intFromFloat(capped);
}

pub fn stringPrimitive(arena: std.mem.Allocator, arg: Value) anyerror![]const u8 {
    if (arg.bits == 0) return "undefined";
    return switch (arg.unbox()) {
        .string => |s| s,
        .number => |n| try val_mod.formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .null_ => "null",
        .undefined_ => "undefined",
        .bigint => |b| try val_mod.bigIntToString(arena, b),
        // ToString(Symbol) throws a TypeError (§7.1.17). The one non-throwing
        // Symbol→String path — `String(sym)` as a plain call — is special-cased by
        // the caller before it reaches here, so any Symbol arriving must throw
        // (e.g. `new String(sym)`, template/`+` coercion).
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a string"),
        // Functions are objects too: `String(function f(){})` is the source
        // text produced by Function.prototype.toString, not "[object Object]".
        .object, .function, .bc_function, .native_function => blk: {
            // ToString(ToPrimitive(arg, "string")) when a user hook applies.
            if (try coercion_mod.toPrimitive(arena, arg, .string)) |prim|
                break :blk try stringPrimitive(arena, prim);
            break :blk "[object Object]";
        },
    };
}

fn nativeStringCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = active_constructing;
    active_constructing = false;
    // String(sym) as a plain call is the sole non-throwing Symbol→String path:
    // it returns SymbolDescriptiveString (ES §22.1.1.1 step 2b). `new String(sym)`
    // still throws (falls through to stringPrimitive).
    if (!constructing and args.len > 0 and args[0].bits != 0 and args[0].unbox() == .symbol) {
        const sd = args[0].unbox().symbol;
        const out = try std.fmt.allocPrint(arena, "Symbol({s})", .{sd.description orelse ""});
        return val_mod.makeString(arena, out);
    }
    const s: []const u8 = if (args.len == 0) "" else try stringPrimitive(arena, args[0]);
    // `new String(x)`: wrap on the synthesized object; plain call returns primitive.
    if (constructing and this_val.bits != 0 and this_val.unbox() == .object) {
        const obj = this_val.toPtr().object;
        try obj.set("[[PrimitiveValue]]", try val_mod.makeString(arena, s));
        // A String exotic object exposes each UTF-16 code unit as an own property
        // { enumerable, non-writable, non-configurable } plus an own non-enumerable
        // "length" (ES 10.4.3 StringCreate / String-exotic define-own-property).
        try installStringExotic(arena, obj, s);
        return this_val;
    }
    return val_mod.makeString(arena, s);
}

/// ToString for a String.raw segment/substitution (primitive-coercing).
fn rawToStr(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    switch (v.unbox()) {
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .null_ => return "null",
        .undefined_ => return "undefined",
        .bigint => |b| return try val_mod.bigIntToString(arena, b),
        // ToString(symbol) throws a TypeError (§7.1.17).
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a string"),
        else => {
            if (try coercion_mod.toPrimitive(arena, v, .string)) |prim| {
                if (prim.bits != 0 and prim.unbox() == .string) return prim.toPtr().string;
                if (prim.bits != 0 and prim.unbox() == .symbol) return throwTypeError(arena, "Cannot convert a Symbol value to a string");
                return try stringPrimitive(arena, prim);
            }
            return "[object Object]";
        },
    }
}

/// String.raw(template, ...substitutions): join template.raw segments with the
/// ToString of each substitution interleaved (ES §22.1.2.4).
fn nativeStringRaw(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object)
        return throwTypeError(arena, "String.raw called on non-object");
    // raw = ToObject(Get(cooked, "raw")); a getter's abrupt completion propagates
    // and a non-object raw throws (ToObject on undefined/null/primitive).
    const raw_v = if (active_context) |ctx| try ctx.getProp(arena, args[0], "raw") else (args[0].toPtr().object.get("raw") orelse Value{});
    if (raw_v.bits == 0 or raw_v.unbox() != .object)
        return throwTypeError(arena, "String.raw: template.raw must be an object");
    const raw = raw_v.toPtr().object;
    // literalSegments = LengthOfArrayLike(raw) = ToLength(Get(raw, "length")) —
    // a generic array-like `raw` (not necessarily a real Array) is honored. Read
    // through the context so an array's synthetic length and inherited/getter
    // "length" (and its valueOf coercion) are resolved.
    const len_v: Value = if (active_context) |ctx| try ctx.getProp(arena, raw_v, "length") else (raw.get("length") orelse Value{});
    // ToLength(Get(raw,"length")) → ToNumber throws for a Symbol/BigInt length.
    if (len_v.bits != 0) switch (len_v.unbox()) {
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .bigint => return throwTypeError(arena, "Cannot convert a BigInt value to a number"),
        else => {},
    };
    const len_num = if (len_v.bits != 0 and len_v.unbox() == .object)
        toNumberCoerce((try coercion_mod.toPrimitive(arena, len_v, .number)) orelse len_v)
    else
        toNumberCoerce(len_v);
    const seg_count: usize = if (std.math.isNan(len_num) or len_num <= 0)
        0
    else if (len_num >= 9007199254740991.0)
        9007199254740991
    else
        @intFromFloat(@trunc(len_num));
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const seg = if (active_context) |ctx| try ctx.getProp(arena, raw_v, key) else (raw.get(key) orelse Value{});
        try buf.appendSlice(arena, try rawToStr(arena, seg));
        // Interleave substitution i (args[i+1]) between segments, but not after last.
        if (i + 1 < seg_count and i + 1 < args.len) {
            try buf.appendSlice(arena, try rawToStr(arena, args[i + 1]));
        }
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES ToUint16: ToNumber, then map into [0, 0xFFFF] via mathematical modulo.
/// NaN / ±Infinity → 0. Object args coerce through ToPrimitive(number).
fn toUint16(arena: std.mem.Allocator, v: Value) anyerror!u16 {
    var num: f64 = undefined;
    if (v.bits == 0) {
        num = std.math.nan(f64);
    } else switch (v.unbox()) {
        .number => |n| num = n,
        .object => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .number)) orelse Value{};
            if (prim.bits != 0 and prim.unbox() == .object) num = std.math.nan(f64) else return toUint16(arena, prim);
        },
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .bigint => return throwTypeError(arena, "Cannot convert a BigInt value to a number"),
        else => num = toNumberCoerce(v),
    }
    if (std.math.isNan(num) or std.math.isInf(num)) return 0;
    return @intFromFloat(@mod(@trunc(num), 65536.0));
}

/// String.fromCharCode(...codeUnits): each argument is ToUint16'd to a UTF-16
/// code unit and appended as WTF-8 (lone surrogates stay raw, matching the
/// engine's CESU-8 string storage).
fn nativeStringFromCharCode(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf = std.ArrayList(u8){};
    for (args) |arg| {
        const code = try toUint16(arena, arg);
        try appendWtf8Cp(&buf, arena, code);
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES ToNumber that coerces objects via ToPrimitive(number) and throws on
/// Symbol / BigInt (used by fromCodePoint's RangeError validation).
pub fn toNumberCheckedRealm(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    // An object with no callable valueOf/toString is a TypeError, not NaN.
    return coercion_mod.toNumberThrowing(arena, v);
}

/// String.fromCodePoint(...codePoints): each argument must be a non-negative
/// integer ≤ 0x10FFFF (else RangeError); astral points become surrogate pairs.
fn nativeStringFromCodePoint(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf = std.ArrayList(u8){};
    for (args) |arg| {
        const num = try toNumberCheckedRealm(arena, arg);
        if (num != @trunc(num) or std.math.isNan(num) or num < 0 or num > 0x10FFFF) {
            return throwRangeError(arena, "Invalid code point");
        }
        try appendWtf8Cp(&buf, arena, @intFromFloat(num));
    }
    return val_mod.makeString(arena, buf.items);
}

fn toNumberCoerce(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        .null_ => 0,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, &std.ascii.whitespace);
            if (t.len == 0) break :blk 0;
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        else => std.math.nan(f64),
    };
}

fn nativeIsNaN(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = try coercion_mod.toNumberThrowing(arena, if (args.len > 0) args[0] else Value{});
    return val_mod.makeBool(arena, std.math.isNan(n));
}

fn nativeIsFinite(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = try coercion_mod.toNumberThrowing(arena, if (args.len > 0) args[0] else Value{});
    return val_mod.makeBool(arena, !std.math.isNan(n) and !std.math.isInf(n));
}

/// ES StrWhiteSpace code point (WhiteSpace ∪ LineTerminator): the set of chars
/// parseInt / parseFloat strip from the front of the input.
fn isStrWhiteSpaceCp(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => cp >= 0x2000 and cp <= 0x200A,
    };
}

/// Byte offset past the leading run of StrWhiteSpace code points in a WTF-8 str.
fn trimLeadingStrWs(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const du = string_proto_mod.decodeWtf8At(s, i);
        if (!isStrWhiteSpaceCp(du.cp)) break;
        i += du.len;
    }
    return i;
}

/// ES ToInt32: ToNumber (already done by caller) → truncate → wrap to [−2³¹,2³¹).
fn toInt32FromF64(num: f64) i32 {
    if (std.math.isNan(num) or std.math.isInf(num)) return 0;
    const m = @mod(@trunc(num), 4294967296.0); // [0, 2^32)
    const u: u32 = @intFromFloat(m);
    return @bitCast(u);
}

fn nativeParseFloat(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const input = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    const s = input[trimLeadingStrWs(input)..];
    // "Infinity" (optionally signed) → ±∞ per StrDecimalLiteral.
    var body = s;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        body = s[1..];
    }
    if (std.mem.startsWith(u8, body, "Infinity")) {
        return val_mod.makeNumber(arena, if (neg) -std.math.inf(f64) else std.math.inf(f64));
    }
    // Longest StrDecimalLiteral prefix of the (signed) trimmed string.
    var end: usize = 0;
    var seen_dot = false;
    var seen_e = false;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (c >= '0' and c <= '9') continue;
        if (c == '.' and !seen_dot and !seen_e) {
            seen_dot = true;
            continue;
        }
        if ((c == 'e' or c == 'E') and !seen_e and end > 0) {
            seen_e = true;
            continue;
        }
        if ((c == '+' or c == '-') and (end == 0 or s[end - 1] == 'e' or s[end - 1] == 'E')) continue;
        break;
    }
    // Trim a trailing exponent marker / sign with no digits (e.g. "1e", "1e+").
    while (end > 0) {
        const last = s[end - 1];
        if (last == 'e' or last == 'E' or last == '+' or last == '-') end -= 1 else break;
    }
    if (end == 0) return val_mod.makeNumber(arena, std.math.nan(f64));
    const parsed = std.fmt.parseFloat(f64, s[0..end]) catch std.math.nan(f64);
    return val_mod.makeNumber(arena, parsed);
}

fn nativeParseInt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const input = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    var s = input[trimLeadingStrWs(input)..];
    var sign: f64 = 1;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        if (s[0] == '-') sign = -1;
        s = s[1..];
    }
    // ToInt32(radix): 0 (or absent) means "decimal, allow 0x"; else must be 2..36.
    var radix: u8 = 10;
    var strip_prefix = true;
    if (args.len > 1) {
        const r = toInt32FromF64(try toNumberCheckedRealm(arena, args[1]));
        if (r != 0) {
            if (r < 2 or r > 36) return val_mod.makeNumber(arena, std.math.nan(f64));
            radix = @intCast(r);
            if (radix != 16) strip_prefix = false;
        }
    }
    if (strip_prefix and s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        radix = 16;
        s = s[2..];
    }
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        _ = std.fmt.charToDigit(s[end], radix) catch break;
    }
    if (end == 0) return val_mod.makeNumber(arena, std.math.nan(f64));
    // Accumulate in f64 so arbitrarily long digit runs saturate to the nearest
    // representable value instead of overflowing an integer.
    var value: f64 = 0;
    const rf: f64 = @floatFromInt(radix);
    for (s[0..end]) |c| {
        const d = std.fmt.charToDigit(c, radix) catch unreachable;
        value = value * rf + @as(f64, @floatFromInt(d));
    }
    return val_mod.makeNumber(arena, sign * value);
}

// ---- URI handling (encodeURI / decodeURI / *Component) — ECMAScript §19.2.6 ----

/// Raise a `URIError` from a native (malformed input for decode / unpaired
/// surrogate for encode).
fn throwURIError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h|
        try JsObject.createOnHeap(h, error_proto_URIError)
    else
        try JsObject.create(arena, error_proto_URIError);
    try eo.set("message", try val_mod.makeString(arena, msg));
    try eo.set("name", try val_mod.makeString(arena, "URIError"));
    pending_exception = try val_mod.makeObject(arena, eo);
    return error.JsException;
}

/// ES ToString for URI arguments: primitive-coercing, throws TypeError on Symbol.
fn uriToString(arena: std.mem.Allocator, v: Value) anyerror![]const u8 {
    if (v.bits == 0) return "undefined";
    switch (v.unbox()) {
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .null_ => return "null",
        .undefined_ => return "undefined",
        .bigint => |bi| return try val_mod.bigIntToString(arena, bi),
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a string"),
        .object, .function, .bc_function, .native_function => {
            // ToString(object): ToPrimitive(string). A missing/uncallable
            // toString & valueOf (null result) is a TypeError, not a fallback.
            const prim = (try coercion_mod.toPrimitive(arena, v, .string)) orelse
                return throwTypeError(arena, "Cannot convert object to primitive value");
            if (!coercion_mod.isPrimitive(prim)) return "[object Object]";
            return uriToString(arena, prim);
        },
    }
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Append a scalar value as WTF-8 / CESU-8: BMP → 1-3 bytes, astral → a
/// UTF-16 surrogate pair (two 3-byte sequences), matching the engine's string
/// storage so decoded astral chars round-trip through charCodeAt / length.
fn appendWtf8Cp(buf: *std.ArrayList(u8), arena: std.mem.Allocator, cp: u21) !void {
    if (cp <= 0x7F) {
        try buf.append(arena, @intCast(cp));
    } else if (cp <= 0x7FF) {
        try buf.append(arena, @intCast(0xC0 | (cp >> 6)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
        try buf.append(arena, @intCast(0xE0 | (cp >> 12)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else {
        const v: u32 = @as(u32, cp) - 0x10000;
        try appendWtf8Cp(buf, arena, @intCast(0xD800 + (v >> 10)));
        try appendWtf8Cp(buf, arena, @intCast(0xDC00 + (v & 0x3FF)));
    }
}

fn appendPctByte(buf: *std.ArrayList(u8), arena: std.mem.Allocator, byte: u8) !void {
    const upper = "0123456789ABCDEF";
    try buf.append(arena, '%');
    try buf.append(arena, upper[byte >> 4]);
    try buf.append(arena, upper[byte & 0x0F]);
}

/// uriUnescaped ::: uriAlpha | DecimalDigit | uriMark  (never %-encoded).
fn isUriUnescaped(c: u8) bool {
    if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) return true;
    return switch (c) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

/// uriReserved (`; / ? : @ & = + $ ,`) plus `#`. For encodeURI these join the
/// unescaped set; for decodeURI these stay %-encoded in the output.
fn isUriReservedOrHash(c: u8) bool {
    return switch (c) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

/// Shared Encode (§19.2.6.4). `component` = true for the *Component variants
/// (only uriUnescaped survives); false for encodeURI (uriReserved + `#` also
/// survive). Iterates the receiver's WTF-8 code units, throwing URIError on
/// an unpaired surrogate.
fn uriEncode(arena: std.mem.Allocator, s: []const u8, component: bool) anyerror!Value {
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const du = string_proto_mod.decodeWtf8At(s, i);
        const cu: u21 = du.cp;
        // ASCII fast path: single code unit that is a member of the unescaped set.
        const in_unescaped = cu <= 0x7F and
            (isUriUnescaped(@intCast(cu)) or (!component and isUriReservedOrHash(@intCast(cu))));
        if (in_unescaped) {
            try buf.append(arena, @intCast(cu));
            i += du.len;
            continue;
        }
        // Resolve the code point, combining a UTF-16 surrogate pair; a lone
        // surrogate (high without a following low, or a bare low) is a URIError.
        var v: u21 = cu;
        var consumed = du.len;
        if (cu >= 0xDC00 and cu <= 0xDFFF) {
            return throwURIError(arena, "URI malformed");
        } else if (cu >= 0xD800 and cu <= 0xDBFF) {
            const next_i = i + du.len;
            if (next_i >= s.len) return throwURIError(arena, "URI malformed");
            const du2 = string_proto_mod.decodeWtf8At(s, next_i);
            if (du2.cp < 0xDC00 or du2.cp > 0xDFFF) return throwURIError(arena, "URI malformed");
            v = @intCast((@as(u32, cu) - 0xD800) * 0x400 + (@as(u32, du2.cp) - 0xDC00) + 0x10000);
            consumed += du2.len;
        }
        // Real (non-WTF) UTF-8 encoding of the scalar value, %-encoded per octet.
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(v, &utf8) catch return throwURIError(arena, "URI malformed");
        for (utf8[0..n]) |b| try appendPctByte(&buf, arena, b);
        i += consumed;
    }
    return val_mod.makeString(arena, buf.items);
}

/// Shared Decode (§19.2.6.5). `preserve_reserved` = true for decodeURI (leaves
/// reserved+`#` escapes intact); false for decodeURIComponent. Emits WTF-8, so
/// astral scalars become CESU-8 surrogate pairs consistent with the rest of the
/// engine's string storage.
fn uriDecode(arena: std.mem.Allocator, s: []const u8, preserve_reserved: bool) anyerror!Value {
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '%') {
            try buf.append(arena, c);
            i += 1;
            continue;
        }
        if (i + 2 >= s.len) return throwURIError(arena, "URI malformed");
        const h1 = hexDigit(s[i + 1]) orelse return throwURIError(arena, "URI malformed");
        const h2 = hexDigit(s[i + 2]) orelse return throwURIError(arena, "URI malformed");
        const b0: u8 = (@as(u8, h1) << 4) | h2;
        if (b0 < 0x80) {
            if (preserve_reserved and isUriReservedOrHash(b0)) {
                // Keep the escape sequence verbatim in the output.
                try buf.appendSlice(arena, s[i .. i + 3]);
            } else {
                try buf.append(arena, b0);
            }
            i += 3;
            continue;
        }
        // Multi-byte UTF-8: leading byte determines the octet count.
        const n: usize = if (b0 >= 0xF0) 4 else if (b0 >= 0xE0) 3 else if (b0 >= 0xC0) 2 else 0;
        if (n == 0) return throwURIError(arena, "URI malformed"); // stray continuation byte
        var octets: [4]u8 = undefined;
        octets[0] = b0;
        var j = i + 3;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            if (j + 2 >= s.len or s[j] != '%') return throwURIError(arena, "URI malformed");
            const c1 = hexDigit(s[j + 1]) orelse return throwURIError(arena, "URI malformed");
            const c2 = hexDigit(s[j + 2]) orelse return throwURIError(arena, "URI malformed");
            const bx: u8 = (@as(u8, c1) << 4) | c2;
            if (bx & 0xC0 != 0x80) return throwURIError(arena, "URI malformed");
            octets[k] = bx;
            j += 3;
        }
        const v = std.unicode.utf8Decode(octets[0..n]) catch return throwURIError(arena, "URI malformed");
        try appendWtf8Cp(&buf, arena, v);
        i = j;
    }
    return val_mod.makeString(arena, buf.items);
}

/// Error.prototype.toString (§20.5.3.4): "name: message", with either side
/// dropped when empty. Uses full [[Get]] so accessor `name`/`message` fire, and
/// ToString-coerces both (throwing on Symbol / abrupt ToPrimitive).
fn nativeErrorToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return throwTypeError(arena, "Error.prototype.toString called on non-object");
    const name_v = if (active_context) |c|
        try c.getProp(arena, this_val, "name")
    else
        this_val.toPtr().object.get("name") orelse Value{};
    const name_s = if (name_v.isUndefined()) "Error" else try uriToString(arena, name_v);
    const msg_v = if (active_context) |c|
        try c.getProp(arena, this_val, "message")
    else
        this_val.toPtr().object.get("message") orelse Value{};
    const msg_s = if (msg_v.isUndefined()) "" else try uriToString(arena, msg_v);
    if (name_s.len == 0) return val_mod.makeString(arena, msg_s);
    if (msg_s.len == 0) return val_mod.makeString(arena, name_s);
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ name_s, msg_s }));
}

/// Error.isError(arg) (ES2024): true iff `arg` is an Object with an
/// [[ErrorData]] internal slot — brand-checked, so it holds across realms and
/// rejects fakes that merely inherit from Error.prototype.
fn nativeErrorIsError(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const arg = args[0];
    if (arg.bits == 0 or arg.unbox() != .object) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, arg.toPtr().object.is_error);
}

/// get Error.prototype.stack (error-stack-accessor proposal). Throws for a
/// non-object receiver; returns undefined when the receiver lacks an
/// [[ErrorData]] internal slot; otherwise an implementation-defined stack
/// string. The result depends only on the [[ErrorData]] slot, never on any own
/// "stack" property (which shadows the accessor only for ordinary [[Get]]).
fn nativeErrorStackGet(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (!isObjectLike(this_val))
        return throwTypeError(arena, "Error.prototype.stack getter called on non-object");
    // Only ordinary objects can carry an [[ErrorData]] slot; callable objects
    // (functions) never do, so they fall through to undefined.
    const is_err = this_val.unbox() == .object and this_val.toPtr().object.is_error;
    if (!is_err) return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, "");
}

/// An "Object" in spec terms: an ordinary object or any callable (function).
fn isObjectLike(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .object, .native_function, .bc_function, .function => true,
        else => false,
    };
}

/// `__privInstallAcc__(target, key, getter, setter)` — PrivateMethodOrAccessorAdd
/// for a private accessor. Unlike a private method (which DEFINE_PRIVATE
/// installs), a `get #x`/`set #x` pair is a SINGLE private element carrying both
/// halves, so the desugar emits one call per private name. Installing twice on
/// the same object is a TypeError, which is observable when a base constructor
/// returns an object that already went through this class's initialization.
pub fn nativePrivInstallAcc(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const target = if (args.len > 0) args[0] else Value{};
    const obj = (try @import("builtins/reflect.zig").reflectTargetObjPub(arena, target)) orelse
        return throwTypeError(arena, "Cannot install a private accessor on a non-object");
    const key_v = if (args.len > 1) args[1] else Value{};
    if (key_v.bits == 0 or key_v.unbox() != .string)
        return throwTypeError(arena, "private accessor key must be a string");
    const key = key_v.toPtr().string;
    if (obj.resolveOwnSlot(key) != null) {
        const class_mod = @import("../parser/class.zig");
        const msg = try std.fmt.allocPrint(arena, "Cannot install private member {s} twice on the same object", .{class_mod.privateDisplayName(key)});
        return throwTypeError(arena, msg);
    }
    // Installing a private accessor on a non-extensible object is a TypeError
    // (matches DEFINE_PRIVATE for fields/methods) — see private-class-field-on
    // -nonextensible-objects.
    if (!obj.extensible) {
        const class_mod = @import("../parser/class.zig");
        const msg = try std.fmt.allocPrint(arena, "Cannot install private member {s} on a non-extensible object", .{class_mod.privateDisplayName(key)});
        return throwTypeError(arena, msg);
    }
    // The accessor holder is the same `{ get, set }` shape the ordinary accessor
    // path stores, so privateGet/privateSet read it unchanged.
    const holder = if (active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null);
    if (args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_)
        try holder.set("get", args[2]);
    if (args.len > 3 and args[3].bits != 0 and args[3].unbox() != .undefined_)
        try holder.set("set", args[3]);
    _ = try obj.defineOwnAccessor(key, try val_mod.makeObject(arena, holder), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
        .is_private = true,
    });
    obj.markPrivate(key);
    return Value{};
}

/// Monotonic source of per-evaluation class brand ids. Every evaluation of a
/// class definition that declares private names calls `__getClassBrand__()` once
/// and stores the result in its class-scope `__cbrand_<id>__` binding; private
/// ops append it to the mangled key so instances of one evaluation are not
/// mistaken for instances of another. A single global counter suffices — brands
/// only need to be unique, never compared across classes or realms.
var class_brand_counter: u64 = 0;

/// `__getClassBrand__()` — return the next unique class-evaluation brand id.
pub fn nativeGetClassBrand(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    class_brand_counter += 1;
    return val_mod.makeNumber(arena, @floatFromInt(class_brand_counter));
}

/// `__superSet__(base, key, value, receiver, strict)` — PutValue on a Super
/// Reference. `Reflect.set` alone is not enough on two counts: an assignment
/// evaluates to the assigned *value*, not to the set's boolean result, and in
/// strict code a failed [[Set]] is a TypeError rather than a silent no-op
/// (§6.2.5.6 PutValue step 6.d).
pub fn nativeSuperSet(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const value = if (args.len > 2) args[2] else Value{};
    const ok = try @import("builtins/reflect.zig").nativeReflectSet(arena, .{}, args[0..@min(args.len, 4)]);
    const strict = args.len > 4 and val_mod.toBoolean(args[4]);
    if (strict and !val_mod.toBoolean(ok))
        return throwTypeError(arena, "Cannot assign to read only property of super");
    return value;
}

/// `__checkHeritage__(value)` — ClassDefinitionEvaluation step 8.d: a non-null
/// ClassHeritage value must be a constructor. The check happens *before* the
/// `superclass.prototype` read, so `class C extends (() => {})` throws a
/// TypeError without ever invoking a `prototype` getter on the heritage value.
/// Returns the value unchanged so the desugar can use it as an expression.
pub fn nativeCheckHeritage(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits != 0 and v.unbox() == .null_) return v;
    if (!@import("builtins/reflect.zig").isConstructorVal(v))
        return throwTypeError(arena, "Class extends value is not a constructor or null");
    return v;
}

/// `__derivedReturn__(value, instance)` — the return-override rule a *derived*
/// constructor applies to an explicit `return` (§10.2.2 [[Construct]] step 13).
/// An Object result replaces the instance; `undefined` keeps it; anything else
/// (`null` included, unlike a base class) is a TypeError. Reached only from the
/// class desugar, which rewrites derived-constructor returns to call it.
pub fn nativeDerivedReturn(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const v = if (args.len > 0) args[0] else Value{};
    if (isObjectLike(v)) return v;
    if (v.bits != 0 and v.unbox() != .undefined_)
        return throwTypeError(arena, "Derived constructors may only return an object or undefined");
    // `return undefined` (and a bare `return`) completes with the instance the
    // parent constructor produced. Still undefined ⇒ super() was never called.
    const instance = if (args.len > 1) args[1] else Value{};
    if (instance.bits == 0 or instance.unbox() == .undefined_) {
        const err_obj = if (active_heap) |h|
            try JsObject.createOnHeap(h, referenceErrorProto())
        else
            try JsObject.create(arena, referenceErrorProto());
        try err_obj.set("message", try val_mod.makeString(arena, "must call super constructor before returning from derived constructor"));
        pending_exception = try val_mod.makeObject(arena, err_obj);
        return error.JsException;
    }
    return instance;
}

/// set Error.prototype.stack (error-stack-accessor). Requires a String `v`
/// (else TypeError, never touching [[ErrorData]]), then runs
/// SetterThatIgnoresPrototypeProperties(this, %Error.prototype%, "stack", v):
/// setting on %Error.prototype% itself throws; otherwise an existing own
/// property receives an ordinary [[Set]] (Throw=true) and a missing one is
/// created as a { writable, enumerable, configurable } data property.
fn nativeErrorStackSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (!isObjectLike(this_val))
        return throwTypeError(arena, "Error.prototype.stack setter called on non-object");
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() != .string)
        return throwTypeError(arena, "Error.prototype.stack setter requires a string value");

    // A Proxy receiver drives SetterThatIgnoresPrototypeProperties through its
    // [[GetOwnProperty]] / [[DefineOwnProperty]] / [[Set]] traps (which may throw).
    if (this_val.unbox() == .object and this_val.toPtr().object.internal_kind == .proxy)
        return errorStackSetViaProxy(arena, this_val, v);

    // Ordinary object or callable: resolve the backing JsObject.
    const obj = if (this_val.unbox() == .object)
        this_val.toPtr().object
    else if (active_context) |c|
        (try c.backingObject(arena, this_val)) orelse return val_mod.makeUndefined(arena)
    else
        return val_mod.makeUndefined(arena);

    // Home-object check: assigning to this realm's %Error.prototype% itself throws
    // (emulates a non-writable data property in strict code).
    if (plainErrorProto()) |ep| {
        if (obj == ep) return throwTypeError(arena, "Cannot assign to read only property 'stack' of Error.prototype");
    }
    if (obj.ownAttr("stack")) |attr| {
        // Own property exists → ordinary [[Set]] with Throw=true.
        if (attr.is_accessor) {
            const holder = obj.ownAccessorHolder("stack") orelse Value{};
            const setter = if (holder.bits != 0 and holder.unbox() == .object)
                (holder.toPtr().object.get("set") orelse Value{})
            else
                Value{};
            if (isCallableVal(setter)) {
                _ = try function_proto_mod.invokeCallback(arena, this_val, setter, &[_]Value{v});
            } else {
                return throwTypeError(arena, "Cannot set property 'stack' which has only a getter");
            }
        } else if (!attr.writable) {
            return throwTypeError(arena, "Cannot assign to read only property 'stack'");
        } else {
            try obj.set("stack", v); // writable data: update value, preserve attributes.
        }
    } else if (!try obj.defineOwnData("stack", v, .{ .writable = true, .enumerable = true, .configurable = true })) {
        // CreateDataPropertyOrThrow failed → the receiver is non-extensible.
        return throwTypeError(arena, "Cannot create property 'stack' on a non-extensible object");
    }
    return val_mod.makeUndefined(arena);
}

/// SetterThatIgnoresPrototypeProperties for a Proxy receiver: run the property
/// operations through the object-method builtins so the proxy's traps fire
/// (getOwnPropertyDescriptor → then either defineProperty or set).
fn errorStackSetViaProxy(arena: std.mem.Allocator, proxy_val: Value, v: Value) anyerror!Value {
    const key = try val_mod.makeString(arena, "stack");
    const desc = try obj_methods_mod.nativeObjectGetOwnPropertyDescriptor(arena, Value{}, &[_]Value{ proxy_val, key });
    if (desc.bits == 0 or desc.unbox() == .undefined_) {
        // CreateDataPropertyOrThrow: a data descriptor { value, writable,
        // enumerable, configurable }, all true (defineProperty throws on failure).
        const dd = try JsObject.create(arena, null);
        try dd.set("value", v);
        try dd.set("writable", try val_mod.makeBool(arena, true));
        try dd.set("enumerable", try val_mod.makeBool(arena, true));
        try dd.set("configurable", try val_mod.makeBool(arena, true));
        _ = try obj_methods_mod.nativeObjectDefineProperty(arena, Value{}, &[_]Value{ proxy_val, key, try val_mod.makeObject(arena, dd) });
    } else if (active_context) |c| {
        // Set(proxy, "stack", v, true) → set trap; a false trap result throws.
        try c.setPropThrow(arena, proxy_val, "stack", v);
    }
    return val_mod.makeUndefined(arena);
}

fn nativeEncodeURI(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    return uriEncode(arena, s, false);
}

fn nativeEncodeURIComponent(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    return uriEncode(arena, s, true);
}

fn nativeDecodeURI(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    return uriDecode(arena, s, true);
}

fn nativeDecodeURIComponent(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    return uriDecode(arena, s, false);
}

// ---- Annex B legacy escape / unescape (§B.2.1) ----

/// The set of code units left untouched by `escape`: A-Za-z0-9 plus `@*_+-./`.
fn isEscapeUnescaped(c: u21) bool {
    if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) return true;
    return switch (c) {
        '@', '*', '_', '+', '-', '.', '/' => true,
        else => false,
    };
}

/// B.2.1.1 escape(string): %-encode code units outside the unescaped set;
/// code units < 256 become `%XX`, the rest `%uXXXX` (uppercase hex).
fn nativeEscape(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    const upper = "0123456789ABCDEF";
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const du = string_proto_mod.decodeWtf8At(s, i);
        const n: u21 = du.cp;
        if (n <= 0x7F and isEscapeUnescaped(n)) {
            try buf.append(arena, @intCast(n));
        } else if (n < 256) {
            try appendPctByte(&buf, arena, @intCast(n));
        } else {
            try buf.append(arena, '%');
            try buf.append(arena, 'u');
            try buf.append(arena, upper[(n >> 12) & 0xF]);
            try buf.append(arena, upper[(n >> 8) & 0xF]);
            try buf.append(arena, upper[(n >> 4) & 0xF]);
            try buf.append(arena, upper[n & 0xF]);
        }
        i += du.len;
    }
    return val_mod.makeString(arena, buf.items);
}

/// B.2.1.2 unescape(string): decode `%XX` and `%uXXXX` sequences back to code
/// units, leaving any malformed `%` and all other code units untouched.
fn nativeUnescape(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const s = try uriToString(arena, if (args.len > 0) args[0] else Value{});
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 6 <= s.len and s[i + 1] == 'u') {
                if (hexDigit(s[i + 2])) |h3| if (hexDigit(s[i + 3])) |h2| if (hexDigit(s[i + 4])) |h1| if (hexDigit(s[i + 5])) |h0| {
                    const cp: u21 = (@as(u21, h3) << 12) | (@as(u21, h2) << 8) | (@as(u21, h1) << 4) | h0;
                    try appendWtf8Cp(&buf, arena, cp);
                    i += 6;
                    continue;
                };
            }
            if (i + 3 <= s.len) {
                if (hexDigit(s[i + 1])) |h1| if (hexDigit(s[i + 2])) |h0| {
                    const cp: u21 = (@as(u21, h1) << 4) | h0;
                    try appendWtf8Cp(&buf, arena, cp);
                    i += 3;
                    continue;
                };
            }
        }
        const du = string_proto_mod.decodeWtf8At(s, i);
        try buf.appendSlice(arena, s[i .. i + du.len]);
        i += du.len;
    }
    return val_mod.makeString(arena, buf.items);
}

/// Hook set by the active VM so the global `eval` can re-enter the interpreter
/// in the current realm/global scope. Returns the eval result or sets
/// pending_exception and returns error.JsException.
pub var eval_hook: ?*const fn (ctx_ptr: *anyopaque, arena: std.mem.Allocator, source: []const u8) anyerror!Value = null;

fn nativeEval(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeUndefined(arena);
    // eval of a non-string returns the argument unchanged (ES5 step 1).
    if (args[0].bits == 0 or args[0].unbox() != .string) return args[0];
    const src = args[0].toPtr().string;
    const ctx = active_context orelse return val_mod.makeUndefined(arena);
    return ctx.evalSource(arena, src);
}

/// Is `v` the %eval% intrinsic itself? A direct eval requires more than the
/// syntactic shape `eval(...)`: §13.3.6.1 falls back to an ordinary call unless
/// the callee actually evaluates to %eval%. So `var eval = f; eval(s)` and
/// `var eval = realEval.bind(null, s); eval()` are plain calls, even though the
/// callee is spelled `eval`.
pub fn isEvalIntrinsic(v: Value) bool {
    if (v.bits == 0 or v.unbox() != .native_function) return false;
    return v.toPtr().native_function.call == nativeEval;
}

fn toBooleanCoerce(v: Value) bool {
    return val_mod.toBoolean(v);
}

fn nativeBooleanCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = active_constructing;
    active_constructing = false;
    const b = if (args.len > 0) toBooleanCoerce(args[0]) else false;
    // `new Boolean(x)`: store the primitive on the synthesized wrapper and return
    // it. Plain `Boolean(x)` returns the primitive.
    if (constructing and this_val.bits != 0 and this_val.unbox() == .object) {
        try this_val.toPtr().object.set("[[PrimitiveValue]]", try val_mod.makeBool(arena, b));
        return this_val;
    }
    return val_mod.makeBool(arena, b);
}

fn numberPrimitive(arena: std.mem.Allocator, arg: Value) anyerror!f64 {
    if (arg.bits == 0) return std.math.nan(f64);
    return switch (arg.unbox()) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        // Number(bigint) is explicitly allowed (unlike ToNumber, which throws).
        // ponytail: |x| > ~1.7e38 → NaN; BigInt64/Uint64 elements always fit.
        .bigint => blk: {
            const i = arg.toPtr().bigint.toConst().toInt(i128) catch break :blk std.math.nan(f64);
            break :blk @floatFromInt(i);
        },
        // Full ES StringToNumber (radix prefixes 0x/0o/0b, Infinity, "" → 0) so
        // Number("0b1110") === +"0b1110" === 14.
        .string => |s| val_mod.jsStringToNumber(s),
        .null_ => 0,
        .undefined_ => std.math.nan(f64),
        // ToNumeric(Symbol) is a TypeError even for `Number(sym)` (only BigInt
        // gets the special Number() carve-out above).
        .symbol => throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .object => blk: {
            // ToNumber(ToPrimitive(arg, "number")) when a user hook applies.
            if (try coercion_mod.toPrimitive(arena, arg, .number)) |prim|
                break :blk try numberPrimitive(arena, prim);
            break :blk std.math.nan(f64);
        },
        else => std.math.nan(f64),
    };
}

fn nativeNumberCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = active_constructing;
    active_constructing = false;
    const n: f64 = if (args.len == 0) 0 else try numberPrimitive(arena, args[0]);
    // `new Number(x)`: wrap on the synthesized object; plain call returns primitive.
    if (constructing and this_val.bits != 0 and this_val.unbox() == .object) {
        try this_val.toPtr().object.set("[[PrimitiveValue]]", try val_mod.makeNumber(arena, n));
        return this_val;
    }
    return val_mod.makeNumber(arena, n);
}

/// BigInt(value): NumberToBigInt for a Number arg (integer or RangeError),
/// else ToBigInt. Not a constructor (`new BigInt` would TypeError, but the
/// dispatcher handles that). ponytail: integer Numbers up to ~9e18 via i64,
/// larger via decimal format — exponential ≥1e21 falls through (rare).
fn nativeBigIntCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var cur = if (args.len > 0) args[0] else Value{};
    if (cur.bits == 0) return throwTypeError(arena, "Cannot convert undefined to a BigInt");
    if (cur.unbox() == .object)
        cur = (try coercion_mod.toPrimitive(arena, cur, .number)) orelse
            return throwTypeError(arena, "Cannot convert object to a BigInt");
    switch (cur.unbox()) {
        .bigint => return cur,
        .boolean => |b| return val_mod.makeBigIntFromI64(arena, if (b) 1 else 0),
        .string => |s| {
            // StringToBigInt handles the sign/whitespace/empty cases the bare
            // literal grammar does not; failure is a SyntaxError per spec.
            return val_mod.stringToBigInt(arena, s) catch
                throwSyntaxError(arena, "Cannot convert string to a BigInt");
        },
        .number => |x| {
            if (std.math.isNan(x) or std.math.isInf(x) or std.math.floor(x) != x) {
                const eo = if (active_heap) |h| try JsObject.createOnHeap(h, rangeErrorProto()) else try JsObject.create(arena, rangeErrorProto());
                try eo.set("message", try val_mod.makeString(arena, "The number is not a safe integer"));
                try eo.set("name", try val_mod.makeString(arena, "RangeError"));
                pending_exception = try val_mod.makeObject(arena, eo);
                return error.JsException;
            }
            if (@abs(x) < 9.0e18) return val_mod.makeBigIntFromI64(arena, @intFromFloat(x));
            // Past i64 the shortest round-trip decimal ("4.503599627370495e21")
            // is NOT the value's exact integer, and NumberToBigInt is exact. Any
            // such x is a normalized double whose significand scales by a
            // non-negative power of two, so mantissa << exp reproduces it bit for
            // bit (1024 bits of range, plus slack for the shift).
            const raw: u64 = @bitCast(@abs(x));
            const mantissa: u64 = (raw & 0xf_ffff_ffff_ffff) | (1 << 52);
            const shift: u32 = @intCast(@as(i32, @intCast((raw >> 52) & 0x7ff)) - 1075);
            const exact: u1100 = @as(u1100, mantissa) << @intCast(shift);
            const s = try std.fmt.allocPrint(arena, "{s}{d}", .{ if (x < 0) "-" else "", exact });
            return val_mod.makeBigIntFromLiteral(arena, s) catch throwTypeError(arena, "Cannot convert number to a BigInt");
        },
        else => return throwTypeError(arena, "Cannot convert value to a BigInt"),
    }
}

/// ES ToBigInt (7.1.13). Unlike `BigInt(x)`, a Number argument is a TypeError —
/// there is no implicit Number→BigInt conversion.
fn toBigIntValue(arena: std.mem.Allocator, v_in: Value) anyerror!Value {
    var v = v_in;
    if (v.bits == 0) return throwTypeError(arena, "Cannot convert undefined to a BigInt");
    if (!coercion_mod.isPrimitive(v))
        v = (try coercion_mod.toPrimitive(arena, v, .number)) orelse
            return throwTypeError(arena, "Cannot convert object to a BigInt");
    return switch (v.unbox()) {
        .bigint => v,
        .boolean => |b| val_mod.makeBigIntFromI64(arena, if (b) 1 else 0),
        .string => |s| val_mod.stringToBigInt(arena, s) catch
            throwSyntaxError(arena, "Cannot convert string to a BigInt"),
        .number => throwTypeError(arena, "Cannot convert a Number to a BigInt"),
        .symbol => throwTypeError(arena, "Cannot convert a Symbol value to a BigInt"),
        else => throwTypeError(arena, "Cannot convert value to a BigInt"),
    };
}

/// ES ToIndex (7.1.22): ToIntegerOrInfinity, then reject anything outside
/// [0, 2**53-1] with a RangeError. `undefined` is 0.
fn toIndexValue(arena: std.mem.Allocator, v: Value) anyerror!u64 {
    const n = try coercion_mod.toNumberThrowing(arena, v);
    const i = if (std.math.isNan(n)) 0 else std.math.trunc(n);
    if (i < 0 or i > 9007199254740991.0) return throwRangeError(arena, "Invalid index");
    return @intFromFloat(i);
}

/// BigInt.asIntN(bits, bigint) / BigInt.asUintN(bits, bigint) — §21.2.2.1-2.
/// ToIndex(bits) runs BEFORE ToBigInt(bigint); tests observe that order.
fn bigIntAsN(arena: std.mem.Allocator, args: []const Value, signed: bool) anyerror!Value {
    const bits = try toIndexValue(arena, if (args.len > 0) args[0] else Value{});
    const big = try toBigIntValue(arena, if (args.len > 1) args[1] else Value{});
    return val_mod.bigIntAsIntN(arena, big, bits, signed) catch |e| switch (e) {
        error.Overflow => throwRangeError(arena, "BigInt is too large"),
        else => e,
    };
}

fn nativeBigIntAsIntN(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return bigIntAsN(arena, args, true);
}

fn nativeBigIntAsUintN(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return bigIntAsN(arena, args, false);
}

/// thisBigIntValue(this): primitive bigint, or a BigInt wrapper's [[PrimitiveValue]].
fn bigIntThisValue(arena: std.mem.Allocator, this_val: Value) anyerror!Value {
    if (this_val.bits != 0) {
        switch (this_val.unbox()) {
            .bigint => return this_val,
            .object => |o| {
                if (o.get("[[PrimitiveValue]]")) |pv| {
                    if (pv.bits != 0 and pv.unbox() == .bigint) return pv;
                }
            },
            else => {},
        }
    }
    return throwTypeError(arena, "BigInt.prototype method called on incompatible receiver");
}

/// BigInt.prototype.toLocaleString — like Number's, `new Intl.NumberFormat(…)
/// .format(this)`; NumberFormat formats a BigInt exactly (no f64 round-trip).
fn nativeBigIntProtoToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const b = try bigIntThisValue(arena, this_val);
    const nf = try intl_mod.nativeNumberFormatCtor(arena, Value{}, args);
    return intl_mod.nativeNumberFormatFormat(arena, nf, &[_]Value{b});
}

fn nativeBigIntProtoToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const b = try bigIntThisValue(arena, this_val);
    var radix: i64 = 10;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        // ToIntegerOrInfinity, i.e. a full ToNumber: a Symbol or BigInt radix is a
        // TypeError, and `null`/non-numeric strings coerce to 0 (→ RangeError),
        // not to the default 10.
        const rn = try coercion_mod.toNumberThrowing(arena, args[0]);
        if (std.math.isNan(rn)) return throwRangeError(arena, "toString() radix must be between 2 and 36");
        radix = val_mod.f64ToI64Sat(rn);
    }
    if (radix < 2 or radix > 36) return throwRangeError(arena, "toString() radix must be between 2 and 36");
    const s = try b.toPtr().bigint.toConst().toStringAlloc(arena, @intCast(radix), .lower);
    return val_mod.makeString(arena, s);
}

fn nativeBigIntProtoValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return bigIntThisValue(arena, this_val);
}

pub fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h| try JsObject.createOnHeap(h, rangeErrorProto()) else try JsObject.create(arena, rangeErrorProto());
    try eo.set("message", try val_mod.makeString(arena, msg));
    try eo.set("name", try val_mod.makeString(arena, "RangeError"));
    pending_exception = try val_mod.makeObject(arena, eo);
    return error.JsException;
}

/// Raise a `SyntaxError` from a native. Spec StringToBigInt reports a malformed
/// numeric string this way (`BigInt("abc")`), not as a TypeError.
pub fn throwSyntaxError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h| try JsObject.createOnHeap(h, syntaxErrorProto()) else try JsObject.create(arena, syntaxErrorProto());
    try eo.set("message", try val_mod.makeString(arena, msg));
    try eo.set("name", try val_mod.makeString(arena, "SyntaxError"));
    pending_exception = try val_mod.makeObject(arena, eo);
    return error.JsException;
}

/// Pull a wrapper object's stored `[[PrimitiveValue]]`, if present.
fn wrapperPrimitive(this_val: Value) ?Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        if (this_val.toPtr().object.get("[[PrimitiveValue]]")) |p| return p;
    }
    return null;
}

/// Raise a `TypeError` from a native: sets `pending_exception` and returns
/// `error.JsException` for the VM to surface as a catchable throw.
pub fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const err_obj = if (active_heap) |h|
        try JsObject.createOnHeap(h, typeErrorProto())
    else
        try JsObject.create(arena, typeErrorProto());
    try err_obj.set("message", try val_mod.makeString(arena, msg));
    try err_obj.set("name", try val_mod.makeString(arena, "TypeError"));
    pending_exception = try val_mod.makeObject(arena, err_obj);
    return error.JsException;
}

// ---- Boolean.prototype ----
/// `this` boolean value: the primitive itself, or a Boolean wrapper's
/// `[[PrimitiveValue]]`. Any other `this` is a TypeError per the spec.
fn thisBoolean(this_val: Value) ?bool {
    if (this_val.bits != 0 and this_val.unbox() == .boolean) return this_val.unbox().boolean;
    if (wrapperPrimitive(this_val)) |p| {
        if (p.bits != 0 and p.unbox() == .boolean) return p.unbox().boolean;
    }
    return null;
}

fn nativeBooleanValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const b = thisBoolean(this_val) orelse return throwTypeError(arena, "Boolean.prototype.valueOf requires a Boolean");
    return val_mod.makeBool(arena, b);
}

fn nativeBooleanToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const b = thisBoolean(this_val) orelse return throwTypeError(arena, "Boolean.prototype.toString requires a Boolean");
    return val_mod.makeString(arena, if (b) "true" else "false");
}

// ---- Number.prototype ----
fn thisNumber(this_val: Value) ?f64 {
    if (this_val.bits != 0 and this_val.unbox() == .number) return this_val.unbox().number;
    if (wrapperPrimitive(this_val)) |p| {
        if (p.bits != 0 and p.unbox() == .number) return p.unbox().number;
    }
    return null;
}

fn nativeNumberValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.valueOf requires a Number");
    return val_mod.makeNumber(arena, n);
}

/// Number.prototype.toLocaleString([locales[, options]]) — ES §21.1.3.4, which
/// with Intl present is `new Intl.NumberFormat(locales, options).format(this)`.
/// Composes the two public NumberFormat entry points so grouping and
/// fraction-digit defaults stay in one place.
fn nativeNumberProtoToLocaleString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toLocaleString requires a Number");
    const nf = try intl_mod.nativeNumberFormatCtor(arena, Value{}, args);
    return intl_mod.nativeNumberFormatFormat(arena, nf, &[_]Value{try val_mod.makeNumber(arena, n)});
}

const RADIX_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Stringify a finite f64 in an arbitrary radix 2..36 (ES Number::toString).
fn numberToRadixString(arena: std.mem.Allocator, n: f64, radix: i32) ![]const u8 {
    const rf: f64 = @floatFromInt(radix);
    const neg = n < 0;
    const x = @abs(n);

    var out: std.ArrayList(u8) = .{};
    // Integer part (most-significant digit emitted last, so reverse it).
    var int_part = @floor(x);
    var int_digits: std.ArrayList(u8) = .{};
    if (int_part == 0) {
        try int_digits.append(arena, '0');
    } else {
        while (int_part > 0) {
            const d: usize = @intFromFloat(@mod(int_part, rf));
            try int_digits.append(arena, RADIX_DIGITS[d]);
            int_part = @floor(int_part / rf);
        }
    }
    var i: usize = int_digits.items.len;
    while (i > 0) {
        i -= 1;
        try out.append(arena, int_digits.items[i]);
    }

    // Fractional part (cap at 20 digits — matches engine precision budget).
    var frac = x - @floor(x);
    if (frac > 0) {
        try out.append(arena, '.');
        var count: usize = 0;
        while (frac > 0 and count < 20) : (count += 1) {
            frac *= rf;
            const d: usize = @intFromFloat(@floor(frac));
            try out.append(arena, RADIX_DIGITS[d]);
            frac -= @floor(frac);
        }
    }

    if (neg) {
        var signed: std.ArrayList(u8) = .{};
        try signed.append(arena, '-');
        try signed.appendSlice(arena, out.items);
        return signed.items;
    }
    return out.items;
}

fn nativeNumberToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toString requires a Number");
    var radix: i32 = 10;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        // ToIntegerOrInfinity(radix) is a real ToNumber: an abrupt valueOf and a
        // Symbol/BigInt radix must surface instead of silently becoming NaN → 0.
        const r_raw = try toNumberCheckedRealm(arena, args[0]);
        const r_int: f64 = if (std.math.isNan(r_raw)) 0 else @trunc(r_raw);
        if (r_int < 2 or r_int > 36) return throwRangeError(arena, "toString() radix must be between 2 and 36");
        radix = @intFromFloat(r_int);
    }
    if (radix == 10) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    if (std.math.isNan(n)) return val_mod.makeString(arena, "NaN");
    if (std.math.isInf(n)) return val_mod.makeString(arena, if (n < 0) "-Infinity" else "Infinity");
    return val_mod.makeString(arena, try numberToRadixString(arena, n, radix));
}

/// Exact Number.prototype.toFixed for a finite, non-negative `x` and `f` in
/// [0,100]: computes n = round(x * 10^f) (ties toward the larger n, per spec)
/// with big-integer arithmetic so every digit of the double's exact value is
/// preserved (Zig's float formatter rounds to ~17 significant digits, which
/// loses the tail of large integers such as 1e18 + 128).
fn exactToFixedAbs(arena: std.mem.Allocator, x: f64, f: usize) ![]const u8 {
    const Managed = std.math.big.int.Managed;
    // Decompose x = m * 2^e (IEEE-754 binary64).
    const bits: u64 = @bitCast(x);
    const raw_exp: u64 = (bits >> 52) & 0x7FF;
    const raw_frac: u64 = bits & 0xFFFFFFFFFFFFF;
    var m_int: u64 = undefined;
    var e: i64 = undefined;
    if (raw_exp == 0) {
        m_int = raw_frac;
        e = -1074;
    } else {
        m_int = raw_frac | (@as(u64, 1) << 52);
        e = @as(i64, @intCast(raw_exp)) - 1075;
    }
    // num = m * 5^f  (then scale by 2^(e+f)).
    var num = try Managed.initSet(arena, m_int);
    {
        var five = try Managed.initSet(arena, 5);
        var acc = try Managed.initSet(arena, 1);
        var tmp = try Managed.init(arena);
        var k: usize = 0;
        while (k < f) : (k += 1) {
            try tmp.mul(&acc, &five);
            acc.swap(&tmp);
        }
        try tmp.mul(&num, &acc);
        num.swap(&tmp);
    }
    const p: i64 = e + @as(i64, @intCast(f));
    var n = try Managed.init(arena);
    if (p >= 0) {
        try n.shiftLeft(&num, @intCast(p));
    } else {
        const shift: usize = @intCast(-p);
        // Round to nearest, ties up: (num + 2^(shift-1)) >> shift.
        var half = try Managed.initSet(arena, 1);
        try half.shiftLeft(&half, shift - 1);
        var summed = try Managed.init(arena);
        try summed.add(&num, &half);
        try n.shiftRight(&summed, shift);
    }
    const digits = try n.toConst().toStringAlloc(arena, 10, .lower);
    if (f == 0) return digits;
    if (digits.len <= f) {
        // 0.<pad><digits>
        var buf = std.ArrayList(u8){};
        try buf.appendSlice(arena, "0.");
        try buf.appendNTimes(arena, '0', f - digits.len);
        try buf.appendSlice(arena, digits);
        return buf.items;
    }
    const split = digits.len - f;
    var buf = std.ArrayList(u8){};
    try buf.appendSlice(arena, digits[0..split]);
    try buf.append(arena, '.');
    try buf.appendSlice(arena, digits[split..]);
    return buf.items;
}

/// round(m * 2^e * 10^k) as a big integer (m ≥ 0), ties toward +∞. Used by the
/// exact exponential/precision formatters.
fn exactRoundScaled(arena: std.mem.Allocator, m_int: u64, e: i64, k: i64) !std.math.big.int.Managed {
    const Managed = std.math.big.int.Managed;
    var num = try Managed.initSet(arena, m_int);
    var den = try Managed.initSet(arena, 1);
    if (k != 0) {
        // 5^|k|
        var five_pow = try Managed.initSet(arena, 1);
        {
            var five = try Managed.initSet(arena, 5);
            var tmp = try Managed.init(arena);
            var kk: usize = @intCast(@abs(k));
            while (kk > 0) : (kk -= 1) {
                try tmp.mul(&five_pow, &five);
                five_pow.swap(&tmp);
            }
        }
        var tmp = try Managed.init(arena);
        if (k > 0) {
            try tmp.mul(&num, &five_pow);
            num.swap(&tmp);
        } else {
            try tmp.mul(&den, &five_pow);
            den.swap(&tmp);
        }
    }
    const two_exp: i64 = e + k;
    if (two_exp >= 0) {
        var tmp = try Managed.init(arena);
        try tmp.shiftLeft(&num, @intCast(two_exp));
        num.swap(&tmp);
    } else {
        var tmp = try Managed.init(arena);
        try tmp.shiftLeft(&den, @intCast(-two_exp));
        den.swap(&tmp);
    }
    // n = round(num/den), ties up: q = num div den; if 2*rem >= den, q += 1.
    var q = try Managed.init(arena);
    var rem = try Managed.init(arena);
    try q.divTrunc(&rem, &num, &den);
    var rem2 = try Managed.init(arena);
    try rem2.shiftLeft(&rem, 1);
    if (rem2.toConst().order(den.toConst()) != .lt) {
        var one = try Managed.initSet(arena, 1);
        var tmp = try Managed.init(arena);
        try tmp.add(&q, &one);
        q.swap(&tmp);
    }
    return q;
}

/// Sign of (x − 10^d) for x = m·2^e (m > 0), computed exactly. Returns .lt/.eq/
/// .gt. Cross-multiplies to a pair of non-negative big integers so no fraction
/// is ever formed.
fn compareXvsPow10(arena: std.mem.Allocator, m_int: u64, e: i64, d: i64) !std.math.Order {
    const Managed = std.math.big.int.Managed;
    // LHS = m · 2^max(e,0) · 10^max(-d,0);  RHS = 10^max(d,0) · 2^max(-e,0)
    var lhs = try Managed.initSet(arena, m_int);
    var rhs = try Managed.initSet(arena, 1);
    if (e > 0) {
        var t = try Managed.init(arena);
        try t.shiftLeft(&lhs, @intCast(e));
        lhs.swap(&t);
    } else if (e < 0) {
        var t = try Managed.init(arena);
        try t.shiftLeft(&rhs, @intCast(-e));
        rhs.swap(&t);
    }
    const pow10 = struct {
        fn mul(a: std.mem.Allocator, target: *Managed, n: usize) !void {
            var ten = try Managed.initSet(a, 10);
            var tmp = try Managed.init(a);
            var k: usize = 0;
            while (k < n) : (k += 1) {
                try tmp.mul(target, &ten);
                target.swap(&tmp);
            }
        }
    };
    if (d < 0) try pow10.mul(arena, &lhs, @intCast(-d));
    if (d > 0) try pow10.mul(arena, &rhs, @intCast(d));
    return lhs.toConst().order(rhs.toConst());
}

/// Exact floor(log10(x)) for a positive finite `x`, seeded by the float estimate
/// and corrected with exact comparisons (float log10 is off by one for values
/// just below a power of ten, e.g. the double nearest 1e-21).
fn floorLog10(arena: std.mem.Allocator, m_int: u64, e: i64, x: f64) !i64 {
    var d: i64 = @intFromFloat(@floor(std.math.log10(x)));
    // Ensure 10^d ≤ x.
    while ((try compareXvsPow10(arena, m_int, e, d)) == .lt) d -= 1;
    // Ensure x < 10^(d+1).
    while ((try compareXvsPow10(arena, m_int, e, d + 1)) != .lt) d += 1;
    return d;
}

/// Exact significant digits of a positive finite `x`: returns exactly `sig`
/// decimal digits (10^(sig-1) ≤ n < 10^sig) plus the base-10 exponent of the
/// leading digit. Ties round toward +∞.
fn exactSignificant(arena: std.mem.Allocator, x: f64, sig: usize) !struct { digits: []const u8, exp: i64 } {
    const bits: u64 = @bitCast(x);
    const raw_exp: u64 = (bits >> 52) & 0x7FF;
    const raw_frac: u64 = bits & 0xFFFFFFFFFFFFF;
    var m_int: u64 = undefined;
    var e2: i64 = undefined;
    if (raw_exp == 0) {
        m_int = raw_frac;
        e2 = -1074;
    } else {
        m_int = raw_frac | (@as(u64, 1) << 52);
        e2 = @as(i64, @intCast(raw_exp)) - 1075;
    }
    // Exact decimal exponent, then correct for a rounding carry into the next
    // decade below.
    var edec: i64 = try floorLog10(arena, m_int, e2, x);
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        const k: i64 = @as(i64, @intCast(sig - 1)) - edec;
        var n = try exactRoundScaled(arena, m_int, e2, k);
        const digits = try n.toConst().toStringAlloc(arena, 10, .lower);
        if (digits.len == sig) {
            return .{ .digits = digits, .exp = edec };
        } else if (digits.len == sig + 1) {
            // Rounding carried into an extra digit (…→10^sig): drop the trailing
            // 0 and bump the exponent.
            return .{ .digits = digits[0..sig], .exp = edec + 1 };
        } else if (digits.len < sig) {
            edec -= 1;
        } else {
            edec += 1;
        }
    }
    // Fallback (should not happen): pad/truncate to sig digits at the estimate.
    const k: i64 = @as(i64, @intCast(sig - 1)) - edec;
    var n = try exactRoundScaled(arena, m_int, e2, k);
    const digits = try n.toConst().toStringAlloc(arena, 10, .lower);
    return .{ .digits = digits, .exp = edec };
}

/// Format `edec` as the `e±N` exponent suffix (no leading zeros).
fn appendExpSuffix(arena: std.mem.Allocator, buf: *std.ArrayList(u8), edec: i64) !void {
    try buf.append(arena, 'e');
    if (edec >= 0) {
        try buf.append(arena, '+');
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{@as(u64, @intCast(edec))}));
    } else {
        try buf.append(arena, '-');
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{@as(u64, @intCast(-edec))}));
    }
}

fn nativeNumberToFixed(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toFixed requires a Number");
    // f = ToIntegerOrInfinity(fractionDigits): ToNumber throws TypeError for
    // Symbol/BigInt and propagates a throwing valueOf/@@toPrimitive.
    const f_raw: f64 = if (args.len == 0) 0.0 else try toNumberCheckedRealm(arena, args[0]);
    const f_int: f64 = if (std.math.isNan(f_raw)) 0 else @trunc(f_raw);
    if (f_int < 0 or f_int > 100) return throwRangeError(arena, "toFixed() digits argument must be between 0 and 100");
    const f: i64 = @intFromFloat(f_int);
    if (std.math.isNan(n)) return val_mod.makeString(arena, "NaN");
    if (!std.math.isFinite(n)) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    if (@abs(n) >= 1e21) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    const fu: usize = @intCast(f);
    // -0 formats without a sign ("0.00", not "-0.00").
    const negative = n < 0.0;
    const abs_n = @abs(n);
    const body = try exactToFixedAbs(arena, abs_n, fu);
    if (negative and abs_n != 0.0) {
        return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "-{s}", .{body}));
    }
    return val_mod.makeString(arena, body);
}

/// Shared helper: format `n` in exponential notation.
/// `f == -1` means no fractionDigits argument (use shortest form).
fn numberToExponentialImpl(arena: std.mem.Allocator, n: f64, f: i64) ![]const u8 {
    const abs_n = @abs(n);
    // Avoid -0 in sign
    const negative = n < 0.0 and abs_n != 0.0;

    // Compute exponent and mantissa
    var exp: i64 = 0;
    var mant: f64 = 0.0;
    if (abs_n != 0.0) {
        const log = std.math.log10(abs_n);
        exp = @as(i64, @intFromFloat(@floor(log)));
        mant = abs_n / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exp)));
        // Clamp to [1, 10) due to floating-point rounding
        if (mant >= 10.0) {
            mant /= 10.0;
            exp += 1;
        } else if (mant < 1.0) {
            mant *= 10.0;
            exp -= 1;
        }
    }

    var buf = std.ArrayList(u8){};
    if (negative) try buf.append(arena, '-');

    if (f == -1) {
        // Not provided: shortest representation (trim trailing zeros)
        const high_prec: usize = 17;
        const full = try std.fmt.allocPrint(arena, "{d:.[1]}", .{ mant, high_prec });
        var end = full.len;
        if (std.mem.indexOfScalar(u8, full, '.') != null) {
            while (end > 0 and full[end - 1] == '0') end -= 1;
            if (end > 0 and full[end - 1] == '.') end -= 1;
        }
        try buf.appendSlice(arena, full[0..end]);
        try appendExpSuffix(arena, &buf, exp);
        return buf.items;
    }

    // Fixed fractionDigits: emit exactly f+1 significant digits (d.ddd…) using
    // the exact decimal value of the double.
    const fu: usize = @intCast(f);
    if (abs_n == 0.0) {
        try buf.append(arena, '0');
        if (fu > 0) {
            try buf.append(arena, '.');
            try buf.appendNTimes(arena, '0', fu);
        }
        try appendExpSuffix(arena, &buf, 0);
        return buf.items;
    }
    const sd = try exactSignificant(arena, abs_n, fu + 1);
    try buf.append(arena, sd.digits[0]);
    if (fu > 0) {
        try buf.append(arena, '.');
        try buf.appendSlice(arena, sd.digits[1..]);
    }
    try appendExpSuffix(arena, &buf, sd.exp);
    return buf.items;
}

fn nativeNumberToExponential(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toExponential requires a Number");
    // ToIntegerOrInfinity(fractionDigits) (step 2) precedes the NaN/Infinity
    // short-circuits (step 3+), and throws TypeError for Symbol/BigInt.
    const has_arg = args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_;
    var f: i64 = -1; // -1 = not provided → shortest
    var f_int: f64 = 0;
    if (has_arg) {
        const f_raw = try toNumberCheckedRealm(arena, args[0]);
        f_int = if (std.math.isNan(f_raw)) 0 else @trunc(f_raw);
    }
    // Non-finite short-circuit (step 3) precedes the fractionDigits range check.
    if (std.math.isNan(n)) return val_mod.makeString(arena, "NaN");
    if (!std.math.isFinite(n)) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    if (has_arg) {
        if (f_int < 0 or f_int > 100) return throwRangeError(arena, "toExponential() argument must be between 0 and 100");
        f = @intFromFloat(f_int);
    }
    return val_mod.makeString(arena, try numberToExponentialImpl(arena, n, f));
}

fn nativeNumberToPrecision(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toPrecision requires a Number");
    const has_arg = args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_;
    // No argument → same as toString
    if (!has_arg) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    // p = ToIntegerOrInfinity(precision) (step 3); ToIntegerOrInfinity(NaN) = 0.
    const p_raw = try toNumberCheckedRealm(arena, args[0]);
    const p_int: f64 = if (std.math.isNan(p_raw)) 0 else @trunc(p_raw);
    // Non-finite short-circuit (steps 4-5) precedes the precision range check.
    if (std.math.isNan(n)) return val_mod.makeString(arena, "NaN");
    if (!std.math.isFinite(n)) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    if (p_int < 1 or p_int > 100) return throwRangeError(arena, "toPrecision() argument must be between 1 and 100");
    const p: i64 = @intFromFloat(p_int);
    const pu: usize = @intCast(p);
    const abs_n = @abs(n);
    const negative = n < 0.0 and abs_n != 0.0;
    var buf = std.ArrayList(u8){};
    if (negative) try buf.append(arena, '-');
    // Zero: "0" / "0.000…" with p-1 fraction digits (e = 0, never exponential).
    if (abs_n == 0.0) {
        try buf.append(arena, '0');
        if (pu > 1) {
            try buf.append(arena, '.');
            try buf.appendNTimes(arena, '0', pu - 1);
        }
        return val_mod.makeString(arena, buf.items);
    }
    // Exact p significant digits + the base-10 exponent of the leading digit.
    const sd = try exactSignificant(arena, abs_n, pu);
    const e = sd.exp;
    if (e < -6 or e >= p) {
        // Exponential form: d.ddd…e±e with p-1 fraction digits.
        try buf.append(arena, sd.digits[0]);
        if (pu > 1) {
            try buf.append(arena, '.');
            try buf.appendSlice(arena, sd.digits[1..]);
        }
        try appendExpSuffix(arena, &buf, e);
    } else if (e >= 0) {
        // Fixed, |x| ≥ 1: e+1 integer digits, remaining p-1-e as the fraction.
        const int_len: usize = @intCast(e + 1);
        try buf.appendSlice(arena, sd.digits[0..int_len]);
        if (int_len < pu) {
            try buf.append(arena, '.');
            try buf.appendSlice(arena, sd.digits[int_len..]);
        }
    } else {
        // Fixed, |x| < 1: 0.<zeros><digits> with (-e-1) leading fraction zeros.
        try buf.appendSlice(arena, "0.");
        try buf.appendNTimes(arena, '0', @intCast(-e - 1));
        try buf.appendSlice(arena, sd.digits);
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES Number.isInteger / isFinite / isNaN / isSafeInteger: no coercion — a
/// non-Number argument yields false rather than being converted.
fn numberArg(args: []const Value) ?f64 {
    if (args.len == 0) return null;
    const v = args[0];
    if (v.bits == 0 or v.unbox() != .number) return null;
    return v.unbox().number;
}

fn nativeNumberIsInteger(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = numberArg(args) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.math.isFinite(n) and @trunc(n) == n);
}

fn nativeNumberIsFinite(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = numberArg(args) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.math.isFinite(n));
}

fn nativeNumberIsNaN(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = numberArg(args) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.math.isNan(n));
}

fn nativeNumberIsSafeInteger(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = numberArg(args) orelse return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.math.isFinite(n) and @trunc(n) == n and @abs(n) <= 9007199254740991.0);
}

// ---- String.prototype valueOf/toString ----
fn thisString(this_val: Value) ?[]const u8 {
    if (this_val.bits != 0 and this_val.unbox() == .string) return this_val.toPtr().string;
    if (wrapperPrimitive(this_val)) |p| {
        if (p.bits != 0 and p.unbox() == .string) return p.toPtr().string;
    }
    return null;
}

fn nativeStringValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = thisString(this_val) orelse return throwTypeError(arena, "String.prototype.valueOf requires a String");
    return val_mod.makeString(arena, s);
}

/// A Boolean/Number/String wrapper object carries a matching [[PrimitiveValue]];
/// return its reserved Object.prototype.toString tag, or null for a plain object.
fn wrapperTag(obj: *JsObject) ?[]const u8 {
    const p = obj.get("[[PrimitiveValue]]") orelse return null;
    if (p.bits == 0) return null;
    return switch (p.unbox()) {
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        else => null,
    };
}

// ---- Object.prototype.toString / valueOf ----
pub fn nativeObjectProtoToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 20.1.3.6: "[object " + builtinTag + "]". undefined/null get special tags.
    if (this_val.bits == 0) return val_mod.makeString(arena, "[object Undefined]");
    const builtin_tag: []const u8 = switch (this_val.unbox()) {
        .undefined_ => "Undefined",
        .null_ => "Null",
        // ES 20.1.3.6 steps 4-14: exotic internal slots select the builtin tag
        // before falling back to "Object". Array/Arguments/callable/Error/wrapper/
        // Date/RegExp each have a reserved tag.
        .object => |obj| if (obj.internal_kind == .proxy)
            // Proxy of an array/callable is tagged as its (recursive) target
            // (ES 20.1.3.6 steps 5-6 use IsArray/[[Call]], which unwrap proxies).
            (if (proxyIsArrayDeep(obj)) "Array" else if (proxyIsCallableDeep(obj)) "Function" else "Object")
        else if (obj.is_array)
            "Array"
        else if (obj.internal_kind == .mapped_arguments)
            "Arguments"
        else if (obj.is_callable_intrinsic or obj.get("__call__") != null or obj.internal_kind == .bound_function)
            // A bound function (and %Function.prototype%) is callable but carries
            // no `__call__` slot, so each needs its own check to get the reserved
            // "Function" tag.
            "Function"
        else if (obj.is_error)
            "Error"
        else if (wrapperTag(obj)) |wt|
            wt
        else if (obj.internal_kind == .date)
            "Date"
        else if (obj.internal_kind == .regexp)
            "RegExp"
        else
            "Object",
        .function, .bc_function, .native_function => "Function",
        // Primitive receivers are ToObject-wrapped first; the wrapper's reserved
        // tag is Boolean/Number/String (ES 20.1.3.6 steps 8-10).
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        else => "Object",
    };
    // ES 20.1.3.6 step 15: `Let tag be ? Get(O, @@toStringTag)` — an ordinary
    // Get that walks the prototype chain and invokes accessors (e.g.
    // %TypedArray%.prototype[@@toStringTag] is an inherited getter). A string
    // result overrides the builtin tag.
    // ToObject(this) so a primitive receiver (e.g. a BigInt) reads @@toStringTag
    // off its wrapper's prototype (BigInt.prototype[@@toStringTag] === "BigInt").
    // Callables are objects too, but toObjectForThis passes them through as
    // .function/.bc_function; resolve them to their backing object so an own
    // @@toStringTag on a function is honoured (ES 20.1.3.6 step 15).
    var recv = try toObjectForThis(arena, this_val);
    switch (recv.unbox()) {
        .function, .bc_function, .native_function => {
            if (active_context) |ctx| {
                if (try ctx.backingObject(arena, recv)) |bo| recv = try val_mod.makeObject(arena, bo);
            }
        },
        else => {},
    }
    if (recv.bits != 0 and recv.unbox() == .object) {
        if (active_sym_to_string_tag) |tag_sym| {
            if (active_context) |ctx| {
                const tv = try ctx.getPropSym(arena, recv, tag_sym);
                if (tv.bits != 0 and tv.unbox() == .string) {
                    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "[object {s}]", .{tv.unbox().string}));
                }
            }
        }
    }
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "[object {s}]", .{builtin_tag}));
}

/// IsArray unwrapping proxies (ES §7.2.2): a proxy is an array iff its target is.
fn proxyIsArrayDeep(obj: *JsObject) bool {
    var cur = obj;
    var depth: usize = 0;
    while (depth < 1000) : (depth += 1) {
        const t = proxy_mod.proxyTarget(cur) orelse return false;
        if (t.bits == 0 or t.unbox() != .object) return false;
        const to = t.toPtr().object;
        if (to.internal_kind == .proxy) {
            cur = to;
            continue;
        }
        return to.is_array;
    }
    return false;
}

/// [[Call]] presence unwrapping proxies: a proxy is callable iff its target is.
fn proxyIsCallableDeep(obj: *JsObject) bool {
    var cur = obj;
    var depth: usize = 0;
    while (depth < 1000) : (depth += 1) {
        const t = proxy_mod.proxyTarget(cur) orelse return false;
        if (t.bits == 0) return false;
        switch (t.unbox()) {
            .function, .bc_function, .native_function => return true,
            .object => |to| {
                if (to.internal_kind == .proxy) {
                    cur = to;
                    continue;
                }
                return to.internal_kind == .bound_function or to.get("__call__") != null;
            },
            else => return false,
        }
    }
    return false;
}

fn nativeObjectProtoValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 20.1.3.7: return ToObject(this). A primitive receiver must come back as
    // its wrapper object (so `typeof valueOf.call(true)` is "object"), and
    // undefined/null throw rather than passing through.
    if (this_val.bits == 0 or this_val.unbox() == .undefined_ or this_val.unbox() == .null_)
        return throwTypeError(arena, "Object.prototype.valueOf called on null or undefined");
    return toObjectForThis(arena, this_val);
}

// ---- Function constructor (minimal) ----
fn nativeNoop(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return val_mod.makeUndefined(arena);
}

fn functionCtorImpl(arena: std.mem.Allocator, args: []const Value, keyword: []const u8) anyerror!Value {
    const ctor_realm = val_mod.g_active_native_realm;
    if (active_context) |ctx| {
        var src = std.ArrayList(u8){};
        try src.append(arena, '(');
        try src.appendSlice(arena, keyword);
        try src.appendSlice(arena, " anonymous(");
        // CreateDynamicFunction ToString's every argument, in order: a non-string
        // parameter name or body used to be dropped silently, which shifted the
        // remaining parameters onto a stray comma and made the source unparsable.
        if (args.len > 1) {
            for (args[0 .. args.len - 1], 0..) |a, i| {
                if (i > 0) try src.append(arena, ',');
                try src.appendSlice(arena, try rawToStr(arena, a));
            }
        }
        // CreateDynamicFunction assembles exactly
        // `<kind> anonymous(<P>\n) {\n<body>\n}` — the line terminators are
        // load-bearing, not cosmetic: without them a trailing `//` or Annex B
        // `<!--` in the parameter list or body would comment out the source's
        // own closing `)` / `}`.
        try src.appendSlice(arena, "\n) {\n");
        if (args.len > 0) {
            try src.appendSlice(arena, try rawToStr(arena, args[args.len - 1]));
        }
        try src.appendSlice(arena, "\n})");
        // NewTarget [[Prototype]] override (CreateDynamicFunction step 18: proto
        // from newTarget's realm). Applies to EVERY dynamic-function kind, not just
        // generators: `Reflect.construct(Function, [], otherRealmFn)` must give the
        // result `otherRealm.Function.prototype`.
        // IMPORTANT: capture pending_new_target/active_constructing BEFORE
        // evalSource/shadowEval, because bcInvokeJs (called inside evalSource)
        // unconditionally clears them. Only honor the newTarget when we are actually
        // constructing — a plain `Function(...)` call keeps the default proto.
        const is_gen = !std.mem.eql(u8, keyword, "function") and !std.mem.eql(u8, keyword, "async function");
        const captured_nt = if (active_constructing) pending_new_target else Value{};
        // Cross-realm: if the constructor realm's global env differs from the
        // current active global env, run the body in the constructor realm's scope
        // so closures capture that realm's globals and the realm tag propagates.
        const result = blk: {
            if (ctor_realm) |cr_opaque| {
                const rp: *Realm = @ptrCast(@alignCast(cr_opaque));
                const agenv = active_global_env;
                if (agenv == null or agenv.? != rp.global_env) {
                    const saved_sr = active_shadow_realm;
                    active_shadow_realm = rp;
                    defer active_shadow_realm = saved_sr;
                    // A parse failure of the assembled source surfaces as a real
                    // SyntaxError (pending_exception already holds it); callers
                    // only recognize `error.JsException` as "catchable JS throw",
                    // so re-tag it here (mirrors ShadowRealm.prototype.evaluate).
                    break :blk ctx.shadowEval(arena, src.items, @ptrCast(rp.global_env)) catch |e| {
                        if (e == error.ShadowParseError) return error.JsException;
                        return e;
                    };
                }
            }
            break :blk try ctx.evalSource(arena, src.items);
        };
        if (captured_nt.bits != 0) {
            const nt = captured_nt;
            const derived_proto: ?*JsObject = proto_blk: {
                const pv = try ctx.getProp(arena, nt, "prototype");
                if (pv.bits != 0 and pv.unbox() == .object) break :proto_blk pv.toPtr().object;
                // Fallback: GetPrototypeFromConstructor uses GetFunctionRealm(newTarget)
                // then that realm's intrinsic prototype for THIS function kind.
                if (getFunctionRealm(nt)) |fr| {
                    if (is_gen) {
                        try ctx.ensureGenChain(@ptrCast(fr));
                        const is_async_gen = std.mem.eql(u8, keyword, "async function*");
                        break :proto_blk if (is_async_gen) fr.async_gen_fn_proto else fr.gen_fn_proto;
                    }
                    if (std.mem.eql(u8, keyword, "async function")) {
                        try ctx.ensureGenChain(@ptrCast(fr));
                        break :proto_blk fr.async_fn_proto orelse fr.function_prototype;
                    }
                    break :proto_blk fr.function_prototype;
                }
                break :proto_blk null;
            };
            if (derived_proto) |dp| {
                if (try ctx.backingObject(arena, result)) |bobj| {
                    bobj.proto = dp;
                    bobj.setProtoBarrier(dp);
                }
            }
            // Consume pending newTarget so constructImpl's post-hoc override does
            // not attempt to re-apply it (it only handles .object returns, not
            // .bc_function — the function type dynamic functions produce).
            pending_new_target = Value{};
        }
        if (ctor_realm) |r| val_mod.setValueRealm(result, r);
        return result;
    }
    // No active VM (shouldn't happen during eval): empty callable.
    const o = if (active_heap) |h|
        try JsObject.createOnHeap(h, active_function_proto)
    else
        try JsObject.create(arena, active_function_proto);
    try o.set("__call__", try val_mod.makeNativeFunction(arena, nativeNoop));
    return val_mod.makeObject(arena, o);
}

fn nativeFunctionCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return functionCtorImpl(arena, args, "function");
}

pub fn nativeGeneratorFunctionCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return functionCtorImpl(arena, args, "function*");
}

pub fn nativeAsyncGeneratorFunctionCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return functionCtorImpl(arena, args, "async function*");
}

pub fn nativeAsyncFunctionCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    return functionCtorImpl(arena, args, "async function");
}

// ---- Function.prototype.toString ----
fn nativeSyntaxString(arena: std.mem.Allocator, name: []const u8) !Value {
    // NativeFunction syntax: `function <name>() { [native code] }`. The name is
    // only emitted when it is a valid identifier (no spaces), else omitted.
    const emit_name = name.len > 0 and std.mem.indexOfScalar(u8, name, ' ') == null;
    const s = if (emit_name)
        try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{name})
    else
        try std.fmt.allocPrint(arena, "function () {{ [native code] }}", .{});
    return val_mod.makeString(arena, s);
}

fn nativeFunctionToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0) {
        switch (this_val.unbox()) {
            .bc_function => |c| {
                if (c.func.source_text) |src| return val_mod.makeString(arena, src);
                return nativeSyntaxString(arena, c.func.name orelse "");
            },
            .native_function => |e| {
                return nativeSyntaxString(arena, e.name orelse "");
            },
            .function => return nativeSyntaxString(arena, ""),
            .object => |o| {
                // Bound function exotic and built-in function objects → NativeFunction.
                if (o.internal_kind == .bound_function) return nativeSyntaxString(arena, "");
                // Proxy exotic with a callable target: NativeFunction syntax.
                if (o.internal_kind == .proxy) {
                    if (proxy_mod.proxyTarget(o)) |t| {
                        if (isCallableVal(t)) return nativeSyntaxString(arena, "");
                    }
                    return throwTypeError(arena, "Function.prototype.toString requires that 'this' be a Function");
                }
                if (o.get("__call__") != null) return nativeSyntaxString(arena, "");
            },
            else => {},
        }
    }
    return throwTypeError(arena, "Function.prototype.toString requires that 'this' be a Function");
}

// ---- Cross-realm: $262.createRealm ----
/// Backing for `__jszCreateRealm__()` exposed to the test262 `$262` shim. Builds
/// a real secondary Realm (own intrinsics + global object) via the VM host hook
/// and returns `{global, evalScript}`; the JS `$262` shim layers
/// detachArrayBuffer/createRealm/gc on top.
pub fn nativeCreateRealm(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const ctx = active_context orelse return val_mod.makeUndefined(arena);
    return ctx.createRealm(arena);
}

// ---- Annex B.3.6: [[IsHTMLDDA]] ----
/// `[[Call]]` for the `document.all` stand-in: returns null when invoked with no
/// arguments, or with `""` as the *first* argument (test262 INTERPRETING.md).
/// That is what makes `"".match(documentAll)` and `"".replace(documentAll)` —
/// which pass the subject string as argument 0 — evaluate to null. Any other
/// call yields undefined.
fn nativeHTMLDDACall(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const empty_call = args.len == 0 or
        (args[0].bits != 0 and args[0].unbox() == .string and args[0].toPtr().string.len == 0);
    if (empty_call) return val_mod.makeNull(arena);
    return val_mod.makeUndefined(arena);
}

/// Backing for `__jszMakeHTMLDDA__()`. Produces a fresh callable object carrying
/// the [[IsHTMLDDA]] slot; the exotic `typeof`/ToBoolean/IsLooselyEqual behavior
/// keys off `internal_kind`, and being an ordinary object means the usual
/// property machinery (defineProperty, symbol keys) works on it unchanged.
pub fn nativeMakeHTMLDDA(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const proto: ?*JsObject = if (active_function_proto) |p| p else null;
    const o = try JsObject.create(arena, proto);
    o.internal_kind = .htmldda;
    try o.set("__call__", try val_mod.makeNativeFunctionNamed(arena, nativeHTMLDDACall, "IsHTMLDDA", 0));
    return val_mod.makeObject(arena, o);
}

/// Packed eval data for secondary realm evalScript native function.
/// Stored as native userdata (opaque *anyopaque, cast back to *const EvalData).
pub const EvalData = struct {
    env: *anyopaque,
    realm: *Realm,
};

/// Host hook backing `$262.evalScript`: evaluates `args[0]` as *Script* code in
/// the running realm's global scope. Unlike `eval`, a Script's top-level
/// `let`/`const`/`class` become global lexical bindings that outlive the call,
/// so this cannot be expressed as either a direct or an indirect eval.
pub fn nativeEvalScript(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const ctx = active_context orelse return val_mod.makeUndefined(arena);
    const env = active_global_env orelse return val_mod.makeUndefined(arena);
    const s: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        "";
    return ctx.shadowEval(arena, s, @ptrCast(env));
}

/// `evalScript` of a secondary realm record: evaluates `args[0]` as Script code
/// in that realm's global environment (carried as native userdata, an opaque
/// `*Environment`). Mirrors global-script semantics via the ShadowRealm eval hook.
pub fn nativeRealmEvalScript(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const data_ptr = val_mod.g_active_native_data orelse return val_mod.makeUndefined(arena);
    const data: *const EvalData = @ptrCast(@alignCast(data_ptr));
    const ctx = active_context orelse return val_mod.makeUndefined(arena);
    const s: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        "";
    // Set shadow realm so bcEvalInEnv tags closures with the correct realm.
    active_shadow_realm = data.realm;
    defer active_shadow_realm = null;
    return ctx.shadowEval(arena, s, data.env);
}

// ---------------------------------------------------------------- Phase 4b registration helpers ---

fn registerStringProto(arena: std.mem.Allocator, proto: *JsObject) !void {
    const fns = .{
        .{ "charAt", string_proto_mod.nativeCharAt },
        .{ "charCodeAt", string_proto_mod.nativeCharCodeAt },
        .{ "codePointAt", string_proto_mod.nativeCodePointAt },
        .{ "indexOf", string_proto_mod.nativeIndexOf },
        .{ "slice", string_proto_mod.nativeSlice },
        .{ "toUpperCase", string_proto_mod.nativeToUpperCase },
        .{ "toLowerCase", string_proto_mod.nativeToLowerCase },
        .{ "split", string_proto_mod.nativeSplit },
        .{ "concat", string_proto_mod.nativeConcat },
        .{ "trim", string_proto_mod.nativeTrim },
        .{ "padStart", string_proto_mod.nativePadStart },
        .{ "padEnd", string_proto_mod.nativePadEnd },
        .{ "trimStart", string_proto_mod.nativeTrimStart },
        .{ "trimEnd", string_proto_mod.nativeTrimEnd },
        .{ "startsWith", string_proto_mod.nativeStartsWith },
        .{ "endsWith", string_proto_mod.nativeEndsWith },
        .{ "includes", string_proto_mod.nativeStringIncludes },
        // Phase 4c: regex-aware string methods
        .{ "match", string_proto_mod.nativeMatch },
        .{ "replace", string_proto_mod.nativeReplace },
        .{ "replaceAll", string_proto_mod.nativeReplaceAll },
        .{ "search", string_proto_mod.nativeSearch },
        .{ "matchAll", string_proto_mod.nativeMatchAll },
        // Core string methods
        .{ "substring", string_proto_mod.nativeSubstring },
        .{ "substr", string_proto_mod.nativeSubstr },
        .{ "at", string_proto_mod.nativeStringAt },
        .{ "repeat", string_proto_mod.nativeRepeat },
        .{ "lastIndexOf", string_proto_mod.nativeLastIndexOf },
        // Locale aliases
        .{ "toLocaleLowerCase", string_proto_mod.nativeToLocaleLowerCase },
        .{ "toLocaleUpperCase", string_proto_mod.nativeToLocaleUpperCase },
        // localeCompare
        .{ "localeCompare", string_proto_mod.nativeLocaleCompare },
        // Unicode normalization
        .{ "normalize", string_proto_mod.nativeNormalize },
        // ES2024 well-formed
        .{ "isWellFormed", string_proto_mod.nativeIsWellFormed },
        .{ "toWellFormed", string_proto_mod.nativeToWellFormed },
        // Annex B HTML wrapper methods
        .{ "anchor", string_proto_mod.nativeAnchor },
        .{ "link", string_proto_mod.nativeLink },
        .{ "fontcolor", string_proto_mod.nativeFontcolor },
        .{ "fontsize", string_proto_mod.nativeFontsize },
        .{ "big", string_proto_mod.nativeBig },
        .{ "blink", string_proto_mod.nativeBlink },
        .{ "bold", string_proto_mod.nativeBold },
        .{ "fixed", string_proto_mod.nativeFixed },
        .{ "italics", string_proto_mod.nativeItalics },
        .{ "small", string_proto_mod.nativeSmall },
        .{ "strike", string_proto_mod.nativeStrike },
        .{ "sub", string_proto_mod.nativeSub },
        .{ "sup", string_proto_mod.nativeSup },
    };
    const str_method_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    inline for (fns) |pair| {
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], builtinLength("String.prototype." ++ pair[0]));
        _ = try proto.defineOwnData(pair[0], fn_val, str_method_attr);
    }
    // Annex B: String.prototype.trimLeft/trimRight are the very same function
    // objects as trimStart/trimEnd (identity + shared "trimStart"/"trimEnd" name).
    if (proto.getOwn("trimStart")) |ts|
        _ = try proto.defineOwnData("trimLeft", ts, str_method_attr);
    if (proto.getOwn("trimEnd")) |te|
        _ = try proto.defineOwnData("trimRight", te, str_method_attr);
    // String.prototype is itself a String object with [[StringData]] = "".
    try proto.set("[[PrimitiveValue]]", try val_mod.makeString(arena, ""));
    _ = try proto.defineOwnData("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeStringValueOf, "valueOf", 0), str_method_attr);
    _ = try proto.defineOwnData("toString", try val_mod.makeNativeFunctionNamed(arena, nativeStringValueOf, "toString", 0), str_method_attr);
}

fn registerArrayProto(arena: std.mem.Allocator, proto: *JsObject) !void {
    const fns = .{
        .{ "push", array_proto_mod.nativePush },
        .{ "pop", array_proto_mod.nativePop },
        .{ "unshift", array_proto_mod.nativeUnshift },
        .{ "shift", array_proto_mod.nativeShift },
        .{ "slice", array_proto_mod.nativeSlice },
        .{ "indexOf", array_proto_mod.nativeIndexOf },
        .{ "includes", array_proto_mod.nativeIncludes },
        .{ "flat", array_proto_mod.nativeFlat },
        .{ "flatMap", array_proto_mod.nativeFlatMap },
        .{ "join", array_proto_mod.nativeJoin },
        .{ "concat", array_proto_mod.nativeConcat },
        // Phase 4d: callback methods
        .{ "forEach", array_proto_mod.nativeForEach },
        .{ "map", array_proto_mod.nativeMap },
        .{ "filter", array_proto_mod.nativeFilter },
        .{ "reduce", array_proto_mod.nativeReduce },
        .{ "reduceRight", array_proto_mod.nativeReduceRight },
        .{ "some", array_proto_mod.nativeSome },
        .{ "every", array_proto_mod.nativeEvery },
        .{ "find", array_proto_mod.nativeFind },
        .{ "findIndex", array_proto_mod.nativeFindIndex },
        .{ "findLast", array_proto_mod.nativeFindLast },
        .{ "findLastIndex", array_proto_mod.nativeFindLastIndex },
        .{ "at", array_proto_mod.nativeAt },
        .{ "sort", array_proto_mod.nativeSort },
        .{ "fill", array_proto_mod.nativeFill },
        .{ "copyWithin", array_proto_mod.nativeCopyWithin },
        .{ "reverse", array_proto_mod.nativeReverse },
        .{ "lastIndexOf", array_proto_mod.nativeLastIndexOf },
        .{ "keys", array_proto_mod.nativeArrayKeys },
        .{ "values", es2015_collections_mod.nativeArrayValues },
        .{ "entries", array_proto_mod.nativeArrayEntries },
        .{ "with", array_proto_mod.nativeWith },
        .{ "toReversed", array_proto_mod.nativeToReversed },
        .{ "toSorted", array_proto_mod.nativeToSorted },
        .{ "toSpliced", array_proto_mod.nativeToSpliced },
        .{ "splice", array_proto_mod.nativeSplice },
        .{ "toLocaleString", array_proto_mod.nativeArrayToLocaleString },
        .{ "toString", array_proto_mod.nativeArrayToString },
    };
    const method_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    inline for (fns) |pair| {
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], builtinLength("Array.prototype." ++ pair[0]));
        _ = try proto.defineOwnData(pair[0], fn_val, method_attr);
    }
}

/// Build a plain object mirroring global env bindings and expose as globalThis/global.
/// Runtime helper for tagged template literals: given the `cooked` strings
/// array and the `raw` strings array (produced by the template-literal source
/// rewrite), attach `raw` to `cooked` as a non-writable/non-configurable
/// property and return `cooked` as the template object. Exposed globally as
/// `__jsztag`.
/// Per-realm tagged-template cache object: own property "<site_id>" → the frozen
/// template object for that source position. Rooted in the global environment
/// (hidden `__jsztmplcache__` binding) so its entries survive GC. §13.2.8.4:
/// GetTemplateObject returns the same object for one source position per realm.
pub var active_template_cache: ?*JsObject = null;

fn nativeTemplateObject(arena: std.mem.Allocator, _: val_mod.Value, args: []const val_mod.Value) anyerror!val_mod.Value {
    // args: (site_id, cooked, raw). site_id keys the realm's template cache.
    const site_id = if (args.len > 0) args[0] else val_mod.Value{};
    const cooked = if (args.len > 1) args[1] else val_mod.Value{};
    const raw = if (args.len > 2) args[2] else val_mod.Value{};

    var key_buf: [24]u8 = undefined;
    const key: ?[]const u8 = if (site_id.bits != 0 and site_id.unbox() == .number)
        std.fmt.bufPrint(&key_buf, "{d}", .{@as(i64, @intFromFloat(site_id.unbox().number))}) catch null
    else
        null;
    if (key) |k| {
        if (active_template_cache) |cache| {
            if (cache.getOwn(k)) |cached| {
                if (cached.bits != 0) return cached;
            }
        }
    }

    // §13.2.8.4 GetTemplateObject: the raw array is frozen (SetIntegrityLevel
    // "frozen"), attached to the cooked array as a non-writable/non-enumerable/
    // non-configurable "raw", then the cooked array is itself frozen. The
    // resulting object's indices are non-writable/non-configurable (still
    // enumerable) and its `length` is non-writable.
    if (raw.bits != 0 and raw.unbox() == .object) raw.toPtr().object.freezeSelf();
    if (cooked.bits != 0 and cooked.unbox() == .object) {
        _ = try cooked.toPtr().object.defineOwnData("raw", raw, .{ .writable = false, .enumerable = false, .configurable = false });
        cooked.toPtr().object.freezeSelf();
    }
    if (key) |k| {
        if (active_template_cache) |cache| {
            _ = try cache.defineOwnData(try arena.dupe(u8, k), cooked, .{ .writable = true, .enumerable = false, .configurable = true });
        }
    }
    return cooked;
}

fn installGlobalThis(arena: std.mem.Allocator, env: *Environment, object_proto: *JsObject) !void {
    const global_obj = try JsObject.create(arena, object_proto);
    var it = env.bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len >= 2 and name[0] == '_' and name[1] == '_') continue;
        // The global constants NaN, Infinity and undefined are non-writable,
        // non-enumerable and non-configurable (ES §19.1).
        const is_const = std.mem.eql(u8, name, "NaN") or std.mem.eql(u8, name, "Infinity") or std.mem.eql(u8, name, "undefined");
        const attrs: obj_mod.PropAttr = if (is_const)
            .{ .writable = false, .enumerable = false, .configurable = false }
        else
            .{ .writable = true, .enumerable = false, .configurable = true };
        _ = try global_obj.defineOwnData(name, entry.value_ptr.value, attrs);
    }
    // §19.1.3: `undefined` is a value property of the global object (it is not
    // an env binding, so the loop above never sees it).
    _ = try global_obj.defineOwnData("undefined", Value{}, .{ .writable = false, .enumerable = false, .configurable = false });
    const global_val = try val_mod.makeObject(arena, global_obj);
    try env.define("globalThis", global_val);
    try env.define("global", global_val);
    // globalThis/global are defined after the mirroring loop, so mirror them by
    // hand (§19.1.1: writable, non-enumerable, configurable).
    const global_attrs: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try global_obj.defineOwnData("globalThis", global_val, global_attrs);
    _ = try global_obj.defineOwnData("global", global_val, global_attrs);
    active_global_object = global_obj;
}

/// ES 9.1.14 step 4a / GetFunctionRealm (10.2.x): recover the Realm that created
/// a callable, used by GetPrototypeFromConstructor's fallback when
/// `newTarget.prototype` is not an object. Returns null for untagged functions
/// (treated as the running/primary realm by callers — they then keep the
/// constructor's own default prototype). Follows constructor objects via their
/// `__call__` slot and Proxies via [[ProxyTarget]].
pub fn getFunctionRealm(v: val_mod.Value) ?*Realm {
    if (v.bits == 0 or !v.isHeapPtr()) return null;
    const jsv = v.toPtr();
    switch (jsv.*) {
        .native_function => |e| return if (e.realm) |r| @ptrCast(@alignCast(r)) else null,
        .bc_function => |c| return if (c.realm) |r| @ptrCast(@alignCast(r)) else null,
        .object => |o| {
            // Proxy exotic: follow [[ProxyTarget]] (stored as a private-symbol
            // own property on the proxy object).
            if (o.internal_kind == .proxy) {
                if (active_sym_proxy_target) |sym| {
                    if (o.getOwnSym(sym)) |tv| {
                        if (tv.bits != 0) return getFunctionRealm(tv);
                    }
                }
                return null;
            }
            // Constructor object holding its callable behind `__call__`.
            if (o.getOwn("__call__")) |cv| {
                if (cv.bits != 0) return getFunctionRealm(cv);
            }
            return null;
        },
        else => return null,
    }
}

/// Snapshot of all per-realm thread-local intrinsic pointers. `$262.createRealm`
/// must build a fully independent secondary Realm via `Realm.init`, which
/// overwrites these globals; we capture them first and restore afterward so the
/// primary realm's execution is unaffected. Well-known symbols are included so
/// the primary realm's symbol identities survive (the secondary realm mints its
/// own during init).
pub const ThreadLocalSnapshot = struct {
    heap: ?*Heap,
    global_env: ?*Environment,
    global_object: ?*JsObject,
    array_proto: ?*JsObject,
    object_proto: ?*JsObject,
    string_proto: ?*JsObject,
    number_proto: ?*JsObject,
    boolean_proto: ?*JsObject,
    bigint_proto: ?*JsObject,
    regexp_proto: ?*JsObject,
    regexp_ctor: ?*JsObject,
    function_proto: ?*JsObject,
    promise_proto: ?*JsObject,
    symbol_proto: ?*JsObject,
    sym_iterator: ?val_mod.Value,
    sym_async_iterator: ?val_mod.Value,
    sym_async_dispose: ?val_mod.Value,
    sym_dispose: ?val_mod.Value,
    sym_to_primitive: ?val_mod.Value,
    sym_to_string_tag: ?val_mod.Value,
    sym_species: ?val_mod.Value,
    sym_proxy_target: ?val_mod.Value,
    sym_proxy_handler: ?val_mod.Value,
    sym_module_ns: ?val_mod.Value,
    sym_deferred_id: ?val_mod.Value,
    deferred_ns_registry: ?val_mod.Value,
    sym_export_names: ?val_mod.Value,
    sym_tdz_export_names: ?val_mod.Value,
    err_Error: ?*JsObject,
    err_TypeError: ?*JsObject,
    err_SyntaxError: ?*JsObject,
    err_RangeError: ?*JsObject,
    err_ReferenceError: ?*JsObject,
    err_AggregateError: ?*JsObject,
    err_URIError: ?*JsObject,
    array_ctor: ?*JsObject,
    ab_proto: ?*JsObject,
    ab_ctor: ?*JsObject,
    sab_proto: ?*JsObject,
    sab_ctor: ?*JsObject,
    dv_proto: ?*JsObject,
    atomics: ?*JsObject,
    ta_proto: ?*JsObject,
    ta_ctor: ?*JsObject,
    ta_iter_proto: ?*JsObject,
    ta_protos: [typed_array_mod.all_kinds.len]?*JsObject,
    ta_ctors: [typed_array_mod.all_kinds.len]?*JsObject,

    pub fn capture() ThreadLocalSnapshot {
        return .{
            .heap = active_heap,
            .global_env = active_global_env,
            .global_object = active_global_object,
            .array_proto = active_array_proto,
            .object_proto = active_object_proto,
            .string_proto = active_string_proto,
            .number_proto = active_number_proto,
            .boolean_proto = active_boolean_proto,
            .bigint_proto = active_bigint_proto,
            .regexp_proto = active_regexp_proto,
            .regexp_ctor = @import("builtins/regexp.zig").active_regexp_ctor,
            .function_proto = active_function_proto,
            .promise_proto = active_promise_proto,
            .symbol_proto = active_symbol_proto,
            .sym_iterator = active_sym_iterator,
            .sym_async_iterator = active_sym_async_iterator,
            .sym_async_dispose = active_sym_async_dispose,
            .sym_dispose = active_sym_dispose,
            .sym_to_primitive = active_sym_to_primitive,
            .sym_to_string_tag = active_sym_to_string_tag,
            .sym_species = active_sym_species,
            .sym_proxy_target = active_sym_proxy_target,
            .sym_proxy_handler = active_sym_proxy_handler,
            .sym_module_ns = active_sym_module_ns,
            .sym_deferred_id = active_sym_deferred_id,
            .deferred_ns_registry = active_deferred_ns_registry,
            .sym_export_names = active_sym_export_names,
            .sym_tdz_export_names = active_sym_tdz_export_names,
            .err_Error = error_proto_Error,
            .err_TypeError = error_proto_TypeError,
            .err_SyntaxError = error_proto_SyntaxError,
            .err_RangeError = error_proto_RangeError,
            .err_ReferenceError = error_proto_ReferenceError,
            .err_AggregateError = error_proto_AggregateError,
            .err_URIError = error_proto_URIError,
            .array_ctor = active_array_ctor,
            .ab_proto = typed_array_mod.active_arraybuffer_proto,
            .ab_ctor = typed_array_mod.active_arraybuffer_ctor,
            .sab_proto = typed_array_mod.active_sharedarraybuffer_proto,
            .sab_ctor = typed_array_mod.active_sharedarraybuffer_ctor,
            .dv_proto = typed_array_mod.active_dataview_proto,
            .atomics = typed_array_mod.active_atomics,
            .ta_proto = typed_array_mod.active_typedarray_proto,
            .ta_ctor = typed_array_mod.active_typedarray_ctor,
            .ta_iter_proto = typed_array_mod.active_ta_iter_proto,
            .ta_protos = typed_array_mod.active_ta_protos,
            .ta_ctors = typed_array_mod.active_ta_ctors,
        };
    }

    pub fn restore(self: ThreadLocalSnapshot) void {
        active_heap = self.heap;
        active_global_env = self.global_env;
        active_global_object = self.global_object;
        active_array_proto = self.array_proto;
        active_array_ctor = self.array_ctor;
        active_object_proto = self.object_proto;
        active_string_proto = self.string_proto;
        active_number_proto = self.number_proto;
        active_boolean_proto = self.boolean_proto;
        active_bigint_proto = self.bigint_proto;
        active_regexp_proto = self.regexp_proto;
        @import("builtins/regexp.zig").active_regexp_ctor = self.regexp_ctor;
        active_function_proto = self.function_proto;
        active_promise_proto = self.promise_proto;
        active_symbol_proto = self.symbol_proto;
        active_sym_iterator = self.sym_iterator;
        active_sym_async_iterator = self.sym_async_iterator;
        active_sym_async_dispose = self.sym_async_dispose;
        active_sym_dispose = self.sym_dispose;
        active_sym_to_primitive = self.sym_to_primitive;
        active_sym_to_string_tag = self.sym_to_string_tag;
        active_sym_species = self.sym_species;
        active_sym_proxy_target = self.sym_proxy_target;
        active_sym_proxy_handler = self.sym_proxy_handler;
        active_sym_module_ns = self.sym_module_ns;
        active_sym_deferred_id = self.sym_deferred_id;
        active_deferred_ns_registry = self.deferred_ns_registry;
        active_sym_export_names = self.sym_export_names;
        active_sym_tdz_export_names = self.sym_tdz_export_names;
        error_proto_Error = self.err_Error;
        error_proto_TypeError = self.err_TypeError;
        error_proto_SyntaxError = self.err_SyntaxError;
        error_proto_RangeError = self.err_RangeError;
        error_proto_ReferenceError = self.err_ReferenceError;
        error_proto_AggregateError = self.err_AggregateError;
        error_proto_URIError = self.err_URIError;
        typed_array_mod.active_arraybuffer_proto = self.ab_proto;
        typed_array_mod.active_arraybuffer_ctor = self.ab_ctor;
        typed_array_mod.active_sharedarraybuffer_proto = self.sab_proto;
        typed_array_mod.active_sharedarraybuffer_ctor = self.sab_ctor;
        typed_array_mod.active_dataview_proto = self.dv_proto;
        typed_array_mod.active_atomics = self.atomics;
        typed_array_mod.active_typedarray_proto = self.ta_proto;
        typed_array_mod.active_typedarray_ctor = self.ta_ctor;
        typed_array_mod.active_ta_iter_proto = self.ta_iter_proto;
        typed_array_mod.active_ta_protos = self.ta_protos;
        typed_array_mod.active_ta_ctors = self.ta_ctors;
    }
};

pub const Realm = struct {
    global_env: *Environment,
    arena: std.mem.Allocator,
    /// Object.prototype — proto of all plain objects.
    object_prototype: *JsObject,
    /// Array.prototype — proto of all array objects.
    array_prototype: *JsObject,
    /// Phase 4a: Error prototypes.
    error_prototype: *JsObject = undefined,
    type_error_prototype: *JsObject = undefined,
    syntax_error_prototype: *JsObject = undefined,
    range_error_prototype: *JsObject = undefined,
    reference_error_prototype: *JsObject = undefined,
    aggregate_error_prototype: *JsObject = undefined,
    /// Phase 4b: String.prototype.
    string_prototype: *JsObject = undefined,
    /// Phase 4c: RegExp.prototype.
    regexp_prototype: *JsObject = undefined,
    /// The %RegExp% constructor object -- the sole valid receiver for the Annex B
    /// legacy statics (RegExp.$1, RegExp.input, ...), which are brand-checked
    /// against the *getter's own* realm's constructor.
    regexp_ctor: ?*JsObject = null,
    /// Phase 4d: Function.prototype.
    function_prototype: *JsObject = undefined,
    /// Phase 3b: GC heap. Null in tree-walker mode (which uses the eval arena).
    heap: ?*Heap = null,
    /// Root Value slots for object_prototype and array_prototype so GC keeps them alive.
    _proto_root: Value = Value{},
    _array_proto_root: Value = Value{},
    /// Root Value slots for Error prototypes.
    _error_proto_root: Value = Value{},
    _type_error_proto_root: Value = Value{},
    _syntax_error_proto_root: Value = Value{},
    _range_error_proto_root: Value = Value{},
    _reference_error_proto_root: Value = Value{},
    _aggregate_error_proto_root: Value = Value{},

    /// Cross-realm: identity of this realm. 0 = the primary realm.
    realm_id: u32 = 0,
    /// Cross-realm: this realm's `globalThis` object (mirror of `global_env`),
    /// captured at init so `$262.createRealm().global` can expose it.
    global_object: ?*JsObject = null,
    /// Per-intrinsic prototypes for GetPrototypeFromConstructor's GetFunctionRealm
    /// fallback (ES 9.1.14 step 4b). Populated for secondary realms by
    /// createSecondaryRealm and for the primary realm by captureIntrinsics.
    ab_prototype: ?*JsObject = null,
    sab_prototype: ?*JsObject = null,
    dv_prototype: ?*JsObject = null,
    /// %Array% of this realm (see `active_array_ctor`).
    array_ctor: ?*JsObject = null,
    /// %Promise.prototype% of this realm (OrdinaryCreateFromConstructor fallback).
    promise_prototype: ?*JsObject = null,
    /// %TypedArray%.prototype (shared base of all per-kind TA prototype chains).
    ta_shared_prototype: ?*JsObject = null,
    /// Per-kind TypedArray prototypes, indexed by typed_array.TAKind.
    ta_kind_prototypes: [typed_array_mod.all_kinds.len]?*JsObject =
        .{null} ** typed_array_mod.all_kinds.len,
    // Per-realm generator intrinsic chain (built lazily by BcVm.ensureGeneratorChain).
    gen_proto: ?*JsObject = null,
    gen_fn_proto: ?*JsObject = null,
    gen_fn_ctor: ?*JsObject = null,
    async_gen_proto: ?*JsObject = null,
    async_gen_fn_proto: ?*JsObject = null,
    async_gen_fn_ctor: ?*JsObject = null,
    async_iter_proto: ?*JsObject = null,
    // %AsyncFunction.prototype% / %AsyncFunction%. Unlike the generator chain
    // there is no matching "instance prototype" slot: async functions have no
    // own `.prototype` property (spec §27.7).
    async_fn_proto: ?*JsObject = null,
    async_fn_ctor: ?*JsObject = null,
    // Cached roots for the generator chain (captured at captureIntrinsics time).
    gen_iterator_proto: ?*JsObject = null,
    gen_function_ctor: ?*JsObject = null,

    pub fn init(arena: std.mem.Allocator) !Realm {
        const env = try Environment.init(arena, null);

        // Build Object.prototype (proto = null, as per spec).
        const object_proto = try JsObject.create(arena, null);

        // Build Array.prototype (proto = Object.prototype). §23.1.3: it is itself
        // an Array exotic object with length 0, so `Array.isArray(Array.prototype)`
        // is true and `Array.prototype.length` is 0 (not undefined).
        const array_proto = try JsObject.create(arena, object_proto);
        array_proto.is_array = true;
        array_proto.array_length = 0;

        // Build Object constructor object: a JsObject with a "create" property.
        const object_ctor = try JsObject.create(arena, null);
        const create_fn = try val_mod.makeNativeFunction(arena, nativeObjectCreate);
        try object_ctor.set("create", create_fn);
        try object_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeObjectCtor));

        // Also expose Object.prototype on the constructor.
        const proto_val = try val_mod.makeObject(arena, object_proto);
        // §20.1.2.x: `Object.prototype` is { [[Writable]]: false,
        // [[Enumerable]]: false, [[Configurable]]: false }.
        try object_ctor.defineOwnDataForced("prototype", proto_val, .{ .writable = false, .enumerable = false, .configurable = false });

        // Define "Object" in global env as the constructor object.
        _ = try object_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try object_ctor.defineOwnData("name", try val_mod.makeString(arena, "Object"), .{ .writable = false, .enumerable = false, .configurable = true });
        const ctor_val = try val_mod.makeObject(arena, object_ctor);
        active_object_ctor = object_ctor;
        try env.define("Object", ctor_val);

        // Object.prototype.constructor === Object (spec §20.1.2.1). Was absent →
        // `({}).constructor` / `Object.prototype.constructor` returned undefined
        // engine-wide (only masked when a nearer proto defined its own constructor).
        _ = try object_proto.defineOwnData("constructor", ctor_val, .{ .writable = true, .enumerable = false, .configurable = true });

        // ---- Phase 4a: Error prototypes and constructors ----
        // Error.prototype: proto = object_prototype.
        const error_proto = try JsObject.create(arena, object_proto);
        const ep_name = try val_mod.makeString(arena, "Error");
        const ep_msg = try val_mod.makeString(arena, "");
        try error_proto.set("name", ep_name);
        try error_proto.set("message", ep_msg);
        _ = try error_proto.defineOwnData("toString", try val_mod.makeNativeFunctionNamed(arena, nativeErrorToString, "toString", 0), .{ .writable = true, .enumerable = false, .configurable = true });
        // Error.prototype.stack (error-stack-accessor proposal): accessor property
        // { [[Enumerable]]: false, [[Configurable]]: true }; get "get stack"/0,
        // set "set stack"/1.
        {
            const stack_holder = try JsObject.create(arena, null);
            try stack_holder.set("get", try val_mod.makeNativeFunctionNamed(arena, nativeErrorStackGet, "get stack", 0));
            try stack_holder.set("set", try val_mod.makeNativeFunctionNamed(arena, nativeErrorStackSet, "set stack", 1));
            _ = try error_proto.defineOwnAccessor("stack", try val_mod.makeObject(arena, stack_holder), .{ .enumerable = false, .configurable = true });
        }

        // TypeError.prototype: proto = Error.prototype.
        const type_error_proto = try JsObject.create(arena, error_proto);
        const tep_name = try val_mod.makeString(arena, "TypeError");
        try type_error_proto.set("name", tep_name);
        try type_error_proto.set("message", ep_msg);

        // SyntaxError.prototype: proto = Error.prototype.
        const syntax_error_proto = try JsObject.create(arena, error_proto);
        const sep_name = try val_mod.makeString(arena, "SyntaxError");
        try syntax_error_proto.set("name", sep_name);
        try syntax_error_proto.set("message", ep_msg);

        // RangeError.prototype: proto = Error.prototype.
        const range_error_proto = try JsObject.create(arena, error_proto);
        const rep_name = try val_mod.makeString(arena, "RangeError");
        try range_error_proto.set("name", rep_name);
        try range_error_proto.set("message", ep_msg);

        // ReferenceError.prototype: proto = Error.prototype.
        const reference_error_proto = try JsObject.create(arena, error_proto);
        const refp_name = try val_mod.makeString(arena, "ReferenceError");
        try reference_error_proto.set("name", refp_name);
        try reference_error_proto.set("message", ep_msg);

        // AggregateError.prototype: proto = Error.prototype.
        const aggregate_error_proto = try JsObject.create(arena, error_proto);
        const aep_name = try val_mod.makeString(arena, "AggregateError");
        try aggregate_error_proto.set("name", aep_name);
        try aggregate_error_proto.set("message", ep_msg);

        // EvalError.prototype / URIError.prototype: proto = Error.prototype.
        const eval_error_proto = try JsObject.create(arena, error_proto);
        try eval_error_proto.set("name", try val_mod.makeString(arena, "EvalError"));
        try eval_error_proto.set("message", ep_msg);
        const uri_error_proto = try JsObject.create(arena, error_proto);
        try uri_error_proto.set("name", try val_mod.makeString(arena, "URIError"));
        try uri_error_proto.set("message", ep_msg);

        // SuppressedError.prototype (ES2024): proto = Error.prototype.
        const suppressed_error_proto = try JsObject.create(arena, error_proto);
        try suppressed_error_proto.set("name", try val_mod.makeString(arena, "SuppressedError"));
        try suppressed_error_proto.set("message", ep_msg);

        // Set thread-local proto pointers so native ctors can find them.
        error_proto_Error = error_proto;
        error_proto_TypeError = type_error_proto;
        error_proto_SyntaxError = syntax_error_proto;
        error_proto_RangeError = range_error_proto;
        error_proto_ReferenceError = reference_error_proto;
        error_proto_AggregateError = aggregate_error_proto;
        error_proto_URIError = uri_error_proto;
        error_proto_EvalError = eval_error_proto;
        error_proto_SuppressedError = suppressed_error_proto;

        // Create Error constructor objects. Each has a .prototype property
        // and a hidden __proto__ marker so `instanceof` can find the prototype.
        const makeErrorCtor = struct {
            fn make(a: std.mem.Allocator, ctor_fn: val_mod.NativeFnPtr, proto_obj: *JsObject, name: []const u8, len: f64) !Value {
                const ctor_obj = try JsObject.create(a, null);
                const ctor_proto_val = try val_mod.makeObject(a, proto_obj);
                // §20.5.x: `Constructor.prototype` is { [[Writable]]: false,
                // [[Enumerable]]: false, [[Configurable]]: false }.
                _ = try ctor_obj.defineOwnData("prototype", ctor_proto_val, .{ .writable = false, .enumerable = false, .configurable = false });
                const fn_val = try val_mod.makeNativeFunction(a, ctor_fn);
                // Store the native fn on the ctor object as "__call__".
                try ctor_obj.set("__call__", fn_val);
                // §20.5.x: each Error constructor has `name` (e.g. "TypeError") and
                // a `length` (largest named-arg count), both non-enumerable /
                // configurable / non-writable. assert.throws and
                // Function.prototype.toString rely on `name`.
                const nlen_attr: obj_mod.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
                _ = try ctor_obj.defineOwnData("length", try val_mod.makeNumber(a, len), nlen_attr);
                _ = try ctor_obj.defineOwnData("name", try val_mod.makeString(a, name), nlen_attr);
                return val_mod.makeObject(a, ctor_obj);
            }
        }.make;

        const error_ctor_val = try makeErrorCtor(arena, nativeErrorCtor, error_proto, "Error", 1);
        const type_error_ctor_val = try makeErrorCtor(arena, nativeTypeErrorCtor, type_error_proto, "TypeError", 1);
        const syntax_error_ctor_val = try makeErrorCtor(arena, nativeSyntaxErrorCtor, syntax_error_proto, "SyntaxError", 1);
        const range_error_ctor_val = try makeErrorCtor(arena, nativeRangeErrorCtor, range_error_proto, "RangeError", 1);
        const reference_error_ctor_val = try makeErrorCtor(arena, nativeReferenceErrorCtor, reference_error_proto, "ReferenceError", 1);
        const aggregate_error_ctor_val = try makeErrorCtor(arena, nativeAggregateErrorCtor, aggregate_error_proto, "AggregateError", 2);
        const eval_error_ctor_val = try makeErrorCtor(arena, nativeEvalErrorCtor, eval_error_proto, "EvalError", 1);
        const uri_error_ctor_val = try makeErrorCtor(arena, nativeUriErrorCtor, uri_error_proto, "URIError", 1);
        const suppressed_error_ctor_val = try makeErrorCtor(arena, nativeSuppressedErrorCtor, suppressed_error_proto, "SuppressedError", 3);

        // Spec: ErrorPrototype.constructor = ErrorConstructor (non-enumerable, writable, configurable).
        // Required for `thrown.constructor === TypeError` identity checks in assert.throws.
        const ctor_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
        _ = try error_proto.defineOwnData("constructor", error_ctor_val, ctor_attr);
        _ = try type_error_proto.defineOwnData("constructor", type_error_ctor_val, ctor_attr);
        _ = try syntax_error_proto.defineOwnData("constructor", syntax_error_ctor_val, ctor_attr);
        _ = try range_error_proto.defineOwnData("constructor", range_error_ctor_val, ctor_attr);
        _ = try reference_error_proto.defineOwnData("constructor", reference_error_ctor_val, ctor_attr);
        _ = try aggregate_error_proto.defineOwnData("constructor", aggregate_error_ctor_val, ctor_attr);
        _ = try eval_error_proto.defineOwnData("constructor", eval_error_ctor_val, ctor_attr);
        _ = try uri_error_proto.defineOwnData("constructor", uri_error_ctor_val, ctor_attr);
        _ = try suppressed_error_proto.defineOwnData("constructor", suppressed_error_ctor_val, ctor_attr);

        // Error.isError (ES2024 static method), non-enumerable / writable / configurable.
        _ = try error_ctor_val.toPtr().object.defineOwnData("isError", try val_mod.makeNativeFunctionNamed(arena, nativeErrorIsError, "isError", 1), .{ .writable = true, .enumerable = false, .configurable = true });

        try env.define("Error", error_ctor_val);
        try env.define("TypeError", type_error_ctor_val);
        try env.define("SyntaxError", syntax_error_ctor_val);
        try env.define("RangeError", range_error_ctor_val);
        try env.define("ReferenceError", reference_error_ctor_val);
        try env.define("AggregateError", aggregate_error_ctor_val);
        try env.define("EvalError", eval_error_ctor_val);
        try env.define("URIError", uri_error_ctor_val);
        try env.define("SuppressedError", suppressed_error_ctor_val);

        // Also store prototypes under hidden names so vm.zig's getErrorProto can find them.
        const error_proto_val = try val_mod.makeObject(arena, error_proto);
        const type_error_proto_val = try val_mod.makeObject(arena, type_error_proto);
        const syntax_error_proto_val = try val_mod.makeObject(arena, syntax_error_proto);
        const range_error_proto_val = try val_mod.makeObject(arena, range_error_proto);
        const reference_error_proto_val = try val_mod.makeObject(arena, reference_error_proto);
        const aggregate_error_proto_val = try val_mod.makeObject(arena, aggregate_error_proto);
        try env.define("__ErrorProto__", error_proto_val);
        try env.define("__TypeErrorProto__", type_error_proto_val);
        try env.define("__SyntaxErrorProto__", syntax_error_proto_val);
        try env.define("__RangeErrorProto__", range_error_proto_val);
        try env.define("__ReferenceErrorProto__", reference_error_proto_val);
        try env.define("__AggregateErrorProto__", aggregate_error_proto_val);

        // ---- Phase 4b: String.prototype ----
        const string_proto = try JsObject.create(arena, object_proto);
        try registerStringProto(arena, string_proto);

        // ---- Phase 4b: Array.prototype methods ----
        try registerArrayProto(arena, array_proto);

        // ---- Phase 4b: Object static methods + hasOwnProperty ----
        // Add keys/values to the existing Object constructor.
        if (env.bindings.getPtr("Object")) |obj_binding| {
            const obj_val_ptr = &obj_binding.value;
            if (obj_val_ptr.bits != 0 and obj_val_ptr.unbox() == .object) {
                const ctor_obj = obj_val_ptr.toPtr().object;
                // All Object static methods are { writable, !enumerable, configurable }
                // with a spec-mandated `length` (function.length descriptor tests).
                const m_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
                const StaticMethod = struct { name: []const u8, fn_ptr: val_mod.NativeFnPtr, len: u32 };
                const static_methods = [_]StaticMethod{
                    .{ .name = "create", .fn_ptr = nativeObjectCreate, .len = 2 },
                    .{ .name = "keys", .fn_ptr = obj_methods_mod.nativeObjectKeys, .len = 1 },
                    .{ .name = "values", .fn_ptr = obj_methods_mod.nativeObjectValues, .len = 1 },
                    .{ .name = "entries", .fn_ptr = obj_methods_mod.nativeObjectEntries, .len = 1 },
                    .{ .name = "assign", .fn_ptr = obj_methods_mod.nativeObjectAssign, .len = 2 },
                    .{ .name = "fromEntries", .fn_ptr = obj_methods_mod.nativeObjectFromEntries, .len = 1 },
                    .{ .name = "getOwnPropertyDescriptors", .fn_ptr = obj_methods_mod.nativeObjectGetOwnPropertyDescriptors, .len = 1 },
                    .{ .name = "getPrototypeOf", .fn_ptr = obj_methods_mod.nativeObjectGetPrototypeOf, .len = 1 },
                    .{ .name = "setPrototypeOf", .fn_ptr = obj_methods_mod.nativeObjectSetPrototypeOf, .len = 2 },
                    .{ .name = "getOwnPropertyNames", .fn_ptr = obj_methods_mod.nativeObjectGetOwnPropertyNames, .len = 1 },
                    .{ .name = "getOwnPropertyDescriptor", .fn_ptr = obj_methods_mod.nativeObjectGetOwnPropertyDescriptor, .len = 2 },
                    .{ .name = "defineProperty", .fn_ptr = obj_methods_mod.nativeObjectDefineProperty, .len = 3 },
                    .{ .name = "defineProperties", .fn_ptr = obj_methods_mod.nativeObjectDefineProperties, .len = 2 },
                    .{ .name = "freeze", .fn_ptr = obj_methods_mod.nativeObjectFreeze, .len = 1 },
                    .{ .name = "seal", .fn_ptr = obj_methods_mod.nativeObjectSeal, .len = 1 },
                    .{ .name = "preventExtensions", .fn_ptr = obj_methods_mod.nativeObjectPreventExtensions, .len = 1 },
                    .{ .name = "isFrozen", .fn_ptr = obj_methods_mod.nativeObjectIsFrozen, .len = 1 },
                    .{ .name = "isSealed", .fn_ptr = obj_methods_mod.nativeObjectIsSealed, .len = 1 },
                    .{ .name = "isExtensible", .fn_ptr = obj_methods_mod.nativeObjectIsExtensible, .len = 1 },
                    .{ .name = "getOwnPropertySymbols", .fn_ptr = obj_methods_mod.nativeObjectGetOwnPropertySymbols, .len = 1 },
                    .{ .name = "is", .fn_ptr = obj_methods_mod.nativeObjectIs, .len = 2 },
                    .{ .name = "hasOwn", .fn_ptr = obj_methods_mod.nativeObjectHasOwn, .len = 2 },
                    .{ .name = "groupBy", .fn_ptr = es2015_collections_mod.nativeObjectGroupBy, .len = 2 },
                };
                inline for (static_methods) |sm| {
                    _ = try ctor_obj.defineOwnData(sm.name, try val_mod.makeNativeFunctionNamed(arena, sm.fn_ptr, sm.name, sm.len), m_attr);
                }
            }
        }
        // hasOwnProperty on Object.prototype (non-enumerable, writable, configurable)
        const meth_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
        _ = try object_proto.defineOwnData("hasOwnProperty", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeHasOwnProperty, "hasOwnProperty", 1), meth_attr);
        _ = try object_proto.defineOwnData("propertyIsEnumerable", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativePropertyIsEnumerable, "propertyIsEnumerable", 1), meth_attr);
        _ = try object_proto.defineOwnData("isPrototypeOf", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeObjectIsPrototypeOf, "isPrototypeOf", 1), meth_attr);
        _ = try object_proto.defineOwnData("toString", try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoToString, "toString", 0), meth_attr);
        _ = try object_proto.defineOwnData("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoValueOf, "valueOf", 0), meth_attr);
        _ = try object_proto.defineOwnData("toLocaleString", try val_mod.makeNativeFunctionNamed(arena, array_proto_mod.nativeObjectToLocaleString, "toLocaleString", 0), meth_attr);
        // Annex B §B.2.2.2-5: legacy accessor helpers on Object.prototype.
        _ = try object_proto.defineOwnData("__defineGetter__", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeDefineGetter, "__defineGetter__", 2), meth_attr);
        _ = try object_proto.defineOwnData("__defineSetter__", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeDefineSetter, "__defineSetter__", 2), meth_attr);
        _ = try object_proto.defineOwnData("__lookupGetter__", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeLookupGetter, "__lookupGetter__", 1), meth_attr);
        _ = try object_proto.defineOwnData("__lookupSetter__", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeLookupSetter, "__lookupSetter__", 1), meth_attr);
        // Annex B §B.2.2.1: Object.prototype.__proto__ accessor (get/set the
        // receiver's [[Prototype]]). Enumerable:false, configurable:true.
        const proto_acc_holder = try JsObject.create(arena, null);
        try proto_acc_holder.set("get", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeObjectProtoGetProto, "get __proto__", 0));
        try proto_acc_holder.set("set", try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeObjectProtoSetProto, "set __proto__", 1));
        _ = try object_proto.defineOwnAccessor("__proto__", try val_mod.makeObject(arena, proto_acc_holder), .{
            .enumerable = false,
            .configurable = true,
        });

        // ---- Phase 4d: Function.prototype (call, apply, bind) ----
        const function_proto = try JsObject.create(arena, object_proto);
        _ = try function_proto.defineOwnData("call", try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionCall, "call", 1), meth_attr);
        _ = try function_proto.defineOwnData("apply", try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionApply, "apply", 2), meth_attr);
        _ = try function_proto.defineOwnData("bind", try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionBind, "bind", 1), meth_attr);
        _ = try function_proto.defineOwnData("toString", try val_mod.makeNativeFunctionNamed(arena, nativeFunctionToString, "toString", 0), meth_attr);

        // AddRestrictedFunctionProperties: "caller" and "arguments" are
        // poison-pill accessors whose [[Get]] and [[Set]] are the shared
        // %ThrowTypeError% intrinsic (enumerable:false, configurable:true).
        const thrower = try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeThrowTypeError, "", 0);
        // §10.2.4.1: %ThrowTypeError% is non-extensible and its `length`/`name`
        // are non-configurable — unlike every other built-in function.
        thrower.toPtr().native_function.frozen_intrinsic = true;
        active_throw_type_error = thrower;
        const thrower_holder = try JsObject.create(arena, null);
        try thrower_holder.set("get", thrower);
        try thrower_holder.set("set", thrower);
        _ = try function_proto.defineOwnAccessor("caller", try val_mod.makeObject(arena, thrower_holder), .{
            .enumerable = false,
            .configurable = true,
        });
        _ = try function_proto.defineOwnAccessor("arguments", try val_mod.makeObject(arena, thrower_holder), .{
            .enumerable = false,
            .configurable = true,
        });
        // %Function.prototype% is itself a function: own "length" (0) and "name"
        // ("") are non-writable, non-enumerable, configurable data properties.
        _ = try function_proto.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try function_proto.defineOwnData("name", try val_mod.makeString(arena, ""), .{ .writable = false, .enumerable = false, .configurable = true });
        // §20.2.3: %Function.prototype% is a callable built-in function object
        // that accepts any arguments and returns undefined. It cannot advertise
        // that with a `__call__` slot -- that slot is found by a prototype-chain
        // walk, so %GeneratorFunction.prototype% and every other inheritor would
        // report `typeof === "function"` too. `is_callable_intrinsic` is the
        // own-object brand each IsCallable site checks instead.
        function_proto.is_callable_intrinsic = true;
        active_function_proto = function_proto;

        // R1: shared registration context for self-registering builtins (each
        // installs its own prototype + constructor + global). Built once here,
        // after the shared prototypes it depends on exist.
        const reg_ctx = intrinsics.Ctx{
            .arena = arena,
            .env = env,
            .object_proto = object_proto,
            .function_proto = function_proto,
            .array_proto = array_proto,
        };

        try date_mod.register(&reg_ctx);

        // ---- Wave 25: Temporal (Instant/Duration/PlainDate/PlainTime/PlainDateTime) ----
        try temporal_mod.register(&reg_ctx);

        // ---- Phase 4b: Math object ----
        try math_mod.register(&reg_ctx);

        // ---- Phase 4b: JSON object ----
        try json_mod.register(&reg_ctx);

        // ---- Phase 4c: RegExp constructor + prototype ----
        try regexp_mod.register(&reg_ctx);

        // ---- Phase 7 baseline: Map/Set/WeakMap/WeakSet ----
        try es2015_collections_mod.register(&reg_ctx);

        // ---- M15: ArrayBuffer / TypedArrays / DataView ----
        try typed_array_mod.register(&reg_ctx);

        // ---- Phase 7 baseline: Promise ----
        active_promise_proto = try promise_mod.register(&reg_ctx);

        try disposable_stack_mod.register(&reg_ctx);
        const require_cache_obj = try JsObject.create(arena, object_proto);
        try env.define("__require_cache__", try val_mod.makeObject(arena, require_cache_obj));
        const require_obj = try JsObject.create(arena, function_proto);
        try require_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeRequire));
        try require_obj.set("resolve", try val_mod.makeNativeFunctionNamed(arena, nativeRequireResolve, "resolve", 0));
        try require_obj.set("cache", try val_mod.makeObject(arena, require_cache_obj));
        try env.define("require", try val_mod.makeObject(arena, require_obj));
        const module_obj = try JsObject.create(arena, null);
        const exports_obj = try JsObject.create(arena, object_proto);
        const exports_val = try val_mod.makeObject(arena, exports_obj);
        try module_obj.set("exports", exports_val);
        try env.define("module", try val_mod.makeObject(arena, module_obj));
        try env.define("exports", exports_val);

        // ---- Phase 4: Array, String, Number constructors ----
        const array_ctor_obj = try JsObject.create(arena, null);
        try array_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, array_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try array_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeArrayCtor));
        try array_ctor_obj.set("isArray", try val_mod.makeNativeFunctionNamed(arena, nativeArrayIsArray, "isArray", 1));
        try array_ctor_obj.set("from", try val_mod.makeNativeFunctionNamed(arena, nativeArrayFrom, "from", 1));
        try array_ctor_obj.set("of", try val_mod.makeNativeFunctionNamed(arena, nativeArrayOf, "of", 0));
        // Array.fromAsync: non-enumerable to satisfy prop-desc test (§23.1.2.1)
        const from_async_attr = obj_mod.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
        _ = try array_ctor_obj.defineOwnData("fromAsync", try val_mod.makeNativeFunctionNamed(arena, nativeArrayFromAsync, "fromAsync", 1), from_async_attr);
        _ = try array_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try array_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Array"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try array_proto.defineOwnData("constructor", try val_mod.makeObject(arena, array_ctor_obj), .{ .writable = true, .enumerable = false, .configurable = true });
        try env.define("Array", try val_mod.makeObject(arena, array_ctor_obj));
        active_array_ctor = array_ctor_obj;

        const string_ctor_obj = try JsObject.create(arena, null);
        try string_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, string_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try string_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeStringCtor));
        try string_ctor_obj.set("fromCharCode", try val_mod.makeNativeFunctionNamed(arena, nativeStringFromCharCode, "fromCharCode", 1));
        try string_ctor_obj.set("fromCodePoint", try val_mod.makeNativeFunctionNamed(arena, nativeStringFromCodePoint, "fromCodePoint", 1));
        try string_ctor_obj.set("raw", try val_mod.makeNativeFunctionNamed(arena, nativeStringRaw, "raw", 1));
        try string_proto.set("constructor", try val_mod.makeObject(arena, string_ctor_obj));
        _ = try string_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try string_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "String"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("String", try val_mod.makeObject(arena, string_ctor_obj));

        const number_proto = try JsObject.create(arena, object_proto);
        // Number.prototype is itself a Number object with [[NumberData]] = +0.
        try number_proto.set("[[PrimitiveValue]]", try val_mod.makeNumber(arena, 0));
        try number_proto.set("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeNumberValueOf, "valueOf", 0));
        try number_proto.set("toString", try val_mod.makeNativeFunctionNamedLen(arena, nativeNumberToString, "toString", 1));
        try number_proto.set("toLocaleString", try val_mod.makeNativeFunctionNamed(arena, nativeNumberProtoToLocaleString, "toLocaleString", 0));
        try number_proto.set("toFixed", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToFixed, "toFixed", 1));
        try number_proto.set("toExponential", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToExponential, "toExponential", 1));
        try number_proto.set("toPrecision", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToPrecision, "toPrecision", 1));
        active_number_proto = number_proto;
        const number_ctor_obj = try JsObject.create(arena, null);
        try number_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, number_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try number_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeNumberCtor));
        // Number static constants are non-writable, non-enumerable, non-configurable
        // (ES 20.1.2): `Number.NaN = 1` must be a silent no-op in sloppy mode.
        const num_const_attr = obj_mod.PropAttr{ .writable = false, .enumerable = false, .configurable = false };
        _ = try number_ctor_obj.defineOwnData("MAX_VALUE", try val_mod.makeNumber(arena, 1.7976931348623157e+308), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("MIN_VALUE", try val_mod.makeNumber(arena, 5e-324), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("NaN", try val_mod.makeNumber(arena, std.math.nan(f64)), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("POSITIVE_INFINITY", try val_mod.makeNumber(arena, std.math.inf(f64)), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("NEGATIVE_INFINITY", try val_mod.makeNumber(arena, -std.math.inf(f64)), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("EPSILON", try val_mod.makeNumber(arena, 2.220446049250313e-16), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("MAX_SAFE_INTEGER", try val_mod.makeNumber(arena, 9007199254740991.0), num_const_attr);
        _ = try number_ctor_obj.defineOwnData("MIN_SAFE_INTEGER", try val_mod.makeNumber(arena, -9007199254740991.0), num_const_attr);
        // Static methods (ES 21.1.2): writable, non-enumerable, configurable; length 1.
        const num_method_attr = obj_mod.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
        _ = try number_ctor_obj.defineOwnData("isInteger", try val_mod.makeNativeFunctionNamed(arena, nativeNumberIsInteger, "isInteger", 1), num_method_attr);
        _ = try number_ctor_obj.defineOwnData("isFinite", try val_mod.makeNativeFunctionNamed(arena, nativeNumberIsFinite, "isFinite", 1), num_method_attr);
        _ = try number_ctor_obj.defineOwnData("isNaN", try val_mod.makeNativeFunctionNamed(arena, nativeNumberIsNaN, "isNaN", 1), num_method_attr);
        _ = try number_ctor_obj.defineOwnData("isSafeInteger", try val_mod.makeNativeFunctionNamed(arena, nativeNumberIsSafeInteger, "isSafeInteger", 1), num_method_attr);
        try number_proto.set("constructor", try val_mod.makeObject(arena, number_ctor_obj));
        _ = try number_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try number_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Number"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Number", try val_mod.makeObject(arena, number_ctor_obj));

        // ---- BigInt(value) global (conversion function; literals `1n` lex
        // independently).
        const bigint_ctor_obj = try JsObject.create(arena, null);
        try bigint_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeBigIntCtor));
        // BigInt.prototype: real object so `BigInt.prototype.toString = ...` and
        // bigint-primitive autoboxing (`(1n).toString()`) work.
        {
            const bi_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
            const bigint_proto = try JsObject.create(arena, object_proto);
            _ = try bigint_proto.defineOwnData("toString", try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoToString, "toString", 0), bi_attr);
            _ = try bigint_proto.defineOwnData("toLocaleString", try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoToLocaleString, "toLocaleString", 0), bi_attr);
            _ = try bigint_proto.defineOwnData("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoValueOf, "valueOf", 0), bi_attr);
            if (active_sym_to_string_tag) |tag_sym| {
                _ = try bigint_proto.defineOwnDataSym(tag_sym, try val_mod.makeString(arena, "BigInt"), .{ .writable = false, .enumerable = false, .configurable = true });
            }
            _ = try bigint_proto.defineOwnData("constructor", try val_mod.makeObject(arena, bigint_ctor_obj), bi_attr);
            try bigint_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, bigint_proto), .{ .writable = false, .enumerable = false, .configurable = false });
            active_bigint_proto = bigint_proto;
        }
        try bigint_ctor_obj.set("asIntN", try val_mod.makeNativeFunctionNamedLen(arena, nativeBigIntAsIntN, "asIntN", 2));
        try bigint_ctor_obj.set("asUintN", try val_mod.makeNativeFunctionNamedLen(arena, nativeBigIntAsUintN, "asUintN", 2));
        _ = try bigint_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try bigint_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "BigInt"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("BigInt", try val_mod.makeObject(arena, bigint_ctor_obj));

        // ---- Function constructor (minimal): callable object so `typeof Function`
        // is "function" and `new Function()` / `Function()` yield a truthy callable.
        // Does NOT compile a body string from arguments.
        const function_ctor_obj = try JsObject.create(arena, null);
        // §20.2.2.2: `Function.prototype` is non-writable/non-configurable.
        try function_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, function_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try function_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeFunctionCtor));
        try function_proto.set("constructor", try val_mod.makeObject(arena, function_ctor_obj));
        _ = try function_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try function_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Function"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Function", try val_mod.makeObject(arena, function_ctor_obj));
        active_function_ctor = function_ctor_obj;

        // ---- Phase 4: global functions + value globals ----
        const boolean_proto = try JsObject.create(arena, object_proto);
        // Boolean.prototype is itself a Boolean object with [[BooleanData]] = false.
        try boolean_proto.set("[[PrimitiveValue]]", try val_mod.makeBool(arena, false));
        try boolean_proto.set("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeBooleanValueOf, "valueOf", 0));
        try boolean_proto.set("toString", try val_mod.makeNativeFunctionNamed(arena, nativeBooleanToString, "toString", 0));
        active_boolean_proto = boolean_proto;
        const boolean_ctor_obj = try JsObject.create(arena, null);
        try boolean_ctor_obj.defineOwnDataForced("prototype", try val_mod.makeObject(arena, boolean_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        try boolean_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeBooleanCtor));
        try boolean_proto.set("constructor", try val_mod.makeObject(arena, boolean_ctor_obj));
        _ = try boolean_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try boolean_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Boolean"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Boolean", try val_mod.makeObject(arena, boolean_ctor_obj));
        try env.define("isNaN", try val_mod.makeNativeFunctionNamed(arena, nativeIsNaN, "isNaN", 1));
        try env.define("eval", try val_mod.makeNativeFunctionNamed(arena, nativeEval, "eval", 1));
        try env.define("isFinite", try val_mod.makeNativeFunctionNamed(arena, nativeIsFinite, "isFinite", 1));
        try env.define("parseInt", try val_mod.makeNativeFunctionNamed(arena, nativeParseInt, "parseInt", 2));
        try env.define("parseFloat", try val_mod.makeNativeFunctionNamed(arena, nativeParseFloat, "parseFloat", 1));
        // §21.1.2.12-13: Number.parseInt/parseFloat are the SAME function objects
        // as the global parseInt/parseFloat, so `Number.parseInt === parseInt`.
        _ = try number_ctor_obj.defineOwnData("parseInt", try env.lookup("parseInt"), num_method_attr);
        _ = try number_ctor_obj.defineOwnData("parseFloat", try env.lookup("parseFloat"), num_method_attr);
        try env.define("encodeURI", try val_mod.makeNativeFunctionNamed(arena, nativeEncodeURI, "encodeURI", 1));
        try env.define("encodeURIComponent", try val_mod.makeNativeFunctionNamed(arena, nativeEncodeURIComponent, "encodeURIComponent", 1));
        try env.define("decodeURI", try val_mod.makeNativeFunctionNamed(arena, nativeDecodeURI, "decodeURI", 1));
        try env.define("decodeURIComponent", try val_mod.makeNativeFunctionNamed(arena, nativeDecodeURIComponent, "decodeURIComponent", 1));
        try env.define("escape", try val_mod.makeNativeFunctionNamed(arena, nativeEscape, "escape", 1));
        try env.define("unescape", try val_mod.makeNativeFunctionNamed(arena, nativeUnescape, "unescape", 1));
        try env.define("NaN", try val_mod.makeNumber(arena, std.math.nan(f64)));
        try env.define("Infinity", try val_mod.makeNumber(arena, std.math.inf(f64)));
        try env.define("structuredClone", try val_mod.makeNativeFunctionNamed(arena, nativeStructuredClone, "structuredClone", 1));

        // ---- console global ----
        try console_mod.register(&reg_ctx);

        // ---- ES2015 Symbol ----
        const symbol_proto = try JsObject.create(arena, object_proto);
        try symbol_proto.set("toString", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolToString, "toString", 0));
        try symbol_proto.set("valueOf", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolValueOf, "valueOf", 0));
        active_symbol_proto = symbol_proto;
        const symbol_ctor = try JsObject.create(arena, null);
        try symbol_ctor.set("__call__", try val_mod.makeNativeFunction(arena, symbol_mod.nativeSymbolCall));
        try symbol_ctor.defineOwnDataForced("prototype", try val_mod.makeObject(arena, symbol_proto), .{ .writable = false, .enumerable = false, .configurable = false });
        _ = try symbol_proto.defineOwnData("constructor", try val_mod.makeObject(arena, symbol_ctor), .{ .writable = true, .enumerable = false, .configurable = true });
        // Fresh realm ⇒ fresh per-agent symbol registry. The registry's buffers
        // live in this realm's arena; a stale registry from a prior (freed) realm
        // dangles and causes a use-after-free on the next Symbol.for.
        symbol_mod.resetRegistry();
        try symbol_ctor.set("for", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolFor, "for", 0));
        try symbol_ctor.set("keyFor", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolKeyFor, "keyFor", 0));
        // Well-known symbols (identity constants; inert in S1).
        const wk_names = [_][]const u8{ "iterator", "asyncIterator", "hasInstance", "isConcatSpreadable", "match", "matchAll", "replace", "search", "split", "species", "toPrimitive", "toStringTag", "unscopables", "dispose", "asyncDispose" };
        for (wk_names) |name| {
            const desc = try std.fmt.allocPrint(arena, "Symbol.{s}", .{name});
            // Well-known symbols are non-writable, non-enumerable, non-configurable.
            _ = try symbol_ctor.defineOwnData(name, try val_mod.makeSymbol(arena, desc), .{ .writable = false, .enumerable = false, .configurable = false });
        }
        // Symbol.prototype.constructor === Symbol, and the `description` accessor
        // (a getter holder `{ get: nativeFn }`, matching the live-reexport pattern).
        try symbol_proto.set("constructor", try val_mod.makeObject(arena, symbol_ctor));
        _ = try symbol_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try symbol_ctor.defineOwnData("name", try val_mod.makeString(arena, "Symbol"), .{ .writable = false, .enumerable = false, .configurable = true });
        const sym_desc_holder = try JsObject.create(arena, null);
        try sym_desc_holder.set("get", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolDescriptionGet, "get", 0));
        _ = try symbol_proto.defineOwnAccessor("description", try val_mod.makeObject(arena, sym_desc_holder), .{
            .enumerable = false,
            .configurable = true,
        });
        try env.define("Symbol", try val_mod.makeObject(arena, symbol_ctor));
        // Capture Symbol.iterator and register Array.prototype[Symbol.iterator].
        active_sym_iterator = symbol_ctor.getOwn("iterator");
        if (active_sym_iterator) |symv| {
            // §23.1.3.41: Array.prototype[@@iterator] is the SAME function object
            // as Array.prototype.values, not a second copy of it.
            const values_fn = array_proto.get("values") orelse
                try val_mod.makeNativeFunction(arena, es2015_collections_mod.nativeArrayValues);
            try array_proto.setSym(symv, values_fn);
            // String.prototype[@@iterator] — by-code-point iteration (overridable
            // and deletable, so it is a writable/configurable own property).
            try string_proto.setSymAttr(symv, try val_mod.makeNativeFunctionNamed(arena, es2015_collections_mod.nativeStringValues, "[Symbol.iterator]", 0), .{ .writable = true, .enumerable = false, .configurable = true });
        }
        // Capture Symbol.asyncIterator and Symbol.asyncDispose.
        active_sym_async_iterator = symbol_ctor.getOwn("asyncIterator");
        active_sym_async_dispose = symbol_ctor.getOwn("asyncDispose");
        active_sym_dispose = symbol_ctor.getOwn("dispose");
        active_sym_unscopables = symbol_ctor.getOwn("unscopables");
        // Array.prototype[@@unscopables]: a null-proto list whose truthy keys are
        // hidden from `with(array)` scopes (spec 23.1.3.35). The property itself
        // is non-writable/non-enumerable/configurable; each entry is a plain
        // writable/enumerable/configurable data property with value `true`.
        if (active_sym_unscopables) |unsym| {
            const unsc_list = try JsObject.create(arena, null);
            // Spec §23.1.3.36 lists these alphabetically; ownKeys order must match.
            const unsc_names = [_][]const u8{
                "at",        "copyWithin", "entries",    "fill",       "find",
                "findIndex", "findLast",   "findLastIndex", "flat",    "flatMap",
                "includes",  "keys",       "toReversed", "toSorted",   "toSpliced",
                "values",
            };
            for (unsc_names) |nm| {
                _ = try unsc_list.defineOwnData(nm, try val_mod.makeBool(arena, true), .{ .writable = true, .enumerable = true, .configurable = true });
            }
            try array_proto.setSymAttr(unsym, try val_mod.makeObject(arena, unsc_list), .{ .writable = false, .enumerable = false, .configurable = true });
        }
        // Capture Symbol.toPrimitive and give Date the spec-correct hook so
        // `date + x` coerces to a string (default hint) rather than a number.
        active_sym_to_primitive = symbol_ctor.getOwn("toPrimitive");
        if (active_sym_to_primitive) |symv| {
            if (date_mod.active_date_proto) |dp| {
                try dp.setSym(symv, try val_mod.makeNativeFunction(arena, date_mod.nativeDateToPrimitive));
            }
            // Symbol.prototype[@@toPrimitive] (non-writable, non-enumerable, configurable).
            _ = try symbol_proto.defineOwnDataSym(symv, try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolToPrimitive, "[Symbol.toPrimitive]", 1), .{ .writable = false, .enumerable = false, .configurable = true });
        }
        // Function.prototype[@@hasInstance] — OrdinaryHasInstance, a non-writable,
        // non-enumerable, non-configurable method (name "[Symbol.hasInstance]",
        // length 1). Installed here once the well-known symbol exists.
        if (symbol_ctor.getOwn("hasInstance")) |hi_sym| {
            active_sym_has_instance = hi_sym;
            _ = try function_proto.defineOwnDataSym(hi_sym, try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionHasInstance, "[Symbol.hasInstance]", 1), .{ .writable = false, .enumerable = false, .configurable = false });
        }

        active_sym_intl_fallback = try val_mod.makeSymbol(arena, "IntlLegacyConstructedSymbol");

        // Capture Symbol.toStringTag and Symbol.species.
        active_sym_to_string_tag = symbol_ctor.getOwn("toStringTag");
        if (active_sym_to_string_tag) |symv| {
            // Symbol.prototype[@@toStringTag] = "Symbol" (non-writable/enumerable, configurable).
            _ = try symbol_proto.defineOwnDataSym(symv, try val_mod.makeString(arena, "Symbol"), .{ .writable = false, .enumerable = false, .configurable = true });
            // BigInt.prototype[@@toStringTag] = "BigInt" (same attrs) so
            // Object.prototype.toString.call(1n) yields "[object BigInt]".
            if (active_bigint_proto) |bp|
                _ = try bp.defineOwnDataSym(symv, try val_mod.makeString(arena, "BigInt"), .{ .writable = false, .enumerable = false, .configurable = true });
        }
        if (active_sym_to_string_tag) |symv| {
            // Math[@@toStringTag] = "Math", JSON[@@toStringTag] = "JSON"
            // (non-writable/enumerable, configurable) so Object.prototype.toString
            // yields "[object Math]" / "[object JSON]".
            const tag_attr: obj_mod.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
            if (env.lookup("Math")) |mv| {
                if (mv.bits != 0 and mv.unbox() == .object)
                    _ = try mv.toPtr().object.defineOwnDataSym(symv, try val_mod.makeString(arena, "Math"), tag_attr);
            } else |_| {}
            if (env.lookup("JSON")) |jv| {
                if (jv.bits != 0 and jv.unbox() == .object)
                    _ = try jv.toPtr().object.defineOwnDataSym(symv, try val_mod.makeString(arena, "JSON"), tag_attr);
            } else |_| {}
        }
        active_sym_species = symbol_ctor.getOwn("species");
        // `get C[@@species]` on the constructors whose prototype methods use
        // SpeciesConstructor (§23.1.2.5 / §27.2.4.7 / §22.2.5.2). Registered here
        // because the well-known symbols only exist after Symbol init.
        if (active_sym_species) |spec_sym| {
            for ([_][]const u8{ "Array", "Promise", "RegExp" }) |ctor_name| {
                const cv = env.lookup(ctor_name) catch continue;
                if (cv.bits == 0 or cv.unbox() != .object) continue;
                try es2015_collections_mod.defineSymGetter(arena, cv.toPtr().object, spec_sym, es2015_collections_mod.nativeSpeciesReturnThis, "get [Symbol.species]");
            }
        }
        active_sym_is_concat_spreadable = symbol_ctor.getOwn("isConcatSpreadable");
        // Capture the RegExp-related well-known symbols and install the
        // RegExp.prototype[@@match/@@replace/@@search/@@split/@@matchAll] methods
        // now that the symbols exist (regexp register() ran earlier).
        active_sym_match = symbol_ctor.getOwn("match");
        active_sym_replace = symbol_ctor.getOwn("replace");
        active_sym_search = symbol_ctor.getOwn("search");
        active_sym_split = symbol_ctor.getOwn("split");
        active_sym_match_all = symbol_ctor.getOwn("matchAll");
        try regexp_mod.registerSymbols(arena);
        // Wire @@toStringTag + @@species onto TypedArray/ArrayBuffer/DataView protos+ctors now
        // that the well-known symbols exist (register() ran before Symbol init).
        try typed_array_mod.registerSymbols(arena);
        // Wire @@toStringTag onto WeakMap.prototype and WeakSet.prototype.
        try es2015_collections_mod.registerSymbols(arena);
        try disposable_stack_mod.registerSymbols(arena);
        try date_mod.registerSymbols(arena);
        try temporal_mod.registerSymbols(arena);
        // Promise.prototype[@@toStringTag] = "Promise" (ES §27.2.5.5), so
        // Object.prototype.toString tags a promise "[object Promise]".
        if (active_sym_to_string_tag) |tag_sym| {
            if (active_promise_proto) |p|
                try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "Promise"), .{ .writable = false, .enumerable = false, .configurable = true });
        }

        // Build the shared %IteratorPrototype% → %ArrayIteratorPrototype% chain
        // now that @@iterator / @@toStringTag exist. Array + TypedArray iterators
        // all inherit from it.
        try es2015_collections_mod.initArrayIteratorProto(arena, object_proto);
        // %RegExpStringIteratorPrototype% — inherits %IteratorPrototype%.
        try regexp_mod.initStringIteratorProto(arena, es2015_collections_mod.active_iterator_proto);

        // ---- ES2024 Iterator global (map/filter/take/drop/… helpers) ----
        try es2015_collections_mod.registerIteratorGlobal(&reg_ctx);

        // ---- ES2015 Reflect ----
        try reflect_mod.register(&reg_ctx);

        // ---- ES2015 Proxy ----
        active_sym_proxy_target = try val_mod.makeSymbol(arena, "[[ProxyTarget]]");
        active_sym_proxy_handler = try val_mod.makeSymbol(arena, "[[ProxyHandler]]");
        active_sym_module_ns = try val_mod.makeSymbol(arena, "[[Module.Namespace]]");
        active_sym_deferred_id = try val_mod.makeSymbol(arena, "[[Module.DeferredId]]");
        active_deferred_ns_registry = try val_mod.makeObject(arena, try JsObject.create(arena, null));
        active_sym_export_names = try val_mod.makeSymbol(arena, "[[Module.ExportNames]]");
        active_sym_tdz_export_names = try val_mod.makeSymbol(arena, "[[Module.TdzNames]]");
        tdz_marker = try val_mod.makeSymbol(arena, "[[TDZ]]");
        const proxy_ctor = try JsObject.create(arena, null);
        try proxy_ctor.set("__call__", try val_mod.makeNativeFunction(arena, proxy_mod.nativeProxyCtor));
        _ = try proxy_ctor.defineOwnData("revocable", try val_mod.makeNativeFunctionNamed(arena, proxy_mod.nativeProxyRevocable, "revocable", 2), .{ .writable = true, .enumerable = false, .configurable = true });
        _ = try proxy_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try proxy_ctor.defineOwnData("name", try val_mod.makeString(arena, "Proxy"), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Proxy", try val_mod.makeObject(arena, proxy_ctor));

        // ---- Intl (en-US, dependency-free) ----
        {
            const intl_obj = try JsObject.create(arena, object_proto);
            // Intl service constructors share a standard shape: a real function
            // object ([[Prototype]] = Function.prototype), a non-writable/-enumerable/
            // -configurable `prototype`, whose object carries non-enumerable methods,
            // an own `constructor`, a `Symbol.toStringTag`, and (for the locale-aware
            // services) a `supportedLocalesOf` static that reuses the shared impl.
            const IntlReg = struct {
                fn method(a: std.mem.Allocator, proto: *JsObject, name: []const u8, f: anytype, len: u8) !void {
                    _ = try proto.defineOwnData(name, try val_mod.makeNativeFunctionNamed(a, f, name, len), .{ .writable = true, .enumerable = false, .configurable = true });
                }
                fn finish(a: std.mem.Allocator, ctor: *JsObject, proto: *JsObject, cname: []const u8, tag: []const u8, len: u8, has_slo: bool) !void {
                    _ = try ctor.defineOwnData("prototype", try val_mod.makeObject(a, proto), .{ .writable = false, .enumerable = false, .configurable = false });
                    _ = try proto.defineOwnData("constructor", try val_mod.makeObject(a, ctor), .{ .writable = true, .enumerable = false, .configurable = true });
                    if (active_sym_to_string_tag) |tag_sym|
                        _ = try proto.defineOwnDataSym(tag_sym, try val_mod.makeString(a, tag), .{ .writable = false, .enumerable = false, .configurable = true });
                    _ = try ctor.defineOwnData("length", try val_mod.makeNumber(a, @floatFromInt(len)), .{ .writable = false, .enumerable = false, .configurable = true });
                    _ = try ctor.defineOwnData("name", try val_mod.makeString(a, cname), .{ .writable = false, .enumerable = false, .configurable = true });
                    if (has_slo)
                        _ = try ctor.defineOwnData("supportedLocalesOf", try val_mod.makeNativeFunctionNamed(a, intl_mod.nativeDurationFormatSupportedLocalesOf, "supportedLocalesOf", 1), .{ .writable = true, .enumerable = false, .configurable = true });
                }
            };
            // Intl.NumberFormat
            const nf_proto = try JsObject.create(arena, object_proto);
            {
                // §15.3.3: `format` is an accessor returning a bound function, not
                // a plain method.
                const holder = try JsObject.create(arena, object_proto);
                try holder.set("get", try val_mod.makeNativeFunctionNamedLen(arena, intl_mod.nativeNumberFormatFormatGetter, "get format", 0));
                _ = try nf_proto.defineOwnAccessor("format", try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
            }
            try IntlReg.method(arena, nf_proto, "formatToParts", intl_mod.nativeNumberFormatFormatToParts, 1);
            try IntlReg.method(arena, nf_proto, "formatRange", intl_mod.nativeNumberFormatFormatRange, 2);
            try IntlReg.method(arena, nf_proto, "formatRangeToParts", intl_mod.nativeNumberFormatFormatRangeToParts, 2);
            try IntlReg.method(arena, nf_proto, "resolvedOptions", intl_mod.nativeNumberFormatResolved, 0);
            const nf_ctor = try JsObject.create(arena, function_proto);
            try nf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeNumberFormatCtor));
            try IntlReg.finish(arena, nf_ctor, nf_proto, "NumberFormat", "Intl.NumberFormat", 0, true);
            try intl_obj.set("NumberFormat", try val_mod.makeObject(arena, nf_ctor));
            // Intl.DateTimeFormat
            const dtf_proto = try JsObject.create(arena, object_proto);
            {
                // §11.3.3: `format` is an accessor returning a bound function.
                const holder = try JsObject.create(arena, object_proto);
                try holder.set("get", try val_mod.makeNativeFunctionNamedLen(arena, intl_mod.nativeDateTimeFormatFormatGetter, "get format", 0));
                _ = try dtf_proto.defineOwnAccessor("format", try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
            }
            try IntlReg.method(arena, dtf_proto, "formatToParts", intl_mod.nativeDateTimeFormatFormatToParts, 1);
            try IntlReg.method(arena, dtf_proto, "formatRange", intl_mod.nativeDateTimeFormatFormatRange, 2);
            try IntlReg.method(arena, dtf_proto, "formatRangeToParts", intl_mod.nativeDateTimeFormatFormatRangeToParts, 2);
            try IntlReg.method(arena, dtf_proto, "resolvedOptions", intl_mod.nativeDateTimeFormatResolved, 0);
            const dtf_ctor = try JsObject.create(arena, function_proto);
            try dtf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeDateTimeFormatCtor));
            try IntlReg.finish(arena, dtf_ctor, dtf_proto, "DateTimeFormat", "Intl.DateTimeFormat", 0, true);
            try intl_obj.set("DateTimeFormat", try val_mod.makeObject(arena, dtf_ctor));
            // Intl.Collator
            const col_proto = try JsObject.create(arena, object_proto);
            {
                // §10.3.3: `compare` is an accessor returning a bound function.
                const holder = try JsObject.create(arena, object_proto);
                try holder.set("get", try val_mod.makeNativeFunctionNamedLen(arena, intl_mod.nativeCollatorCompareGetter, "get compare", 0));
                _ = try col_proto.defineOwnAccessor("compare", try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
            }
            try IntlReg.method(arena, col_proto, "resolvedOptions", intl_mod.nativeCollatorResolved, 0);
            const col_ctor = try JsObject.create(arena, function_proto);
            try col_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeCollatorCtor));
            try IntlReg.finish(arena, col_ctor, col_proto, "Collator", "Intl.Collator", 0, true);
            try intl_obj.set("Collator", try val_mod.makeObject(arena, col_ctor));
            // The three legacy services keep working when called without `new`,
            // which needs their prototypes.
            intl_mod.registerLegacyServiceProtos(nf_proto, dtf_proto, col_proto);
            // Intl.Locale (no supportedLocalesOf; ctor length 1)
            const loc_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, loc_proto, "toString", intl_mod.nativeLocaleToString, 0);
            try IntlReg.method(arena, loc_proto, "maximize", intl_mod.nativeLocaleMaximize, 0);
            try IntlReg.method(arena, loc_proto, "minimize", intl_mod.nativeLocaleMinimize, 0);
            try IntlReg.method(arena, loc_proto, "getCalendars", intl_mod.nativeLocaleGetCalendars, 0);
            try IntlReg.method(arena, loc_proto, "getCollations", intl_mod.nativeLocaleGetCollations, 0);
            try IntlReg.method(arena, loc_proto, "getHourCycles", intl_mod.nativeLocaleGetHourCycles, 0);
            try IntlReg.method(arena, loc_proto, "getNumberingSystems", intl_mod.nativeLocaleGetNumberingSystems, 0);
            try IntlReg.method(arena, loc_proto, "getTimeZones", intl_mod.nativeLocaleGetTimeZones, 0);
            try IntlReg.method(arena, loc_proto, "getTextInfo", intl_mod.nativeLocaleGetTextInfo, 0);
            try IntlReg.method(arena, loc_proto, "getWeekInfo", intl_mod.nativeLocaleGetWeekInfo, 0);
            try intl_mod.registerLocaleAccessors(arena, loc_proto);
            const loc_ctor = try JsObject.create(arena, function_proto);
            try loc_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeLocaleCtor));
            try IntlReg.finish(arena, loc_ctor, loc_proto, "Locale", "Intl.Locale", 1, false);
            try intl_obj.set("Locale", try val_mod.makeObject(arena, loc_ctor));
            // Intl.ListFormat
            const lf_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, lf_proto, "format", intl_mod.nativeListFormatFormat, 1);
            try IntlReg.method(arena, lf_proto, "formatToParts", intl_mod.nativeListFormatFormatToParts, 1);
            try IntlReg.method(arena, lf_proto, "resolvedOptions", intl_mod.nativeListFormatResolved, 0);
            const lf_ctor = try JsObject.create(arena, function_proto);
            try lf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeListFormatCtor));
            try IntlReg.finish(arena, lf_ctor, lf_proto, "ListFormat", "Intl.ListFormat", 0, true);
            try intl_obj.set("ListFormat", try val_mod.makeObject(arena, lf_ctor));
            // Intl.PluralRules
            const pr_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, pr_proto, "select", intl_mod.nativePluralRulesSelect, 1);
            try IntlReg.method(arena, pr_proto, "selectRange", intl_mod.nativePluralRulesSelectRange, 2);
            try IntlReg.method(arena, pr_proto, "resolvedOptions", intl_mod.nativePluralRulesResolved, 0);
            const pr_ctor = try JsObject.create(arena, function_proto);
            try pr_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativePluralRulesCtor));
            try IntlReg.finish(arena, pr_ctor, pr_proto, "PluralRules", "Intl.PluralRules", 0, true);
            try intl_obj.set("PluralRules", try val_mod.makeObject(arena, pr_ctor));
            // Intl.RelativeTimeFormat
            const rtf_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, rtf_proto, "format", intl_mod.nativeRelativeTimeFormatFormat, 2);
            try IntlReg.method(arena, rtf_proto, "formatToParts", intl_mod.nativeRelativeTimeFormatFormatToParts, 2);
            try IntlReg.method(arena, rtf_proto, "resolvedOptions", intl_mod.nativeRelativeTimeFormatResolved, 0);
            const rtf_ctor = try JsObject.create(arena, function_proto);
            try rtf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeRelativeTimeFormatCtor));
            try IntlReg.finish(arena, rtf_ctor, rtf_proto, "RelativeTimeFormat", "Intl.RelativeTimeFormat", 0, true);
            try intl_obj.set("RelativeTimeFormat", try val_mod.makeObject(arena, rtf_ctor));
            // Intl.DisplayNames
            const dn_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, dn_proto, "of", intl_mod.nativeDisplayNamesOf, 1);
            try IntlReg.method(arena, dn_proto, "resolvedOptions", intl_mod.nativeDisplayNamesResolved, 0);
            const dn_ctor = try JsObject.create(arena, function_proto);
            try dn_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeDisplayNamesCtor));
            try IntlReg.finish(arena, dn_ctor, dn_proto, "DisplayNames", "Intl.DisplayNames", 2, true);
            try intl_obj.set("DisplayNames", try val_mod.makeObject(arena, dn_ctor));
            // Intl.DurationFormat
            const df_proto = try JsObject.create(arena, object_proto);
            _ = try df_proto.defineOwnData("format", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDurationFormatFormat, "format", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            _ = try df_proto.defineOwnData("formatToParts", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDurationFormatFormatToParts, "formatToParts", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            _ = try df_proto.defineOwnData("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDurationFormatResolved, "resolvedOptions", 0), .{ .writable = true, .enumerable = false, .configurable = true });
            if (active_sym_to_string_tag) |tag_sym|
                _ = try df_proto.defineOwnDataSym(tag_sym, try val_mod.makeString(arena, "Intl.DurationFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            const df_ctor = try JsObject.create(arena, null);
            try df_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeDurationFormatCtor));
            _ = try df_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, df_proto), .{ .writable = false, .enumerable = false, .configurable = false });
            _ = try df_proto.defineOwnData("constructor", try val_mod.makeObject(arena, df_ctor), .{ .writable = true, .enumerable = false, .configurable = true });
            _ = try df_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try df_ctor.defineOwnData("name", try val_mod.makeString(arena, "DurationFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try df_ctor.defineOwnData("supportedLocalesOf", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDurationFormatSupportedLocalesOf, "supportedLocalesOf", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            try intl_obj.set("DurationFormat", try val_mod.makeObject(arena, df_ctor));
            // Intl.Segmenter, plus the two prototypes `segment()` produces. Both
            // are reachable only through instances (they have no global binding),
            // so the module keeps them in module-level slots.
            const seg_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, seg_proto, "segment", segmenter_mod.nativeSegmenterSegment, 1);
            try IntlReg.method(arena, seg_proto, "resolvedOptions", segmenter_mod.nativeSegmenterResolved, 0);
            const seg_ctor = try JsObject.create(arena, function_proto);
            try seg_ctor.set("__call__", try val_mod.makeNativeFunction(arena, segmenter_mod.nativeSegmenterCtor));
            try IntlReg.finish(arena, seg_ctor, seg_proto, "Segmenter", "Intl.Segmenter", 0, true);
            try intl_obj.set("Segmenter", try val_mod.makeObject(arena, seg_ctor));

            // %SegmentsPrototype% — `containing` plus @@iterator.
            const segs_proto = try JsObject.create(arena, object_proto);
            try IntlReg.method(arena, segs_proto, "containing", segmenter_mod.nativeSegmentsContaining, 1);
            if (active_sym_iterator) |symv|
                try segs_proto.setSymAttr(symv, try val_mod.makeNativeFunctionNamed(arena, segmenter_mod.nativeSegmentsIterator, "[Symbol.iterator]", 0), .{ .writable = true, .enumerable = false, .configurable = true });
            segmenter_mod.segments_proto = segs_proto;

            // %SegmentIteratorPrototype% — inherits %IteratorPrototype% so the
            // segment iterator is itself iterable.
            const segit_proto = try JsObject.create(arena, es2015_collections_mod.active_iterator_proto orelse object_proto);
            try IntlReg.method(arena, segit_proto, "next", segmenter_mod.nativeSegmentIteratorNext, 0);
            if (active_sym_to_string_tag) |tag_sym|
                _ = try segit_proto.defineOwnDataSym(tag_sym, try val_mod.makeString(arena, "Segmenter String Iterator"), .{ .writable = false, .enumerable = false, .configurable = true });
            segmenter_mod.segment_iterator_proto = segit_proto;
            // Intl.getCanonicalLocales (static)
            _ = try intl_obj.defineOwnData("getCanonicalLocales", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeGetCanonicalLocales, "getCanonicalLocales", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            // Intl.supportedValuesOf (static)
            _ = try intl_obj.defineOwnData("supportedValuesOf", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeSupportedValuesOf, "supportedValuesOf", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            // §8.1.1: the Intl namespace object's own @@toStringTag is "Intl",
            // so `Object.prototype.toString.call(Intl)` is "[object Intl]".
            if (active_sym_to_string_tag) |tag_sym|
                _ = try intl_obj.defineOwnDataSym(tag_sym, try val_mod.makeString(arena, "Intl"), .{ .writable = false, .enumerable = false, .configurable = true });
            try env.define("Intl", try val_mod.makeObject(arena, intl_obj));
        }

        // ---- M16 Phase 4: ShadowRealm (defined before globalThis so the host
        // global object mirrors the `ShadowRealm` binding) ----
        try shadow_realm_mod.register(arena, env, object_proto, function_proto);

        // ---- ES2020 globalThis (+ Node-compatible `global`) ----
        try installGlobalThis(arena, env, object_proto);

        // `new.target` desugars to a read of `__new_target__`, which the construct
        // path binds in the constructor's call env. Provide a global fallback of
        // undefined so an ordinary (non-construct) call observes `new.target ===
        // undefined` instead of a ReferenceError. (installGlobalThis skips `__`
        // names, so this is not exposed as a globalThis property.)
        try env.define("__new_target__", try val_mod.makeUndefined(arena));

        // Tagged-template runtime helper (see rewriteTemplateLiterals): builds the
        // template strings object from its cooked + raw arrays.
        try env.define("__jsztag", try val_mod.makeNativeFunction(arena, nativeTemplateObject));
        // Per-realm tagged-template cache, rooted in the global env (hidden `__`
        // binding, so not mirrored onto globalThis) so its cached template
        // objects survive GC across tag calls.
        {
            const cache_obj = try JsObject.create(arena, null);
            active_template_cache = cache_obj;
            try env.define("__jsztmplcache__", try val_mod.makeObject(arena, cache_obj));
        }

        // ---- Post-pass: give built-in constructors and namespace objects their
        // [[Prototype]]. Most constructor objects above were created with a null
        // proto (an ordering artifact: e.g. the Object constructor is built before
        // %Function.prototype% exists). A null [[Prototype]] broke
        // Object.getPrototypeOf(ctor), `ctor instanceof Function`, and inheritance
        // of Function.prototype.{call,bind,apply}; likewise namespace objects
        // (Math, JSON, Reflect, ...) lost Object.prototype methods. Assign here,
        // once %Object.prototype% and %Function.prototype% both exist. Callable
        // globals get %Function.prototype%; plain namespace objects get
        // %Object.prototype%. Only null protos are touched, so objects created
        // with a correct proto (including Object.create(null) users, which are not
        // globals) are never clobbered.
        {
            var it = env.bindings.iterator();
            while (it.next()) |entry| {
                const bname = entry.key_ptr.*;
                // Skip hidden internal bindings (e.g. __ErrorProto__, __jsztag).
                if (bname.len >= 2 and bname[0] == '_' and bname[1] == '_') continue;
                const bv = entry.value_ptr.value;
                if (bv.bits == 0 or bv.unbox() != .object) continue;
                const bo = bv.toPtr().object;
                if (bo.proto != null) continue;
                const target_proto = if (bo.get("__call__") != null) function_proto else object_proto;
                bo.proto = target_proto;
                bo.setProtoBarrier(target_proto);
            }
        }

        // Correct enumerability: core built-in own properties (constructor static
        // methods, namespace-object methods/constants, and each constructor's
        // `prototype` object's methods) are all non-enumerable, but many are
        // registered with `set()` (which defaults to enumerable). Walk the global
        // built-in objects and their `prototype` objects, flipping every own
        // property to non-enumerable. Runs at realm init, before any user code, so
        // no user-created (legitimately enumerable) property is ever affected.
        {
            var it = env.bindings.iterator();
            while (it.next()) |entry| {
                const bname = entry.key_ptr.*;
                if (bname.len >= 2 and bname[0] == '_' and bname[1] == '_') continue;
                const bv = entry.value_ptr.value;
                if (bv.bits == 0 or bv.unbox() != .object) continue;
                const bo = bv.toPtr().object;
                bo.markOwnNonEnumerable();
                // A constructor's `.prototype` object holds the instance methods.
                if (bo.getOwn("prototype")) |pv| {
                    if (pv.bits != 0 and pv.unbox() == .object) pv.toPtr().object.markOwnNonEnumerable();
                }
            }
            // %Object.prototype% and %Function.prototype% are also reachable via
            // the Object/Function constructors' `prototype` links above, but mark
            // them directly too (defensive; they are the roots of every chain).
            object_proto.markOwnNonEnumerable();
            function_proto.markOwnNonEnumerable();
        }
        // Error subtype constructors chain to the %Error% constructor (ES §20.5.6),
        // not directly to %Function.prototype%. (%Error% itself → %Function.prototype%
        // via the loop above.)
        {
            const error_ctor_obj = error_ctor_val.toPtr().object;
            for ([_]Value{
                type_error_ctor_val,      syntax_error_ctor_val,
                range_error_ctor_val,     reference_error_ctor_val,
                aggregate_error_ctor_val, eval_error_ctor_val,
                uri_error_ctor_val,       suppressed_error_ctor_val,
            }) |cv| {
                const co = cv.toPtr().object;
                co.proto = error_ctor_obj;
                co.setProtoBarrier(error_ctor_obj);
            }
        }

        // Set thread-locals for builtins that need them.
        active_array_proto = array_proto;
        active_object_proto = object_proto;
        active_string_proto = string_proto;
        active_global_env = env;

        return Realm{
            .global_env = env,
            .arena = arena,
            .object_prototype = object_proto,
            .array_prototype = array_proto,
            .error_prototype = error_proto,
            .type_error_prototype = type_error_proto,
            .syntax_error_prototype = syntax_error_proto,
            .range_error_prototype = range_error_proto,
            .reference_error_prototype = reference_error_proto,
            .aggregate_error_prototype = aggregate_error_proto,
            .string_prototype = string_proto,
            .regexp_prototype = active_regexp_proto.?,
            .function_prototype = function_proto,
            .global_object = active_global_object,
        };
    }

    /// Cross-realm: snapshot the per-intrinsic prototypes (ArrayBuffer, DataView,
    /// %TypedArray% and per-kind TA prototypes) from the live thread-local builtin
    /// state into this Realm. MUST be called while THIS realm is the active one
    /// (i.e. right after Realm.init, before any other realm overwrites the
    /// thread-locals). Used by GetPrototypeFromConstructor's realm fallback.
    pub fn captureIntrinsics(self: *Realm) void {
        self.array_ctor = active_array_ctor;
        self.promise_prototype = active_promise_proto;
        self.ab_prototype = typed_array_mod.active_arraybuffer_proto;
        self.sab_prototype = typed_array_mod.active_sharedarraybuffer_proto;
        self.dv_prototype = typed_array_mod.active_dataview_proto;
        self.ta_shared_prototype = typed_array_mod.active_typedarray_proto;
        for (&self.ta_kind_prototypes, typed_array_mod.active_ta_protos) |*slot, p| {
            slot.* = p;
        }
        if (self.global_object == null) self.global_object = active_global_object;
        const es2015_mod = @import("builtins/es2015_collections.zig");
        self.gen_iterator_proto = es2015_mod.active_iterator_proto;
        self.gen_function_ctor = active_function_ctor;
        self.regexp_ctor = @import("builtins/regexp.zig").active_regexp_ctor;
    }

    /// Cross-realm: tag every top-level builtin function in this realm's global
    /// scope with this Realm (opaque) so GetFunctionRealm can recover it. Covers
    /// the dynamic `Function` constructor (whose `__call__` entry is what stamps
    /// the realm onto a `new other.Function()` result). Independent of the
    /// thread-locals, so it may run after they have been restored.
    pub fn tagNativeFunctions(self: *Realm) void {
        const r_opaque: *anyopaque = @ptrCast(self);
        var seen = std.AutoHashMap(*JsObject, void).init(self.arena);
        defer seen.deinit();
        var it = self.global_env.bindings.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.value;
            if (v.bits == 0 or !v.isHeapPtr()) continue;
            switch (v.toPtr().*) {
                .native_function, .bc_function => val_mod.setValueRealm(v, r_opaque),
                .object => |o| tagObjectTree(o, r_opaque, &seen, 0),
                else => {},
            }
        }
    }

    /// Reach the built-ins that are NOT global bindings — prototype methods and
    /// accessor getters such as `RegExp.prototype.global` — so each also knows the
    /// realm that created it. Bounded by `seen` (the graph is cyclic:
    /// `String.prototype.constructor.prototype` …) and by depth.
    fn tagObjectTree(obj: *JsObject, r_opaque: *anyopaque, seen: *std.AutoHashMap(*JsObject, void), depth: u8) void {
        if (depth > 4) return;
        const gop = seen.getOrPut(obj) catch return;
        if (gop.found_existing) return;
        for (obj.ownKeys()) |k| {
            const slot = obj.resolveOwnSlot(k) orelse continue;
            if (slot >= obj.slots.items.len) continue;
            const raw = obj.slots.items[slot];
            if (raw.bits == 0 or !raw.isHeapPtr()) continue;
            if (obj.attrAt(slot).is_accessor) {
                // Accessor slots hold a `{get, set}` holder object, not a callable.
                if (raw.unbox() != .object) continue;
                const holder = raw.toPtr().object;
                for ([_][]const u8{ "get", "set" }) |side| {
                    const f = holder.getOwn(side) orelse continue;
                    if (f.bits != 0 and f.isHeapPtr()) val_mod.setValueRealm(f, r_opaque);
                }
                continue;
            }
            switch (raw.toPtr().*) {
                .native_function, .bc_function => val_mod.setValueRealm(raw, r_opaque),
                .object => |child| tagObjectTree(child, r_opaque, seen, depth + 1),
                else => {},
            }
        }
    }

    /// Wire in a GC heap and register Realm intrinsics as roots.
    pub fn activateHeap(self: *Realm, heap: *Heap) !void {
        self.heap = heap;
        active_heap = heap;

        // M19: wire the collector's strong-trace and weak-process hooks so Map/Set
        // keep their entries alive and WeakMap/WeakSet/WeakRef/FinalizationRegistry
        // get true ephemeron semantics (dead entries purged, dead refs cleared).
        const es2015 = @import("builtins/es2015_collections.zig");
        heap.strong_trace_fn = es2015.gcStrongTrace;
        heap.weak_process_fn = es2015.gcProcessWeak;

        // Create arena-backed Value wrappers for the prototypes and register as GC roots.
        // We store them as fields so their lifetimes match the Realm.
        // Note: these objects are arena-allocated (intrinsics), so they don't have GcHeaders.
        // The Heap will call markObject on them, but they aren't in all_objects_head, so
        // headerOf() would give garbage. We need a different approach for arena objects.
        //
        // Strategy: arena-allocated intrinsics don't need GC protection because they live
        // for the full eval lifetime (arena resets at end of eval). We only need GC to
        // protect objects it allocated itself. So: skip registering arena-based protos as roots.
        // The GC simply won't free them (they're not in all_objects_head).
        //
        // However, if user objects reference arena objects via proto links, we need to NOT
        // free those user objects incorrectly. The markObject path follows proto links —
        // if proto is an arena object, headerOf(proto) will be garbage. This is unsafe.
        //
        // Solution: make markObject check if an object is in the GC-managed list before
        // trying to mark it. Heap.isGcManaged() checks the linked list.
        // That's O(n) per call. Alternatively, embed a magic sentinel in the GcHeader
        // and check it before trusting the header.
        //
        // For MVP: use a sentinel. GcHeader gets a magic field.
        // For now: Object.prototype and Array.prototype are arena-allocated, so we
        // allocate GC-managed shadow roots that wrap them.
        // Actually the cleanest MVP approach: Realm.object_prototype and array_prototype
        // should also be heap-allocated so GC owns them. Let's migrate them.
        //
        // Simpler still for MVP: just don't register arena objects as GC roots.
        // The heap only frees objects in its all_objects_head list. Arena objects never
        // appear there, so they'll never be freed by GC regardless of mark state.
        // markObject on an arena object will read garbage from the GcHeader prefix —
        // that's UB.
        //
        // SAFE SOLUTION for MVP: when following proto links in markObject, only follow
        // if the proto is also GC-managed. Heap tracks which pointers are GC-managed.
        // We add a lookup set OR embed a sentinel byte at a known offset.
        //
        // Use sentinel approach: lowest bit of GcHeader.size is always 0 (naturally,
        // since size >= sizeof(GcHeader)+sizeof(JsObject) which is > 1). We set
        // a magic value in GcHeader.kind field that only GC allocations have.
        // Actually GcObjectKind is a u8 enum with .js_object == 0. An arena JsObject's
        // bytes before it could be anything.
        //
        // SIMPLEST SAFE APPROACH: Make Realm.object_prototype and array_prototype
        // also be GC-allocated when a heap is active. Do that here.

        // The arena-allocated %Object.prototype% that every built-in prototype was
        // parented to during Realm.init. After migration below it is replaced by a
        // heap copy; any built-in prototype still pointing here must be reparented so
        // identity checks like `Object.getPrototypeOf(X.prototype) === Object.prototype`
        // continue to hold.
        const old_object_proto = self.object_prototype;

        // Reallocate intrinsics on the heap so they have proper GcHeaders and
        // will be visited during mark. Register them as roots so they survive collect.
        const hp_proto = try heap.allocateObject(null);
        // Copy properties from arena object to heap object, preserving attrs.
        // Accessor slots (e.g. the `__proto__` get/set pair) must be re-installed
        // as accessors — `getOwn` returns null for them, so a plain defineOwnData
        // copy would silently turn them into a broken data property.
        for (self.object_prototype.ownKeys()) |k| {
            const a = self.object_prototype.ownAttr(k) orelse obj_mod.PropAttr{};
            if (a.is_accessor) {
                if (self.object_prototype.ownAccessorHolder(k)) |holder| {
                    _ = try hp_proto.defineOwnAccessor(k, holder, a);
                    continue;
                }
            }
            const v = self.object_prototype.getOwn(k) orelse val_mod.Value{};
            _ = try hp_proto.defineOwnData(k, v, a);
        }
        for (self.object_prototype.sym_props.items) |sp| {
            try hp_proto.setSymAttr(sp.key, sp.value, sp.attr);
        }

        const hp_array_proto = try heap.allocateObject(hp_proto);
        // %Array.prototype% is itself an Array exotic object (§23.1.3); the
        // heap-migrated copy must keep that brand and its length.
        hp_array_proto.is_array = self.array_prototype.is_array;
        hp_array_proto.array_length = self.array_prototype.array_length;
        for (self.array_prototype.ownKeys()) |k| {
            const a = self.array_prototype.ownAttr(k) orelse obj_mod.PropAttr{};
            if (a.is_accessor) {
                if (self.array_prototype.ownAccessorHolder(k)) |holder| {
                    _ = try hp_array_proto.defineOwnAccessor(k, holder, a);
                    continue;
                }
            }
            const v = self.array_prototype.getOwn(k) orelse val_mod.Value{};
            _ = try hp_array_proto.defineOwnData(k, v, a);
        }
        for (self.array_prototype.sym_props.items) |sp| {
            try hp_array_proto.setSymAttr(sp.key, sp.value, sp.attr);
        }

        self.object_prototype = hp_proto;
        self.array_prototype = hp_array_proto;

        // Update the Object constructor's "prototype" property to point to new hp_proto.
        // Find the Object ctor in global env.
        if (self.global_env.bindings.getPtr("Object")) |obj_binding| {
            const obj_val_ptr = &obj_binding.value;
            if (obj_val_ptr.bits != 0) {
                switch (obj_val_ptr.unbox()) {
                    .object => |ctor_obj| {
                        const new_proto_val = try val_mod.makeObject(self.arena, hp_proto);
                        // The slot is locked (non-writable/non-configurable), so
                        // re-point it directly rather than through [[Set]].
                        try ctor_obj.defineOwnDataForced("prototype", new_proto_val, .{ .writable = false, .enumerable = false, .configurable = false });
                    },
                    else => {},
                }
            }
        }

        // Likewise update the Array constructor's "prototype" so identity checks
        // (`Object.getPrototypeOf(arr) === Array.prototype`) hold: array literals
        // and JSON.parse build arrays off the migrated hp_array_proto, so the
        // ctor's "prototype" must reference the same heap object, not the stale
        // arena proto. (Matches the Object ctor fix above.)
        if (self.global_env.bindings.getPtr("Array")) |arr_binding| {
            const arr_val_ptr = &arr_binding.value;
            if (arr_val_ptr.bits != 0) {
                switch (arr_val_ptr.unbox()) {
                    .object => |ctor_obj| {
                        const new_proto_val = try val_mod.makeObject(self.arena, hp_array_proto);
                        try ctor_obj.defineOwnDataForced("prototype", new_proto_val, .{ .writable = false, .enumerable = false, .configurable = false });
                    },
                    else => {},
                }
            }
        }

        // Reparent every built-in prototype that was directly parented to the old
        // arena %Object.prototype% so its [[Prototype]] now resolves to the heap copy
        // exposed as `Object.prototype`. Each global constructor binding (Object,
        // Symbol, Promise, Map, ShadowRealm, …) carries a `prototype` whose proto is
        // the old object proto; fix those in one pass. (Array.prototype is already
        // remapped above; reparenting it again is a harmless no-op.)
        {
            var it = self.global_env.bindings.iterator();
            while (it.next()) |entry| {
                const v = entry.value_ptr.value;
                if (v.bits == 0 or v.unbox() != .object) continue;
                const ctor = v.toPtr().object;
                // Reparent namespace objects (Math, JSON, Atomics, …) that are
                // directly parented to old_object_proto (no "prototype" property).
                if (ctor.proto == old_object_proto) ctor.proto = hp_proto;
                const proto_v = ctor.getOwn("prototype") orelse {
                    // A namespace's members are constructors in their own right
                    // (Intl.NumberFormat, …); their prototypes need the same fix.
                    for (ctor.ownKeys()) |k| {
                        const mv = ctor.getOwn(k) orelse continue;
                        if (mv.bits == 0 or mv.unbox() != .object) continue;
                        const member = mv.toPtr().object;
                        if (member.proto == old_object_proto) member.proto = hp_proto;
                        const mp = member.getOwn("prototype") orelse continue;
                        if (mp.bits == 0 or mp.unbox() != .object) continue;
                        const mchild = mp.toPtr().object;
                        if (mchild.proto == old_object_proto) mchild.proto = hp_proto;
                    }
                    continue;
                };
                if (proto_v.bits == 0 or proto_v.unbox() != .object) continue;
                const child = proto_v.toPtr().object;
                if (child.proto == old_object_proto) child.proto = hp_proto;
            }
        }

        // Nested namespace objects and per-type prototypes that are reachable
        // only as properties (not global bindings) are missed by the pass above.
        // Temporal.{Instant,Duration,…}.prototype and Temporal.Now fall in this
        // bucket; reparent them explicitly so their [[Prototype]] resolves to the
        // heap %Object.prototype%.
        temporal_mod.reparentObjectProto(old_object_proto, hp_proto);

        // Phase 4b: update thread-locals to point to heap-migrated protos.
        active_array_proto = hp_array_proto;
        active_object_proto = hp_proto;
        // string_prototype stays arena-allocated (ok — it's not GC-managed, won't be freed).

        // Prepare root Value slots. The caller must call registerRoots() after
        // the Realm is in its final stack location (avoids dangling pointers).
        self._proto_root = try val_mod.makeObject(self.arena, hp_proto);
        self._array_proto_root = try val_mod.makeObject(self.arena, hp_array_proto);
    }

    /// Register proto roots with the heap. Call after the Realm is in its
    /// final stack location (i.e., after the Vm struct is fully initialized).
    pub fn registerRoots(self: *Realm) !void {
        if (self.heap) |heap| {
            try heap.addRoot(&self._proto_root);
            try heap.addRoot(&self._array_proto_root);
        }
    }

    pub fn deinit(self: *Realm) void {
        if (self.heap) |heap| {
            if (self._proto_root.bits != 0) {
                heap.removeRoot(&self._proto_root);
            }
            if (self._array_proto_root.bits != 0) {
                heap.removeRoot(&self._array_proto_root);
            }
            active_heap = null;
        }
        active_array_proto = null;
        active_array_ctor = null;
        active_object_proto = null;
        active_string_proto = null;
        active_number_proto = null;
        active_boolean_proto = null;
        active_regexp_proto = null;
        active_function_proto = null;
        active_promise_proto = null;
        active_symbol_proto = null;
        active_sym_iterator = null;
        active_sym_to_primitive = null;
        active_sym_to_string_tag = null;
        active_sym_intl_fallback = null;
        active_sym_species = null;
        active_sym_module_ns = null;
        active_sym_deferred_id = null;
        active_deferred_ns_registry = null;
        active_sym_export_names = null;
        active_sym_tdz_export_names = null;
        tdz_marker = null;
        active_sym_proxy_target = null;
        active_sym_proxy_handler = null;
        typed_array_mod.active_arraybuffer_proto = null;
        typed_array_mod.active_dataview_proto = null;
        typed_array_mod.active_typedarray_proto = null;
        typed_array_mod.active_ta_iter_proto = null;
        for (&typed_array_mod.active_ta_protos) |*p| p.* = null;
        for (&typed_array_mod.active_ta_ctors) |*p| p.* = null;
        active_global_env = null;
        pending_exception = Value{};
        // Transient execution-state globals: a test/script that unwinds mid-
        // construct or via an uncaught throw can leave these set. They outlive
        // the realm (module-level vars) and Realm.init never clears them, so a
        // reused process (e.g. the test262 runner's isolate-per-test loop) would
        // inherit dirty state and cascade-fail unrelated later evals. Reset here.
        active_constructing = false;
        callback_depth = 0;
        pending_new_target = Value{};
        active_context = null;
    }
};

test "Realm init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var realm = try Realm.init(arena.allocator());
    defer realm.deinit();
    try std.testing.expect(realm.global_env.parent == null);
    try std.testing.expect(realm.object_prototype.proto == null);
    try std.testing.expect(realm.array_prototype.proto == realm.object_prototype);
}

test "Realm: Object.create in env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var realm = try Realm.init(arena.allocator());
    defer realm.deinit();
    const obj_val = try realm.global_env.lookup("Object");
    try std.testing.expect(obj_val.bits != 0);
    try std.testing.expect(obj_val.unbox() == .object);
}

test "evalModule: cached/cyclic/errored records short-circuit without re-running" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A Context whose callbacks are never reached on these early-return paths;
    // if evalModule wrongly called eval_fn the undefined pointer would trap.
    var ctx: Context = undefined;
    var reg = ModuleRegistry.init(arena);

    // Unknown id → ModuleNotFound.
    try std.testing.expectError(error.ModuleNotFound, evalModule(&ctx, arena, &reg, "missing"));

    // Already-evaluated → returns the cached namespace.
    const done = try reg.getOrCreate("done", "x");
    done.status = .evaluated;
    done.namespace = Value{ .bits = 42 };
    const got = try evalModule(&ctx, arena, &reg, "done");
    try std.testing.expectEqual(@as(u64, 42), got.bits);

    // Cyclic re-entry (status == .evaluating) → returns the partial namespace.
    const cyc = try reg.getOrCreate("cyc", "x");
    cyc.status = .evaluating;
    cyc.namespace = Value{ .bits = 7 };
    const partial = try evalModule(&ctx, arena, &reg, "cyc");
    try std.testing.expectEqual(@as(u64, 7), partial.bits);

    // Errored → re-raises as a JS exception with the captured value.
    const bad = try reg.getOrCreate("bad", "x");
    bad.status = .errored;
    bad.eval_error = Value{ .bits = 99 };
    pending_exception = Value{};
    try std.testing.expectError(error.JsException, evalModule(&ctx, arena, &reg, "bad"));
    try std.testing.expectEqual(@as(u64, 99), pending_exception.bits);
}

test "Realm: activateHeap migrates protos to heap" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var realm = try Realm.init(arena.allocator());
    defer realm.deinit();

    try realm.activateHeap(&heap);
    // Register roots after realm is in final location.
    try realm.registerRoots();

    // After activation, 2 objects should be on the heap (object_proto + array_proto).
    try std.testing.expect(heap.objects_alive >= 2);

    // Collect: both should survive (they are roots).
    const stats = heap.collect();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
}
