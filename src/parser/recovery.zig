// SPDX-License-Identifier: MIT
//! ParseError accumulator. Collects errors; parser aborts on first in Phase 1.
const std = @import("std");

pub const ParseError = struct {
    message: []const u8,
    line: u32,
    column: u32,
};

/// Accumulates parse errors. In Phase 1, we stop at the first error.
pub const ErrorAccumulator = struct {
    errors: std.ArrayListUnmanaged(ParseError) = .{},

    pub fn add(self: *ErrorAccumulator, allocator: std.mem.Allocator, err: ParseError) !void {
        try self.errors.append(allocator, err);
    }

    pub fn hasErrors(self: *const ErrorAccumulator) bool {
        return self.errors.items.len > 0;
    }

    pub fn first(self: *const ErrorAccumulator) ?ParseError {
        if (self.errors.items.len == 0) return null;
        return self.errors.items[0];
    }

    pub fn deinit(self: *ErrorAccumulator, allocator: std.mem.Allocator) void {
        self.errors.deinit(allocator);
    }
};

test "ErrorAccumulator empty" {
    var acc = ErrorAccumulator{};
    defer acc.deinit(std.testing.allocator);
    try std.testing.expect(!acc.hasErrors());
}

test "ErrorAccumulator add and first" {
    var acc = ErrorAccumulator{};
    defer acc.deinit(std.testing.allocator);
    try acc.add(std.testing.allocator, .{ .message = "oops", .line = 1, .column = 5 });
    try std.testing.expect(acc.hasErrors());
    const e = acc.first().?;
    try std.testing.expectEqualStrings("oops", e.message);
}
