// SPDX-License-Identifier: Apache-2.0
//! Soak test: long-running stability gates for embedders.
//!
//! Four phases, each with a bounded-resource assertion; any breach exits 1:
//!   1. eval-churn      — thousands of evals in ONE context; live objects
//!                        after GC must stay flat (no per-eval leak).
//!   2. context-churn   — create/use/destroy contexts in one isolate; live
//!                        objects after GC must stay bounded.
//!   3. isolate-churn   — create/use/destroy whole isolates, each on its own
//!                        GeneralPurposeAllocator; gpa.deinit() must report
//!                        no leaks for every single isolate lifecycle.
//!   4. interrupt-churn — gas-limited `while(true){}` over and over; every
//!                        run must interrupt as an exception and the engine
//!                        must stay healthy afterwards.
//!
//! Usage: zig build soak            (defaults sized for ~1-2 min in CI)
//!        zig build soak -- 5       (scale all iteration counts 5x)
const std = @import("std");
const jsz = @import("jsz");

var out_buf: [4096]u8 = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var stdout: *std.Io.Writer = undefined;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    stdout.print("FAIL: " ++ fmt ++ "\n", args) catch {};
    stdout.flush() catch {};
    std.process.exit(1);
}

/// Mixed workload: objects + shape splits, arrays, strings, closures, Map,
/// JSON roundtrip, regex. Reassigns the same globals every eval so prior
/// garbage is collectable. Returns a checksum the caller asserts.
const CHURN_SRC =
    \\var objs = [];
    \\for (var i = 0; i < 300; i++) {
    \\  var o = { i: i, s: "s" + i, f: (function (n) { return function () { return n; }; })(i) };
    \\  if ((i & 7) === 0) o.extra = i;
    \\  objs.push(o);
    \\}
    \\var m = new Map();
    \\for (var k = 0; k < 50; k++) m.set("k" + k, { v: k });
    \\var round = JSON.parse(JSON.stringify({ list: objs.slice(0, 20), n: 7 }));
    \\var hits = 0;
    \\for (var r = 0; r < 40; r++) if (/s1\d/.test(objs[r].s)) hits++;
    \\objs[13].f() + m.get("k7").v + round.list.length + round.n + hits
;
const CHURN_EXPECT: f64 = 13 + 7 + 20 + 7 + 10;

fn evalExpect(ctx: *jsz.Context, src: []const u8, expect: f64, phase: []const u8) void {
    switch (ctx.eval(src, "<soak>")) {
        .ok => |v| {
            if (v.toF64() != expect)
                fail("{s}: expected {d}, got {d}", .{ phase, expect, v.toF64() });
        },
        .exception => |e| fail("{s}: exception: {s}", .{ phase, e.message }),
        .parse_error => |e| fail("{s}: parse error: {s}", .{ phase, e.message }),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    stdout_writer = std.fs.File.stdout().writer(&out_buf);
    stdout = &stdout_writer.interface;

    // Optional single argument: iteration scale factor.
    var scale: usize = 1;
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // program name
    if (args.next()) |a| scale = std.fmt.parseInt(usize, a, 10) catch 1;

    try stdout.print("=== soak (scale {d}) ===\n", .{scale});

    // ------------------------------------------------------------ phase 1 ---
    {
        var iso = try jsz.Isolate.init(alloc);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();

        const rounds = 800 * scale;
        var baseline_alive: usize = 0;
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            evalExpect(ctx, CHURN_SRC, CHURN_EXPECT, "eval-churn");
            if ((i + 1) % 100 == 0) {
                _ = ctx.gc();
                const alive = ctx.gcStats().objects_alive;
                if (baseline_alive == 0) baseline_alive = alive;
                // Flat-line check: allow 2x slack over the first checkpoint,
                // which catches per-eval leaks long before an absolute cap.
                if (alive > baseline_alive * 2 + 500)
                    fail("eval-churn: live objects grew {d} -> {d} after {d} evals", .{ baseline_alive, alive, i + 1 });
            }
        }
        _ = ctx.gc();
        try stdout.print("phase 1 eval-churn: {d} evals, live after gc {d} (baseline {d})\n", .{ rounds, ctx.gcStats().objects_alive, baseline_alive });
        try stdout.flush();
    }

    // ------------------------------------------------------------ phase 2 ---
    {
        var iso = try jsz.Isolate.init(alloc);
        defer iso.deinit();

        const rounds = 300 * scale;
        var i: usize = 0;
        var last_alive: usize = 0;
        while (i < rounds) : (i += 1) {
            var ctx = try iso.newContext();
            evalExpect(ctx, "var a=[1,2,3].map(function(x){return x*2});a[0]+a[1]+a[2]", 12, "context-churn");
            if ((i + 1) % 100 == 0) {
                _ = ctx.gc();
                last_alive = ctx.gcStats().objects_alive;
                if (last_alive > 20000)
                    fail("context-churn: {d} live objects after {d} contexts", .{ last_alive, i + 1 });
            }
            ctx.deinit();
        }
        try stdout.print("phase 2 context-churn: {d} contexts, last live-after-gc {d}\n", .{ rounds, last_alive });
        try stdout.flush();
    }

    // ------------------------------------------------------------ phase 3 ---
    {
        const rounds = 150 * scale;
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            var iso_gpa = std.heap.GeneralPurposeAllocator(.{}){};
            {
                var iso = jsz.Isolate.init(iso_gpa.allocator()) catch fail("isolate-churn: init OOM at {d}", .{i});
                defer iso.deinit();
                var ctx = iso.newContext() catch fail("isolate-churn: ctx OOM at {d}", .{i});
                defer ctx.deinit();
                evalExpect(ctx, "JSON.stringify([1,{a:'b'}]).length", 13, "isolate-churn");
            }
            if (iso_gpa.deinit() == .leak)
                fail("isolate-churn: allocator leak in isolate lifecycle {d}", .{i});
            // The global shape store intentionally persists across isolates;
            // reset it periodically (safe here: no isolate is live).
            if ((i + 1) % 25 == 0) jsz.resetGlobalShapes();
        }
        jsz.resetGlobalShapes();
        try stdout.print("phase 3 isolate-churn: {d} isolates, 0 allocator leaks\n", .{rounds});
        try stdout.flush();
    }

    // ------------------------------------------------------------ phase 4 ---
    {
        var iso = try jsz.Isolate.init(alloc);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();

        const rounds = 200 * scale;
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            ctx.setLimits(.{ .gas = 200_000 });
            switch (ctx.eval("while (true) {}", "<soak-loop>")) {
                .exception => {},
                .ok => fail("interrupt-churn: runaway loop returned ok at {d}", .{i}),
                .parse_error => |e| fail("interrupt-churn: parse error: {s}", .{e.message}),
            }
            ctx.setLimits(.{});
            evalExpect(ctx, "1 + 1", 2, "interrupt-churn-sanity");
        }
        _ = ctx.gc();
        const alive = ctx.gcStats().objects_alive;
        if (alive > 10_000)
            fail("interrupt-churn: {d} live objects after {d} interrupts", .{ alive, rounds });
        try stdout.print("phase 4 interrupt-churn: {d} interrupts, engine healthy, live {d}\n", .{ rounds, alive });
    }

    try stdout.print("PASS: all soak phases bounded\n", .{});
    try stdout.flush();
}
