// SPDX-License-Identifier: MIT
//! Regex parser stub — dedicated sub-engine. Phase 4.
const std = @import("std");

pub const RegexPattern = struct {
    source: []const u8,
    flags: []const u8 = "",
};

/// Parse a regex pattern into an AST. Phase 4.
pub fn parse(_: []const u8, _: []const u8) ?RegexPattern {
    return null;
}

test "regex parser stub" {
    try std.testing.expect(parse(".*", "") == null);
}
