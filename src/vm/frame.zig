// SPDX-License-Identifier: MIT
//! Call frames for the tree-walker (Phase 1) and bytecode VM (Phase 2).
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const Environment = @import("../runtime/execution_context.zig").Environment;

/// Phase 1 tree-walker call frame: tracks function name for error messages.
pub const Frame = struct {
    function_name: ?[]const u8,
    env: *Environment,

    pub fn init(name: ?[]const u8, env: *Environment) Frame {
        return Frame{ .function_name = name, .env = env };
    }
};

/// Phase 2 bytecode call frame. Defined here for import convenience;
/// the full implementation lives in vm/bc_vm.zig.
pub const BcCallFrame = @import("./bc_vm.zig").BcCallFrame;

test "Frame init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const env = try Environment.init(arena.allocator(), null);
    const f = Frame.init("test", env);
    try std.testing.expectEqualStrings("test", f.function_name.?);
}

test "BcCallFrame type exists" {
    // Compilation check.
    const T = BcCallFrame;
    _ = T;
    try std.testing.expect(true);
}
