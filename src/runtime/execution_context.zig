// SPDX-License-Identifier: MIT
//! Lexical scope chain (Environment). define/lookup/assign bindings.
//! Arena-allocated; no deallocation needed per-binding.
const std = @import("std");
const Value = @import("../value/value.zig").Value;

pub const EnvError = error{
    OutOfMemory,
    NotDefined,
};

/// A single lexical environment frame. Linked to parent.
pub const Environment = struct {
    parent: ?*Environment,
    bindings: std.StringHashMapUnmanaged(Value),
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

    /// Define a binding in THIS frame (var hoisting or block).
    pub fn define(self: *Environment, name: []const u8, value: Value) !void {
        try self.bindings.put(self.arena, name, value);
    }

    /// Look up a binding in this frame or any parent.
    pub fn lookup(self: *Environment, name: []const u8) EnvError!Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.lookup(name);
        return EnvError.NotDefined;
    }

    /// Assign an existing binding (walk up the chain).
    pub fn assign(self: *Environment, name: []const u8, value: Value) EnvError!void {
        if (self.bindings.contains(name)) {
            self.bindings.putAssumeCapacity(name, value);
            return;
        }
        if (self.parent) |p| return p.assign(name, value);
        return EnvError.NotDefined;
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
