// SPDX-License-Identifier: Apache-2.0
//! Lexical scope chain (Environment). define/lookup/assign bindings.
//! Arena-allocated; no deallocation needed per-binding.
const std = @import("std");
const Value = @import("../value/value.zig").Value;

pub const EnvError = error{
    OutOfMemory,
    NotDefined,
    TemporalDeadZone,
    ConstAssignment,
};

pub const BindingKind = enum {
    var_,
    let,
    const_,
};

pub const Binding = struct {
    value: Value,
    kind: BindingKind,
    initialized: bool,
};

/// A single lexical environment frame. Linked to parent.
pub const Environment = struct {
    parent: ?*Environment,
    bindings: std.StringHashMapUnmanaged(Binding),
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, parent: ?*Environment) !*Environment {
        const env = try arena.create(Environment);
        env.* = Environment{
            .parent = parent,
            .bindings = .{},
            .arena = arena,
        };
        return env;
    }

    /// Hoist a `var`/function-declaration binding into THIS frame: define it as
    /// `value` (usually undefined) only if this frame has no own binding for the
    /// name yet. Never walks the parent chain and never clobbers an existing
    /// binding (e.g. a parameter, or an already-hoisted name). This gives every
    /// `var` an `undefined` value at scope entry without overwriting params.
    pub fn hoistVar(self: *Environment, name: []const u8, value: Value) !void {
        if (self.bindings.contains(name)) return;
        try self.define(name, value);
    }

    /// Define a var-style binding in THIS frame.
    pub fn define(self: *Environment, name: []const u8, value: Value) !void {
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = .var_,
            .initialized = true,
        });
    }

    /// Define a lexical binding in THIS frame. If `initialized` is false, the binding
    /// is in TDZ and any lookup/assignment should throw until initialized.
    pub fn defineLexical(self: *Environment, name: []const u8, kind: BindingKind, initialized: bool, value: Value) !void {
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = kind,
            .initialized = initialized,
        });
    }

    /// Upgrade a binding to const_ so subsequent assignments throw TypeError.
    pub fn upgradeToConst(self: *Environment, name: []const u8) void {
        if (self.bindings.getPtr(name)) |b| { b.kind = .const_; return; }
        if (self.parent) |p| p.upgradeToConst(name);
    }

    /// Initialize an existing lexical binding in this frame or any parent frame.
    pub fn initialize(self: *Environment, name: []const u8, value: Value) EnvError!void {
        if (self.bindings.getPtr(name)) |b| {
            b.value = value;
            b.initialized = true;
            return;
        }
        if (self.parent) |p| return p.initialize(name, value);
        return EnvError.NotDefined;
    }

    /// Look up a binding in this frame or any parent.
    pub fn lookup(self: *Environment, name: []const u8) EnvError!Value {
        if (self.bindings.get(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            return b.value;
        }
        if (self.parent) |p| return p.lookup(name);
        return EnvError.NotDefined;
    }

    /// Assign an existing binding (walk up the chain).
    pub fn assign(self: *Environment, name: []const u8, value: Value) EnvError!void {
        if (self.bindings.getPtr(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            if (b.kind == .const_) return EnvError.ConstAssignment;
            b.value = value;
            return;
        }
        if (self.parent) |p| return p.assign(name, value);
        return EnvError.NotDefined;
    }

    /// Mirror a `globalThis.name = value` write into an existing top-level `var`
    /// binding of the same name, keeping the global environment record and the
    /// global object in sync. No-op unless an initialized `var` binding exists
    /// (lexical/const globals are not aliased to global-object properties).
    pub fn mirrorGlobalVar(self: *Environment, name: []const u8, value: Value) void {
        if (self.bindings.getPtr(name)) |b| {
            if (b.kind == .var_ and b.initialized) b.value = value;
        }
    }

    /// Define or create in the global frame (walk to root).
    pub fn defineGlobal(self: *Environment, name: []const u8, value: Value) !void {
        if (self.parent == null) {
            try self.define(name, value);
            return;
        }
        try self.parent.?.defineGlobal(name, value);
    }
};

// ------------------------------------------------------------------- tests ---

test "Environment: define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const v = try val.makeNumber(arena.allocator(), 42);
    const env = try Environment.init(arena.allocator(), null);
    try env.define("x", v);
    const got = try env.lookup("x");
    try std.testing.expectEqual(@as(f64, 42), got.toF64());
}

test "Environment: lexical TDZ and initialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const env = try Environment.init(arena.allocator(), null);
    const undef = try val.makeUndefined(arena.allocator());
    try env.defineLexical("x", .let, false, undef);
    try std.testing.expectError(EnvError.TemporalDeadZone, env.lookup("x"));
    const one = try val.makeNumber(arena.allocator(), 1);
    try env.initialize("x", one);
    const got = try env.lookup("x");
    try std.testing.expectEqual(@as(f64, 1), got.toF64());
}

test "Environment: const assignment rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const env = try Environment.init(arena.allocator(), null);
    const one = try val.makeNumber(arena.allocator(), 1);
    try env.defineLexical("c", .const_, true, one);
    const two = try val.makeNumber(arena.allocator(), 2);
    try std.testing.expectError(EnvError.ConstAssignment, env.assign("c", two));
}

test "Environment: parent chain lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const parent = try Environment.init(arena.allocator(), null);
    const v = try val.makeNumber(arena.allocator(), 10);
    try parent.define("y", v);
    const child = try Environment.init(arena.allocator(), parent);
    const got = try child.lookup("y");
    try std.testing.expectEqual(@as(f64, 10), got.toF64());
}

test "Environment: assign walks chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const parent = try Environment.init(arena.allocator(), null);
    const v1 = try val.makeNumber(arena.allocator(), 1);
    try parent.define("z", v1);
    const child = try Environment.init(arena.allocator(), parent);
    const v2 = try val.makeNumber(arena.allocator(), 2);
    try child.assign("z", v2);
    const got = try parent.lookup("z");
    try std.testing.expectEqual(@as(f64, 2), got.toF64());
}
