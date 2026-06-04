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

/// Side channel: set immediately before invoking a native_function entry so a
/// shared trampoline can recover its per-registration userdata. Single-threaded.
pub var g_active_native_data: ?*anyopaque = null;

/// A native function plus optional host userdata. Builtins use data == null.
pub const NativeFnEntry = struct {
    call: NativeFnPtr,
    data: ?*anyopaque = null,

    pub fn invoke(self: NativeFnEntry, arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
        g_active_native_data = self.data;
        return self.call(arena, this_val, args);
    }
};

pub const NativeBinding = struct { name: []const u8, entry: NativeFnEntry };

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
    native_function: NativeFnEntry,

    pub const Tag = std.meta.Tag(JsValue);
};

/// ECMAScript number → string for display (shared by VM + public API).
pub fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == @trunc(n) and @abs(n) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

// WebKit-style JSVALUE64 NaN-boxed Value representation (committed). Numbers are
// encoded inline as int32 (`NumberTag|u32`) or offset-doubles; null/true/false
// use the WebKit immediate constants; `bits==0` is undefined (WebKit ValueEmpty),
// so all `bits==0` guards remain valid. Constants from
// Source/JavaScriptCore/runtime/JSCJSValue.h.
const NumberTag: u64 = 0xfffe000000000000;
const DoubleEncodeOffset: u64 = 1 << 49; // 0x0002000000000000
const NotCellMask: u64 = NumberTag | 0x2; // 0xfffe000000000002
const nb_null: u64 = 0x2; //  OtherTag
const nb_false: u64 = 0x6; // OtherTag|BoolTag
const nb_true: u64 = 0x7; //  OtherTag|BoolTag|1

/// Inclusive SMI integer bounds: i32 (WebKit int32 tag).
const smi_min: i64 = -2147483648;
const smi_max: i64 = 2147483647;

/// SMI range guard: integral, finite, within i32 range.
inline fn smiFits(n: f64) bool {
    if (!std.math.isFinite(n) or @floor(n) != n) return false;
    if (n == 0.0 and std.math.signbit(n)) return false; // preserve -0.0 distinctly
    return n >= @as(f64, @floatFromInt(smi_min)) and n <= @as(f64, @floatFromInt(smi_max));
}

/// Integer arithmetic fast-path: when both operands are SMIs and the exact
/// integer result stays in SMI range, return it as an SMI (no f64 round-trip,
/// no allocation); else null so the caller falls back to f64 semantics. `op` is
/// '+','-','*'. Multiply returning 0 defers to f64 to preserve JS -0.
pub inline fn smiArith(a: Value, b: Value, op: u8) ?Value {
    if (!a.isSmi() or !b.isSmi()) return null;
    const x = a.smiValue();
    const y = b.smiValue();
    const r: i64 = switch (op) {
        '+' => std.math.add(i64, x, y) catch return null,
        '-' => std.math.sub(i64, x, y) catch return null,
        '*' => blk: {
            const m = std.math.mul(i64, x, y) catch return null;
            if (m == 0) return null; // could be -0 in JS; let f64 decide
            break :blk m;
        },
        else => return null,
    };
    if (r < smi_min or r > smi_max) return null; // SMI range
    return Value.fromSmi(r);
}

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
    /// Phase 4: own properties (functions are objects). Lazily allocated.
    own_props: ?*JsObject = null,
};

