// SPDX-License-Identifier: Apache-2.0
//! C ABI for embedding jsz from C, Rust, Go, or anything that speaks cdecl.
//! Mirrors the Zig API in root.zig (Isolate/Context/eval/Limits) behind
//! opaque handles. See include/jsz.h for the C-side declarations and
//! examples/embed.c for a runnable example.
//!
//! Memory contract:
//!   - jsz_eval copies the source string; the caller may free it immediately.
//!     (JS string values may alias evaluated source, so copies are retained
//!     until jsz_context_free.)
//!   - The string returned by jsz_last_string is owned by the context and
//!     valid until the next jsz_eval on that context (or jsz_context_free).
//!   - All handles are freed exactly once via their _free function.
const std = @import("std");
const jsz = @import("root.zig");
const val_mod = @import("value/value.zig");
const isolate_mod = @import("vm/isolate.zig");
const realm_mod = @import("runtime/realm.zig");
const JsObject = @import("object/object.zig").JsObject;

const calloc = std.heap.c_allocator;

fn implOf(c: *CContext) *isolate_mod.IsolateImpl {
    return @ptrCast(@alignCast(c.ctx._isolate._impl.?));
}

/// Status codes returned by jsz_eval. Keep in sync with include/jsz.h.
const JSZ_OK: c_int = 0;
const JSZ_EXCEPTION: c_int = 1;
const JSZ_PARSE_ERROR: c_int = 2;
const JSZ_ERR_NOMEM: c_int = 3;

const CIsolate = struct {
    iso: jsz.Isolate,
};

const CContext = struct {
    ctx: *jsz.Context,
    /// Retained copies of every evaluated source (JS strings may alias them).
    sources: std.ArrayList([]u8) = .{},
    /// Native-function registrations (c_fn + userdata per JS-visible name).
    native_regs: std.ArrayList(*CNativeReg) = .{},
    /// Strings handed out by jsz_as_string; freed at jsz_context_free.
    str_pool: std.ArrayList([:0]u8) = .{},
    /// GC-protected value slots (jsz_protect); each is heap.addRoot'ed.
    protected: std.ArrayList(*val_mod.Value) = .{},
    /// Display string of the last result / error message. c_allocator-owned.
    last_str: ?[:0]u8 = null,
    last_num: f64 = 0,
    last_is_num: bool = false,
    last_value: CValue = .{},

    fn setLastString(self: *CContext, s: []const u8) void {
        if (self.last_str) |old| calloc.free(old);
        self.last_str = calloc.dupeZ(u8, s) catch null;
    }
};

export fn jsz_version() [*:0]const u8 {
    return jsz.version ++ "";
}

export fn jsz_isolate_new() ?*CIsolate {
    const ci = calloc.create(CIsolate) catch return null;
    ci.iso = jsz.Isolate.init(calloc) catch {
        calloc.destroy(ci);
        return null;
    };
    return ci;
}

export fn jsz_isolate_free(ci: ?*CIsolate) void {
    const c = ci orelse return;
    c.iso.deinit();
    calloc.destroy(c);
}

export fn jsz_context_new(ci: ?*CIsolate) ?*CContext {
    const c = ci orelse return null;
    const cc = calloc.create(CContext) catch return null;
    cc.* = .{ .ctx = c.iso.newContext() catch {
        calloc.destroy(cc);
        return null;
    } };
    return cc;
}

export fn jsz_context_free(cc: ?*CContext) void {
    const c = cc orelse return;
    // Unroot protected slots BEFORE deinit while the heap can still be
    // reached; leaving stale extra_roots would be a UAF at the next GC.
    const impl = implOf(c);
    for (c.protected.items) |slot| impl.heap.removeRoot(slot);
    c.ctx.deinit();
    for (c.sources.items) |s| calloc.free(s);
    c.sources.deinit(calloc);
    for (c.native_regs.items) |r| calloc.destroy(r);
    c.native_regs.deinit(calloc);
    for (c.protected.items) |slot| calloc.destroy(slot);
    c.protected.deinit(calloc);
    for (c.str_pool.items) |s| calloc.free(s);
    c.str_pool.deinit(calloc);
    if (c.last_str) |s| calloc.free(s);
    calloc.destroy(c);
}

