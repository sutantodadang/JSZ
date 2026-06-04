// SPDX-License-Identifier: MIT
//! Benchmark: fib(20) under the bytecode VM.
const std = @import("std");
const jsz = @import("jsz");

const FIB20 = "(function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); })(20)";
const ITERS = 10;

fn benchMode(allocator: std.mem.Allocator, mode: jsz.InterpMode) !f64 {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        var iso = try jsz.Isolate.init(allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        ctx.setInterpMode(mode);
        const result = ctx.eval(FIB20, "<bench>");
        switch (result) {
            .ok => |v| {
                const n = v.toF64();
                if (n != 6765.0) {
                    std.debug.print("ERROR: expected 6765, got {d}\n", .{n});
                    return error.WrongResult;
                }
            },
            .exception => |e| {
                std.debug.print("exception: {s}\n", .{e.message});
                return error.JsException;
            },
            .parse_error => |e| {
                std.debug.print("parse_error: {s}\n", .{e.message});
                return error.ParseFailed;
            },
        }
    }
    const elapsed_ns = timer.read();
    const avg_ns: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, ITERS);
    return avg_ns / 1_000_000.0; // ms
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [512]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    const bc_ms = try benchMode(allocator, .bc);
    try out.print("bc: {d:.3}ms\n", .{bc_ms});
    try out.flush();
}
