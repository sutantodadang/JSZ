// SPDX-License-Identifier: MIT
//! Object builtin stub. Phase 3a.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "object.install stub" {
    try std.testing.expect(true);
}
