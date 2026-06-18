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
// Phase 13 Intl
const intl_mod = @import("./builtins/intl.zig");

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
    /// Set [[Prototype]] of an object OR bc_function (materializing the closure's
    /// backing object). Used by Object.setPrototypeOf for class static inheritance.
    set_proto_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, obj_val: Value, proto: ?*JsObject) anyerror!void,
    /// Resolve a value to its property-bearing JsObject: an object returns
    /// itself; a bc_function materializes (lazily creates) its backing object;
    /// non-property-bearing values (primitives, native_function) return null.
    /// Lets generic object ops (defineProperty, getOwnPropertyDescriptor) treat
    /// functions as the objects they are.
    backing_obj_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, val: Value) anyerror!?*JsObject,

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

    pub fn setProto(self: *Context, arena: std.mem.Allocator, obj_val: Value, proto: ?*JsObject) anyerror!void {
        return self.set_proto_fn(self.ptr, arena, obj_val, proto);
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
    var proto: ?*JsObject = null;
    if (args.len > 0) {
        const a = args[0];
        if (a.bits != 0) {
            switch (a.unbox()) {
                .object => |obj| proto = obj,
                .null_ => proto = null,
                else => {},
            }
        }
    }
    // Allocate on the active heap if available, otherwise fallback to arena.
    // Always use `arena` for the JsValue wrapper (it's eval-arena-lifetime).
    if (active_heap) |heap| {
        const obj = try JsObject.createOnHeap(heap, proto);
        return val_mod.makeObject(arena, obj);
    }
    // Fallback: arena (when heap not yet wired, e.g., tree-walker path).
    const obj = try JsObject.create(arena, proto);
    return val_mod.makeObject(arena, obj);
}

/// Minimal CommonJS-style host shim:
/// require(name) reads from global __modules__[name] when present.
fn nativeRequire(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return val_mod.makeUndefined(arena);
    }
    const name = args[0].toPtr().string;
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
    if (modules_obj.get(lookup_name)) |entry| {
        if (entry.bits != 0 and entry.unbox() == .object) {
            const mod_obj = entry.toPtr().object;
            if (mod_obj.get("exports")) |exports_val| {
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
            _ = function_proto_mod.invokeCallback(
                arena,
                exports_val,
                entry,
                &[_]Value{ require_fn, module_val, exports_val },
            ) catch return val_mod.makeUndefined(arena);
            const final_exports = module_obj.get("exports") orelse exports_val;
            try module_obj.set("loaded", try val_mod.makeBool(arena, true));
            return final_exports;
        }
        try syncRequireCache(env, lookup_name, entry);
        return entry;
    }
    return throwModuleNotFound(arena, name);
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

/// M16 Phase 3: dynamic `import(specifier)`. Desugared by the parser to a call
/// `__import__(specifier)`. Resolves and loads the module through the same
/// `__modules__` registry + `require()` resolver used by static imports, wraps
/// the resulting live `exports` in a Module Namespace exotic object, and hands
/// back a Promise (ES §16.2.1.8 ImportCall): fulfilled with the namespace, or
/// rejected with whatever the resolve/evaluation threw. The specifier argument
/// is already evaluated by the VM before this native runs, so an abrupt
/// specifier expression propagates synchronously (never as a rejection).
pub fn nativeImport(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
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
    // A fresh promise per call (ImportCall NewPromiseCapability) fulfilled with
    // the namespace. `nativePromiseResolve` only short-circuits for a promise
    // argument; a namespace is an ordinary object, so a new promise is created.
    return promise_mod.nativePromiseResolve(arena, Value{}, &[_]Value{ns});
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
pub var active_promise_proto: ?*JsObject = null;
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
/// Phase 13: private symbols storing a Proxy's [[ProxyTarget]]/[[ProxyHandler]]
/// as GC-traced symbol-keyed own properties.
pub var active_sym_proxy_target: ?Value = null;
pub var active_sym_proxy_handler: ?Value = null;
/// M16: private symbol caching a module's namespace exotic object on its live
/// exports object, so GetModuleNamespace returns the *same* object each time
/// (`import * as a` and `import * as b` of one module compare ===).
pub var active_sym_module_ns: ?Value = null;

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
        return this_val;
    }
    // Fallback: create new object with the right proto.
    const proto: ?*JsObject = null;
    return createErrorObj(arena, proto, name, message);
}

fn nativeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return populateErrorThis(arena, this_val, "Error", extractMessage(args));
}

fn nativeTypeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return populateErrorThis(arena, this_val, "TypeError", extractMessage(args));
}

