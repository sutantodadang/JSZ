// SPDX-License-Identifier: MIT
//! Minimal jsz embedding example. Build + run: `zig build example-embed`.
const std = @import("std");
const jsz = @import("jsz");

fn hostAddOne(ctx: *jsz.Context, args: []const jsz.Value) jsz.NativeResult {
    const n = if (args.len > 0) args[0].toF64() else 0;
    return .{ .ok = ctx.makeNumber(n + 1) };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    // Expose a host function to JS.
    try ctx.registerNativeFn("addOne", hostAddOne);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    // Globals persist across eval calls on the same context.
    _ = ctx.eval("var total = 0;", "<embed>");
    _ = ctx.eval("total = addOne(total); total = addOne(total);", "<embed>");

    switch (ctx.eval("total", "<embed>")) {
        .ok => |v| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const s = try jsz.valueToDisplayString(arena.allocator(), v);
            try out.print("total = {s}\n", .{s});
        },
        .exception => |e| try out.print("uncaught: {s}\n", .{e.message}),
        .parse_error => |e| try out.print("syntax error: {s}\n", .{e.message}),
    }

    // Read a JS global back from the host via globalObject().
    const g = ctx.globalObject();
    const total = ctx.getProperty(g, "total");
    try out.print("host sees total = {d}\n", .{total.toF64()});
    try out.flush();
}
