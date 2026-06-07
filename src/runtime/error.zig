// SPDX-License-Identifier: Apache-2.0
//! Error message formatting helpers for Phase 1 runtime errors.
const std = @import("std");

pub const RuntimeErrorKind = enum {
    type_error,
    reference_error,
    range_error,
    generic,
};

/// Format a runtime error message into the provided buffer.
pub fn formatError(
    allocator: std.mem.Allocator,
    kind: RuntimeErrorKind,
    message: []const u8,
) ![]const u8 {
    const prefix = switch (kind) {
        .type_error => "TypeError",
        .reference_error => "ReferenceError",
        .range_error => "RangeError",
        .generic => "Error",
    };
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, message });
}

test "formatError type_error" {
    const msg = try formatError(std.testing.allocator, .type_error, "not a function");
    defer std.testing.allocator.free(msg);
    try std.testing.expectEqualStrings("TypeError: not a function", msg);
}
