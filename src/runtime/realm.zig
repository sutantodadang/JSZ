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
// Phase 13 Intl
const intl_mod = @import("./builtins/intl.zig");
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
    /// HasProperty(O, key): own-or-inherited existence check firing Proxy `has`
    /// traps. Used by array methods to skip holes (absent indices).
    has_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool,
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
        return self.invoke_fn(self.ptr, arena, this_val, fn_val, args);
    }

    pub fn construct(self: *Context, arena: std.mem.Allocator, ctor_val: Value, args: []const Value) anyerror!Value {
        return self.construct_fn(self.ptr, arena, ctor_val, args);
    }

    pub fn evalSource(self: *Context, arena: std.mem.Allocator, source: []const u8) anyerror!Value {
        return self.eval_fn(self.ptr, arena, source);
    }

    pub fn getProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value {
        return self.get_fn(self.ptr, arena, obj_val, key);
    }

    pub fn constructNewTarget(self: *Context, arena: std.mem.Allocator, ctor_val: Value, args: []const Value, new_target: Value) anyerror!Value {
        return self.construct_nt_fn(self.ptr, arena, ctor_val, args, new_target);
    }

    pub fn getPropSym(self: *Context, arena: std.mem.Allocator, obj_val: Value, sym_key: Value) anyerror!Value {
        return self.get_sym_fn(self.ptr, arena, obj_val, sym_key);
    }

    pub fn setProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8, value: Value) anyerror!void {
        return self.set_fn(self.ptr, arena, obj_val, key, value);
    }

    pub fn hasProp(self: *Context, arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!bool {
        return self.has_fn(self.ptr, arena, obj_val, key);
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

/// Dynamic deferred import: `import.defer(spec)` returns a promise that fulfils
/// with the module's deferred namespace exotic object WITHOUT evaluating it (the
/// module body runs lazily on first triggering access). Loading is synchronous in
/// the bundler model, so the promise resolves immediately with the (cached)
/// deferred namespace — identical to the static `import defer` object.
pub fn nativeImportDeferDynamic(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{
            try val_mod.makeString(arena, "TypeError: import.defer() requires a string specifier"),
        });
    }
    const spec = args[0].toPtr().string;
    const env = active_global_env;
    const canonical = if (env) |e| (resolveModuleName(arena, e, spec) catch spec) else spec;
    const ns = try getOrMakeDeferredNamespace(arena, canonical);
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{ns});
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
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{
            try val_mod.makeString(arena, "TypeError: import() requires a string specifier"),
        });
    }
    // A second argument `{ with: { type: '...' } }` selects a typed (JSON/text)
    // module: fold the type into the specifier so it keys the same synthetic
    // module record the static-import desugar registers (`spec\x00type`).
    const args2 = importApplyTypeAttr(arena, args) catch args;
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

/// If `import(spec, options)` carries an import-attributes `with: { type: '...' }`
/// (or legacy `assert: { ... }`) second argument, return a new args slice whose
/// specifier is `spec\x00type`; otherwise return `args` unchanged. The folded
/// specifier matches the typed-module key the static-import desugar registers.
fn importApplyTypeAttr(arena: std.mem.Allocator, args: []const Value) anyerror![]const Value {
    if (args.len < 2 or args[1].bits == 0 or args[1].unbox() != .object) return args;
    const opts = args[1].toPtr().object;
    const attrs_val = opts.get("with") orelse opts.get("assert") orelse return args;
    if (attrs_val.bits == 0 or attrs_val.unbox() != .object) return args;
    const type_val = attrs_val.toPtr().object.get("type") orelse return args;
    if (type_val.bits == 0 or type_val.unbox() != .string) return args;
    const ty = type_val.toPtr().string;
    if (ty.len == 0) return args;
    const typed = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ args[0].toPtr().string, ty });
    const out = try arena.alloc(Value, 1);
    out[0] = try val_mod.makeString(arena, typed);
    return out;
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
        try JsObject.createOnHeap(h, error_proto_Error)
    else
        try JsObject.create(arena, error_proto_Error);
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
        .object => |o| o.get("__call__") != null,
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
/// ES2015 Symbol.isConcatSpreadable well-known symbol value.
pub var active_sym_is_concat_spreadable: ?Value = null;
/// ES2023 Symbol.asyncIterator well-known symbol value.
pub var active_sym_async_iterator: ?Value = null;
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

/// Create an Error object with the given name and message, using proto as [[Prototype]].
fn createErrorObj(arena: std.mem.Allocator, proto: ?*JsObject, name: []const u8, message: []const u8) anyerror!Value {
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, message);
    const name_val = try val_mod.makeString(arena, name);
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    obj.is_error = true;
    return val_mod.makeObject(arena, obj);
}

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

fn extractMessage(args: []const Value) []const u8 {
    if (args.len > 0 and args[0].bits != 0) {
        return switch (args[0].unbox()) {
            .string => |s| s,
            .undefined_ => "",
            else => "error",
        };
    }
    return "";
}

fn populateErrorThis(arena: std.mem.Allocator, this_val: Value, name: []const u8, message: []const u8) !Value {
    // If this_val is an object, populate it and return it.
    // Otherwise create a new object.
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const obj = this_val.toPtr().object;
        const msg_val = try val_mod.makeString(arena, message);
        const name_val = try val_mod.makeString(arena, name);
        try obj.set("message", msg_val);
        try obj.set("name", name_val);
        obj.is_error = true;
        return this_val;
    }
    // Fallback: create new object with the right proto.
    const proto: ?*JsObject = null;
    return createErrorObj(arena, proto, name, message);
}

/// InstallErrorCause (ES §20.5.8.1): if `options` is an object with an own
/// "cause", set `error.cause` to it (writable, non-enumerable, configurable).
fn installErrorCause(arena: std.mem.Allocator, result: Value, options: Value) !void {
    if (result.bits == 0 or result.unbox() != .object) return;
    if (options.bits == 0 or options.unbox() != .object) return;
    const opts = options.toPtr().object;
    if (!opts.hasOwn("cause")) return;
    const cause = opts.getOwn("cause") orelse try val_mod.makeUndefined(arena);
    _ = try result.toPtr().object.defineOwnData("cause", cause, .{ .writable = true, .enumerable = false, .configurable = true });
}

fn errorCtorWithCause(arena: std.mem.Allocator, this_val: Value, name: []const u8, args: []const Value) anyerror!Value {
    const result = try populateErrorThis(arena, this_val, name, extractMessage(args));
    try installErrorCause(arena, result, if (args.len > 1) args[1] else Value{});
    return result;
}

fn nativeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "Error", args);
}

fn nativeTypeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "TypeError", args);
}

fn nativeSyntaxErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "SyntaxError", args);
}

fn nativeRangeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "RangeError", args);
}

fn nativeReferenceErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "ReferenceError", args);
}

