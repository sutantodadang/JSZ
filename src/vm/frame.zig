// SPDX-License-Identifier: Apache-2.0
//! Bytecode VM call frame re-export.
const std = @import("std");

/// Phase 2 bytecode call frame. Defined here for import convenience;
/// the full implementation lives in vm/bc_vm.zig.
pub const BcCallFrame = @import("./bc_vm.zig").BcCallFrame;

test "BcCallFrame type exists" {
    // Compilation check.
    const T = BcCallFrame;
    _ = T;
    try std.testing.expect(true);
}
