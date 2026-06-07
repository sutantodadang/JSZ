// SPDX-License-Identifier: Apache-2.0
//! JS Object stub — Cell-headed, hashmap-backed slots (Phase 3a).
const std = @import("std");
const Cell = @import("./cell.zig").Cell;
const Value = @import("./value.zig").Value;

pub const Object = struct {
    cell: Cell = .{},
    /// Slot storage — phase 3a will use a hashmap.
    _slots: ?*anyopaque = null,

    pub fn getSlot(_: *Object, _: []const u8) Value {
        return Value{};
    }

    pub fn setSlot(_: *Object, _: []const u8, _: Value) void {}
};

test "Object default" {
    const o = Object{};
    try std.testing.expect(o.cell.flags == 0);
}
