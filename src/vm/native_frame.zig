// SPDX-License-Identifier: MIT
//! Native re-entry ABI stub — HandleScope around every native boundary.
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const HandleScope = @import("../gc/handle.zig").HandleScope;

/// Represents a native function activation on the call stack.
/// Mandatory: create one on the Zig stack before calling any JS-accessible API.
pub const NativeFrame = struct {
    scope: HandleScope = .{},
    _prev: ?*NativeFrame = null,

    pub fn enter(self: *NativeFrame) void {
        self.scope.open();
    }

    pub fn leave(self: *NativeFrame) void {
        self.scope.close();
        _ = self._prev;
    }
};

test "NativeFrame stub" {
    var nf = NativeFrame{};
    nf.enter();
    nf.leave();
    try std.testing.expect(true);
}
