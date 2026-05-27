// SPDX-License-Identifier: MIT
//! Global object builtins stub. Phase 3a.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "global.install stub" {
    try std.testing.expect(true);
}