/// Resource limits for untrusted input; 0 = unlimited (see root.zig Limits).
export fn jsz_context_set_limits(cc: ?*CContext, mem_bytes: usize, gas: u64, time_ms: u64) void {
    const c = cc orelse return;
    c.ctx.setLimits(.{ .mem_bytes = mem_bytes, .gas = gas, .time_ms = time_ms });
}

/// Evaluate `src` (NUL-terminated). `name` is optional (NULL → "<eval>").
/// Returns JSZ_OK / JSZ_EXCEPTION / JSZ_PARSE_ERROR / JSZ_ERR_NOMEM; fetch
/// the result display string or error message via jsz_last_string, or the
/// result value via jsz_last_value.
export fn jsz_eval(cc: ?*CContext, src: ?[*:0]const u8, name: ?[*:0]const u8) c_int {
    return evalCommon(cc, src, name, false);
}

/// Evaluate as an ES module (import/export, TLA). Same result contract.
export fn jsz_eval_module(cc: ?*CContext, src: ?[*:0]const u8, name: ?[*:0]const u8) c_int {
    return evalCommon(cc, src, name, true);
}

fn evalCommon(cc: ?*CContext, src: ?[*:0]const u8, name: ?[*:0]const u8, module: bool) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const s = src orelse return JSZ_ERR_NOMEM;
    c.last_is_num = false;
    c.last_value = .{};

    const copy = calloc.dupe(u8, std.mem.span(s)) catch return JSZ_ERR_NOMEM;
    c.sources.append(calloc, copy) catch {
        calloc.free(copy);
        return JSZ_ERR_NOMEM;
    };
    const src_name: []const u8 = if (name) |n| std.mem.span(n) else "<eval>";

    switch (if (module) c.ctx.evalModule(copy, src_name) else c.ctx.eval(copy, src_name)) {
        .ok => |v| {
            var arena = std.heap.ArenaAllocator.init(calloc);
            defer arena.deinit();
            const disp = jsz.valueToDisplayString(arena.allocator(), v) catch "<value>";
            c.setLastString(disp);
            c.last_value = .{ .bits = v.bits };
            if (v.bits != 0) {
                const inner = val_mod.Value{ .bits = v.bits };
                if (inner.unbox() == .number) {
                    c.last_num = v.toF64();
                    c.last_is_num = true;
                }
            }
            return JSZ_OK;
        },
        .exception => |e| {
            c.setLastString(e.message);
            return JSZ_EXCEPTION;
        },
        .parse_error => |e| {
            c.setLastString(e.message);
            return JSZ_PARSE_ERROR;
        },
    }
}

/// Display string of the last eval result (JSZ_OK) or the error message
/// (JSZ_EXCEPTION / JSZ_PARSE_ERROR). Owned by the context; valid until the
/// next jsz_eval on this context. NULL if nothing evaluated yet.
export fn jsz_last_string(cc: ?*CContext) ?[*:0]const u8 {
    const c = cc orelse return null;
    return if (c.last_str) |s| s.ptr else null;
}

/// If the last result was a number, writes it to out and returns true.
export fn jsz_last_number(cc: ?*CContext, out: ?*f64) bool {
    const c = cc orelse return false;
    if (!c.last_is_num) return false;
    if (out) |o| o.* = c.last_num;
    return true;
}

/// Force a full GC cycle on the context's isolate.
export fn jsz_gc(cc: ?*CContext) void {
    const c = cc orelse return;
    _ = c.ctx.gc();
}

// ------------------------------------------------------------ native fns ---
// A C host function callable from JS. `args`/`argc` are the call arguments;
// write the return value into `*result` (leave untouched for undefined) and
// return 0. A nonzero return throws in JS as "native function failed (code N)".

