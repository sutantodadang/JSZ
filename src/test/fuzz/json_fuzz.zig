// SPDX-License-Identifier: Apache-2.0
//! JSON fuzz harness: arbitrary bytes fed to JSON.parse must not panic.
//! The bytes are embedded as a JS string literal so JSON.parse receives them
//! verbatim as its source. Any result (ok/exception) is fine; panics are not.
//! Run: zig build fuzz --fuzz
const std = @import("std");
const jsz = @import("jsz");

/// Emit `bytes` as a JS double-quoted string literal into `out`.
fn jsLit(a: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    const hx = "0123456789abcdef";
    try out.append(a, '"');
    for (bytes) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try out.append(a, c),
        else => {
            try out.appendSlice(a, "\\x");
            try out.append(a, hx[c >> 4]);
            try out.append(a, hx[c & 0xF]);
        },
    };
    try out.append(a, '"');
}

test "fuzz json" {
    const Context = struct {
        fn testOne(_: @This(), input: []const u8) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var src = std.ArrayList(u8){};
            src.appendSlice(a, "JSON.parse(") catch return;
            jsLit(a, input, &src) catch return;
            src.append(a, ')') catch return;

            var iso = jsz.Isolate.init(std.testing.allocator) catch return;
            defer iso.deinit();
            var ctx = iso.newContext() catch return;
            defer ctx.deinit();
            _ = ctx.eval(src.items, "<fuzz>");
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
