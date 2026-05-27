// SPDX-License-Identifier: MIT
//! Phase 3a value representation.
//! JsValue is an internal tagged union allocated in the eval arena.
//! The public Value handle (Value{ bits: u64 }) stores a pointer to JsValue.
//! This is NOT the final NaN-boxing layout (Phase 6) — it uses the same
//! external surface so callers don't need to change.
const std = @import("std");

/// Phase 2 bytecode closure type (forward-declared to avoid circular import).
const BcClosure = @import("../bytecode/function.zig").BcClosure;

/// Phase 3a object type.
const JsObject = @import("../object/object.zig").JsObject;

/// Signature for a native function callable from JS (mirrors root.zig NativeFn).
/// We use a simpler form here to avoid circular imports: args are []Value, returns Value.
pub const NativeFnPtr = *const fn (arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value;

/// Internal tagged JavaScript value. Arena-allocated per eval call.
pub const JsValue = union(enum) {
    undefined_,
    null_,
    boolean: bool,
    number: f64,
    string: []const u8,
    /// Phase 1: AST-based function (tree-walker).
    function: *FuncVal,
    /// Phase 2: bytecode closure.
    bc_function: *BcClosure,
    /// Phase 3a: object (plain object or array).
    object: *JsObject,
    /// Phase 3a: native function (host-provided).
    native_function: NativeFnPtr,

    pub const Tag = std.meta.Tag(JsValue);
};

/// A JS function value: captures its AST + closure environment.
pub const FuncVal = struct {
    name: ?[]const u8,
    params: [][]const u8,
    param_defaults: []?*anyopaque = &[_]?*anyopaque{},
    rest_param: ?[]const u8 = null,
    /// Pointer to the function's body statement list. Opaque pointer to []*Node
    /// to avoid circular imports; cast in the evaluator.
    body_ptr: *anyopaque,
    /// Pointer to the closure Environment at definition time.
    closure_env: *anyopaque,
    /// Phase 4d: whether this function is in strict mode.
    is_strict: bool = false,
    /// Phase 7: function prototype object used by `new` and class desugaring.
    prototype_obj: ?*JsObject = null,
    /// Phase 7: arrow function captures lexical `this`.
    is_arrow: bool = false,
    lexical_this: Value = Value{},
    /// Phase 7: generator function (`function*`).
    is_generator: bool = false,
    /// Phase 7: derived class constructor must call `super` before `this`.
    requires_super: bool = false,
};

/// Public handle — an opaque u64 whose bits are a *JsValue pointer.
/// Valid until the owning Context's eval arena is reset.
pub const Value = extern struct {
    bits: u64 = 0,

    /// Wrap a *JsValue pointer into a Value handle.
    pub fn fromPtr(ptr: *JsValue) Value {
        return Value{ .bits = @intFromPtr(ptr) };
    }

    /// Unwrap the *JsValue pointer. Only safe when bits != 0.
    pub fn toPtr(self: Value) *JsValue {
        return @ptrFromInt(self.bits);
    }

    pub fn isNull(self: Value) bool {
        if (self.bits == 0) return false;
        return self.toPtr().* == .null_;
    }

    pub fn isUndefined(self: Value) bool {
        if (self.bits == 0) return true; // zero = uninitialized = undefined
        return self.toPtr().* == .undefined_;
    }

    /// Phase 0 compat: return i32 approximation.
    pub fn toI32(self: Value) i32 {
        if (self.bits == 0) return 0;
        return switch (self.toPtr().*) {
            .number => |n| @intFromFloat(n),
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
    }

    pub fn toF64(self: Value) f64 {
        if (self.bits == 0) return std.math.nan(f64);
        return switch (self.toPtr().*) {
            .number => |n| n,
            .boolean => |b| if (b) 1.0 else 0.0,
            .null_ => 0.0,
            .undefined_ => std.math.nan(f64),
            .string => |s| std.fmt.parseFloat(f64, s) catch std.math.nan(f64),
            .function => std.math.nan(f64),
            .bc_function => std.math.nan(f64),
            .object => std.math.nan(f64),
            .native_function => std.math.nan(f64),
        };
    }

    pub fn toString(self: Value) []const u8 {
        if (self.bits == 0) return "undefined";
        return switch (self.toPtr().*) {
            .undefined_ => "undefined",
            .null_ => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| {
                _ = n;
                return "<number>"; // caller should use formatNumber
            },
            .string => |s| s,
            .function => |f| f.name orelse "function",
            .bc_function => |c| c.func.name orelse "function",
            .object => "[object Object]",
            .native_function => "function",
        };
    }
};

/// Allocate a new JsValue in the given arena.
pub fn makeUndefined(arena: std.mem.Allocator) !Value {
    const v = try arena.create(JsValue);
    v.* = .undefined_;
    return Value.fromPtr(v);
}

pub fn makeNull(arena: std.mem.Allocator) !Value {
    const v = try arena.create(JsValue);
    v.* = .null_;
    return Value.fromPtr(v);
}

pub fn makeBool(arena: std.mem.Allocator, b: bool) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .boolean = b };
    return Value.fromPtr(v);
}

pub fn makeNumber(arena: std.mem.Allocator, n: f64) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .number = n };
    return Value.fromPtr(v);
}

pub fn makeString(arena: std.mem.Allocator, s: []const u8) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .string = s };
    return Value.fromPtr(v);
}

pub fn makeFunction(arena: std.mem.Allocator, fv: *FuncVal) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .function = fv };
    return Value.fromPtr(v);
}

pub fn makeBcFunction(arena: std.mem.Allocator, closure: *BcClosure) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .bc_function = closure };
    return Value.fromPtr(v);
}

/// Phase 3a: wrap a JsObject pointer as a Value.
pub fn makeObject(arena: std.mem.Allocator, obj: *JsObject) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .object = obj };
    return Value.fromPtr(v);
}

/// Phase 3a: wrap a native function pointer as a Value.
pub fn makeNativeFunction(arena: std.mem.Allocator, fn_ptr: NativeFnPtr) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .native_function = fn_ptr };
    return Value.fromPtr(v);
}

// ------------------------------------------------------------------- tests ---

test "Value default zero" {
    const v = Value{};
    try std.testing.expect(v.bits == 0);
    try std.testing.expect(v.isUndefined());
}

test "Value number round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try makeNumber(arena.allocator(), 42.0);
    try std.testing.expectEqual(@as(f64, 42.0), v.toF64());
    try std.testing.expectEqual(@as(i32, 42), v.toI32());
}

test "Value boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try makeBool(arena.allocator(), true);
    const f = try makeBool(arena.allocator(), false);
    try std.testing.expect(t.toI32() == 1);
    try std.testing.expect(f.toI32() == 0);
}

test "Value object arm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const obj = try JsObject.create(arena.allocator(), null);
    const v = try makeObject(arena.allocator(), obj);
    try std.testing.expect(v.bits != 0);
    try std.testing.expect(v.toPtr().* == .object);
}