fn nativeSyntaxErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return populateErrorThis(arena, this_val, "SyntaxError", extractMessage(args));
}

fn nativeRangeErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return populateErrorThis(arena, this_val, "RangeError", extractMessage(args));
}

fn nativeReferenceErrorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return populateErrorThis(arena, this_val, "ReferenceError", extractMessage(args));
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
            .string, .symbol, .bigint => active_object_proto,
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
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_, .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
}

fn isTruthyValue(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len != 0,
        .undefined_, .null_ => false,
        else => true,
    };
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

fn stringPrimitive(arena: std.mem.Allocator, arg: Value) anyerror![]const u8 {
    if (arg.bits == 0) return "undefined";
    return switch (arg.unbox()) {
        .string => |s| s,
        .number => |n| try val_mod.formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .null_ => "null",
        .undefined_ => "undefined",
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
    const s: []const u8 = if (args.len == 0) "" else try stringPrimitive(arena, args[0]);
    // `new String(x)`: wrap on the synthesized object; plain call returns primitive.
    if (constructing and this_val.bits != 0 and this_val.unbox() == .object) {
        try this_val.toPtr().object.set("[[PrimitiveValue]]", try val_mod.makeString(arena, s));
        return this_val;
    }
    return val_mod.makeString(arena, s);
}

fn nativeStringFromCharCode(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) return val_mod.makeString(arena, "");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (args) |arg| {
        if (arg.bits != 0 and arg.unbox() == .number) {
            const code: u32 = @intFromFloat(@mod(arg.unbox().number, 65536));
            if (code < 128 and len < buf.len) {
                buf[len] = @intCast(code);
                len += 1;
            }
        }
    }
    return val_mod.makeString(arena, try arena.dupe(u8, buf[0..len]));
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

fn nativeParseFloat(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return val_mod.makeNumber(arena, std.math.nan(f64));
    }
    const s = std.mem.trimLeft(u8, args[0].toPtr().string, &std.ascii.whitespace);
    // Find the longest valid float prefix.
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
    if (end == 0) return val_mod.makeNumber(arena, std.math.nan(f64));
    const parsed = std.fmt.parseFloat(f64, s[0..end]) catch std.math.nan(f64);
    return val_mod.makeNumber(arena, parsed);
}

fn nativeParseInt(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .string) {
        return val_mod.makeNumber(arena, std.math.nan(f64));
    }
    var s = std.mem.trimLeft(u8, args[0].toPtr().string, &std.ascii.whitespace);
    var radix: u8 = 10;
    if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .number) {
        const r = args[1].unbox().number;
        if (r >= 2 and r <= 36) radix = @intFromFloat(r);
    }
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if ((radix == 16 or radix == 10) and s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        radix = 16;
        s = s[2..];
    }
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const d = std.fmt.charToDigit(s[end], radix) catch break;
        _ = d;
    }
    if (end == 0) return val_mod.makeNumber(arena, std.math.nan(f64));
    const val = std.fmt.parseInt(i64, s[0..end], radix) catch return val_mod.makeNumber(arena, std.math.nan(f64));
    const f: f64 = @floatFromInt(val);
    return val_mod.makeNumber(arena, if (neg) -f else f);
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
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .null_, .undefined_ => false,
        else => true,
    };
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
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
            if (trimmed.len == 0) break :blk 0;
            break :blk std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
        },
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
            const t = std.mem.trim(u8, s, " \t\r\n");
            return val_mod.makeBigIntFromLiteral(arena, if (t.len == 0) "0" else t) catch
                throwTypeError(arena, "Cannot convert string to a BigInt");
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

fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const eo = if (active_heap) |h| try JsObject.createOnHeap(h, error_proto_RangeError) else try JsObject.create(arena, error_proto_RangeError);
    try eo.set("message", try val_mod.makeString(arena, msg));
    try eo.set("name", try val_mod.makeString(arena, "RangeError"));
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
fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
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

fn nativeNumberToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const n = thisNumber(this_val) orelse return throwTypeError(arena, "Number.prototype.toString requires a Number");
    return val_mod.makeString(arena, try val_mod.formatNumber(arena, n));
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

