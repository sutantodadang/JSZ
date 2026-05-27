// SPDX-License-Identifier: MIT
//! JSON builtin stub. Phase 4.
const std = @import("std");
const JszError = @import("../root.zig").JszError;

pub fn install(_: *anyopaque) JszError!void {
    return error.NotImplemented;
}

test "json.install stub" {
    try std.testing.expect(true);
}