/// Value handle across the C boundary — same layout as the Zig-side Value
/// (a pointer-boxed u64). bits == 0 means undefined.
pub const CValue = extern struct { bits: u64 = 0 };

pub const JszNativeFn = *const fn (?*CContext, ?*anyopaque, [*c]const CValue, usize, [*c]CValue) callconv(.c) c_int;

const CNativeReg = struct {
    cc: *CContext,
    fn_ptr: JszNativeFn,
    userdata: ?*anyopaque,
};

/// Internal-ABI trampoline: recovers the per-registration CNativeReg from the
/// engine's active-native side channel (re-entrancy safe: it is saved/restored
/// around every native invoke) and bridges to the C callback.
fn cNativeTrampoline(arena: std.mem.Allocator, this_val: val_mod.Value, args: []const val_mod.Value) anyerror!val_mod.Value {
    _ = this_val;
    const data = val_mod.g_active_native_data orelse return error.JsException;
    const reg: *CNativeReg = @ptrCast(@alignCast(data));
    var result = CValue{};
    // val_mod.Value and CValue are both extern { bits: u64 } — reinterpret.
    const argv: [*c]const CValue = if (args.len == 0) null else @ptrCast(args.ptr);
    const rc = reg.fn_ptr(reg.cc, reg.userdata, argv, args.len, &result);
    if (rc != 0) {
        const msg = try std.fmt.allocPrint(arena, "native function failed (code {d})", .{rc});
        realm_mod.pending_exception = try val_mod.makeString(arena, msg);
        return error.JsException;
    }
    if (result.bits == 0) return val_mod.makeUndefined(arena);
    return val_mod.Value{ .bits = result.bits };
}

/// Register `fn` as a global JS function named `name`. `userdata` is passed
/// back verbatim on every call. Returns JSZ_OK or JSZ_ERR_NOMEM.
export fn jsz_register_function(cc: ?*CContext, name: ?[*:0]const u8, f: ?JszNativeFn, userdata: ?*anyopaque) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const n = name orelse return JSZ_ERR_NOMEM;
    const fp = f orelse return JSZ_ERR_NOMEM;
    const impl: *isolate_mod.IsolateImpl = @ptrCast(@alignCast(c.ctx._isolate._impl.?));
    const reg = calloc.create(CNativeReg) catch return JSZ_ERR_NOMEM;
    reg.* = .{ .cc = c, .fn_ptr = fp, .userdata = userdata };
    c.native_regs.append(calloc, reg) catch {
        calloc.destroy(reg);
        return JSZ_ERR_NOMEM;
    };
    impl.registerNative(std.mem.span(n), cNativeTrampoline, reg) catch return JSZ_ERR_NOMEM;
    return JSZ_OK;
}

// ------------------------------------------------------------ value API ---
// Constructors allocate from the context's persistent arena: the returned
// handles stay valid for the context's lifetime. v0 covers primitives only —
// objects/arrays cross the boundary as values you inspect from JS.

export fn jsz_number(cc: ?*CContext, n: f64) CValue {
    const c = cc orelse return .{};
    return .{ .bits = c.ctx.makeNumber(n).bits };
}

/// Copies `s` (NUL-terminated) into the engine; caller may free `s` after.
export fn jsz_string(cc: ?*CContext, s: ?[*:0]const u8) CValue {
    const c = cc orelse return .{};
    const str = s orelse return .{};
    return .{ .bits = c.ctx.makeString(std.mem.span(str)).bits };
}

export fn jsz_boolean(cc: ?*CContext, b: bool) CValue {
    const c = cc orelse return .{};
    return .{ .bits = c.ctx.makeBool(b).bits };
}

export fn jsz_undefined(cc: ?*CContext) CValue {
    const c = cc orelse return .{};
    return .{ .bits = c.ctx.makeUndefined().bits };
}

