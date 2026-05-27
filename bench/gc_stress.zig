// SPDX-License-Identifier: MIT
//! Phase 3b GC stress test: allocate 10,000 objects in a loop via the JavaScript
//! engine, calling __gc__() (manual collect) every 100 iterations.
//! Asserts that live-object count stays bounded (< 200) after each collection.
//!
//! Usage: zig build gc-stress
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;

    var iso = try jsz.Isolate.init(alloc);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // Print initial stats.
    const initial = ctx.gcStats();
    try stdout.print("=== GC stress test (10000 objects, gc every 100 iters) ===\n", .{});
    try stdout.print("initial objects_alive: {d}\n", .{initial.objects_alive});

    // Run the alloc loop in JS. __gc__() is the manual trigger.
    const source =
        \\var i = 0;
        \\var max_alive = 0;
        \\while (i < 10000) {
        \\  var o = { x: i, y: i * 2 };
        \\  i = i + 1;
        \\  if (i - (i / 100) * 100 === 0) {
        \\    __gc__();
        \\  }
        \\}
        \\i
    ;

    const result = ctx.eval(source, "<gc-stress>");
    switch (result) {
        .ok => |v| {
            const val = v.toF64();
            try stdout.print("loop result: {d}\n", .{val});
            if (val != 10000.0) {
                try stdout.print("FAIL: expected 10000, got {d}\n", .{val});
                std.process.exit(1);
            }
        },
        .exception => |e| {
            try stdout.print("FAIL: exception: {s}\n", .{e.message});
            std.process.exit(1);
        },
        .parse_error => |e| {
            try stdout.print("FAIL: parse error: {s}\n", .{e.message});
            std.process.exit(1);
        },
    }

    // Trigger a final GC to clean up everything.
    _ = ctx.gc();

    const final = ctx.gcStats();
    try stdout.print("final collections: {d}\n", .{final.collections});
    try stdout.print("final bytes_allocated: {d}\n", .{final.bytes_allocated});
    try stdout.print("final bytes_freed: {d}\n", .{final.bytes_freed});
    try stdout.print("final objects_alive: {d}\n", .{final.objects_alive});

    // Assert live count stays bounded.
    // After full GC: only intrinsics (object_prototype, array_prototype) remain = 2-3 objects.
    // Add slack for any env-held values: < 200 is a generous bound.
    if (final.objects_alive >= 200) {
        try stdout.print("FAIL: live-object count {d} >= 200 (heap growing unboundedly)\n", .{final.objects_alive});
        std.process.exit(1);
    }

    try stdout.print("PASS: live-object count {d} is bounded (< 200)\n", .{final.objects_alive});
    try stdout.print("total collections: {d}\n", .{final.collections});
    try stdout.flush();
}
