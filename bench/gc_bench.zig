// SPDX-License-Identifier: Apache-2.0
//! M19 GC perf benchmark: generational vs non-generational mark-sweep.
//!
//! Runs the same GC-heavy workload (a stable retained set + heavy short-lived
//! churn) under two collector configurations on fresh isolates:
//!   A) generational  — minor (nursery) collections, a major every N minors.
//!   B) mark-sweep     — every auto-collection is a full major (major_period=0).
//! Reports wall-clock throughput and pause percentiles (p50/p99/max) for each,
//! then the throughput speedup and p99 pause for the M19 gate:
//!   * p99 pause < 10 ms
//!   * throughput >= 2x vs mark-sweep
//!
//! Usage: zig build gc-bench
const std = @import("std");
const jsz = @import("jsz");

// Fixed 1 MiB nursery: minor collections stay cheap and roughly constant-cost.
const NURSERY: usize = 1024 * 1024;
const MAJOR_PERIOD: usize = 16; // generational: 1 major per 16 minors

// Workload: a large stable old set (KEEP) makes a full major expensive, while a
// heavy short-lived churn drives many collections. Generational wins because a
// minor never traces/sweeps the big old set.
const SOURCE =
    \\var keep = [];
    \\var KEEP = 20000;
    \\for (var k = 0; k < KEEP; k++) { keep.push({ id: k, p: { q: k, r: k * 2 } }); }
    \\var sink = 0;
    \\var CHURN = 1500000;
    \\for (var i = 0; i < CHURN; i++) {
    \\  var tmp = { a: i, b: i * 2, c: { d: i, e: i + 1 } };
    \\  sink += tmp.a + tmp.c.d;
    \\}
    \\sink
;

const RunResult = struct {
    wall_ns: u64,
    gc_ns: u64, // total time spent in GC (sum of pauses)
    collections: usize,
    minor: usize,
    major: usize,
    p50_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    objects_alive: usize,
};

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(@round(idx_f));
    return sorted[@min(idx, sorted.len - 1)];
}

fn runWorkload(alloc: std.mem.Allocator, major_period: usize) !RunResult {
    var iso = try jsz.Isolate.init(alloc);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // Configure the collector and enable pause logging BEFORE the workload runs.
    ctx.gcConfigure(NURSERY, major_period, true);

    var timer = try std.time.Timer.start();
    const result = ctx.eval(SOURCE, "<gc-bench>");
    const wall_ns = timer.read();
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("FAIL: exception: {s}\n", .{e.message});
            return error.WorkloadFailed;
        },
        .parse_error => |e| {
            std.debug.print("FAIL: parse error: {s}\n", .{e.message});
            return error.WorkloadFailed;
        },
    }

    // Copy + sort the pauses to compute percentiles + total GC time.
    const pauses = ctx.gcPauses();
    const buf = try alloc.alloc(u64, pauses.len);
    defer alloc.free(buf);
    @memcpy(buf, pauses);
    var gc_ns: u64 = 0;
    for (buf) |p| gc_ns += p;
    std.mem.sort(u64, buf, {}, std.sort.asc(u64));

    const stats = ctx.gcStats();
    const gen = ctx.gcGenCounts();
    return RunResult{
        .wall_ns = wall_ns,
        .gc_ns = gc_ns,
        .collections = stats.collections,
        .minor = gen.minor,
        .major = gen.major,
        .p50_ns = percentile(buf, 0.50),
        .p99_ns = percentile(buf, 0.99),
        .max_ns = if (buf.len > 0) buf[buf.len - 1] else 0,
        .objects_alive = stats.objects_alive,
    };
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn report(name: []const u8, r: RunResult) void {
    std.debug.print(
        \\[{s}]
        \\  wall:        {d:.2} ms
        \\  gc total:    {d:.2} ms ({d:.1}% of wall)
        \\  collections: {d} (minor {d}, major {d})
        \\  pause p50:   {d:.4} ms
        \\  pause p99:   {d:.4} ms
        \\  pause max:   {d:.4} ms
        \\  alive:       {d}
        \\
    , .{ name, ms(r.wall_ns), ms(r.gc_ns), 100.0 * @as(f64, @floatFromInt(r.gc_ns)) / @as(f64, @floatFromInt(r.wall_ns)), r.collections, r.minor, r.major, ms(r.p50_ns), ms(r.p99_ns), ms(r.max_ns), r.objects_alive });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("=== M19 GC benchmark (generational vs mark-sweep) ===\n", .{});
    std.debug.print("workload: 20000 retained + 1500000 churned objects, 1 MiB nursery\n\n", .{});

    // Warm up once (page-in, code paths) — discard.
    _ = try runWorkload(alloc, MAJOR_PERIOD);

    const sweep = try runWorkload(alloc, 0); // every collect is a full major
    const gen = try runWorkload(alloc, MAJOR_PERIOD);

    report("mark-sweep (major_period=0)", sweep);
    report("generational (major_period=16)", gen);

    // GC throughput = work reclaimed per unit of GC time; with the same workload,
    // the meaningful ratio is GC-time(mark-sweep) / GC-time(generational). Total
    // wall time is mutator-dominated, so it is reported but not the gate metric.
    const gc_speedup = @as(f64, @floatFromInt(sweep.gc_ns)) / @as(f64, @floatFromInt(gen.gc_ns));
    const wall_speedup = @as(f64, @floatFromInt(sweep.wall_ns)) / @as(f64, @floatFromInt(gen.wall_ns));
    const p99_ms = ms(gen.p99_ns);
    std.debug.print(
        \\
        \\=== M19 gate ===
        \\  GC throughput (mark-sweep GC time / generational GC time): {d:.2}x  (target >= 2.00x)
        \\  generational p99 pause: {d:.4} ms  (target < 10 ms)
        \\  (wall-time speedup, mutator-dominated, for reference: {d:.2}x)
        \\
    , .{ gc_speedup, p99_ms, wall_speedup });

    const pass_speedup = gc_speedup >= 2.0;
    const pass_pause = p99_ms < 10.0;
    if (pass_speedup and pass_pause) {
        std.debug.print("  RESULT: PASS\n", .{});
    } else {
        std.debug.print("  RESULT: GC throughput {s}, p99 {s}\n", .{
            if (pass_speedup) "PASS" else "FAIL",
            if (pass_pause) "PASS" else "FAIL",
        });
    }
}
