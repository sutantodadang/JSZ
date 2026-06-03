// SPDX-License-Identifier: MIT
//! Regex fuzz harness: arbitrary bytes as a pattern must not panic.
//! Invalid patterns return error (fine); the matcher must not crash.
//! Run: zig build fuzz --fuzz
const std = @import("std");
const regexp = @import("jsz")._regex;

test "fuzz regex" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const re = regexp.compileRegex(arena.allocator(), input, "") catch return;
            // Short subject bounds backtracking; any match result is fine.
            _ = regexp.matchAnywhere(&re, "abcabcabcabc", 0);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
