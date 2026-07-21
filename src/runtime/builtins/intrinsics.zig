// SPDX-License-Identifier: Apache-2.0
//! R1 refactor: shared helpers for building intrinsics (prototypes, constructors,
//! accessor getters). Collapses the boilerplate that was copy-pasted ~15× inside
//! `realm.init`, so each builtin's registration is a few declarative calls.
//!
//! These are behaviour-preserving: `makeCtor` builds exactly the
//! `{ prototype, __call__ }` shape the inline code used (it does NOT add a
//! `constructor` back-link — callers that want one set it explicitly, matching
//! the prior per-builtin behaviour).
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const PropAttr = @import("../../object/object.zig").PropAttr;
const Environment = @import("../execution_context.zig").Environment;

/// Registration context threaded to each builtin's `register(ctx)`. Bundles the
/// shared, already-allocated realm state a builtin needs to install its
/// prototype + constructor and bind its global. `function_proto` is null until
/// Function.prototype exists (builtins registered before it must not need it).
pub const Ctx = struct {
    arena: std.mem.Allocator,
    env: *Environment,
    object_proto: *JsObject,
    function_proto: ?*JsObject = null,
    /// Array.prototype, available once registerArrayProto has run. Lets builtins
    /// share the exact same function object (e.g. %TypedArray%.prototype.toString
    /// must be the same object as Array.prototype.toString per spec).
    array_proto: ?*JsObject = null,

    /// Define a global binding to a freshly-boxed object value.
    pub fn defineGlobal(self: *const Ctx, name: []const u8, obj: *JsObject) !void {
        try self.env.define(name, try val_mod.makeObject(self.arena, obj));
    }
};

/// Spec attributes for a built-in method / data property: writable, NON-enumerable,
/// configurable (ES §17 "Every other data property ... { [[Writable]]: true,
/// [[Enumerable]]: false, [[Configurable]]: true }").
pub const method_attr: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };

/// Set many native-function methods on `obj` from a comptime tuple of
/// `.{ name, fn_ptr }` pairs. Each function gets `.name` and `.length = 0`
/// stored inline on the NativeFnEntry (accessible via getProp). Installed
/// NON-enumerable per spec.
pub fn setMethods(arena: std.mem.Allocator, obj: *JsObject, comptime pairs: anytype) !void {
    inline for (pairs) |pair| {
        const fn_val = try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], 0);
        _ = try obj.defineOwnData(pair[0], fn_val, method_attr);
    }
}

/// Set a single native-function method with name/length stored on the entry.
/// Installed NON-enumerable per spec.
pub fn setMethod(arena: std.mem.Allocator, obj: *JsObject, name: []const u8, fn_ptr: val_mod.NativeFnPtr) !void {
    const fn_val = try val_mod.makeNativeFunctionNamed(arena, fn_ptr, name, 0);
    _ = try obj.defineOwnData(name, fn_val, method_attr);
}

/// Like `setMethod` but pins an explicit `.length` (arity). Use when the shared
/// name→length inference would give the wrong value (e.g. names such as `with`,
/// `toJSON`, `toPlainDate` mean different arities on different built-ins). The
/// `.name` is still set from `name`. Installed NON-enumerable per spec.
pub fn setMethodLen(arena: std.mem.Allocator, obj: *JsObject, name: []const u8, fn_ptr: val_mod.NativeFnPtr, length: u8) !void {
    const fn_val = try val_mod.makeNativeFunctionNamedLen(arena, fn_ptr, name, length);
    _ = try obj.defineOwnData(name, fn_val, method_attr);
}

/// Build a constructor object with the `{ prototype, __call__ }` shape used
/// throughout `realm.init`. `ctor_proto` is the constructor object's own
/// prototype (usually `null` historically, or Function.prototype). Does not add a
/// `constructor` back-link — set it explicitly if needed.
pub fn makeCtor(arena: std.mem.Allocator, proto: *JsObject, call_fn: val_mod.NativeFnPtr, ctor_proto: ?*JsObject) !*JsObject {
    const ctor = try JsObject.create(arena, ctor_proto);
    try ctor.set("prototype", try val_mod.makeObject(arena, proto));
    try ctor.set("__call__", try val_mod.makeNativeFunction(arena, call_fn));
    return ctor;
}

/// Install a read-only accessor (getter only) on `proto` under `key`.
/// Non-enumerable, configurable — the spec shape for prototype getters.
/// The getter function's `.name` is set to `"get " + key` per spec §17.
pub fn defineGetter(arena: std.mem.Allocator, proto: *JsObject, key: []const u8, getter: val_mod.NativeFnPtr) !void {
    const holder = try JsObject.create(arena, null);
    const getter_name = try std.fmt.allocPrint(arena, "get {s}", .{key});
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, getter_name, 0));
    const hv = try val_mod.makeObject(arena, holder);
    _ = try proto.defineOwnAccessor(key, hv, .{ .enumerable = false, .configurable = true, .writable = false });
}
