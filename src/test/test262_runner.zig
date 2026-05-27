// SPDX-License-Identifier: MIT
//! Test262 conformance runner.
//! When external/test262/test/ is absent, prints instructions and exits 0.
//! To activate: git submodule add https://github.com/tc39/test262 external/test262
const std = @import("std");
const jsz = @import("jsz");

const TEST262_PATH = "external/test262/test";
const WHITELIST_PATH = "tests/test262_whitelist.txt";

/// Frontmatter metadata from a test262 file header.
const TestMeta = struct {
    description: []const u8 = "",
    negative: bool = false,
    negative_type: []const u8 = "",
    flags: []const u8 = "",
    includes: []const u8 = "",
};

/// Parse the /*--- ... ---*/ frontmatter block.
fn parseMeta(allocator: std.mem.Allocator, source: []const u8) !TestMeta {
    _ = allocator;
    var meta = TestMeta{};
    const start_marker = "/*---";
    const end_marker = "---*/";
    const start = std.mem.indexOf(u8, source, start_marker) orelse return meta;
    const rest = source[start + start_marker.len ..];
    const end = std.mem.indexOf(u8, rest, end_marker) orelse return meta;
    const yaml = rest[0..end];
    // Phase 1: minimal parsing — just detect "negative:" key.
    if (std.mem.indexOf(u8, yaml, "negative:") != null) {
        meta.negative = true;
    }
    return meta;
}

fn runOneTest(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !bool {
    const meta = try parseMeta(allocator, source);
    _ = path;

    var iso = jsz.Isolate.init(allocator) catch return false;
    defer iso.deinit();
    var ctx = iso.newContext() catch return false;
    defer ctx.deinit();

    const result = ctx.eval(source, "<test262>");
    if (meta.negative) {
        // Negative test: expect exception or parse error.
        return switch (result) {
            .exception, .parse_error => true,
            .ok => false,
        };
    }
    return switch (result) {
        .ok => true,
        .exception => false,
        .parse_error => false,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const list_mode = for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--list")) break true;
    } else false;

    // Check if test262 corpus exists.
    std.fs.cwd().access(TEST262_PATH, .{}) catch {
        try out.print(
            "Test262 corpus not found at {s}.\n" ++
            "Run: git submodule add https://github.com/tc39/test262 external/test262\n",
            .{TEST262_PATH},
        );
        try out.flush();
        return; // exit 0 — absence is OK
    };

    // Load whitelist
    var whitelist: std.ArrayList([]const u8) = .empty;
    defer whitelist.deinit(allocator);
    const wl_src = std.fs.cwd().readFileAlloc(allocator, WHITELIST_PATH, 1 * 1024 * 1024) catch null;
    defer if (wl_src) |s| allocator.free(s);
    if (wl_src) |src| {
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
                try whitelist.append(allocator, trimmed);
            }
        }
    }

    if (list_mode) {
        try out.print("Test262 whitelist ({d} tests):\n", .{whitelist.items.len});
        for (whitelist.items) |entry| {
            try out.print("  {s}\n", .{entry});
        }
        try out.flush();
        return;
    }

    // Run whitelisted tests.
    var pass: u32 = 0;
    var fail: u32 = 0;
    for (whitelist.items) |rel_path| {
        var path_buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TEST262_PATH, rel_path }) catch continue;
        const source = std.fs.cwd().readFileAlloc(allocator, full, 512 * 1024) catch continue;
        defer allocator.free(source);
        if (try runOneTest(allocator, rel_path, source)) {
            pass += 1;
        } else {
            fail += 1;
            try out.print("FAIL: {s}\n", .{rel_path});
        }
    }

    try out.print("Test262: {d} pass, {d} fail out of {d} whitelisted\n", .{
        pass, fail, whitelist.items.len,
    });
    try out.flush();

    if (fail > 0) std.process.exit(1);
}

test "test262_runner compiles" {
    try std.testing.expect(true);
}

test "parseMeta: detects negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\/*---
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
        \\var x = ;
    ;
    const meta = try parseMeta(arena.allocator(), source);
    try std.testing.expect(meta.negative);
}
