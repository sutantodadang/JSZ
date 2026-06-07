// SPDX-License-Identifier: Apache-2.0
//! VM fuzz harness: arbitrary bytes treated as JS source, no panics allowed.
//! Run: zig build fuzz --fuzz
const std = @import("std");
const jsz = @import("jsz");

test "fuzz vm" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            var iso = jsz.Isolate.init(std.testing.allocator) catch return;
            defer iso.deinit();
            var ctx = iso.newContext() catch return;
            defer ctx.deinit();
            // Run lex + parse + eval. Any result is fine.
            _ = ctx.eval(input, "<fuzz>");
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