// ---- Object.prototype.toString / valueOf ----
fn nativeObjectProtoToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    // ES 20.1.3.6: "[object " + builtinTag + "]". undefined/null get special tags.
    if (this_val.bits == 0) return val_mod.makeString(arena, "[object Undefined]");
    const builtin_tag: []const u8 = switch (this_val.unbox()) {
        .undefined_ => "Undefined",
        .null_ => "Null",
        .object => |obj| if (obj.is_array) "Array" else if (obj.get("__call__") != null) "Function" else "Object",
        .function, .bc_function, .native_function => "Function",
        else => "Object",
    };
    // ES 20.1.3.6 step 16: check @@toStringTag, override for non-Undefined/Null.
    if (this_val.unbox() != .undefined_ and this_val.unbox() != .null_) {
        if (active_sym_to_string_tag) |tag_sym| {
            if (this_val.unbox() == .object) {
                const obj = this_val.unbox().object;
                if (obj.getSym(tag_sym)) |tv| {
                    const s = tv.unbox();
                    if (s == .string) {
                        return val_mod.makeString(arena, try std.fmt.allocPrint(arena, "[object {s}]", .{s.string}));
                    }
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

fn nativeFunctionCtor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // `new Function(p1, …, pN, body)`: assemble `(function anonymous(p1,…){body})`
    // and compile it through the eval bridge, returning the function value.
    // ponytail: string args only (ToString of non-strings skipped); covers
    // `new Function("a","return a")` and `new Function("return class … {}")`.
    if (active_context) |ctx| {
        var src = std.ArrayList(u8){};
        try src.appendSlice(arena, "(function anonymous(");
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
        return ctx.evalSource(arena, src.items);
    }
    // No active VM (shouldn't happen during eval): empty callable.
    const o = if (active_heap) |h|
        try JsObject.createOnHeap(h, active_function_proto)
    else
        try JsObject.create(arena, active_function_proto);
    try o.set("__call__", try val_mod.makeNativeFunction(arena, nativeNoop));
    return val_mod.makeObject(arena, o);
}

// ---- Function.prototype.toString ----
fn nativeFunctionToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    var name: []const u8 = "";
    if (this_val.bits != 0) {
        switch (this_val.unbox()) {
            .bc_function => |c| name = c.func.name orelse "",
            else => {},
        }
    }
    const s = try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{name});
    return val_mod.makeString(arena, s);
}

// ---------------------------------------------------------------- Phase 4b registration helpers ---

fn registerStringProto(arena: std.mem.Allocator, proto: *JsObject) !void {
    const fns = .{
        .{ "charAt", string_proto_mod.nativeCharAt },
        .{ "charCodeAt", string_proto_mod.nativeCharCodeAt },
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
    };
    const str_method_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    inline for (fns) |pair| {
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], 0);
        _ = try proto.defineOwnData(pair[0], fn_val, str_method_attr);
    }
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
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], 0);
        _ = try proto.defineOwnData(pair[0], fn_val, method_attr);
    }
}