fn nativeEvalErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "EvalError", args);
}

fn nativeUriErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return errorCtorWithCause(arena, this_val, "URIError", args);
}

fn nativeAggregateErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // args[0] = errors iterable/array, args[1] = message string
    const message = if (args.len > 1) extractMessage(args[1..]) else "";
    const result = try populateErrorThis(arena, this_val, "AggregateError", message);
    // Attach the errors array (args[0]) if it is an array/object, else empty array.
    const errors_val: Value = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object)
        args[0]
    else blk: {
        const arr_proto = active_array_proto;
        const empty_arr = if (active_heap) |h|
            try JsObject.createOnHeap(h, arr_proto)
        else
            try JsObject.create(arena, arr_proto);
        empty_arr.is_array = true;
        empty_arr.array_length = 0;
        break :blk try val_mod.makeObject(arena, empty_arr);
    };
    if (result.bits != 0 and result.unbox() == .object) {
        try result.toPtr().object.set("errors", errors_val);
    }
    // AggregateError options object is the third argument.
    try installErrorCause(arena, result, if (args.len > 2) args[2] else Value{});
    return result;
}

// ---- Phase 4: Array/String/Number constructors ----

fn nativeObjectCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // new Object() / Object(): if arg is an object return it, else create new.
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object) {
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
        return val_mod.makeObject(arena, w);
    }
    return v;
}

fn nativeArrayCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    if (args.len == 1 and args[0].bits != 0 and args[0].unbox() == .number) {
        const len = args[0].unbox().number;
        if (len >= 0 and len == @floor(len) and len < 4294967296) {
            obj.array_length = @intFromFloat(len);
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
        return val_mod.makeBool(arena, args[0].toPtr().object.is_array);
    }
    return val_mod.makeBool(arena, false);
}

/// ES2015 Array.from(arrayLike [, mapFn [, thisArg]])
/// Converts any array-like (length + indexed) or iterable to a real Array.
fn nativeArrayFrom(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // Helper: create a new array with the given items.
    const makeJsArray = struct {
        fn make(alloc: std.mem.Allocator, items: []const Value) !Value {
            const obj = if (active_heap) |heap|
                try JsObject.createOnHeap(heap, active_array_proto)
            else
                try JsObject.create(alloc, active_array_proto);
            obj.is_array = true;
            for (items, 0..) |v, i| {
                const key = try std.fmt.allocPrint(alloc, "{d}", .{i});
                try obj.set(key, v);
            }
            obj.array_length = @intCast(items.len);
            return val_mod.makeObject(alloc, obj);
        }
    }.make;

    if (args.len == 0 or args[0].bits == 0) return try makeJsArray(arena, &[_]Value{});
    const src = args[0];
    const map_fn = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) args[1] else Value{};

    var items = std.ArrayList(Value){};
    const src_unboxed = src.unbox();
    if (src_unboxed == .object) {
        const obj = src_unboxed.object;
        if (obj.internal_kind == .typed_array) {
            // TypedArray: use taLoad to get each element as a JS Value.
            if (typed_array_mod.getTd(src)) |td| {
                var i: usize = 0;
                while (i < td.length) : (i += 1) {
                    try items.append(arena, try typed_array_mod.taLoad(arena, td, i));
                }
            }
        } else if (obj.is_array) {
            // Real Array: iterate by [[ArrayLength]] + indexed reads (length is
            // the `array_length` slot, NOT an ordinary "length" property).
            const len: usize = obj.getArrayLength();
            var i: usize = 0;
            var buf: [32]u8 = undefined;
            while (i < len) : (i += 1) {
                const key = try std.fmt.bufPrint(&buf, "{d}", .{i});
                try items.append(arena, obj.get(key) orelse Value{});
            }
        } else if (try arrayFromIterate(arena, src, &items)) {
            // Consumed via the @@iterator protocol (Set/Map/generators/custom).
        } else {
            // Generic array-like: read .length then [0..length-1].
            const len_v = obj.get("length") orelse Value{};
            const len: usize = if (len_v.bits != 0 and len_v.unbox() == .number)
                @intFromFloat(@max(0, len_v.unbox().number))
            else
                0;
            var i: usize = 0;
            var buf: [32]u8 = undefined;
            while (i < len) : (i += 1) {
                const key = try std.fmt.bufPrint(&buf, "{d}", .{i});
                const v = obj.get(key) orelse Value{};
                try items.append(arena, v);
            }
        }
    } else if (src_unboxed == .string) {
        // String: each Unicode code unit becomes an element.
        const s = src_unboxed.string;
        var i: usize = 0;
        while (i < s.len) {
            const byte_len: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const slice = if (i + byte_len <= s.len) s[i .. i + byte_len] else s[i .. i + 1];
            const cv = try val_mod.makeString(arena, try arena.dupe(u8, slice));
            try items.append(arena, cv);
            i += byte_len;
        }
    }

    // Apply mapFn if provided.
    if (map_fn.bits != 0) {
        const undef = try val_mod.makeUndefined(arena);
        for (items.items, 0..) |v, i| {
            const idx = try val_mod.makeNumber(arena, @floatFromInt(i));
            items.items[i] = try function_proto_mod.invokeCallback(arena, undef, map_fn, &[_]Value{ v, idx });
        }
    }

    return try makeJsArray(arena, items.items);
}

/// Consume `src` via the @@iterator protocol into `items`. Returns false when
/// `src` is not iterable (no callable @@iterator) so the caller can fall back to
/// the array-like path. Used by Array.from for Set/Map/generators/custom iterables.
fn arrayFromIterate(arena: std.mem.Allocator, src: Value, items: *std.ArrayList(Value)) anyerror!bool {
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
        .object => |o| o.get("__call__") != null,
        else => false,
    };
}

fn isTruthyVal(v: Value) bool {
    return val_mod.toBoolean(v);
}

fn isTruthyValue(v: Value) bool {
    return val_mod.toBoolean(v);
}

/// ES2015 Array.of(...args) — creates array from arguments (no special-case for length).
fn nativeArrayOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    for (args, 0..) |v, i| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try obj.set(key, v);
    }
    obj.array_length = @intCast(args.len);
    return val_mod.makeObject(arena, obj);
}

/// ES2023 Array.fromAsync(items, mapFn?, thisArg?) → Promise<Array>
/// Drives async/sync iterables and array-likes; each element is awaited
/// so thenables are unwrapped. Always returns a Promise.
fn nativeArrayFromAsync(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // not-a-constructor guard (§23.1.2.2 step 1)
    if (active_constructing) {
        active_constructing = false;
        return throwTypeError(arena, "Array.fromAsync is not a constructor");
    }
    const result = arrayFromAsyncWork(arena, args) catch |e| {
        if (e == error.JsException) {
            const ex = pending_exception;
            pending_exception = Value{};
            return promise_mod.nativePromiseReject(arena, Value{}, &[_]Value{ex});
        }
        return e;
    };
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{result});
}

