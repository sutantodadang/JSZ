// SPDX-License-Identifier: MIT
//! Regex VM stub — backtracking matcher. Phase 4.
const std = @import("std");
const RegexPattern = @import("./parser.zig").RegexPattern;

pub const MatchResult = struct {
    matched: bool,
    start: usize = 0,
    end: usize = 0,
};

/// Execute a regex against input. Phase 4.
pub fn execute(_: *const RegexPattern, _: []const u8) MatchResult {
    return .{ .matched = false };
}

test "regex vm stub" {
    const pat = RegexPattern{ .source = "a+" };
    const r = execute(&pat, "aaa");
    try std.testing.expect(!r.matched);
}
