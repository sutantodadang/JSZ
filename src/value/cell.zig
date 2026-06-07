// SPDX-License-Identifier: Apache-2.0
//! Cell header — foundation for all GC-managed objects.
//! No imports from other jsz modules; this is the lowest layer.
const std = @import("std");

/// Every heap-allocated JS object begins with a Cell header.
/// Stores shape pointer, GC flags, and object size.
pub const Cell = struct {
    /// GC color bits + object-type tag. Layout TBD in Phase 3b.
    flags: u32 = 0,
    /// Byte size of this object (including the Cell header).
    size: u32 = 0,
    /// Opaque pointer to the Shape (hidden class). Null until Phase 6.
    shape: ?*anyopaque = null,
};

test "Cell default" {
    const c = Cell{};
    try std.testing.expect(c.flags == 0);
}
