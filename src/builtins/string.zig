// SPDX-License-Identifier: MIT
//! String builtin stub. Phase 3a.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "string.install stub" {
    try std.testing.expect(true);
}
