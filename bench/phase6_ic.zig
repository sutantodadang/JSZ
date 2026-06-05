// SPDX-License-Identifier: MIT
//! Phase 6 benchmark: object/shape heavy property access.
//! Measures bytecode VM property-access throughput.
const std = @import("std");
const jsz = @import("jsz");

const ITERS = 8;

const HOT_OBJECT =
    \\var o = ({ x: 1, y: 2, z: 3 });
    \\var sum = 0;
    \\for (var i = 0; i < 120000; i = i + 1) {
    \\  sum = sum + o.x;
    \\  o.x = (o.x + 1) % 97;
    \\}
    \\sum;
;

const POLY_OBJECT =
    \\var a = ({ x: 1 });
    \\var b = ({ x: 2 });
    \\var c = ({ x: 3 });
    \\var d = ({ x: 4 });
    \\var out = 0;
    \\for (var i = 0; i < 80000; i = i + 1) {
    \\  out = out + a.x + b.x + c.x + d.x;
    \\}
    \\out;
;

const DYN_STRING_KEY =
    \\var o = ({ x: 1, y: 2 });
    \\var k = "x";
    \\var sum = 0;
    \\for (var i = 0; i < 120000; i = i + 1) {
    \\  sum = sum + o[k];
    \\  o[k] = (o[k] + 1) % 97;
    \\}
    \\sum;
;

const ARITH_HOT =
    \\var s = 0;
    \\for (var i = 0; i < 400000; i = i + 1) {
    \\  s = s + (i * 3) - 7;
    \\}
    \\s;
;

const TYPEOF_HOT =
    \\var o = ({ x: 1 });
    \\var c = 0;
    \\for (var i = 0; i < 250000; i = i + 1) {
    \\  if (typeof o === "object") c = c + 1;
    \\}
    \\c;
;

const INSTANCEOF_HOT =
    \\function C() {}
    \\var o = new C();
    \\var c = 0;
    \\for (var i = 0; i < 150000; i = i + 1) {
    \\  if (o instanceof C) c = c + 1;
    \\}
    \\c;
;

// Megamorphic benchmark: a single access site reads .v from objects cycling
// through 12 distinct shapes, driving the site past the polymorphic cap (8)
// and exercising the MegaIC HashMap path.
const MEGA_OBJECT =
    \\function mk(tag) {
    \\  var o = { v: tag };
    \\  if (tag === 0)  { o.a0 = 0; }
    \\  if (tag === 1)  { o.a1 = 1; }
    \\  if (tag === 2)  { o.a2 = 2; }
    \\  if (tag === 3)  { o.a3 = 3; }
    \\  if (tag === 4)  { o.a4 = 4; }
    \\  if (tag === 5)  { o.a5 = 5; }
    \\  if (tag === 6)  { o.a6 = 6; }
    \\  if (tag === 7)  { o.a7 = 7; }
    \\  if (tag === 8)  { o.a8 = 8; }
    \\  if (tag === 9)  { o.a9 = 9; }
    \\  if (tag === 10) { o.a10 = 10; }
    \\  if (tag === 11) { o.a11 = 11; }
    \\  return o;
    \\}
    \\var objs = [];
    \\var n = 0;
    \\while (n < 12) { objs[n] = mk(n); n = n + 1; }
    \\var sum = 0;
    \\for (var i = 0; i < 60000; i = i + 1) {
    \\  sum = sum + objs[i % 12].v;
    \\}
    \\sum;
;

// Prototype method/data dispatch: a single access site reads `.m` (a data
// property living on the shared prototype, not own) off instances in a hot loop.
// Exercises the depth-1 prototype inline cache.
const PROTO_METHOD =
    \\function C() { this.v = 1; }
    \\C.prototype.m = 7;
    \\var arr = [];
    \\var n = 0;
    \\while (n < 4) { arr[n] = new C(); n = n + 1; }
    \\var sum = 0;
    \\for (var i = 0; i < 120000; i = i + 1) {
    \\  sum = sum + arr[i % 4].m;
    \\}
    \\sum;
;

const Case = struct {
    name: []const u8,
    source: []const u8,
};

fn benchCase(allocator: std.mem.Allocator, mode: jsz.InterpMode, source: []const u8) !f64 {
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        var iso = try jsz.Isolate.init(allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        ctx.setInterpMode(mode);
        const result = ctx.eval(source, "<bench-phase6>");
        switch (result) {
            .ok => {},
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
    return (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, ITERS)) / 1_000_000.0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cases = [_]Case{
        .{ .name = "monomorphic", .source = HOT_OBJECT },
        .{ .name = "polymorphic", .source = POLY_OBJECT },
        .{ .name = "dynamic-string-key", .source = DYN_STRING_KEY },
        .{ .name = "arith-hot", .source = ARITH_HOT },
        .{ .name = "typeof-hot", .source = TYPEOF_HOT },
        .{ .name = "instanceof-hot", .source = INSTANCEOF_HOT },
        .{ .name = "megamorphic", .source = MEGA_OBJECT },
        .{ .name = "proto-method", .source = PROTO_METHOD },
    };

    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    for (cases) |c| {
        const bc_ms = try benchCase(allocator, .bc, c.source);
        try out.print("{s}: bc={d:.3}ms\n", .{ c.name, bc_ms });
    }
    try out.flush();
}
