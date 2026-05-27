// SPDX-License-Identifier: MIT
//! Phase 3a/3b/4a/4b Realm: holds global Environment, Object.prototype, Array.prototype,
//! the Object constructor, Error constructors, Math, JSON, String/Array/Object builtins,
//! and (Phase 3b) the GC Heap.
const std = @import("std");
const Environment = @import("./execution_context.zig").Environment;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../object/object.zig").JsObject;
const Heap = @import("../gc/heap.zig").Heap;

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

// ---------------------------------------------------------------- Context interface ---

/// Opaque context that allows native callbacks to re-enter the JS interpreter.
/// Set by both VMs at their eval entry point, cleared on exit.
pub const Context = struct {
    /// Opaque pointer to the VM instance.
    ptr: *anyopaque,
    /// Invoke a JS function value with given this/args. Returns Value or sets
    /// pending_exception + returns error.JsException.
    invoke_fn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value,

    pub fn invokeJs(self: *Context, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
        return self.invoke_fn(self.ptr, arena, this_val, fn_val, args);
    }
};

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
            switch (a.toPtr().*) {
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

/// Thread-local pointer to the currently active Heap.
/// Set by Realm.activateHeap(), cleared on deinit.
pub var active_heap: ?*Heap = null;

/// Phase 4b: thread-locals for prototype access from builtin fns.
pub var active_array_proto: ?*JsObject = null;
pub var active_object_proto: ?*JsObject = null;
/// Phase 4b: thread-local for String.prototype (autoboxing lookup).
pub var active_string_proto: ?*JsObject = null;
/// Phase 4c: thread-local for RegExp.prototype.
pub var active_regexp_proto: ?*JsObject = null;
/// Phase 4d: thread-local for Function.prototype.
pub var active_function_proto: ?*JsObject = null;

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

fn extractMessage(args: []const Value) []const u8 {
    if (args.len > 0 and args[0].bits != 0) {
        return switch (args[0].toPtr().*) {
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
    if (this_val.bits != 0 and this_val.toPtr().* == .object) {
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

// ---------------------------------------------------------------- Phase 4b registration helpers ---

fn registerStringProto(arena: std.mem.Allocator, proto: *JsObject) !void {
    const fns = .{
        .{ "charAt",     string_proto_mod.nativeCharAt },
        .{ "charCodeAt", string_proto_mod.nativeCharCodeAt },
        .{ "indexOf",    string_proto_mod.nativeIndexOf },
        .{ "slice",      string_proto_mod.nativeSlice },
        .{ "toUpperCase", string_proto_mod.nativeToUpperCase },
        .{ "toLowerCase", string_proto_mod.nativeToLowerCase },
        .{ "split",      string_proto_mod.nativeSplit },
        .{ "concat",     string_proto_mod.nativeConcat },
        .{ "trim",       string_proto_mod.nativeTrim },
        // Phase 4c: regex-aware string methods
        .{ "match",      string_proto_mod.nativeMatch },
        .{ "replace",    string_proto_mod.nativeReplace },
        .{ "search",     string_proto_mod.nativeSearch },
    };
    inline for (fns) |pair| {
        const fn_val = try val_mod.makeNativeFunction(arena, pair[1]);
        try proto.set(pair[0], fn_val);
    }
}

fn registerArrayProto(arena: std.mem.Allocator, proto: *JsObject) !void {
    const fns = .{
        .{ "push",        array_proto_mod.nativePush },
        .{ "pop",         array_proto_mod.nativePop },
        .{ "slice",       array_proto_mod.nativeSlice },
        .{ "indexOf",     array_proto_mod.nativeIndexOf },
        .{ "join",        array_proto_mod.nativeJoin },
        .{ "concat",      array_proto_mod.nativeConcat },
        // Phase 4d: callback methods
        .{ "forEach",     array_proto_mod.nativeForEach },
        .{ "map",         array_proto_mod.nativeMap },
        .{ "filter",      array_proto_mod.nativeFilter },
        .{ "reduce",      array_proto_mod.nativeReduce },
        .{ "reduceRight", array_proto_mod.nativeReduceRight },
        .{ "some",        array_proto_mod.nativeSome },
        .{ "every",       array_proto_mod.nativeEvery },
        .{ "find",        array_proto_mod.nativeFind },
        .{ "findIndex",   array_proto_mod.nativeFindIndex },
        .{ "sort",        array_proto_mod.nativeSort },
    };
    inline for (fns) |pair| {
        const fn_val = try val_mod.makeNativeFunction(arena, pair[1]);
        try proto.set(pair[0], fn_val);
    }
}

fn registerMath(arena: std.mem.Allocator, obj: *JsObject) !void {
    // Constants
    const pi_val = try val_mod.makeNumber(arena, std.math.pi);
    const e_val = try val_mod.makeNumber(arena, std.math.e);
    const ln2_val = try val_mod.makeNumber(arena, std.math.ln2);
    const ln10_val = try val_mod.makeNumber(arena, std.math.ln10);
    const log2e_val = try val_mod.makeNumber(arena, std.math.log2e);
    const log10e_val = try val_mod.makeNumber(arena, std.math.log10e);
    const sqrt2_val = try val_mod.makeNumber(arena, std.math.sqrt2);
    const sqrt1_2_val = try val_mod.makeNumber(arena, 1.0 / std.math.sqrt2);
    try obj.set("PI", pi_val);
    try obj.set("E", e_val);
    try obj.set("LN2", ln2_val);
    try obj.set("LN10", ln10_val);
    try obj.set("LOG2E", log2e_val);
    try obj.set("LOG10E", log10e_val);
    try obj.set("SQRT2", sqrt2_val);
    try obj.set("SQRT1_2", sqrt1_2_val);

    // Functions
    const func_fns = .{
        .{ "abs",    math_mod.nativeAbs },
        .{ "floor",  math_mod.nativeFloor },
        .{ "ceil",   math_mod.nativeCeil },
        .{ "round",  math_mod.nativeRound },
        .{ "trunc",  math_mod.nativeTrunc },
        .{ "sqrt",   math_mod.nativeSqrt },
        .{ "pow",    math_mod.nativePow },
        .{ "exp",    math_mod.nativeExp },
        .{ "log",    math_mod.nativeLog },
        .{ "sin",    math_mod.nativeSin },
        .{ "cos",    math_mod.nativeCos },
        .{ "tan",    math_mod.nativeTan },
        .{ "min",    math_mod.nativeMin },
        .{ "max",    math_mod.nativeMax },
        .{ "random", math_mod.nativeRandom },
    };
    inline for (func_fns) |pair| {
        const fn_val = try val_mod.makeNativeFunction(arena, pair[1]);
        try obj.set(pair[0], fn_val);
    }
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

        // Also expose Object.prototype on the constructor.
        const proto_val = try val_mod.makeObject(arena, object_proto);
        try object_ctor.set("prototype", proto_val);

        // Define "Object" in global env as the constructor object.
        const ctor_val = try val_mod.makeObject(arena, object_ctor);
        try env.define("Object", ctor_val);

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

        // Set thread-local proto pointers so native ctors can find them.
        error_proto_Error = error_proto;
        error_proto_TypeError = type_error_proto;
        error_proto_SyntaxError = syntax_error_proto;
        error_proto_RangeError = range_error_proto;
        error_proto_ReferenceError = reference_error_proto;

        // Create Error constructor objects. Each has a .prototype property
        // and a hidden __proto__ marker so `instanceof` can find the prototype.
        const makeErrorCtor = struct {
            fn make(a: std.mem.Allocator, ctor_fn: val_mod.NativeFnPtr, proto_obj: *JsObject) !Value {
                const ctor_obj = try JsObject.create(a, null);
                const ctor_proto_val = try val_mod.makeObject(a, proto_obj);
                try ctor_obj.set("prototype", ctor_proto_val);
                const fn_val = try val_mod.makeNativeFunction(a, ctor_fn);
                // Store the native fn on the ctor object as "__call__".
                try ctor_obj.set("__call__", fn_val);
                return val_mod.makeObject(a, ctor_obj);
            }
        }.make;

        const error_ctor_val = try makeErrorCtor(arena, nativeErrorCtor, error_proto);
        const type_error_ctor_val = try makeErrorCtor(arena, nativeTypeErrorCtor, type_error_proto);
        const syntax_error_ctor_val = try makeErrorCtor(arena, nativeSyntaxErrorCtor, syntax_error_proto);
        const range_error_ctor_val = try makeErrorCtor(arena, nativeRangeErrorCtor, range_error_proto);
        const reference_error_ctor_val = try makeErrorCtor(arena, nativeReferenceErrorCtor, reference_error_proto);

        try env.define("Error", error_ctor_val);
        try env.define("TypeError", type_error_ctor_val);
        try env.define("SyntaxError", syntax_error_ctor_val);
        try env.define("RangeError", range_error_ctor_val);
        try env.define("ReferenceError", reference_error_ctor_val);

        // Also store prototypes under hidden names so vm.zig's getErrorProto can find them.
        const error_proto_val = try val_mod.makeObject(arena, error_proto);
        const type_error_proto_val = try val_mod.makeObject(arena, type_error_proto);
        const syntax_error_proto_val = try val_mod.makeObject(arena, syntax_error_proto);
        const range_error_proto_val = try val_mod.makeObject(arena, range_error_proto);
        const reference_error_proto_val = try val_mod.makeObject(arena, reference_error_proto);
        try env.define("__ErrorProto__", error_proto_val);
        try env.define("__TypeErrorProto__", type_error_proto_val);
        try env.define("__SyntaxErrorProto__", syntax_error_proto_val);
        try env.define("__RangeErrorProto__", range_error_proto_val);
        try env.define("__ReferenceErrorProto__", reference_error_proto_val);

        // ---- Phase 4b: String.prototype ----
        const string_proto = try JsObject.create(arena, object_proto);
        try registerStringProto(arena, string_proto);

        // ---- Phase 4b: Array.prototype methods ----
        try registerArrayProto(arena, array_proto);

        // ---- Phase 4b: Object static methods + hasOwnProperty ----
        // Add keys/values to the existing Object constructor.
        if (env.bindings.getPtr("Object")) |obj_val_ptr| {
            if (obj_val_ptr.bits != 0 and obj_val_ptr.toPtr().* == .object) {
                const ctor_obj = obj_val_ptr.toPtr().object;
                const keys_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectKeys);
                const values_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeObjectValues);
                try ctor_obj.set("keys", keys_fn);
                try ctor_obj.set("values", values_fn);
            }
        }
        // hasOwnProperty on Object.prototype
        const hop_fn = try val_mod.makeNativeFunction(arena, obj_methods_mod.nativeHasOwnProperty);
        try object_proto.set("hasOwnProperty", hop_fn);

        // ---- Phase 4b: Math object ----
        const math_obj = try JsObject.create(arena, null);
        try registerMath(arena, math_obj);
        const math_val = try val_mod.makeObject(arena, math_obj);
        try env.define("Math", math_val);

        // ---- Phase 4b: JSON object ----
        const json_obj = try JsObject.create(arena, null);
        const stringify_fn = try val_mod.makeNativeFunction(arena, json_mod.nativeJsonStringify);
        const parse_fn = try val_mod.makeNativeFunction(arena, json_mod.nativeJsonParse);
        try json_obj.set("stringify", stringify_fn);
        try json_obj.set("parse", parse_fn);
        const json_val = try val_mod.makeObject(arena, json_obj);
        try env.define("JSON", json_val);

        // ---- Phase 4c: RegExp constructor + prototype ----
        const regexp_proto = try JsObject.create(arena, object_proto);
        // Install prototype methods
        const re_test_fn = try val_mod.makeNativeFunction(arena, regexp_mod.nativeRegExpTest);
        const re_exec_fn = try val_mod.makeNativeFunction(arena, regexp_mod.nativeRegExpExec);
        try regexp_proto.set("test", re_test_fn);
        try regexp_proto.set("exec", re_exec_fn);

        // Build RegExp constructor object (same pattern as Error constructors)
        const regexp_ctor_obj = try JsObject.create(arena, null);
        const regexp_proto_val = try val_mod.makeObject(arena, regexp_proto);
        try regexp_ctor_obj.set("prototype", regexp_proto_val);
        const regexp_call_fn = try val_mod.makeNativeFunction(arena, regexp_mod.nativeRegExpCtor);
        try regexp_ctor_obj.set("__call__", regexp_call_fn);
        const regexp_ctor_val = try val_mod.makeObject(arena, regexp_ctor_obj);
        try env.define("RegExp", regexp_ctor_val);

        // Thread-local so RegExp constructor in regexp.zig can access it.
        active_regexp_proto = regexp_proto;

        // ---- Phase 4d: Function.prototype (call, apply, bind) ----
        const function_proto = try JsObject.create(arena, object_proto);
        const fn_call_fn = try val_mod.makeNativeFunction(arena, function_proto_mod.nativeFunctionCall);
        const fn_apply_fn = try val_mod.makeNativeFunction(arena, function_proto_mod.nativeFunctionApply);
        const fn_bind_fn = try val_mod.makeNativeFunction(arena, function_proto_mod.nativeFunctionBind);
        try function_proto.set("call", fn_call_fn);
        try function_proto.set("apply", fn_apply_fn);
        try function_proto.set("bind", fn_bind_fn);
        active_function_proto = function_proto;

        // ---- Phase 4d: Date ----
        const date_proto = try JsObject.create(arena, object_proto);
        const date_fns = .{
            .{ "getTime",         date_mod.nativeDateGetTime },
            .{ "valueOf",         date_mod.nativeDateValueOf },
            .{ "getFullYear",     date_mod.nativeDateGetFullYear },
            .{ "getMonth",        date_mod.nativeDateGetMonth },
            .{ "getDate",         date_mod.nativeDateGetDate },
            .{ "getDay",          date_mod.nativeDateGetDay },
            .{ "getHours",        date_mod.nativeDateGetHours },
            .{ "getMinutes",      date_mod.nativeDateGetMinutes },
            .{ "getSeconds",      date_mod.nativeDateGetSeconds },
            .{ "getMilliseconds", date_mod.nativeDateGetMilliseconds },
            .{ "toISOString",     date_mod.nativeDateToISOString },
            .{ "toString",        date_mod.nativeDateToString },
        };
        inline for (date_fns) |pair| {
            const fn_v = try val_mod.makeNativeFunction(arena, pair[1]);
            try date_proto.set(pair[0], fn_v);
        }
        date_mod.active_date_proto = date_proto;

        // Build Date constructor.
        const date_ctor_obj = try JsObject.create(arena, null);
        const date_proto_val = try val_mod.makeObject(arena, date_proto);
        try date_ctor_obj.set("prototype", date_proto_val);
        const date_call_fn = try val_mod.makeNativeFunction(arena, date_mod.nativeDateCtor);
        try date_ctor_obj.set("__call__", date_call_fn);
        const date_now_fn = try val_mod.makeNativeFunction(arena, date_mod.nativeDateNow);
        try date_ctor_obj.set("now", date_now_fn);
        const date_ctor_val = try val_mod.makeObject(arena, date_ctor_obj);
        try env.define("Date", date_ctor_val);

        // Set thread-locals for builtins that need them.
        active_array_proto = array_proto;
        active_object_proto = object_proto;
        active_string_proto = string_proto;

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
            .string_prototype = string_proto,
            .regexp_prototype = regexp_proto,
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
        // Copy properties from arena object to heap object.
        var it = self.object_prototype.props.iterator();
        while (it.next()) |entry| {
            try hp_proto.set(entry.key_ptr.*, entry.value_ptr.*);
        }

        const hp_array_proto = try heap.allocateObject(hp_proto);
        var it2 = self.array_prototype.props.iterator();
        while (it2.next()) |entry| {
            try hp_array_proto.set(entry.key_ptr.*, entry.value_ptr.*);
        }

        self.object_prototype = hp_proto;
        self.array_prototype = hp_array_proto;

        // Update the Object constructor's "prototype" property to point to new hp_proto.
        // Find the Object ctor in global env.
        if (self.global_env.bindings.getPtr("Object")) |obj_val_ptr| {
            if (obj_val_ptr.bits != 0) {
                switch (obj_val_ptr.toPtr().*) {
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
        active_regexp_proto = null;
        pending_exception = Value{};
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
    try std.testing.expect(obj_val.toPtr().* == .object);
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
