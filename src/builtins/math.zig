// SPDX-License-Identifier: MIT
//! Math builtin stub. Phase 4.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "math.install stub" {
    try std.testing.expect(true);
}
