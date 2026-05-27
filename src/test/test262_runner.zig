// SPDX-License-Identifier: MIT
//! Test262 conformance runner.
//! When external/test262/test/ is absent, prints instructions and exits 0.
//! To activate: git submodule add https://github.com/tc39/test262 external/test262
const std = @import("std");
const jsz = @import("jsz");

const TEST262_PATH = "external/test262/test";
const WHITELIST_PATH = "tests/test262_whitelist.txt";
const KNOWN_FAILING_PATH = "tests/test262_known_failing.txt";

const Category = enum(u8) {
    builtins = 0,
    language = 1,
    statements = 2,
    expressions = 3,
};

const category_count: usize = 4;

const CategoryStats = struct {
    pass: u32 = 0,
    fail: u32 = 0,

    fn total(self: CategoryStats) u32 {
        return self.pass + self.fail;
    }
};

const CategoryPriority = struct {
    category: Category,
    weighted_failures: u32,
};

const CategoryWeight = struct {
    category: Category,
    weight: u32,
};

const category_weights = [_]CategoryWeight{
    .{ .category = .builtins, .weight = 4 },
    .{ .category = .language, .weight = 3 },
    .{ .category = .statements, .weight = 2 },
    .{ .category = .expressions, .weight = 2 },
};

fn categoryLabel(category: Category) []const u8 {
    return switch (category) {
        .builtins => "built-ins",
        .language => "language",
        .statements => "statements",
        .expressions => "expressions",
    };
}

fn classifyCategory(rel_path: []const u8) Category {
    if (std.mem.startsWith(u8, rel_path, "built-ins/")) return .builtins;
    if (std.mem.startsWith(u8, rel_path, "language/statements/")) return .statements;
    if (std.mem.startsWith(u8, rel_path, "language/expressions/")) return .expressions;
    return .language;
}

fn formatPercent(out: *std.Io.Writer, numerator: u32, denominator: u32) !void {
    if (denominator == 0) {
        try out.print("n/a", .{});
        return;
    }
    const scaled: u64 = (@as(u64, numerator) * 10_000) / @as(u64, denominator);
    const whole: u64 = scaled / 100;
    const frac: u64 = scaled % 100;
    try out.print("{d}.{d:0>2}%", .{ whole, frac });
}

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

fn loadList(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !struct {
    source: ?[]u8,
    entries: std.ArrayList([]const u8),
} {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer entries.deinit(allocator);

    const src = std.fs.cwd().readFileAlloc(allocator, path, max_size) catch |err| switch (err) {
        error.FileNotFound => return .{ .source = null, .entries = entries },
        else => return err,
    };

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
            try entries.append(allocator, trimmed);
        }
    }
    return .{ .source = src, .entries = entries };
}

fn printCategorySummary(
    out: *std.Io.Writer,
    stats: [category_count]CategoryStats,
    total_pass: u32,
    total_fail: u32,
    total_count: u32,
) !void {
    try out.print("Test262 summary: {d} pass, {d} fail out of {d} (", .{
        total_pass,
        total_fail,
        total_count,
    });
    try formatPercent(out, total_pass, total_count);
    try out.print(")\n", .{});

    try out.print("Category buckets:\n", .{});
    inline for ([_]Category{ .builtins, .language, .statements, .expressions }) |category| {
        const s = stats[@intFromEnum(category)];
        try out.print("  {s}: {d} pass, {d} fail out of {d} (", .{
            categoryLabel(category),
            s.pass,
            s.fail,
            s.total(),
        });
        try formatPercent(out, s.pass, s.total());
        try out.print(")\n", .{});
    }

    var priorities = [_]CategoryPriority{
        .{ .category = .builtins, .weighted_failures = stats[@intFromEnum(Category.builtins)].fail * category_weights[0].weight },
        .{ .category = .language, .weighted_failures = stats[@intFromEnum(Category.language)].fail * category_weights[1].weight },
        .{ .category = .statements, .weighted_failures = stats[@intFromEnum(Category.statements)].fail * category_weights[2].weight },
        .{ .category = .expressions, .weighted_failures = stats[@intFromEnum(Category.expressions)].fail * category_weights[3].weight },
    };

    var i: usize = 0;
    while (i < priorities.len) : (i += 1) {
        var max_idx = i;
        var j: usize = i + 1;
        while (j < priorities.len) : (j += 1) {
            if (priorities[j].weighted_failures > priorities[max_idx].weighted_failures) {
                max_idx = j;
            }
        }
        if (max_idx != i) {
            const tmp = priorities[i];
            priorities[i] = priorities[max_idx];
            priorities[max_idx] = tmp;
        }
    }

    try out.print("Bug priority (weighted failures):\n", .{});
    for (priorities) |entry| {
        try out.print("  {s}: {d}\n", .{
            categoryLabel(entry.category),
            entry.weighted_failures,
        });
    }
}

