// SPDX-License-Identifier: MIT
//! Inline cache stub — monomorphic -> polymorphic -> megamorphic. Phase 6.
const std = @import("std");

pub const IcState = enum { uninitialized, monomorphic, polymorphic, megamorphic };

pub const InlineCache = struct {
    state: IcState = .uninitialized,
    /// Cached shape pointer (mono state). Phase 6.
    shape: ?*anyopaque = null,
};

test "IC default" {
    const ic = InlineCache{};
    try std.testing.expect(ic.state == .uninitialized);
}
