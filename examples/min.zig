const std = @import("std");
const root = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var iso = try root.Isolate.init(alloc);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    const result = ctx.eval("var o = {x: 42}; __gc__(); o.x", "<test>");
    switch (result) {
        .ok => |v| std.debug.print("ok: {d}\n", .{v.toF64()}),
        else => std.debug.print("not ok\n", .{}),
    }
}
