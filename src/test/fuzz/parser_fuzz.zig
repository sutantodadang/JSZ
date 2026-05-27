// SPDX-License-Identifier: MIT
//! Parser fuzz harness: arbitrary bytes must not cause panics.
//! Parse errors and lex errors are OK; panics are not.
//! Run: zig build fuzz --fuzz
const std = @import("std");
const jsz = @import("jsz");

test "fuzz parser" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            var iso = jsz.Isolate.init(std.testing.allocator) catch return;
            defer iso.deinit();
            var ctx = iso.newContext() catch return;
            defer ctx.deinit();
            // Any result is fine (ok, exception, parse_error). No panics allowed.
            _ = ctx.eval(input, "<fuzz>");
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