/// Build a plain object mirroring global env bindings and expose as globalThis/global.
fn installGlobalThis(arena: std.mem.Allocator, env: *Environment, object_proto: *JsObject) !void {
    const global_obj = try JsObject.create(arena, object_proto);
    var it = env.bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len >= 2 and name[0] == '_' and name[1] == '_') continue;
        _ = try global_obj.defineOwnData(name, entry.value_ptr.value, .{ .writable = true, .enumerable = false, .configurable = true });
    }
    const global_val = try val_mod.makeObject(arena, global_obj);
    try env.define("globalThis", global_val);
    try env.define("global", global_val);
}

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

        // Set thread-local proto pointers so native ctors can find them.
        error_proto_Error = error_proto;
        error_proto_TypeError = type_error_proto;
        error_proto_SyntaxError = syntax_error_proto;
        error_proto_RangeError = range_error_proto;
        error_proto_ReferenceError = reference_error_proto;
        error_proto_AggregateError = aggregate_error_proto;

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

        // Spec: ErrorPrototype.constructor = ErrorConstructor (non-enumerable, writable, configurable).
        // Required for `thrown.constructor === TypeError` identity checks in assert.throws.
        const ctor_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
        _ = try error_proto.defineOwnData("constructor", error_ctor_val, ctor_attr);
        _ = try type_error_proto.defineOwnData("constructor", type_error_ctor_val, ctor_attr);
        _ = try syntax_error_proto.defineOwnData("constructor", syntax_error_ctor_val, ctor_attr);
        _ = try range_error_proto.defineOwnData("constructor", range_error_ctor_val, ctor_attr);
        _ = try reference_error_proto.defineOwnData("constructor", reference_error_ctor_val, ctor_attr);
        _ = try aggregate_error_proto.defineOwnData("constructor", aggregate_error_ctor_val, ctor_attr);

        try env.define("Error", error_ctor_val);
        try env.define("TypeError", type_error_ctor_val);
        try env.define("SyntaxError", syntax_error_ctor_val);
        try env.define("RangeError", range_error_ctor_val);
        try env.define("ReferenceError", reference_error_ctor_val);
        try env.define("AggregateError", aggregate_error_ctor_val);

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
                const keys_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectKeys);
                const values_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectValues);
                try ctor_obj.set("keys", keys_fn);
                try ctor_obj.set("values", values_fn);
                const entries_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectEntries);
                try ctor_obj.set("entries", entries_fn);
                const from_entries_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectFromEntries);
                try ctor_obj.set("fromEntries", from_entries_fn);
                const gopd_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectGetOwnPropertyDescriptors);
                try ctor_obj.set("getOwnPropertyDescriptors", gopd_fn);
                try ctor_obj.set("getPrototypeOf", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectGetPrototypeOf));
                try ctor_obj.set("setPrototypeOf", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectSetPrototypeOf));
                try ctor_obj.set("getOwnPropertyNames", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectGetOwnPropertyNames));
                try ctor_obj.set("getOwnPropertyDescriptor", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectGetOwnPropertyDescriptor));
                try ctor_obj.set("defineProperty", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectDefineProperty));
                try ctor_obj.set("defineProperties", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectDefineProperties));
                try ctor_obj.set("freeze", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectFreeze));
                try ctor_obj.set("seal", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectSeal));
                try ctor_obj.set("preventExtensions", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectPreventExtensions));
                try ctor_obj.set("isFrozen", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectIsFrozen));
                try ctor_obj.set("isSealed", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectIsSealed));
                try ctor_obj.set("isExtensible", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectIsExtensible));
                try ctor_obj.set("getOwnPropertySymbols", try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectGetOwnPropertySymbols));
            }
        }
        // hasOwnProperty on Object.prototype (non-enumerable, writable, configurable)
        const meth_attr: obj_mod.PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
        _ = try object_proto.defineOwnData("hasOwnProperty",
            try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativeHasOwnProperty, "hasOwnProperty", 1), meth_attr);
        _ = try object_proto.defineOwnData("propertyIsEnumerable",
            try val_mod.makeNativeFunctionNamed(arena, obj_methods_mod.nativePropertyIsEnumerable, "propertyIsEnumerable", 1), meth_attr);
        _ = try object_proto.defineOwnData("toString",
            try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoToString, "toString", 0), meth_attr);
        _ = try object_proto.defineOwnData("valueOf",
            try val_mod.makeNativeFunctionNamed(arena, nativeObjectProtoValueOf, "valueOf", 0), meth_attr);
        _ = try object_proto.defineOwnData("toLocaleString",
            try val_mod.makeNativeFunctionNamed(arena, array_proto_mod.nativeObjectToLocaleString, "toLocaleString", 0), meth_attr);

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
        try require_obj.set("resolve", try val_mod.makeNativeFunction(arena, nativeRequireResolve));
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
        try env.define("Array", try val_mod.makeObject(arena, array_ctor_obj));

        const string_ctor_obj = try JsObject.create(arena, null);
        try string_ctor_obj.set("prototype", try val_mod.makeObject(arena, string_proto));
        try string_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeStringCtor));
        try string_ctor_obj.set("fromCharCode", try val_mod.makeNativeFunction(arena, nativeStringFromCharCode));
        try string_proto.set("constructor", try val_mod.makeObject(arena, string_ctor_obj));
        try env.define("String", try val_mod.makeObject(arena, string_ctor_obj));

        const number_proto = try JsObject.create(arena, object_proto);
        // Number.prototype is itself a Number object with [[NumberData]] = +0.
        try number_proto.set("[[PrimitiveValue]]", try val_mod.makeNumber(arena, 0));
        try number_proto.set("valueOf", try val_mod.makeNativeFunction(arena, nativeNumberValueOf));
        try number_proto.set("toString", try val_mod.makeNativeFunction(arena, nativeNumberToString));
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
        try env.define("BigInt", try val_mod.makeObject(arena, bigint_ctor_obj));

        // ---- Function constructor (minimal): callable object so `typeof Function`
        // is "function" and `new Function()` / `Function()` yield a truthy callable.
        // Does NOT compile a body string from arguments.
        const function_ctor_obj = try JsObject.create(arena, null);
        try function_ctor_obj.set("prototype", try val_mod.makeObject(arena, function_proto));
        try function_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeFunctionCtor));
        try function_proto.set("constructor", try val_mod.makeObject(arena, function_ctor_obj));
        try env.define("Function", try val_mod.makeObject(arena, function_ctor_obj));

        // ---- Phase 4: global functions + value globals ----
        const boolean_proto = try JsObject.create(arena, object_proto);
        // Boolean.prototype is itself a Boolean object with [[BooleanData]] = false.
        try boolean_proto.set("[[PrimitiveValue]]", try val_mod.makeBool(arena, false));
        try boolean_proto.set("valueOf", try val_mod.makeNativeFunction(arena, nativeBooleanValueOf));
        try boolean_proto.set("toString", try val_mod.makeNativeFunction(arena, nativeBooleanToString));
        active_boolean_proto = boolean_proto;
        const boolean_ctor_obj = try JsObject.create(arena, null);
        try boolean_ctor_obj.set("prototype", try val_mod.makeObject(arena, boolean_proto));
        try boolean_ctor_obj.set("__call__", try val_mod.makeNativeFunction(arena, nativeBooleanCtor));
        try boolean_proto.set("constructor", try val_mod.makeObject(arena, boolean_ctor_obj));
        try env.define("Boolean", try val_mod.makeObject(arena, boolean_ctor_obj));
        try env.define("isNaN", try val_mod.makeNativeFunction(arena, nativeIsNaN));
        try env.define("eval", try val_mod.makeNativeFunction(arena, nativeEval));
        try env.define("isFinite", try val_mod.makeNativeFunction(arena, nativeIsFinite));
        try env.define("parseInt", try val_mod.makeNativeFunction(arena, nativeParseInt));
        try env.define("parseFloat", try val_mod.makeNativeFunction(arena, nativeParseFloat));
        try env.define("NaN", try val_mod.makeNumber(arena, std.math.nan(f64)));
        try env.define("Infinity", try val_mod.makeNumber(arena, std.math.inf(f64)));

        // ---- console global ----
        try console_mod.register(&reg_ctx);

        // ---- ES2015 Symbol ----
        const symbol_proto = try JsObject.create(arena, object_proto);
        try symbol_proto.set("toString", try val_mod.makeNativeFunction(arena, symbol_mod.nativeSymbolToString));
        active_symbol_proto = symbol_proto;
        const symbol_ctor = try JsObject.create(arena, null);
        try symbol_ctor.set("__call__", try val_mod.makeNativeFunction(arena, symbol_mod.nativeSymbolCall));
        try symbol_ctor.set("prototype", try val_mod.makeObject(arena, symbol_proto));
        // Fresh realm ⇒ fresh per-agent symbol registry. The registry's buffers
        // live in this realm's arena; a stale registry from a prior (freed) realm
        // dangles and causes a use-after-free on the next Symbol.for.
        symbol_mod.resetRegistry();
        try symbol_ctor.set("for", try val_mod.makeNativeFunction(arena, symbol_mod.nativeSymbolFor));
        try symbol_ctor.set("keyFor", try val_mod.makeNativeFunction(arena, symbol_mod.nativeSymbolKeyFor));
        // Well-known symbols (identity constants; inert in S1).
        const wk_names = [_][]const u8{ "iterator", "asyncIterator", "hasInstance", "isConcatSpreadable", "match", "replace", "search", "split", "species", "toPrimitive", "toStringTag", "unscopables" };
        for (wk_names) |name| {
            const desc = try std.fmt.allocPrint(arena, "Symbol.{s}", .{name});
            try symbol_ctor.set(name, try val_mod.makeSymbol(arena, desc));
        }
        try env.define("Symbol", try val_mod.makeObject(arena, symbol_ctor));
        // Capture Symbol.iterator and register Array.prototype[Symbol.iterator].
        active_sym_iterator = symbol_ctor.getOwn("iterator");
        if (active_sym_iterator) |symv| {
            try array_proto.setSym(symv, try val_mod.makeNativeFunction(arena, es2015_collections_mod.nativeArrayValues));
        }
        // Capture Symbol.toPrimitive and give Date the spec-correct hook so
        // `date + x` coerces to a string (default hint) rather than a number.
        active_sym_to_primitive = symbol_ctor.getOwn("toPrimitive");
        if (active_sym_to_primitive) |symv| {
            if (date_mod.active_date_proto) |dp| {
                try dp.setSym(symv, try val_mod.makeNativeFunction(arena, date_mod.nativeDateToPrimitive));
            }
        }
        // Capture Symbol.toStringTag and Symbol.species.
        active_sym_to_string_tag = symbol_ctor.getOwn("toStringTag");
        active_sym_species = symbol_ctor.getOwn("species");
        // Wire @@toStringTag + @@species onto TypedArray/ArrayBuffer/DataView protos+ctors now
        // that the well-known symbols exist (register() ran before Symbol init).
        try typed_array_mod.registerSymbols(arena);

        // Build the shared %IteratorPrototype% → %ArrayIteratorPrototype% chain
        // now that @@iterator / @@toStringTag exist. Array + TypedArray iterators
        // all inherit from it.
        try es2015_collections_mod.initArrayIteratorProto(arena, object_proto);

        // ---- ES2015 Reflect ----
        try reflect_mod.register(&reg_ctx);

        // ---- ES2015 Proxy ----
        active_sym_proxy_target = try val_mod.makeSymbol(arena, "[[ProxyTarget]]");
        active_sym_proxy_handler = try val_mod.makeSymbol(arena, "[[ProxyHandler]]");
        active_sym_module_ns = try val_mod.makeSymbol(arena, "[[Module.Namespace]]");
        const proxy_ctor = try JsObject.create(arena, null);
        try proxy_ctor.set("__call__", try val_mod.makeNativeFunction(arena, proxy_mod.nativeProxyCtor));
        try env.define("Proxy", try val_mod.makeObject(arena, proxy_ctor));

        // ---- Intl (en-US, dependency-free) ----
        {
            const intl_obj = try JsObject.create(arena, object_proto);
            // Intl.NumberFormat
            const nf_proto = try JsObject.create(arena, object_proto);
            try nf_proto.set("format", try val_mod.makeNativeFunction(arena, intl_mod.nativeNumberFormatFormat));
            const nf_ctor = try JsObject.create(arena, null);
            try nf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeNumberFormatCtor));
            try nf_ctor.set("prototype", try val_mod.makeObject(arena, nf_proto));
            try intl_obj.set("NumberFormat", try val_mod.makeObject(arena, nf_ctor));
            // Intl.DateTimeFormat
            const dtf_proto = try JsObject.create(arena, object_proto);
            try dtf_proto.set("format", try val_mod.makeNativeFunction(arena, intl_mod.nativeDateTimeFormatFormat));
            const dtf_ctor = try JsObject.create(arena, null);
            try dtf_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeDateTimeFormatCtor));
            try dtf_ctor.set("prototype", try val_mod.makeObject(arena, dtf_proto));
            try intl_obj.set("DateTimeFormat", try val_mod.makeObject(arena, dtf_ctor));
            // Intl.Collator
            const col_proto = try JsObject.create(arena, object_proto);
            try col_proto.set("compare", try val_mod.makeNativeFunction(arena, intl_mod.nativeCollatorCompare));
            const col_ctor = try JsObject.create(arena, null);
            try col_ctor.set("__call__", try val_mod.makeNativeFunction(arena, intl_mod.nativeCollatorCtor));
            try col_ctor.set("prototype", try val_mod.makeObject(arena, col_proto));
            try intl_obj.set("Collator", try val_mod.makeObject(arena, col_ctor));
            try env.define("Intl", try val_mod.makeObject(arena, intl_obj));
        }

        // ---- ES2020 globalThis (+ Node-compatible `global`) ----
        try installGlobalThis(arena, env, object_proto);

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
        };
    }

    /// Wire in a GC heap and register Realm intrinsics as roots.
    pub fn activateHeap(self: *Realm, heap: *Heap) !void {
        self.heap = heap;
        active_heap = heap;

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

        // Reallocate intrinsics on the heap so they have proper GcHeaders and
        // will be visited during mark. Register them as roots so they survive collect.
        const hp_proto = try heap.allocateObject(null);
        // Copy properties from arena object to heap object, preserving attrs.
        for (self.object_prototype.ownKeys()) |k| {
            const v = self.object_prototype.getOwn(k).?;
            const a = self.object_prototype.ownAttr(k) orelse obj_mod.PropAttr{};
            _ = try hp_proto.defineOwnData(k, v, a);
        }
        for (self.object_prototype.sym_props.items) |sp| {
            try hp_proto.setSymAttr(sp.key, sp.value, sp.attr);
        }

        const hp_array_proto = try heap.allocateObject(hp_proto);
        for (self.array_prototype.ownKeys()) |k| {
            const v = self.array_prototype.getOwn(k).?;
            const a = self.array_prototype.ownAttr(k) orelse obj_mod.PropAttr{};
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
