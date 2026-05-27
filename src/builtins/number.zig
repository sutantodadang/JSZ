// SPDX-License-Identifier: MIT
//! Number builtin stub. Phase 3a.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "number.install stub" {
    try std.testing.expect(true);
}
