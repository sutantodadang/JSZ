// SPDX-License-Identifier: MIT
//! Node.js differential testing harness.
//! For each corpus file, runs jsz under bc mode and compares against Node.js.
const std = @import("std");
const jsz = @import("jsz");

const CORPUS_PATH = "tests/diff_corpus";

fn runJszMode(allocator: std.mem.Allocator, source: []const u8, mode: jsz.InterpMode) ![]const u8 {
    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<diff>");
    return switch (result) {
        .ok => |v| jsz.valueToDisplayString(allocator, v) catch "?",
        .exception => |e| try std.fmt.allocPrint(allocator, "ERROR:{s}", .{e.message}),
        .parse_error => |e| try std.fmt.allocPrint(allocator, "SYNTAX:{s}", .{e.message}),
    };
}

fn runNode(allocator: std.mem.Allocator, source: []const u8) !?[]const u8 {
    const node_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "node", "--version" },
    }) catch return null;
    allocator.free(node_check.stdout);
    allocator.free(node_check.stderr);

    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(allocator);
    for (source) |c| switch (c) {
        '\\' => try esc.appendSlice(allocator, "\\\\"),
        '"' => try esc.appendSlice(allocator, "\\\""),
        '\n' => try esc.appendSlice(allocator, "\\n"),
        '\r' => try esc.appendSlice(allocator, "\\r"),
        '\t' => try esc.appendSlice(allocator, "\\t"),
        else => try esc.append(allocator, c),
    };
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "process.stdout.write(String((function(){{ return eval(\"{s}\"); }})()))",
        .{esc.items},
    );
    defer allocator.free(wrapped);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "node", "-e", wrapped },
    }) catch return null;
    defer allocator.free(result.stderr);
    const stdout = result.stdout;
    return std.mem.trimRight(u8, stdout, "\r\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    std.fs.cwd().access(CORPUS_PATH, .{}) catch {
        try out.print("Differential corpus not found at {s}. Skipping.\n", .{CORPUS_PATH});
        try out.flush();
        return;
    };

    const node_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "node", "--version" },
    }) catch {
        try out.print("Differential testing requires Node.js (node not found on PATH). Skipping.\n", .{});
        try out.flush();
        return;
    };
    allocator.free(node_result.stdout);
    allocator.free(node_result.stderr);

    var dir = try std.fs.cwd().openDir(CORPUS_PATH, .{ .iterate = true });
    defer dir.close();

    var pass: u32 = 0;
    var fail: u32 = 0;
    var skip: u32 = 0;
    var total: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        total += 1;

        var path_buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ CORPUS_PATH, entry.name }) catch continue;
        const source = std.fs.cwd().readFileAlloc(allocator, full, 64 * 1024) catch continue;
        defer allocator.free(source);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const bc_out = runJszMode(arena.allocator(), source, .bc) catch {
            skip += 1;
            continue;
        };
        const node_out_opt = runNode(arena.allocator(), source) catch {
            skip += 1;
            continue;
        };

        if (node_out_opt == null) {
            skip += 1;
            continue;
        }
        const node_out = node_out_opt.?;

        const bc_ok = std.mem.eql(u8, bc_out, node_out);

        if (bc_ok) {
            pass += 1;
        } else {
            fail += 1;
            try out.print("MISMATCH bc:   {s}\n  bc:   {s}\n  node: {s}\n", .{
                entry.name, bc_out, node_out,
            });
        }
    }

    try out.print("{d}/{d} tests pass; {d} mismatches; {d} skipped\n", .{ pass, total, fail, skip });
    try out.flush();

    if (fail > 0) std.process.exit(1);
}

test "differential compiles" {
    try std.testing.expect(true);
}
