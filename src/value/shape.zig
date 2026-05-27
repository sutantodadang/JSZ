// SPDX-License-Identifier: MIT
//! Shape (hidden class) stub — Phase 6.
const std = @import("std");

pub const Shape = struct {
    id: u32 = 0,
    /// Property count tracked by this shape.
    property_count: u32 = 0,
};

test "Shape default" {
    const s = Shape{};
    try std.testing.expect(s.id == 0);
}