export fn jsz_null(cc: ?*CContext) CValue {
    const c = cc orelse return .{};
    return .{ .bits = c.ctx.makeNull().bits };
}

fn unboxTag(v: CValue) ?std.meta.Tag(val_mod.JsValue) {
    if (v.bits == 0) return null; // undefined
    // unbox() decodes inline SMI/double/immediate forms too — never toPtr here.
    return (val_mod.Value{ .bits = v.bits }).unbox();
}

export fn jsz_is_number(v: CValue) bool {
    return (unboxTag(v) orelse return false) == .number;
}

export fn jsz_is_string(v: CValue) bool {
    return (unboxTag(v) orelse return false) == .string;
}

export fn jsz_is_bool(v: CValue) bool {
    return (unboxTag(v) orelse return false) == .boolean;
}

export fn jsz_is_undefined(v: CValue) bool {
    const t = unboxTag(v) orelse return true;
    return t == .undefined_;
}

/// ToF64 of the value (0 for non-numbers — check jsz_is_number first).
export fn jsz_as_number(v: CValue) f64 {
    if (v.bits == 0) return 0;
    return (val_mod.Value{ .bits = v.bits }).toF64();
}

export fn jsz_as_bool(v: CValue) bool {
    if (v.bits == 0) return false;
    return switch ((val_mod.Value{ .bits = v.bits }).unbox()) {
        .boolean => |b| b,
        else => false,
    };
}

/// Display string of any value (ECMAScript ToString semantics for printing).
/// Owned by the context; valid until jsz_context_free. NULL on failure.
export fn jsz_as_string(cc: ?*CContext, v: CValue) ?[*:0]const u8 {
    const c = cc orelse return null;
    var arena = std.heap.ArenaAllocator.init(calloc);
    defer arena.deinit();
    const disp = jsz.valueToDisplayString(arena.allocator(), jsz.Value{ .bits = v.bits }) catch return null;
    const dup = calloc.dupeZ(u8, disp) catch return null;
    c.str_pool.append(calloc, dup) catch {
        calloc.free(dup);
        return null;
    };
    return dup.ptr;
}

// ---------------------------------------------------------------- typeof ---
// Keep in sync with the JSZ_TYPE_* constants in include/jsz.h.

export fn jsz_typeof(v: CValue) c_int {
    const t = unboxTag(v) orelse return 0; // undefined
    return switch (t) {
        .undefined_ => 0,
        .null_ => 1,
        .boolean => 2,
        .number => 3,
        .string => 4,
        .object => 5,
        .function, .bc_function, .native_function => 6,
        .symbol => 7,
        .bigint => 8,
    };
}

export fn jsz_is_object(v: CValue) bool {
    return (unboxTag(v) orelse return false) == .object;
}

export fn jsz_is_array(v: CValue) bool {
    if ((unboxTag(v) orelse return false) != .object) return false;
    return (val_mod.Value{ .bits = v.bits }).toPtr().object.is_array;
}

export fn jsz_is_function(v: CValue) bool {
    const t = unboxTag(v) orelse return false;
    return t == .function or t == .bc_function or t == .native_function;
}

// ------------------------------------------------------- objects & arrays ---

/// New empty object with the realm's Object.prototype.
export fn jsz_object_new(cc: ?*CContext) CValue {
    const c = cc orelse return .{};
    const impl = implOf(c);
    const realm = impl.realm orelse return .{};
    const obj = JsObject.createOnHeap(&impl.heap, realm.object_prototype) catch return .{};
    const v = val_mod.makeObject(impl.persistentAllocator(), obj) catch return .{};
    return .{ .bits = v.bits };
}

/// New empty array with the realm's Array.prototype.
export fn jsz_array_new(cc: ?*CContext) CValue {
    const c = cc orelse return .{};
    const impl = implOf(c);
    const realm = impl.realm orelse return .{};
    const arr = JsObject.createArrayOnHeap(&impl.heap, realm.array_prototype) catch return .{};
    const v = val_mod.makeObject(impl.persistentAllocator(), arr) catch return .{};
    return .{ .bits = v.bits };
}