fn makeFromAsyncArray(arena: std.mem.Allocator, items: []const Value) !Value {
    const obj = if (active_heap) |heap|
        try JsObject.createOnHeap(heap, active_array_proto)
    else
        try JsObject.create(arena, active_array_proto);
    obj.is_array = true;
    for (items, 0..) |v, i| {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try obj.set(key, v);
    }
    obj.array_length = @intCast(items.len);
    return val_mod.makeObject(arena, obj);
}

fn arrayFromAsyncWork(arena: std.mem.Allocator, args: []const Value) anyerror!Value {
    const src = if (args.len > 0 and args[0].bits != 0) args[0] else Value{};
    const map_fn_raw = if (args.len > 1) args[1] else Value{};
    const has_map = map_fn_raw.bits != 0 and
        map_fn_raw.unbox() != .undefined_ and
        map_fn_raw.unbox() != .null_;
    if (has_map and !isCallableVal(map_fn_raw))
        return throwTypeError(arena, "Array.fromAsync: mapFn is not callable");

    var items = std.ArrayListUnmanaged(Value){};

    if (src.bits == 0) return makeFromAsyncArray(arena, items.items);
    if (src.unbox() != .object) return makeFromAsyncArray(arena, items.items);

    const ctx = active_context orelse return makeFromAsyncArray(arena, items.items);

    // 1. Try @@asyncIterator
    if (active_sym_async_iterator) |async_sym| {
        const iter_fn = ctx.getPropSym(arena, src, async_sym) catch Value{};
        if (iter_fn.bits != 0 and iter_fn.unbox() != .undefined_ and
            iter_fn.unbox() != .null_ and isCallableVal(iter_fn))
        {
            const iterator = try function_proto_mod.invokeCallback(arena, src, iter_fn, &[_]Value{});
            if (iterator.bits == 0 or iterator.unbox() != .object)
                return throwTypeError(arena, "@@asyncIterator() did not return an object");
            const next_fn = try ctx.getProp(arena, iterator, "next");
            if (!isCallableVal(next_fn))
                return throwTypeError(arena, "async iterator.next is not a function");
            var k: usize = 0;
            while (k < 100_000_000) : (k += 1) {
                const next_p = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
                const step = try promise_mod.awaitValue(arena, next_p);
                if (step.bits == 0 or step.unbox() != .object) break;
                const done_v = try ctx.getProp(arena, step, "done");
                if (isTruthyVal(done_v)) break;
                var val = try ctx.getProp(arena, step, "value");
                val = try promise_mod.awaitValue(arena, val);
                if (has_map) {
                    const idx_v = try val_mod.makeNumber(arena, @floatFromInt(k));
                    const mapped = try function_proto_mod.invokeCallback(arena, try val_mod.makeUndefined(arena), map_fn_raw, &[_]Value{ val, idx_v });
                    val = try promise_mod.awaitValue(arena, mapped);
                }
                try items.append(arena, val);
            }
            return makeFromAsyncArray(arena, items.items);
        }
    }

    // 2. Try @@iterator (sync iterable — each value is awaited per spec)
    if (active_sym_iterator) |iter_sym| {
        const iter_fn = ctx.getPropSym(arena, src, iter_sym) catch Value{};
        if (iter_fn.bits != 0 and iter_fn.unbox() != .undefined_ and
            iter_fn.unbox() != .null_ and isCallableVal(iter_fn))
        {
            const iterator = try function_proto_mod.invokeCallback(arena, src, iter_fn, &[_]Value{});
            if (iterator.bits == 0 or iterator.unbox() != .object)
                return throwTypeError(arena, "@@iterator() did not return an object");
            const next_fn = try ctx.getProp(arena, iterator, "next");
            if (!isCallableVal(next_fn))
                return throwTypeError(arena, "iterator.next is not a function");
            var k: usize = 0;
            while (k < 100_000_000) : (k += 1) {
                const res = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
                if (res.bits == 0 or res.unbox() != .object) break;
                const done_v = try ctx.getProp(arena, res, "done");
                if (isTruthyVal(done_v)) break;
                var val = try ctx.getProp(arena, res, "value");
                val = try promise_mod.awaitValue(arena, val);
                if (has_map) {
                    const idx_v = try val_mod.makeNumber(arena, @floatFromInt(k));
                    const mapped = try function_proto_mod.invokeCallback(arena, try val_mod.makeUndefined(arena), map_fn_raw, &[_]Value{ val, idx_v });
                    val = try promise_mod.awaitValue(arena, mapped);
                }
                try items.append(arena, val);
            }
            return makeFromAsyncArray(arena, items.items);
        }
    }

    // 3. Array-like: read length, then elements by index (each awaited)
    const src_obj = src.toPtr().object;
    const len_v = src_obj.get("length") orelse Value{};
    const len: usize = blk: {
        if (len_v.bits == 0) break :blk 0;
        const lv = try promise_mod.awaitValue(arena, len_v);
        if (lv.bits == 0) break :blk 0;
        break :blk switch (lv.unbox()) {
            .number => |n| if (n <= 0 or std.math.isNan(n)) 0 else @min(@as(usize, @intFromFloat(@trunc(n))), 4294967295),
            else => 0,
        };
    };
    var buf: [32]u8 = undefined;
    var k: usize = 0;
    while (k < len) : (k += 1) {
        const key = try std.fmt.bufPrint(&buf, "{d}", .{k});
        var val = src_obj.get(key) orelse try val_mod.makeUndefined(arena);
        val = try promise_mod.awaitValue(arena, val);
        if (has_map) {
            const idx_v = try val_mod.makeNumber(arena, @floatFromInt(k));
            const mapped = try function_proto_mod.invokeCallback(arena, try val_mod.makeUndefined(arena), map_fn_raw, &[_]Value{ val, idx_v });
            val = try promise_mod.awaitValue(arena, mapped);
        }
        try items.append(arena, val);
    }
    return makeFromAsyncArray(arena, items.items);
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
        .object => blk: {
            // ToString(ToPrimitive(arg, "string")) when a user hook applies.
            if (try coercion_mod.toPrimitive(arena, arg, .string)) |prim|
                break :blk try stringPrimitive(arena, prim);
            break :blk "[object Object]";
        },
        else => "[object Object]",
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
        // A String exotic object exposes each code unit as an own property
        // { enumerable, non-writable, non-configurable } plus an own non-enumerable
        // "length" (ES 10.4.3 StringCreate / String-exotic define-own-property).
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            _ = try obj.defineOwnData(key, try val_mod.makeString(arena, try arena.dupe(u8, s[i .. i + 1])), .{ .writable = false, .enumerable = true, .configurable = false });
        }
        _ = try obj.defineOwnData("length", try val_mod.makeNumber(arena, @floatFromInt(s.len)), .{ .writable = false, .enumerable = false, .configurable = false });
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
        else => {
            if (try coercion_mod.toPrimitive(arena, v, .string)) |prim| {
                if (prim.bits != 0 and prim.unbox() == .string) return prim.toPtr().string;
                if (prim.bits != 0 and prim.unbox() == .number) return try val_mod.formatNumber(arena, prim.unbox().number);
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
    const raw_v = args[0].toPtr().object.get("raw") orelse return val_mod.makeString(arena, "");
    if (raw_v.bits == 0 or raw_v.unbox() != .object)
        return val_mod.makeString(arena, "");
    const raw = raw_v.toPtr().object;
    const seg_count = raw.array_length;
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const seg = raw.getOwn(key) orelse Value{};
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
    if (v.bits == 0) return std.math.nan(f64);
    switch (v.unbox()) {
        .number => |n| return n,
        .boolean => |b| return if (b) 1 else 0,
        .null_ => return 0,
        .undefined_ => return std.math.nan(f64),
        .string => |s| return val_mod.jsStringToNumber(s),
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .bigint => return throwTypeError(arena, "Cannot convert a BigInt value to a number"),
        .object => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .number)) orelse return std.math.nan(f64);
            if (prim.bits != 0 and prim.unbox() == .object) return std.math.nan(f64);
            return toNumberCheckedRealm(arena, prim);
        },
        else => return std.math.nan(f64),
    }
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
    const n = if (args.len > 0) toNumberCoerce(args[0]) else std.math.nan(f64);
    return val_mod.makeBool(arena, std.math.isNan(n));
}

