// SPDX-License-Identifier: Apache-2.0
//! Minimal jsz embedding example. Builds with `zig build example-hello`.
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var iso = try jsz.Isolate.init(alloc);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    const result = ctx.eval("1 + 2", "<embed>");
    switch (result) {
        .ok => |v| std.debug.print("1 + 2 = {d}\n", .{v.toF64()}),
        .exception => |e| std.debug.print("uncaught: {s}\n", .{e.message}),
        .parse_error => |e| std.debug.print("SyntaxError: {s}\n", .{e.message}),
    }
}