fn objectOf(v: CValue) ?*JsObject {
    if ((unboxTag(v) orelse return null) != .object) return null;
    return (val_mod.Value{ .bits = v.bits }).toPtr().object;
}

/// Own/inherited property read (raw [[Get]]: getters and proxy traps do NOT
/// fire — use jsz_eval/jsz_call for those). undefined if absent/non-object.
export fn jsz_get(cc: ?*CContext, obj: CValue, key: ?[*:0]const u8) CValue {
    const c = cc orelse return .{};
    const k = key orelse return .{};
    const v = c.ctx.getProperty(jsz.Value{ .bits = obj.bits }, std.mem.span(k));
    return .{ .bits = v.bits };
}

/// Set an own property. The key is copied. JSZ_OK / JSZ_ERR_NOMEM.
export fn jsz_set(cc: ?*CContext, obj: CValue, key: ?[*:0]const u8, v: CValue) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const k = key orelse return JSZ_ERR_NOMEM;
    const o = objectOf(obj) orelse return JSZ_ERR_NOMEM;
    const key_dup = implOf(c).persistentAllocator().dupe(u8, std.mem.span(k)) catch return JSZ_ERR_NOMEM;
    o.set(key_dup, val_mod.Value{ .bits = v.bits }) catch return JSZ_ERR_NOMEM;
    return JSZ_OK;
}

export fn jsz_get_index(cc: ?*CContext, arr: CValue, idx: u32) CValue {
    var buf: [12]u8 = undefined;
    const key = std.fmt.bufPrintZ(&buf, "{d}", .{idx}) catch return .{};
    return jsz_get(cc, arr, key.ptr);
}

export fn jsz_set_index(cc: ?*CContext, arr: CValue, idx: u32, v: CValue) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const o = objectOf(arr) orelse return JSZ_ERR_NOMEM;
    const key = std.fmt.allocPrint(implOf(c).persistentAllocator(), "{d}", .{idx}) catch return JSZ_ERR_NOMEM;
    o.set(key, val_mod.Value{ .bits = v.bits }) catch return JSZ_ERR_NOMEM;
    if (o.is_array and idx >= o.array_length) o.array_length = idx + 1;
    return JSZ_OK;
}

/// Array length ("length" for arrays; 0 otherwise).
export fn jsz_array_length(cc: ?*CContext, arr: CValue) u32 {
    _ = cc;
    const o = objectOf(arr) orelse return 0;
    if (!o.is_array) return 0;
    return o.array_length;
}

/// Bind `v` as a global named `name` (visible to subsequent evals).
export fn jsz_set_global(cc: ?*CContext, name: ?[*:0]const u8, v: CValue) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const n = name orelse return JSZ_ERR_NOMEM;
    const impl = implOf(c);
    const realm = impl.realm orelse return JSZ_ERR_NOMEM;
    const name_dup = impl.persistentAllocator().dupe(u8, std.mem.span(n)) catch return JSZ_ERR_NOMEM;
    realm.global_env.define(name_dup, val_mod.Value{ .bits = v.bits }) catch return JSZ_ERR_NOMEM;
    return JSZ_OK;
}

/// Read a global by name (undefined if absent).
export fn jsz_get_global(cc: ?*CContext, name: ?[*:0]const u8) CValue {
    const c = cc orelse return .{};
    const n = name orelse return .{};
    const impl = implOf(c);
    const realm = impl.realm orelse return .{};
    const v = realm.global_env.lookup(std.mem.span(n)) catch return .{};
    return .{ .bits = v.bits };
}

// ------------------------------------------------------------ GC rooting ---