fn nativeIsFinite(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const n = if (args.len > 0) toNumberCoerce(args[0]) else std.math.nan(f64);
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
        .object => {
            // ToString(object): ToPrimitive(string). A missing/uncallable
            // toString & valueOf (null result) is a TypeError, not a fallback.
            const prim = (try coercion_mod.toPrimitive(arena, v, .string)) orelse
                return throwTypeError(arena, "Cannot convert object to primitive value");
            if (prim.bits != 0 and prim.unbox() == .object) return "[object Object]";
            return uriToString(arena, prim);
        },
        else => return "[object Object]",
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
                const eo = if (active_heap) |h| try JsObject.createOnHeap(h, error_proto_RangeError) else try JsObject.create(arena, error_proto_RangeError);
                try eo.set("message", try val_mod.makeString(arena, "The number is not a safe integer"));
                try eo.set("name", try val_mod.makeString(arena, "RangeError"));
                pending_exception = try val_mod.makeObject(arena, eo);
                return error.JsException;
            }
            if (@abs(x) < 9.0e18) return val_mod.makeBigIntFromI64(arena, @intFromFloat(x));
            const s = try std.fmt.allocPrint(arena, "{d}", .{x});
            return val_mod.makeBigIntFromLiteral(arena, s) catch throwTypeError(arena, "Cannot convert number to a BigInt");
        },
        else => return throwTypeError(arena, "Cannot convert value to a BigInt"),
    }
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

fn nativeBigIntProtoToString(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const b = try bigIntThisValue(arena, this_val);
    var radix: i64 = 10;
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) {
        const prim = (try coercion_mod.toPrimitive(arena, args[0], .number)) orelse args[0];
        const rn: f64 = switch (prim.unbox()) {
            .number => |n| n,
            .boolean => |bo| if (bo) 1 else 0,
            else => 10,
        };
        if (std.math.isNan(rn)) return throwRangeError(arena, "toString() radix must be between 2 and 36");
        radix = @intFromFloat(@trunc(rn));
    }
    if (radix < 2 or radix > 36) return throwRangeError(arena, "toString() radix must be between 2 and 36");
    const s = try b.toPtr().bigint.toConst().toStringAlloc(arena, @intCast(radix), .lower);
    return val_mod.makeString(arena, s);
}

fn nativeBigIntProtoValueOf(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return bigIntThisValue(arena, this_val);
}

pub fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h| try JsObject.createOnHeap(h, error_proto_RangeError) else try JsObject.create(arena, error_proto_RangeError);
    try eo.set("message", try val_mod.makeString(arena, msg));
    try eo.set("name", try val_mod.makeString(arena, "RangeError"));
    pending_exception = try val_mod.makeObject(arena, eo);
    return error.JsException;
}

/// Raise a `SyntaxError` from a native. Spec StringToBigInt reports a malformed
/// numeric string this way (`BigInt("abc")`), not as a TypeError.
fn throwSyntaxError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h| try JsObject.createOnHeap(h, error_proto_SyntaxError) else try JsObject.create(arena, error_proto_SyntaxError);
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
        try JsObject.createOnHeap(h, error_proto_TypeError)
    else
        try JsObject.create(arena, error_proto_TypeError);
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
    if (args.len > 0 and args[0].bits != 0) {
        const r_raw = args[0].toF64();
        const r_int: f64 = if (std.math.isNan(r_raw)) 0 else @trunc(r_raw);
        if (r_int < 2 or r_int > 36) return throwRangeError(arena, "toString() radix must be between 2 and 36");
        radix = @intFromFloat(r_int);
    }
    if (radix == 10) return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
    if (std.math.isNan(n)) return val_mod.makeString(arena, "NaN");
    if (std.math.isInf(n)) return val_mod.makeString(arena, if (n < 0) "-Infinity" else "Infinity");
    return val_mod.makeString(arena, try numberToRadixString(arena, n, radix));
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
    const nf: f64 = if (n == 0) 0.0 else n;
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d:.[1]}", .{ nf, fu }));
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
        if (mant >= 10.0) { mant /= 10.0; exp += 1; }
        else if (mant < 1.0) { mant *= 10.0; exp -= 1; }
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
    } else {
        const fu: usize = @intCast(f);
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d:.[1]}", .{ mant, fu }));
    }

    // Exponent: e+N or e-N, no leading zeros
    try buf.append(arena, 'e');
    if (exp >= 0) {
        try buf.append(arena, '+');
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{@as(u64, @intCast(exp))}));
    } else {
        try buf.append(arena, '-');
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{@as(u64, @intCast(-exp))}));
    }
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
    const abs_n = @abs(n);
    // -0 formats without a sign (ES: the "-" prefix is added only when x < 0).
    const nf: f64 = if (abs_n == 0.0) 0.0 else n;
    // e = floor(log10(|n|)), 0 for n == 0
    const e: i64 = if (abs_n == 0.0) 0 else @as(i64, @intFromFloat(@floor(std.math.log10(abs_n))));
    if (e >= p or e < -6) {
        // Exponential form: p-1 fraction digits
        return val_mod.makeString(arena, try numberToExponentialImpl(arena, nf, p - 1));
    } else {
        // Fixed form: p-1-e fraction digits
        const frac: i64 = p - 1 - e;
        const fu: usize = if (frac < 0) 0 else @intCast(frac);
        return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "{d:.[1]}", .{ nf, fu }));
    }
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
fn nativeObjectProtoToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 20.1.3.6: "[object " + builtinTag + "]". undefined/null get special tags.
    if (this_val.bits == 0) return val_mod.makeString(arena, "[object Undefined]");
    const builtin_tag: []const u8 = switch (this_val.unbox()) {
        .undefined_ => "Undefined",
        .null_ => "Null",
        // ES 20.1.3.6 steps 4-14: exotic internal slots select the builtin tag
        // before falling back to "Object". Array/Arguments/callable/Error/wrapper/
        // Date/RegExp each have a reserved tag.
        .object => |obj| if (obj.is_array)
            "Array"
        else if (obj.internal_kind == .mapped_arguments)
            "Arguments"
        else if (obj.get("__call__") != null)
            "Function"
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
    if (this_val.unbox() == .object) {
        if (active_sym_to_string_tag) |tag_sym| {
            if (active_context) |ctx| {
                const tv = try ctx.getPropSym(arena, this_val, tag_sym);
                if (tv.bits != 0 and tv.unbox() == .string) {
                    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "[object {s}]", .{tv.unbox().string}));
                }
            }
        }
    }
    return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "[object {s}]", .{builtin_tag}));
}