/// Public handle — an opaque u64 whose bits are a *JsValue pointer.
/// Valid until the owning Context's eval arena is reset.
pub const Value = extern struct {
    bits: u64 = 0,

    /// Wrap a *JsValue pointer into a Value handle.
    pub fn fromPtr(ptr: *JsValue) Value {
        return Value{ .bits = @intFromPtr(ptr) };
    }

    /// Unwrap the *JsValue pointer. Only safe when bits != 0 and not an SMI.
    pub fn toPtr(self: Value) *JsValue {
        return @ptrFromInt(self.bits);
    }

    /// True if this handle carries an inline small integer (WebKit int32 tag).
    pub inline fn isSmi(self: Value) bool {
        return (self.bits & NumberTag) == NumberTag;
    }

    /// Decode an SMI payload. Caller must check `isSmi`.
    pub inline fn smiValue(self: Value) i64 {
        return @as(i32, @bitCast(@as(u32, @truncate(self.bits)))); // i32 in low 32
    }

    /// Encode an integer as an inline SMI handle (no allocation). The value must
    /// be in i32 range (callers guarantee via `smiFits`).
    pub inline fn fromSmi(n: i64) Value {
        return Value{ .bits = NumberTag | @as(u64, @as(u32, @bitCast(@as(i32, @intCast(n))))) };
    }

    /// True when these bits denote a real heap JsValue pointer (a "cell"):
    /// `(bits & NotCellMask)==0 && bits!=0`.
    pub inline fn isHeapPtr(self: Value) bool {
        return self.bits != 0 and (self.bits & NotCellMask) == 0;
    }

    /// Read-dispatch superset accessor: the JsValue this handle denotes. Decodes
    /// inline int32/double/immediate forms; otherwise it is exactly `toPtr().*`.
    /// READ sites only — write sites (`toPtr().* = …`) must keep `toPtr()`.
    pub inline fn unbox(self: Value) JsValue {
        if (self.bits == 0) return .undefined_;
        if ((self.bits & NumberTag) != 0) { // number
            if ((self.bits & NumberTag) == NumberTag) return .{ .number = @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(self.bits))))) };
            return .{ .number = @bitCast(self.bits -% DoubleEncodeOffset) };
        }
        switch (self.bits) {
            nb_null => return .null_,
            nb_true => return .{ .boolean = true },
            nb_false => return .{ .boolean = false },
            else => {},
        }
        return self.toPtr().*;
    }

    pub fn isNull(self: Value) bool {
        if (self.bits == 0) return false;
        return self.unbox() == .null_;
    }

    pub fn isUndefined(self: Value) bool {
        if (self.bits == 0) return true; // zero = uninitialized = undefined
        return self.unbox() == .undefined_;
    }

    /// True if the value is `null` or `undefined` (ES nullish).
    pub fn isNullish(self: Value) bool {
        if (self.bits == 0) return true; // uninitialized = undefined
        const tag = self.unbox();
        return tag == .null_ or tag == .undefined_;
    }

    /// Phase 0 compat: return i32 approximation.
    pub fn toI32(self: Value) i32 {
        if (self.bits == 0) return 0;
        return switch (self.unbox()) {
            .number => |n| @intFromFloat(n),
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
    }

    pub fn toF64(self: Value) f64 {
        if (self.bits == 0) return std.math.nan(f64);
        return switch (self.unbox()) {
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
        return switch (self.unbox()) {
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
    _ = arena;
    return Value{ .bits = nb_null };
}

pub fn makeBool(arena: std.mem.Allocator, b: bool) !Value {
    _ = arena;
    return Value{ .bits = if (b) nb_true else nb_false };
}

pub fn makeNumber(arena: std.mem.Allocator, n: f64) !Value {
    _ = arena;
    if (smiFits(n)) return Value.fromSmi(@intFromFloat(n));
    const d = if (std.math.isNan(n)) std.math.nan(f64) else n; // purify NaN
    return Value{ .bits = @as(u64, @bitCast(d)) +% DoubleEncodeOffset };
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
    v.* = .{ .native_function = .{ .call = fn_ptr } };
    return Value.fromPtr(v);
}

/// Wrap a native fn pointer plus host userdata as a Value.
pub fn makeNativeFunctionData(arena: std.mem.Allocator, fn_ptr: NativeFnPtr, data: ?*anyopaque) !Value {
    const v = try arena.create(JsValue);
    v.* = .{ .native_function = .{ .call = fn_ptr, .data = data } };
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

test "immediate singletons decode and never look like heap pointers" {
    const a = std.testing.allocator;
    const nul = try makeNull(a);
    const t = try makeBool(a, true);
    const f = try makeBool(a, false);
    try std.testing.expect(!nul.isHeapPtr() and !t.isHeapPtr() and !f.isHeapPtr());
    try std.testing.expect(nul.unbox() == .null_ and nul.isNull());
    try std.testing.expect(t.unbox().boolean == true);
    try std.testing.expect(f.unbox().boolean == false);
    // distinct from undefined(0), SMI(bit0), and each other.
    try std.testing.expect(nul.bits != 0 and (nul.bits & 1) == 0);
}

test "smiArith integer fast-path: exact, range/overflow/-0 aware" {
    const a = Value.fromSmi(3);
    const b = Value.fromSmi(4);
    try std.testing.expectEqual(@as(i64, 7), smiArith(a, b, '+').?.smiValue());
    try std.testing.expectEqual(@as(i64, -1), smiArith(a, b, '-').?.smiValue());
    try std.testing.expectEqual(@as(i64, 12), smiArith(a, b, '*').?.smiValue());
    // multiply to 0 defers to f64 (JS -0 hazard).
    try std.testing.expect(smiArith(Value.fromSmi(-1), Value.fromSmi(0), '*') == null);
    // overflow past the SMI range defers.
    const big = Value.fromSmi(smi_max);
    try std.testing.expect(smiArith(big, big, '+') == null);
    // non-SMI operands defer.
    try std.testing.expect(smiArith(Value{}, a, '+') == null);
}

test "nanbox codec: double round-trip + disjoint classification (flag-independent)" {
    const isNum = struct {
        fn f(b: u64) bool {
            return (b & NumberTag) != 0;
        }
    }.f;
    const isInt = struct {
        fn f(b: u64) bool {
            return (b & NumberTag) == NumberTag;
        }
    }.f;
    // Doubles: encode→ number, not int32, bit-exact decode.
    const ds = [_]f64{ 0.5, -0.5, 1.5, -1.5, 3.14159, 1e300, -1e300, 1e-300, std.math.floatMax(f64), -std.math.floatMax(f64), std.math.inf(f64), -std.math.inf(f64) };
    for (ds) |d| {
        const enc = @as(u64, @bitCast(d)) +% DoubleEncodeOffset;
        try std.testing.expect(isNum(enc) and !isInt(enc));
        try std.testing.expectEqual(d, @as(f64, @bitCast(enc -% DoubleEncodeOffset)));
    }
    // Canonical NaN: still a (non-int) number, decodes to NaN.
    const nan_enc = @as(u64, @bitCast(std.math.nan(f64))) +% DoubleEncodeOffset;
    try std.testing.expect(isNum(nan_enc) and !isInt(nan_enc));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(nan_enc -% DoubleEncodeOffset))));
    // Int32: tagged, classified as int, decodes exactly.
    for ([_]i32{ 0, 1, -1, 2147483647, -2147483648, 42 }) |i| {
        const enc = NumberTag | @as(u64, @as(u32, @bitCast(i)));
        try std.testing.expect(isNum(enc) and isInt(enc));
        try std.testing.expectEqual(i, @as(i32, @bitCast(@as(u32, @truncate(enc)))));
    }
    // Immediates + a fake cell pointer: not numbers, cell-mask disjoint.
    try std.testing.expect(!isNum(nb_null) and !isNum(nb_true) and !isNum(nb_false));
    try std.testing.expect((nb_null & NotCellMask) != 0); // immediates are not cells
    const fake_cell: u64 = 0x1000; // 8-aligned, low memory
    try std.testing.expect(!isNum(fake_cell) and (fake_cell & NotCellMask) == 0);
}