/// Root `v` so the GC keeps it (and everything reachable from it) alive while
/// C holds the handle. Pair every protect with jsz_unprotect (or rely on
/// jsz_context_free, which releases all remaining protections).
export fn jsz_protect(cc: ?*CContext, v: CValue) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const slot = calloc.create(val_mod.Value) catch return JSZ_ERR_NOMEM;
    slot.* = .{ .bits = v.bits };
    implOf(c).heap.addRoot(slot) catch {
        calloc.destroy(slot);
        return JSZ_ERR_NOMEM;
    };
    c.protected.append(calloc, slot) catch {
        implOf(c).heap.removeRoot(slot);
        calloc.destroy(slot);
        return JSZ_ERR_NOMEM;
    };
    return JSZ_OK;
}

/// Release one protection previously added for a value with these bits.
export fn jsz_unprotect(cc: ?*CContext, v: CValue) void {
    const c = cc orelse return;
    for (c.protected.items, 0..) |slot, i| {
        if (slot.bits == v.bits) {
            implOf(c).heap.removeRoot(slot);
            calloc.destroy(slot);
            _ = c.protected.swapRemove(i);
            return;
        }
    }
}

// ------------------------------------------------------------- host call ---

/// Call a JS function value from C. Runs through the full VM (closures,
/// exceptions, microtasks), implemented by binding the callee + args to
/// hidden globals and evaluating an .apply() expression. Result contract is
/// the same as jsz_eval (jsz_last_value / jsz_last_string on JSZ_OK;
/// error message on JSZ_EXCEPTION).
export fn jsz_call(cc: ?*CContext, func: CValue, args: ?[*]const CValue, argc: usize, result: ?*CValue) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    if (!jsz_is_function(func)) return JSZ_EXCEPTION;

    const args_arr = jsz_array_new(cc);
    if (args_arr.bits == 0) return JSZ_ERR_NOMEM;
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const a = args.?[i];
        if (jsz_set_index(cc, args_arr, @intCast(i), a) != JSZ_OK) return JSZ_ERR_NOMEM;
    }
    if (jsz_set_global(cc, "__capi_fn__", func) != JSZ_OK) return JSZ_ERR_NOMEM;
    if (jsz_set_global(cc, "__capi_args__", args_arr) != JSZ_OK) return JSZ_ERR_NOMEM;

    const rc = jsz_eval(cc, "__capi_fn__.apply(undefined, __capi_args__)", "<jsz_call>");
    if (rc == JSZ_OK) {
        if (result) |r| r.* = c.last_value;
    }
    return rc;
}

// ------------------------------------------------------------ JSON bridge ---

/// JSON.stringify(v). Context-owned string (valid until the next eval on this
/// context — it reuses the eval result buffer). NULL on failure/exception.
export fn jsz_json_encode(cc: ?*CContext, v: CValue) ?[*:0]const u8 {
    if (cc == null) return null;
    if (jsz_set_global(cc, "__capi_v__", v) != JSZ_OK) return null;
    if (jsz_eval(cc, "JSON.stringify(__capi_v__)", "<jsz_json_encode>") != JSZ_OK) return null;
    return jsz_last_string(cc);
}

/// JSON.parse(s). undefined (bits 0) on failure; message via jsz_last_string.
export fn jsz_json_decode(cc: ?*CContext, s: ?[*:0]const u8) CValue {
    const c = cc orelse return .{};
    const str = s orelse return .{};
    const sv = jsz_string(cc, str);
    if (sv.bits == 0) return .{};
    if (jsz_set_global(cc, "__capi_v__", sv) != JSZ_OK) return .{};
    if (jsz_eval(cc, "JSON.parse(__capi_v__)", "<jsz_json_decode>") != JSZ_OK) return .{};
    return c.last_value;
}

/// Result value of the last successful eval/call (undefined if none/error).
/// Valid until jsz_context_free; protect with jsz_protect if the value is an
/// object that must survive future GCs while only C references it.
export fn jsz_last_value(cc: ?*CContext) CValue {
    const c = cc orelse return .{};
    return c.last_value;
}