fn nativeObjectProtoValueOf(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 20.1.3.7: ToObject(this); for our purposes return `this` unchanged.
    return this_val;
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
        if (args.len > 1) {
            for (args[0 .. args.len - 1], 0..) |a, i| {
                if (i > 0) try src.append(arena, ',');
                if (a.bits != 0 and a.unbox() == .string) try src.appendSlice(arena, a.toPtr().string);
            }
        }
        try src.appendSlice(arena, "){");
        if (args.len > 0) {
            const body = args[args.len - 1];
            if (body.bits != 0 and body.unbox() == .string) try src.appendSlice(arena, body.toPtr().string);
        }
        try src.appendSlice(arena, "})");
        // NewTarget [[Prototype]] override for dynamic generator/async-generator
        // functions (CreateDynamicFunction step 18: proto from newTarget's realm).
        // IMPORTANT: capture pending_new_target BEFORE evalSource/shadowEval, because
        // bcInvokeJs (called inside evalSource) unconditionally clears pending_new_target.
        const is_gen = !std.mem.eql(u8, keyword, "function");
        const captured_nt = if (is_gen) pending_new_target else Value{};
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
                    break :blk try ctx.shadowEval(arena, src.items, @ptrCast(rp.global_env));
                }
            }
            break :blk try ctx.evalSource(arena, src.items);
        };
        if (is_gen and captured_nt.bits != 0) {
            const nt = captured_nt;
            const derived_proto: ?*JsObject = proto_blk: {
                const pv = try ctx.getProp(arena, nt, "prototype");
                if (pv.bits != 0 and pv.unbox() == .object) break :proto_blk pv.toPtr().object;
                // Fallback: GetFunctionRealm(newTarget) then that realm's gen proto.
                if (getFunctionRealm(nt)) |fr| {
                    try ctx.ensureGenChain(@ptrCast(fr));
                    const is_async_gen = std.mem.eql(u8, keyword, "async function*");
                    break :proto_blk if (is_async_gen) fr.async_gen_fn_proto else fr.gen_fn_proto;
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
            // .bc_function — the generator function type).
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

/// Packed eval data for secondary realm evalScript native function.
/// Stored as native userdata (opaque *anyopaque, cast back to *const EvalData).
pub const EvalData = struct {
    env: *anyopaque,
    realm: *Realm,
};

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
fn nativeTemplateObject(_: std.mem.Allocator, _: val_mod.Value, args: []const val_mod.Value) anyerror!val_mod.Value {
    const cooked = if (args.len > 0) args[0] else val_mod.Value{};
    const raw = if (args.len > 1) args[1] else val_mod.Value{};
    if (cooked.bits != 0 and cooked.unbox() == .object) {
        _ = try cooked.toPtr().object.defineOwnData("raw", raw, .{ .writable = false, .enumerable = false, .configurable = false });
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
    const global_val = try val_mod.makeObject(arena, global_obj);
    try env.define("globalThis", global_val);
    try env.define("global", global_val);
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
    function_proto: ?*JsObject,
    promise_proto: ?*JsObject,
    symbol_proto: ?*JsObject,
    sym_iterator: ?val_mod.Value,
    sym_async_iterator: ?val_mod.Value,
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
            .function_proto = active_function_proto,
            .promise_proto = active_promise_proto,
            .symbol_proto = active_symbol_proto,
            .sym_iterator = active_sym_iterator,
            .sym_async_iterator = active_sym_async_iterator,
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
        active_object_proto = self.object_proto;
        active_string_proto = self.string_proto;
        active_number_proto = self.number_proto;
        active_boolean_proto = self.boolean_proto;
        active_bigint_proto = self.bigint_proto;
        active_regexp_proto = self.regexp_proto;
        active_function_proto = self.function_proto;
        active_promise_proto = self.promise_proto;
        active_symbol_proto = self.symbol_proto;
        active_sym_iterator = self.sym_iterator;
        active_sym_async_iterator = self.sym_async_iterator;
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

        // Build Array.prototype (proto = Object.prototype).
        const array_proto = try JsObject.create(arena, object_proto);

        // Build Object constructor object: a JsObject with a "create" property.
        const object_ctor = try JsObject.create(arena, null);
        const create_fn = try val_mod.makeNativeFunction(arena, nativeObjectCreate);
        try object_ctor.set("create", create_fn);
        try object_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeObjectCtor));

        // Also expose Object.prototype on the constructor.
        const proto_val = try val_mod.makeObject(arena, object_proto);
        try object_ctor.set("prototype", proto_val);

        // Define "Object" in global env as the constructor object.
        _ = try object_ctor.defineOwnData("name", try val_mod.makeString(arena, "Object"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try object_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        const ctor_val = try val_mod.makeObject(arena, object_ctor);
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

        // Set thread-local proto pointers so native ctors can find them.
        error_proto_Error = error_proto;
        error_proto_TypeError = type_error_proto;
        error_proto_SyntaxError = syntax_error_proto;
        error_proto_RangeError = range_error_proto;
        error_proto_ReferenceError = reference_error_proto;
        error_proto_AggregateError = aggregate_error_proto;
        error_proto_URIError = uri_error_proto;

        // Create Error constructor objects. Each has a .prototype property
        // and a hidden __proto__ marker so `instanceof` can find the prototype.
        const makeErrorCtor = struct {
            fn make(a: std.mem.Allocator, ctor_fn: val_mod.NativeFnPtr, proto_obj: *JsObject, name: []const u8) !Value {
                const ctor_obj = try JsObject.create(a, null);
                const ctor_proto_val = try val_mod.makeObject(a, proto_obj);
                try ctor_obj.set("prototype", ctor_proto_val);
                const fn_val = try val_mod.makeNativeFunction(a, ctor_fn);
                // Store the native fn on the ctor object as "__call__".
                try ctor_obj.set("__call__", fn_val);
                // §20.5.x: each Error constructor has `name` (e.g. "TypeError") and
                // `length` 1, both non-enumerable / configurable. assert.throws and
                // Function.prototype.toString rely on `name`.
                const nlen_attr: obj_mod.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
                _ = try ctor_obj.defineOwnData("name", try val_mod.makeString(a, name), nlen_attr);
                _ = try ctor_obj.defineOwnData("length", try val_mod.makeNumber(a, 1), nlen_attr);
                return val_mod.makeObject(a, ctor_obj);
            }
        }.make;

        const error_ctor_val = try makeErrorCtor(arena, nativeErrorCtor, error_proto, "Error");
        const type_error_ctor_val = try makeErrorCtor(arena, nativeTypeErrorCtor, type_error_proto, "TypeError");
        const syntax_error_ctor_val = try makeErrorCtor(arena, nativeSyntaxErrorCtor, syntax_error_proto, "SyntaxError");
        const range_error_ctor_val = try makeErrorCtor(arena, nativeRangeErrorCtor, range_error_proto, "RangeError");
        const reference_error_ctor_val = try makeErrorCtor(arena, nativeReferenceErrorCtor, reference_error_proto, "ReferenceError");
        const aggregate_error_ctor_val = try makeErrorCtor(arena, nativeAggregateErrorCtor, aggregate_error_proto, "AggregateError");
        const eval_error_ctor_val = try makeErrorCtor(arena, nativeEvalErrorCtor, eval_error_proto, "EvalError");
        const uri_error_ctor_val = try makeErrorCtor(arena, nativeUriErrorCtor, uri_error_proto, "URIError");

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
        _ = try object_proto.defineOwnData("hasOwnProperty",
            try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeHasOwnProperty, "hasOwnProperty", 1), meth_attr);
        _ = try object_proto.defineOwnData("propertyIsEnumerable",
            try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativePropertyIsEnumerable, "propertyIsEnumerable", 1), meth_attr);
        _ = try object_proto.defineOwnData("isPrototypeOf",
            try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeObjectIsPrototypeOf, "isPrototypeOf", 1), meth_attr);
        _ = try object_proto.defineOwnData("toString",
            try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoToString, "toString", 0), meth_attr);
        _ = try object_proto.defineOwnData("valueOf",
            try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoValueOf, "valueOf", 0), meth_attr);
        _ = try object_proto.defineOwnData("toLocaleString",
            try val_mod.makeNativeFunctionNamed(arena, array_proto_mod.nativeObjectToLocaleString, "toLocaleString", 0), meth_attr);
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
        _ = try function_proto.defineOwnData("call",
            try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionCall, "call", 1), meth_attr);
        _ = try function_proto.defineOwnData("apply",
            try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionApply, "apply", 2), meth_attr);
        _ = try function_proto.defineOwnData("bind",
            try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeFunctionBind, "bind", 1), meth_attr);
        _ = try function_proto.defineOwnData("toString",
            try val_mod.makeNativeFunctionNamed(arena, nativeFunctionToString, "toString", 0), meth_attr);

        // AddRestrictedFunctionProperties: "caller" and "arguments" are
        // poison-pill accessors whose [[Get]] and [[Set]] are the shared
        // %ThrowTypeError% intrinsic (enumerable:false, configurable:true).
        const thrower = try val_mod.makeNativeFunctionNamed(arena, function_proto_mod.nativeThrowTypeError, "", 0);
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
        try array_ctor_obj.set("prototype", try val_mod.makeObject(arena, array_proto));
        try array_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeArrayCtor));
        try array_ctor_obj.set("isArray", try val_mod.makeNativeFunctionNamed(arena, nativeArrayIsArray, "isArray", 1));
        try array_ctor_obj.set("from", try val_mod.makeNativeFunctionNamed(arena, nativeArrayFrom, "from", 1));
        try array_ctor_obj.set("of", try val_mod.makeNativeFunctionNamed(arena, nativeArrayOf, "of", 0));
        // Array.fromAsync: non-enumerable to satisfy prop-desc test (§23.1.2.1)
        const from_async_attr = obj_mod.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
        _ = try array_ctor_obj.defineOwnData("fromAsync", try val_mod.makeNativeFunctionNamed(arena, nativeArrayFromAsync, "fromAsync", 1), from_async_attr);
        _ = try array_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Array"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try array_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try array_proto.defineOwnData("constructor", try val_mod.makeObject(arena, array_ctor_obj), .{ .writable = true, .enumerable = false, .configurable = true });
        try env.define("Array", try val_mod.makeObject(arena, array_ctor_obj));

        const string_ctor_obj = try JsObject.create(arena, null);
        try string_ctor_obj.set("prototype", try val_mod.makeObject(arena, string_proto));
        try string_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeStringCtor));
        try string_ctor_obj.set("fromCharCode", try val_mod.makeNativeFunctionNamed(arena, nativeStringFromCharCode, "fromCharCode", 1));
        try string_ctor_obj.set("fromCodePoint", try val_mod.makeNativeFunctionNamed(arena, nativeStringFromCodePoint, "fromCodePoint", 1));
        try string_ctor_obj.set("raw", try val_mod.makeNativeFunctionNamed(arena, nativeStringRaw, "raw", 1));
        try string_proto.set("constructor", try val_mod.makeObject(arena, string_ctor_obj));
        _ = try string_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "String"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try string_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("String", try val_mod.makeObject(arena, string_ctor_obj));

        const number_proto = try JsObject.create(arena, object_proto);
        // Number.prototype is itself a Number object with [[NumberData]] = +0.
        try number_proto.set("[[PrimitiveValue]]", try val_mod.makeNumber(arena, 0));
        try number_proto.set("valueOf", try val_mod.makeNativeFunctionNamed(arena, nativeNumberValueOf, "valueOf", 0));
        try number_proto.set("toString", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToString, "toString", 0));
        try number_proto.set("toFixed", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToFixed, "toFixed", 1));
        try number_proto.set("toExponential", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToExponential, "toExponential", 1));
        try number_proto.set("toPrecision", try val_mod.makeNativeFunctionNamed(arena, nativeNumberToPrecision, "toPrecision", 1));
        active_number_proto = number_proto;
        const number_ctor_obj = try JsObject.create(arena, null);
        try number_ctor_obj.set("prototype", try val_mod.makeObject(arena, number_proto));
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
        _ = try number_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Number"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try number_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Number", try val_mod.makeObject(arena, number_ctor_obj));

        // ---- BigInt(value) global (conversion function; literals `1n` lex
        // independently). ponytail: asIntN/asUintN/prototype not added yet.
        const bigint_ctor_obj = try JsObject.create(arena, null);
        try bigint_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeBigIntCtor));
        // BigInt.prototype: real object so `BigInt.prototype.toString = ...` and
        // bigint-primitive autoboxing (`(1n).toString()`) work.
        {
            const bi_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
            const bigint_proto = try JsObject.create(arena, object_proto);
            _ = try bigint_proto.defineOwnData("toString",
                try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoToString, "toString", 0), bi_attr);
            _ = try bigint_proto.defineOwnData("toLocaleString",
                try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoToString, "toLocaleString", 0), bi_attr);
            _ = try bigint_proto.defineOwnData("valueOf",
                try val_mod.makeNativeFunctionNamed(arena, nativeBigIntProtoValueOf, "valueOf", 0), bi_attr);
            if (active_sym_to_string_tag) |tag_sym| {
                _ = try bigint_proto.defineOwnDataSym(tag_sym,
                    try val_mod.makeString(arena, "BigInt"),
                    .{ .writable = false, .enumerable = false, .configurable = true });
            }
            _ = try bigint_proto.defineOwnData("constructor",
                try val_mod.makeObject(arena, bigint_ctor_obj), bi_attr);
            try bigint_ctor_obj.set("prototype", try val_mod.makeObject(arena, bigint_proto));
            active_bigint_proto = bigint_proto;
        }
        _ = try bigint_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "BigInt"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try bigint_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("BigInt", try val_mod.makeObject(arena, bigint_ctor_obj));

        // ---- Function constructor (minimal): callable object so `typeof Function`
        // is "function" and `new Function()` / `Function()` yield a truthy callable.
        // Does NOT compile a body string from arguments.
        const function_ctor_obj = try JsObject.create(arena, null);
        try function_ctor_obj.set("prototype", try val_mod.makeObject(arena, function_proto));
        try function_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeFunctionCtor));
        try function_proto.set("constructor", try val_mod.makeObject(arena, function_ctor_obj));
        _ = try function_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Function"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try function_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
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
        try boolean_ctor_obj.set("prototype", try val_mod.makeObject(arena, boolean_proto));
        try boolean_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeBooleanCtor));
        try boolean_proto.set("constructor", try val_mod.makeObject(arena, boolean_ctor_obj));
        _ = try boolean_ctor_obj.defineOwnData("name", try val_mod.makeString(arena, "Boolean"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try boolean_ctor_obj.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Boolean", try val_mod.makeObject(arena, boolean_ctor_obj));
        try env.define("isNaN", try val_mod.makeNativeFunction(arena, nativeIsNaN));
        try env.define("eval", try val_mod.makeNativeFunction(arena, nativeEval));
        try env.define("isFinite", try val_mod.makeNativeFunction(arena, nativeIsFinite));
        try env.define("parseInt", try val_mod.makeNativeFunctionNamed(arena, nativeParseInt, "parseInt", 2));
        try env.define("parseFloat", try val_mod.makeNativeFunctionNamed(arena, nativeParseFloat, "parseFloat", 1));
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
        try symbol_ctor.set("prototype", try val_mod.makeObject(arena, symbol_proto));
        _ = try symbol_proto.defineOwnData("constructor", try val_mod.makeObject(arena, symbol_ctor), .{ .writable = true, .enumerable = false, .configurable = true });
        // Fresh realm ⇒ fresh per-agent symbol registry. The registry's buffers
        // live in this realm's arena; a stale registry from a prior (freed) realm
        // dangles and causes a use-after-free on the next Symbol.for.
        symbol_mod.resetRegistry();
        try symbol_ctor.set("for", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolFor, "for", 0));
        try symbol_ctor.set("keyFor", try val_mod.makeNativeFunctionNamed(arena, symbol_mod.nativeSymbolKeyFor, "keyFor", 0));
        // Well-known symbols (identity constants; inert in S1).
        const wk_names = [_][]const u8{ "iterator", "asyncIterator", "hasInstance", "isConcatSpreadable", "match", "matchAll", "replace", "search", "split", "species", "toPrimitive", "toStringTag", "unscopables" };
        for (wk_names) |name| {
            const desc = try std.fmt.allocPrint(arena, "Symbol.{s}", .{name});
            // Well-known symbols are non-writable, non-enumerable, non-configurable.
            _ = try symbol_ctor.defineOwnData(name, try val_mod.makeSymbol(arena, desc), .{ .writable = false, .enumerable = false, .configurable = false });
        }
        // Symbol.prototype.constructor === Symbol, and the `description` accessor
        // (a getter holder `{ get: nativeFn }`, matching the live-reexport pattern).
        try symbol_proto.set("constructor", try val_mod.makeObject(arena, symbol_ctor));
        _ = try symbol_ctor.defineOwnData("name", try val_mod.makeString(arena, "Symbol"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try symbol_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
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
            try array_proto.setSym(symv, try val_mod.makeNativeFunction(arena, es2015_collections_mod.nativeArrayValues));
            // String.prototype[@@iterator] — by-code-point iteration (overridable
            // and deletable, so it is a writable/configurable own property).
            try string_proto.setSymAttr(symv, try val_mod.makeNativeFunctionNamed(arena, es2015_collections_mod.nativeStringValues, "[Symbol.iterator]", 0), .{ .writable = true, .enumerable = false, .configurable = true });
        }
        // Capture Symbol.asyncIterator.
        active_sym_async_iterator = symbol_ctor.getOwn("asyncIterator");
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

        // Capture Symbol.toStringTag and Symbol.species.
        active_sym_to_string_tag = symbol_ctor.getOwn("toStringTag");
        if (active_sym_to_string_tag) |symv| {
            // Symbol.prototype[@@toStringTag] = "Symbol" (non-writable/enumerable, configurable).
            _ = try symbol_proto.defineOwnDataSym(symv, try val_mod.makeString(arena, "Symbol"), .{ .writable = false, .enumerable = false, .configurable = true });
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
        try date_mod.registerSymbols(arena);

        // Build the shared %IteratorPrototype% → %ArrayIteratorPrototype% chain
        // now that @@iterator / @@toStringTag exist. Array + TypedArray iterators
        // all inherit from it.
        try es2015_collections_mod.initArrayIteratorProto(arena, object_proto);

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
        _ = try proxy_ctor.defineOwnData("name", try val_mod.makeString(arena, "Proxy"), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try proxy_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 2), .{ .writable = false, .enumerable = false, .configurable = true });
        try env.define("Proxy", try val_mod.makeObject(arena, proxy_ctor));

        // ---- Intl (en-US, dependency-free) ----
        {
            const intl_obj = try JsObject.create(arena, object_proto);
            // Intl.NumberFormat
            const nf_proto = try JsObject.create(arena, object_proto);
            try nf_proto.set("format", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeNumberFormatFormat, "format", 0));
            try nf_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeNumberFormatResolved, "resolvedOptions", 0));
            const nf_ctor = try JsObject.create(arena, null);
            try nf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeNumberFormatCtor));
            try nf_ctor.set("prototype", try val_mod.makeObject(arena, nf_proto));
            _ = try nf_ctor.defineOwnData("name", try val_mod.makeString(arena, "NumberFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try nf_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("NumberFormat", try val_mod.makeObject(arena, nf_ctor));
            // Intl.DateTimeFormat
            const dtf_proto = try JsObject.create(arena, object_proto);
            try dtf_proto.set("format", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDateTimeFormatFormat, "format", 0));
            try dtf_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeDateTimeFormatResolved, "resolvedOptions", 0));
            const dtf_ctor = try JsObject.create(arena, null);
            try dtf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeDateTimeFormatCtor));
            try dtf_ctor.set("prototype", try val_mod.makeObject(arena, dtf_proto));
            _ = try dtf_ctor.defineOwnData("name", try val_mod.makeString(arena, "DateTimeFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try dtf_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("DateTimeFormat", try val_mod.makeObject(arena, dtf_ctor));
            // Intl.Collator
            const col_proto = try JsObject.create(arena, object_proto);
            try col_proto.set("compare", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeCollatorCompare, "compare", 0));
            try col_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeCollatorResolved, "resolvedOptions", 0));
            const col_ctor = try JsObject.create(arena, null);
            try col_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeCollatorCtor));
            try col_ctor.set("prototype", try val_mod.makeObject(arena, col_proto));
            _ = try col_ctor.defineOwnData("name", try val_mod.makeString(arena, "Collator"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try col_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("Collator", try val_mod.makeObject(arena, col_ctor));
            // Intl.Locale
            const loc_proto = try JsObject.create(arena, object_proto);
            try loc_proto.set("toString", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeLocaleToString, "toString", 0));
            const loc_ctor = try JsObject.create(arena, null);
            try loc_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeLocaleCtor));
            try loc_ctor.set("prototype", try val_mod.makeObject(arena, loc_proto));
            _ = try loc_ctor.defineOwnData("name", try val_mod.makeString(arena, "Locale"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try loc_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("Locale", try val_mod.makeObject(arena, loc_ctor));
            // Intl.ListFormat
            const lf_proto = try JsObject.create(arena, object_proto);
            try lf_proto.set("format", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeListFormatFormat, "format", 1));
            try lf_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeListFormatResolved, "resolvedOptions", 0));
            const lf_ctor = try JsObject.create(arena, null);
            try lf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeListFormatCtor));
            try lf_ctor.set("prototype", try val_mod.makeObject(arena, lf_proto));
            _ = try lf_ctor.defineOwnData("name", try val_mod.makeString(arena, "ListFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try lf_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("ListFormat", try val_mod.makeObject(arena, lf_ctor));
            // Intl.PluralRules
            const pr_proto = try JsObject.create(arena, object_proto);
            try pr_proto.set("select", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativePluralRulesSelect, "select", 1));
            try pr_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativePluralRulesResolved, "resolvedOptions", 0));
            const pr_ctor = try JsObject.create(arena, null);
            try pr_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativePluralRulesCtor));
            try pr_ctor.set("prototype", try val_mod.makeObject(arena, pr_proto));
            _ = try pr_ctor.defineOwnData("name", try val_mod.makeString(arena, "PluralRules"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try pr_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("PluralRules", try val_mod.makeObject(arena, pr_ctor));
            // Intl.RelativeTimeFormat
            const rtf_proto = try JsObject.create(arena, object_proto);
            try rtf_proto.set("format", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeRelativeTimeFormatFormat, "format", 2));
            try rtf_proto.set("resolvedOptions", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeRelativeTimeFormatResolved, "resolvedOptions", 0));
            const rtf_ctor = try JsObject.create(arena, null);
            try rtf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeRelativeTimeFormatCtor));
            try rtf_ctor.set("prototype", try val_mod.makeObject(arena, rtf_proto));
            _ = try rtf_ctor.defineOwnData("name", try val_mod.makeString(arena, "RelativeTimeFormat"), .{ .writable = false, .enumerable = false, .configurable = true });
            _ = try rtf_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), .{ .writable = false, .enumerable = false, .configurable = true });
            try intl_obj.set("RelativeTimeFormat", try val_mod.makeObject(arena, rtf_ctor));
            // Intl.getCanonicalLocales (static)
            _ = try intl_obj.defineOwnData("getCanonicalLocales", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeGetCanonicalLocales, "getCanonicalLocales", 1), .{ .writable = true, .enumerable = false, .configurable = true });
            // Intl.supportedValuesOf (static)
            _ = try intl_obj.defineOwnData("supportedValuesOf", try val_mod.makeNativeFunctionNamed(arena, intl_mod.nativeSupportedValuesOf, "supportedValuesOf", 1), .{ .writable = true, .enumerable = false, .configurable = true });
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
                type_error_ctor_val,   syntax_error_ctor_val,
                range_error_ctor_val,  reference_error_ctor_val,
                aggregate_error_ctor_val, eval_error_ctor_val,
                uri_error_ctor_val,
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
    }

    /// Cross-realm: tag every top-level builtin function in this realm's global
    /// scope with this Realm (opaque) so GetFunctionRealm can recover it. Covers
    /// the dynamic `Function` constructor (whose `__call__` entry is what stamps
    /// the realm onto a `new other.Function()` result). Independent of the
    /// thread-locals, so it may run after they have been restored.
    pub fn tagNativeFunctions(self: *Realm) void {
        const r_opaque: *anyopaque = @ptrCast(self);
        var it = self.global_env.bindings.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.value;
            if (v.bits == 0 or !v.isHeapPtr()) continue;
            switch (v.toPtr().*) {
                .native_function, .bc_function => val_mod.setValueRealm(v, r_opaque),
                .object => |o| {
                    if (o.getOwn("__call__")) |cv| {
                        if (cv.bits != 0) val_mod.setValueRealm(cv, r_opaque);
                    }
                },
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
                        try ctor_obj.set("prototype", new_proto_val);
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
                        try ctor_obj.set("prototype", new_proto_val);
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
                const proto_v = ctor.getOwn("prototype") orelse continue;
                if (proto_v.bits == 0 or proto_v.unbox() != .object) continue;
                const child = proto_v.toPtr().object;
                if (child.proto == old_object_proto) child.proto = hp_proto;
            }
        }

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
