// SPDX-License-Identifier: MIT
//! OneByteString (Latin-1) and TwoByteString (UCS-2) stubs.
const std = @import("std");
const Cell = @import("./cell.zig").Cell;

pub const OneByteString = struct {
    cell: Cell = .{},
    len: u32 = 0,
    /// Inline bytes follow the struct in the allocation.

    pub fn slice(_: *const OneByteString) []const u8 {
        return "";
    }
};

pub const TwoByteString = struct {
    cell: Cell = .{},
    len: u32 = 0,
    /// Inline u16 code units follow the struct in the allocation.

    pub fn slice(_: *const TwoByteString) []const u16 {
        return &[_]u16{};
    }
};

pub const StringVariant = union(enum) {
    one_byte: *OneByteString,
    two_byte: *TwoByteString,
};

test "StringVariant compiles" {
    try std.testing.expect(true);
}
