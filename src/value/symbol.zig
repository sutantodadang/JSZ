// SPDX-License-Identifier: Apache-2.0
//! Symbol stub — ES2015 placeholder, Phase 7.
const std = @import("std");
const Cell = @import("./cell.zig").Cell;

pub const Symbol = struct {
    cell: Cell = .{},
    /// Unique id assigned by the symbol registry.
    id: u64 = 0,
    /// Optional description string (may be null).
    description: ?[]const u8 = null,
};

test "Symbol default" {
    const s = Symbol{};
    try std.testing.expect(s.id == 0);
}