fn writeDashboard(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    stats: [category_count]CategoryStats,
    pass: u32,
    fail: u32,
    total: u32,
    unexpected_fail: u32,
    unexpected_pass: u32,
) !void {
    _ = allocator;

    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const out = &writer.interface;

    try out.print("# Conformance Dashboard\n\n", .{});
    try out.print("- Total: {d}\n", .{total});
    try out.print("- Pass: {d}\n", .{pass});
    try out.print("- Fail: {d}\n", .{fail});
    try out.print("- Pass rate: ", .{});
    try formatPercent(out, pass, total);
    try out.print("\n", .{});
    try out.print("- Unexpected fail flips: {d}\n", .{unexpected_fail});
    try out.print("- Unexpected pass flips: {d}\n\n", .{unexpected_pass});
    try out.print("| Category | Pass | Fail | Total | Pass rate |\n", .{});
    try out.print("|---|---:|---:|---:|---:|\n", .{});
    inline for ([_]Category{ .builtins, .language, .statements, .expressions }) |category| {
        const s = stats[@intFromEnum(category)];
        try out.print("| {s} | {d} | {d} | {d} | ", .{
            categoryLabel(category),
            s.pass,
            s.fail,
            s.total(),
        });
        try formatPercent(out, s.pass, s.total());
        try out.print(" |\n", .{});
    }
    try out.flush();
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

    var list_mode = false;
    var summary_mode = false;
    var strict_failures = false;
    var dashboard_path: ?[]const u8 = null;
    var arg_idx: usize = 1;
    while (arg_idx < argv.len) : (arg_idx += 1) {
        const arg = argv[arg_idx];
        if (std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_mode = true;
        } else if (std.mem.eql(u8, arg, "--strict-failures")) {
            strict_failures = true;
        } else if (std.mem.startsWith(u8, arg, "--dashboard=")) {
            dashboard_path = arg["--dashboard=".len..];
        } else if (std.mem.eql(u8, arg, "--dashboard") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            dashboard_path = argv[arg_idx];
        }
    }

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

    // Load whitelist.
    var whitelist_data = try loadList(allocator, WHITELIST_PATH, 1 * 1024 * 1024);
    defer whitelist_data.entries.deinit(allocator);
    defer if (whitelist_data.source) |src| allocator.free(src);
    const whitelist = whitelist_data.entries.items;

    // Load known failing list.
    var known_data = try loadList(allocator, KNOWN_FAILING_PATH, 1 * 1024 * 1024);
    defer known_data.entries.deinit(allocator);
    defer if (known_data.source) |src| allocator.free(src);

    var known_failing = std.StringHashMap(void).init(allocator);
    defer known_failing.deinit();
    for (known_data.entries.items) |entry| {
        try known_failing.put(entry, {});
    }

    var seen_known = std.StringHashMap(void).init(allocator);
    defer seen_known.deinit();

    if (list_mode) {
        try out.print("Test262 whitelist ({d} tests):\n", .{whitelist.len});
        for (whitelist) |entry| {
            try out.print("  {s}\n", .{entry});
        }
        try out.flush();
        return;
    }

    // Run whitelisted tests.
    var pass: u32 = 0;
    var fail: u32 = 0;
    var unexpected_fail: u32 = 0;
    var unexpected_pass: u32 = 0;
    var categories = [_]CategoryStats{.{}} ** category_count;

    for (whitelist) |rel_path| {
        const category = classifyCategory(rel_path);
        const cat_idx = @intFromEnum(category);
        const expected_fail = known_failing.contains(rel_path);

        if (expected_fail) {
            try seen_known.put(rel_path, {});
        }

        var path_buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TEST262_PATH, rel_path }) catch {
            fail += 1;
            categories[cat_idx].fail += 1;
            unexpected_fail += 1;
            try out.print("UNEXPECTED_FAIL: {s} (path too long)\n", .{rel_path});
            continue;
        };
        const source = std.fs.cwd().readFileAlloc(allocator, full, 512 * 1024) catch |err| {
            fail += 1;
            categories[cat_idx].fail += 1;
            if (!expected_fail) {
                unexpected_fail += 1;
                try out.print("UNEXPECTED_FAIL: {s} (read error: {s})\n", .{ rel_path, @errorName(err) });
            } else if (!summary_mode) {
                try out.print("KNOWN_FAIL: {s} (read error: {s})\n", .{ rel_path, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(source);
        const is_pass = try runOneTest(allocator, rel_path, source);

        if (is_pass) {
            pass += 1;
            categories[cat_idx].pass += 1;
            if (expected_fail) {
                unexpected_pass += 1;
                try out.print("UNEXPECTED_PASS: {s}\n", .{rel_path});
            }
        } else {
            fail += 1;
            categories[cat_idx].fail += 1;
            if (!expected_fail) {
                unexpected_fail += 1;
                try out.print("UNEXPECTED_FAIL: {s}\n", .{rel_path});
            } else if (!summary_mode) {
                try out.print("KNOWN_FAIL: {s}\n", .{rel_path});
            }
        }
    }

    for (known_data.entries.items) |entry| {
        if (!seen_known.contains(entry)) {
            try out.print("STALE_KNOWN_FAILING_ENTRY: {s}\n", .{entry});
            unexpected_fail += 1;
        }
    }

    const total_count: u32 = @intCast(whitelist.len);
    try printCategorySummary(out, categories, pass, fail, total_count);
    try out.print("Known-failing flips: {d} unexpected fail, {d} unexpected pass\n", .{
        unexpected_fail,
        unexpected_pass,
    });

    if (dashboard_path) |path| {
        try writeDashboard(allocator, path, categories, pass, fail, total_count, unexpected_fail, unexpected_pass);
        try out.print("Dashboard: {s}\n", .{path});
    }

    try out.flush();

    if (unexpected_fail > 0 or unexpected_pass > 0) std.process.exit(1);
    if (strict_failures and fail > 0) std.process.exit(1);
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

test "classifyCategory buckets by path prefix" {
    try std.testing.expectEqual(Category.builtins, classifyCategory("built-ins/Array/prototype/push/S15.4.4.7_A1.js"));
    try std.testing.expectEqual(Category.statements, classifyCategory("language/statements/if/S12.5_A1.js"));
    try std.testing.expectEqual(Category.expressions, classifyCategory("language/expressions/addition/S11.6.1_A1.js"));
    try std.testing.expectEqual(Category.language, classifyCategory("language/global-code/some-test.js"));
}
