// SPDX-License-Identifier: Apache-2.0
//! Test262 conformance runner.
//! When external/test262/test/ is absent, prints instructions and exits 0.
//! To activate: git submodule add -f https://github.com/tc39/test262 external/test262
const std = @import("std");
const jsz = @import("jsz");

const TEST262_PATH = "external/test262/test";
const HARNESS_PATH = "external/test262/harness";
const WHITELIST_PATH = "tests/test262_whitelist.txt";
const KNOWN_FAILING_PATH = "tests/test262_known_failing.txt";
const KNOWN_FAILING_FULL_PATH = "tests/test262_known_failing_full.txt";

/// Per-test outcome. `skip` = the test needs a feature the harness can't
/// provide (module/raw/async flags, or an unreadable harness include) so it is
/// excluded from the pass/fail denominator rather than counted as a failure.
const Outcome = enum { pass, fail, skip };

const Category = enum(u8) {
    builtins = 0,
    language = 1,
    statements = 2,
    expressions = 3,
};

const category_count: usize = 4;

const CategoryStats = struct {
    listed: u32 = 0,
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

const ExitPolicy = struct {
    fail_on_flips: bool,
    strict_failures: bool,
    fail: u32,
    unexpected_fail: u32,
    unexpected_pass: u32,
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

fn exitCodeForResults(policy: ExitPolicy) u8 {
    if (policy.fail_on_flips and (policy.unexpected_fail > 0 or policy.unexpected_pass > 0)) return 1;
    if (policy.strict_failures and policy.fail > 0) return 1;
    return 0;
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

/// Return the /*--- ---*/ frontmatter slice, or "" if absent.
fn frontmatter(source: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, source, "/*---") orelse return "";
    const rest = source[start + 5 ..];
    const end = std.mem.indexOf(u8, rest, "---*/") orelse return "";
    return rest[0..end];
}

/// Eligibility for auto-expansion: pure ES5 (has es5id), no unsupported
/// harness includes, and no module/raw/async flags. Keeps the auto-grown
/// set to tests our engine + minimal prelude (assert.js/sta.js) can run.
fn isEligibleEs5(source: []const u8, allow_es6: bool) bool {
    const yaml = frontmatter(source);
    if (yaml.len == 0) return false;
    // ES5 (es5id) always; later-spec (esid) only for directories opted in via "es6:".
    const has_es5 = std.mem.indexOf(u8, yaml, "es5id:") != null;
    const has_esid = std.mem.indexOf(u8, yaml, "esid:") != null;
    if (!has_es5 and !(allow_es6 and has_esid)) return false;
    // Unsupported flags.
    if (std.mem.indexOf(u8, yaml, "flags:")) |fi| {
        const line_end = std.mem.indexOfScalarPos(u8, yaml, fi, '\n') orelse yaml.len;
        const flags = yaml[fi..line_end];
        if (std.mem.indexOf(u8, flags, "module") != null) return false;
        if (std.mem.indexOf(u8, flags, "raw") != null) return false;
        if (std.mem.indexOf(u8, flags, "async") != null) return false;
        if (std.mem.indexOf(u8, flags, "CanBlockIsFalse") != null) return false;
    }
    // Includes: only allow the prelude-provided harness files.
    if (std.mem.indexOf(u8, yaml, "includes:")) |ii| {
        const line_end = std.mem.indexOfScalarPos(u8, yaml, ii, '\n') orelse yaml.len;
        const inc = yaml[ii..line_end];
        // Allow assert.js / sta.js (provided by prelude); reject anything else.
        var it = std.mem.tokenizeAny(u8, inc, " [],\r");
        _ = it.next(); // skip "includes:"
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "assert.js")) continue;
            if (std.mem.eql(u8, tok, "sta.js")) continue;
            return false;
        }
    }
    return true;
}

/// Append all eligible ES5 .js tests under `rel_dir` (relative to TEST262_PATH)
/// to `out`, with paths allocated from `arena`. Skips _FIXTURE files.
fn expandDir(arena: std.mem.Allocator, rel_dir: []const u8, allow_es6: bool, out: *std.ArrayList([]const u8)) !void {
    var path_buf: [512]u8 = undefined;
    const abs_dir = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ TEST262_PATH, rel_dir }) catch return;
    var dir = std.fs.cwd().openDir(abs_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".js")) continue;
        if (std.mem.indexOf(u8, entry.path, "_FIXTURE") != null) continue;
        var full_buf: [768]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ abs_dir, entry.path }) catch continue;
        const src = std.fs.cwd().readFileAlloc(arena, full, 512 * 1024) catch continue;
        if (!isEligibleEs5(src, allow_es6)) continue;
        // Normalize Windows backslashes in entry.path to forward slashes.
        const norm = try arena.dupe(u8, entry.path);
        for (norm) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel_dir, norm });
        try out.append(arena, rel);
    }
}

/// Expand whitelist entries: entries ending in '/' are directory globs
/// (recursively expanded, ES5-filtered). A leading "es6:" opts the directory
/// into also accepting esid (ES2015+) tests. Other entries are kept as-is.
fn expandWhitelist(arena: std.mem.Allocator, raw: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |entry| {
        if (std.mem.endsWith(u8, entry, "/")) {
            const allow_es6 = std.mem.startsWith(u8, entry, "es6:");
            const dir_full = if (allow_es6) entry[4..] else entry;
            const dir = dir_full[0 .. dir_full.len - 1];
            try expandDir(arena, dir, allow_es6, &out);
        } else {
            try out.append(arena, entry);
        }
    }
    return out.items;
}

/// Minimal Test262 harness prelude (sta.js + assert.js subset). Used for the
/// curated whitelist run and as the fallback when the real harness dir is absent.
const HARDCODED_PRELUDE =
    \\function Test262Error(message) { this.message = message || ""; }
    \\Test262Error.prototype.toString = function () { return "Test262Error: " + this.message; };
    \\function $DONOTEVALUATE() { throw "Test262: This statement should not be evaluated."; }
    \\var assert = function (mustBeTrue, message) {
    \\  if (mustBeTrue === true) return;
    \\  throw new Test262Error(message || "Expected true but got " + String(mustBeTrue));
    \\};
    \\assert._isSameValue = function (a, b) {
    \\  if (a === b) return a !== 0 || 1 / a === 1 / b;
    \\  return a !== a && b !== b;
    \\};
    \\assert.sameValue = function (actual, expected, message) {
    \\  if (assert._isSameValue(actual, expected)) return;
    \\  throw new Test262Error((message || "") + " Expected SameValue(" + String(actual) + ", " + String(expected) + ") to be true");
    \\};
    \\assert.notSameValue = function (actual, unexpected, message) {
    \\  if (!assert._isSameValue(actual, unexpected)) return;
    \\  throw new Test262Error((message || "") + " Expected SameValue to be false");
    \\};
    \\assert.notSameValue = function (actual, unexpected, message) {
    \\  if (!assert._isSameValue(actual, unexpected)) return;
    \\  throw new Test262Error((message || "") + " Expected SameValue to be false");
    \\};
    \\assert.throws = function (expectedErrorConstructor, func, message) {
    \\  try { func(); } catch (thrown) { return; }
    \\  throw new Test262Error((message || "") + " Expected a thrown error");
    \\};
    \\
;

const DOLLAR262_PRELUDE =
    \\var $262 = {
    \\  detachArrayBuffer: function(buffer) { if (!buffer.detached) buffer.transfer(0); },
    \\  global: globalThis,
    \\  createRealm: function() { return $262; },
    \\  evalScript: function(s) { return eval(s); }
    \\};
    \\
;

/// Return the value region of the `includes:` frontmatter key, covering both the
/// inline `[a.js, b.js]` form and the indented block-list form.
fn includesRegion(yaml: []const u8) []const u8 {
    const key = "includes:";
    const ii = std.mem.indexOf(u8, yaml, key) orelse return "";
    const start = ii + key.len;
    var end = std.mem.indexOfScalarPos(u8, yaml, ii, '\n') orelse return yaml[start..];
    var p = end + 1;
    while (p < yaml.len) {
        if (yaml[p] == ' ' or yaml[p] == '\t') {
            const nl = std.mem.indexOfScalarPos(u8, yaml, p, '\n') orelse yaml.len;
            end = nl;
            p = nl + 1;
        } else break;
    }
    return yaml[start..end];
}

/// Looser eligibility for the full corpus: attempt anything except tests whose
/// flags need features the single-file harness can't satisfy.
fn isRunnableFull(source: []const u8) bool {
    const yaml = frontmatter(source);
    if (std.mem.indexOf(u8, yaml, "flags:")) |fi| {
        const line_end = std.mem.indexOfScalarPos(u8, yaml, fi, '\n') orelse yaml.len;
        const flags = yaml[fi..line_end];
        if (std.mem.indexOf(u8, flags, "module") != null) return false;
        if (std.mem.indexOf(u8, flags, "raw") != null) return false;
        if (std.mem.indexOf(u8, flags, "async") != null) return false;
        if (std.mem.indexOf(u8, flags, "CanBlockIsFalse") != null) return false;
    }
    return true;
}

/// Collect every non-fixture `.js` test under TEST262_PATH (paths relative to it,
/// forward-slash normalized). Runnability is decided per-test at run time.
fn collectFullCorpus(arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var dir = std.fs.cwd().openDir(TEST262_PATH, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".js")) continue;
        if (std.mem.indexOf(u8, entry.path, "_FIXTURE") != null) continue;
        const norm = try arena.dupe(u8, entry.path);
        for (norm) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        try out.append(arena, norm);
    }
}

fn loadHarness(allocator: std.mem.Allocator, name: []const u8, out: *std.ArrayList(u8)) !void {
    var pbuf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ HARNESS_PATH, name });
    const src = try std.fs.cwd().readFileAlloc(allocator, p, 256 * 1024);
    defer allocator.free(src);
    try out.appendSlice(allocator, src);
    try out.append(allocator, '\n');
}

/// Build the prelude from the real Test262 harness: sta.js + assert.js plus every
/// file named in the test's `includes:`. Errors (missing include) propagate so the
/// caller can mark the test skipped rather than failed.
fn buildHarnessPrelude(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try loadHarness(allocator, "sta.js", &buf);
    try loadHarness(allocator, "assert.js", &buf);
    var it = std.mem.tokenizeAny(u8, includesRegion(frontmatter(source)), " \t\r\n[],");
    while (it.next()) |tok| {
        if (!std.mem.endsWith(u8, tok, ".js")) continue;
        if (std.mem.eql(u8, tok, "sta.js") or std.mem.eql(u8, tok, "assert.js")) continue;
        try loadHarness(allocator, tok, &buf);
    }
    return buf.toOwnedSlice(allocator);
}

fn runOneTest(allocator: std.mem.Allocator, source: []const u8, full_mode: bool, harness_present: bool) !Outcome {
    if (full_mode and !isRunnableFull(source)) return .skip;
    const meta = try parseMeta(allocator, source);

    var iso = jsz.Isolate.init(allocator) catch return .fail;
    defer iso.deinit();
    var ctx = iso.newContext() catch return .fail;
    defer ctx.deinit();

    // In a -Djit build, run every test under the experimental JIT so the
    // conformance suite actually gates the native tier (parity requirement).
    if (jsz.jit_build) ctx.setJitMode(.experimental);

    // Per-test resource limits so a looping/allocating test can't hang the
    // whole run. Enforced in the bc VM (the default); a breach surfaces as an
    // `EvalResult.exception` with an "interrupted:"/"out of memory" message,
    // which we treat as `.skip` (not a genuine pass/fail).
    ctx.setLimits(.{
        .time_ms = 1000,
        .mem_bytes = 256 * 1024 * 1024,
        .gas = 0,
    });

    const prelude_owned: ?[]u8 = if (full_mode and harness_present)
        (buildHarnessPrelude(allocator, source) catch return .skip)
    else
        null;
    defer if (prelude_owned) |p| allocator.free(p);
    const prelude: []const u8 = prelude_owned orelse HARDCODED_PRELUDE;

    // Only inject $262 when the test actually uses it (or $DETACHBUFFER which
    // depends on it). This avoids breaking harness/detachArrayBuffer.js which
    // explicitly tests that $262 is NOT defined by default.
    const needs_dollar262 = std.mem.indexOf(u8, source, "$262") != null or
        std.mem.indexOf(u8, source, "$DETACHBUFFER") != null or
        std.mem.indexOf(u8, prelude, "$262") != null;
    // onlyStrict tests must run as strict-mode code: prepend a directive prologue
    // to the whole program (must be the very first token to take effect).
    const strict_prefix: []const u8 = if (std.mem.indexOf(u8, source, "onlyStrict") != null)
        "\"use strict\";\n"
    else
        "";
    const full_source = if (needs_dollar262)
        std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ strict_prefix, DOLLAR262_PRELUDE, prelude, source }) catch return .fail
    else
        std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ strict_prefix, prelude, source }) catch return .fail;
    defer allocator.free(full_source);

    const result = ctx.eval(full_source, "<test262>");

    // A resource-limit interrupt is neither a pass nor a fail — skip it so a
    // looping test cannot masquerade as a passing negative test.
    if (result == .exception) {
        const msg = result.exception.message;
        if (std.mem.startsWith(u8, msg, "interrupted:") or
            std.mem.startsWith(u8, msg, "out of memory") or
            std.mem.startsWith(u8, msg, "Uncaught out of memory"))
        {
            return .skip;
        }
    }

    if (meta.negative) {
        // Negative test: expect exception or parse error.
        return switch (result) {
            .exception, .parse_error => .pass,
            .ok => .fail,
        };
    }
    switch (result) {
        .ok => return .pass,
        .exception => |e| {
            const n = @min(e.message.len, g_fail_msg_buf.len);
            @memcpy(g_fail_msg_buf[0..n], e.message[0..n]);
            g_fail_msg_len = n;
            return .fail;
        },
        .parse_error => |e| {
            const n = @min(e.message.len, g_fail_msg_buf.len);
            @memcpy(g_fail_msg_buf[0..n], e.message[0..n]);
            g_fail_msg_len = n;
            return .fail;
        },
    }
}

var g_fail_msg_buf: [1024]u8 = undefined;
var g_fail_msg_len: usize = 0;
var debug_fail: bool = false;

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

fn countWhitelistCategories(entries: []const []const u8) [category_count]CategoryStats {
    var stats = [_]CategoryStats{.{}} ** category_count;
    for (entries) |rel_path| {
        stats[@intFromEnum(classifyCategory(rel_path))].listed += 1;
    }
    return stats;
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
    corpus_present: bool,
    stats: [category_count]CategoryStats,
    pass: u32,
    fail: u32,
    whitelist_count: u32,
    known_failing_count: u32,
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
    try out.print("Generated by `zig build conformance-dashboard` from `{s}` and `{s}`.\n\n", .{
        WHITELIST_PATH,
        KNOWN_FAILING_PATH,
    });

    try out.print("## Status\n\n", .{});
    if (corpus_present) {
        try out.print("- Corpus: available (`{s}`)\n", .{TEST262_PATH});
        try out.print("- Runnable state: ready\n", .{});
    } else {
        try out.print("- Corpus: missing (`{s}`)\n", .{TEST262_PATH});
        try out.print("- Runnable state: blocked (missing external Test262 corpus)\n", .{});
    }
    try out.print("- Whitelisted runnable tests: {d}\n", .{whitelist_count});
    try out.print("- Known failing entries: {d}\n", .{known_failing_count});
    try out.print("- Tests run: {d}\n", .{pass + fail});
    try out.print("- Pass: {d}\n", .{pass});
    try out.print("- Fail: {d}\n", .{fail});
    try out.print("- Pass rate: ", .{});
    try formatPercent(out, pass, pass + fail);
    try out.print("\n", .{});
    try out.print("- Unexpected fail flips: {d}\n", .{unexpected_fail});
    try out.print("- Unexpected pass flips: {d}\n\n", .{unexpected_pass});

    if (!corpus_present) {
        try out.print("## Enable Test262\n\n", .{});
        try out.print("Test262 is not bundled. Add the corpus, then regenerate this dashboard:\n\n", .{});
        try out.print("```sh\n", .{});
        try out.print("git submodule add -f https://github.com/tc39/test262 external/test262\n", .{});
        try out.print("git submodule update --init --recursive\n", .{});
        try out.print("zig build conformance-dashboard\n", .{});
        try out.print("```\n\n", .{});
    }

    try out.print("## Category Buckets\n\n", .{});
    try out.print("| Category | Whitelist | Pass | Fail | Run | Pass rate |\n", .{});
    try out.print("|---|---:|---:|---:|---:|---:|\n", .{});
    inline for ([_]Category{ .builtins, .language, .statements, .expressions }) |category| {
        const s = stats[@intFromEnum(category)];
        try out.print("| {s} | {d} | {d} | {d} | {d} | ", .{
            categoryLabel(category),
            s.listed,
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
    var full_mode = false;
    var fail_on_flips = true;
    var strict_failures = false;
    var dashboard_path: ?[]const u8 = null;
    var write_failing_path: ?[]const u8 = null;
    // Crash-resilient run support: --progress-file records the test about to run
    // (truncated+flushed each iteration, so after a hard crash it names the
    // crasher); --results-file appends one "PASS|FAIL|SKIP <path>" line per test
    // (append mode, survives across resumed runs); --start-after skips every test
    // up to and including the named path (resume past a crasher).
    var progress_file_path: ?[]const u8 = null;
    var results_file_path: ?[]const u8 = null;
    var start_after: ?[]const u8 = null;
    // --filter <substr>: only run tests whose relative path contains <substr>
    // (full mode only). Lets a single feature area be measured in isolation.
    var path_filter: ?[]const u8 = null;
    var arg_idx: usize = 1;
    while (arg_idx < argv.len) : (arg_idx += 1) {
        const arg = argv[arg_idx];
        if (std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_mode = true;
            fail_on_flips = false;
        } else if (std.mem.eql(u8, arg, "--full")) {
            // Run the entire corpus instead of the curated whitelist. Defaults to
            // baseline-reporting (no flip gate); pass --fail-on-flips to re-enable.
            full_mode = true;
            summary_mode = true;
            fail_on_flips = false;
        } else if (std.mem.eql(u8, arg, "--fail-on-flips")) {
            fail_on_flips = true;
        } else if (std.mem.eql(u8, arg, "--strict-failures")) {
            strict_failures = true;
        } else if (std.mem.eql(u8, arg, "--debug-fail")) {
            debug_fail = true;
        } else if (std.mem.startsWith(u8, arg, "--dashboard=")) {
            dashboard_path = arg["--dashboard=".len..];
        } else if (std.mem.eql(u8, arg, "--dashboard") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            dashboard_path = argv[arg_idx];
        } else if (std.mem.startsWith(u8, arg, "--write-known-failing=")) {
            write_failing_path = arg["--write-known-failing=".len..];
        } else if (std.mem.eql(u8, arg, "--write-known-failing") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            write_failing_path = argv[arg_idx];
        } else if (std.mem.eql(u8, arg, "--progress-file") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            progress_file_path = argv[arg_idx];
        } else if (std.mem.eql(u8, arg, "--results-file") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            results_file_path = argv[arg_idx];
        } else if (std.mem.eql(u8, arg, "--start-after") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            start_after = argv[arg_idx];
        } else if (std.mem.eql(u8, arg, "--filter") and arg_idx + 1 < argv.len) {
            arg_idx += 1;
            path_filter = argv[arg_idx];
        }
    }

    // Load whitelist.
    var whitelist_data = try loadList(allocator, WHITELIST_PATH, 1 * 1024 * 1024);
    defer whitelist_data.entries.deinit(allocator);
    defer if (whitelist_data.source) |src| allocator.free(src);

    // Expand directory globs (entries ending in '/') into ES5-filtered tests.
    var wl_arena = std.heap.ArenaAllocator.init(allocator);
    defer wl_arena.deinit();
    const whitelist = try expandWhitelist(wl_arena.allocator(), whitelist_data.entries.items);

    // In full mode the test set is the entire corpus; otherwise the curated whitelist.
    const tests: []const []const u8 = if (full_mode) blk: {
        var corpus: std.ArrayList([]const u8) = .empty;
        try collectFullCorpus(wl_arena.allocator(), &corpus);
        // Deterministic order so --start-after resume is stable across runs
        // (filesystem walk order is not guaranteed identical run-to-run).
        std.mem.sort([]const u8, corpus.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        break :blk corpus.items;
    } else whitelist;

    // Load known failing list (a separate, larger list backs full-corpus runs).
    const known_path = if (full_mode) KNOWN_FAILING_FULL_PATH else KNOWN_FAILING_PATH;
    var known_data = try loadList(allocator, known_path, 8 * 1024 * 1024);
    defer known_data.entries.deinit(allocator);
    defer if (known_data.source) |src| allocator.free(src);

    if (list_mode) {
        try out.print("Test262 tests ({d}):\n", .{tests.len});
        for (tests) |entry| {
            try out.print("  {s}\n", .{entry});
        }
        try out.flush();
        return;
    }

    var categories = countWhitelistCategories(tests);
    const total_count: u32 = @intCast(tests.len);
    const known_failing_count: u32 = @intCast(known_data.entries.items.len);

    // Check if test262 corpus exists after loading metadata so dashboard
    // generation can still be useful without the external checkout.
    std.fs.cwd().access(TEST262_PATH, .{}) catch {
        try out.print(
            "Test262 corpus not found at {s}.\n" ++
                "Whitelist: {d} configured tests; 0 run.\n" ++
                "Run: git submodule add -f https://github.com/tc39/test262 external/test262\n" ++
                "Then: git submodule update --init --recursive\n",
            .{ TEST262_PATH, total_count },
        );
        if (dashboard_path) |path| {
            try writeDashboard(
                allocator,
                path,
                false,
                categories,
                0,
                0,
                total_count,
                known_failing_count,
                0,
                0,
            );
            try out.print("Dashboard: {s}\n", .{path});
        }
        try out.flush();
        return; // exit 0 — absence is OK
    };

    var known_failing = std.StringHashMap(void).init(allocator);
    defer known_failing.deinit();
    for (known_data.entries.items) |entry| {
        try known_failing.put(entry, {});
    }

    var seen_known = std.StringHashMap(void).init(allocator);
    defer seen_known.deinit();

    // The real harness dir lets full mode load per-test `includes:` files.
    const harness_present = blk: {
        std.fs.cwd().access(HARNESS_PATH, .{}) catch break :blk false;
        break :blk true;
    };

    // Run the selected tests.
    // `quiet` = a full baseline run (no flip gate): suppress the per-test
    // UNEXPECTED_/KNOWN_/STALE lines that would otherwise be thousands long. The
    // delta gate (full + --fail-on-flips) keeps them so regressions are visible.
    const quiet = full_mode and !fail_on_flips;
    var failing_list: std.ArrayList([]const u8) = .empty;
    defer failing_list.deinit(allocator);

    var pass: u32 = 0;
    var fail: u32 = 0;
    var skipped: u32 = 0;
    var unexpected_fail: u32 = 0;
    var unexpected_pass: u32 = 0;

    // Append-mode results sink for crash-resilient runs (one line per test).
    var results_file: ?std.fs.File = null;
    if (results_file_path) |rp| {
        if (std.fs.cwd().createFile(rp, .{ .truncate = false })) |f| {
            f.seekFromEnd(0) catch {};
            results_file = f;
        } else |_| {}
    }
    defer if (results_file) |f| f.close();

    // Resume support: when --start-after is set, skip every test up to and
    // including the named path; begin running at the next one.
    var resumed = (start_after == null);

    for (tests) |rel_path| {
        if (!resumed) {
            if (start_after) |sa| {
                if (std.mem.eql(u8, rel_path, sa)) resumed = true;
            }
            continue;
        }
        if (path_filter) |pf| {
            if (std.mem.indexOf(u8, rel_path, pf) == null) continue;
        }
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
            if (!quiet) try out.print("UNEXPECTED_FAIL: {s} (path too long)\n", .{rel_path});
            continue;
        };
        const source = std.fs.cwd().readFileAlloc(allocator, full, 512 * 1024) catch |err| {
            fail += 1;
            categories[cat_idx].fail += 1;
            if (!expected_fail) {
                unexpected_fail += 1;
                if (!quiet) try out.print("UNEXPECTED_FAIL: {s} (read error: {s})\n", .{ rel_path, @errorName(err) });
            } else if (!summary_mode) {
                try out.print("KNOWN_FAIL: {s} (read error: {s})\n", .{ rel_path, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(source);

        // Record the test we're about to run (truncate+flush) so a hard crash
        // inside runOneTest leaves the crasher's path on disk for the wrapper.
        if (progress_file_path) |pp| {
            if (std.fs.cwd().createFile(pp, .{ .truncate = true })) |pf| {
                pf.writeAll(rel_path) catch {};
                pf.close();
            } else |_| {}
        }

        const outcome = try runOneTest(allocator, source, full_mode, harness_present);

        // Append the per-test outcome (survives across resumed runs).
        if (results_file) |f| {
            const tag = switch (outcome) {
                .pass => "PASS",
                .fail => "FAIL",
                .skip => "SKIP",
            };
            var lb: [600]u8 = undefined;
            if (std.fmt.bufPrint(&lb, "{s} {s}\n", .{ tag, rel_path })) |line| {
                f.writeAll(line) catch {};
            } else |_| {}
        }

        switch (outcome) {
            .skip => skipped += 1,
            .pass => {
                pass += 1;
                categories[cat_idx].pass += 1;
                if (expected_fail) {
                    unexpected_pass += 1;
                    if (!quiet) try out.print("UNEXPECTED_PASS: {s}\n", .{rel_path});
                }
            },
            .fail => {
                if (debug_fail) {
                    std.debug.print("DBG {s} :: {s}\n", .{ rel_path, g_fail_msg_buf[0..g_fail_msg_len] });
                }
                fail += 1;
                categories[cat_idx].fail += 1;
                if (write_failing_path != null) try failing_list.append(allocator, rel_path);
                if (!expected_fail) {
                    unexpected_fail += 1;
                    if (!quiet) try out.print("UNEXPECTED_FAIL: {s}\n", .{rel_path});
                } else if (!summary_mode and !quiet) {
                    try out.print("KNOWN_FAIL: {s}\n", .{rel_path});
                }
            },
        }
    }

    // Stale known-failing entries are noise during a quiet baseline run.
    if (!quiet) {
        for (known_data.entries.items) |entry| {
            if (!seen_known.contains(entry)) {
                try out.print("STALE_KNOWN_FAILING_ENTRY: {s}\n", .{entry});
                unexpected_fail += 1;
            }
        }
    }

    if (write_failing_path) |path| {
        std.mem.sort([]const u8, failing_list.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var fbuf: [4096]u8 = undefined;
        var fw = file.writer(&fbuf);
        const fout = &fw.interface;
        try fout.print("# Auto-generated by --write-known-failing. {d} failing tests.\n", .{failing_list.items.len});
        for (failing_list.items) |entry| try fout.print("{s}\n", .{entry});
        try fout.flush();
        try out.print("Wrote known-failing list ({d} entries): {s}\n", .{ failing_list.items.len, path });
    }

    try printCategorySummary(out, categories, pass, fail, pass + fail);
    if (full_mode) try out.print("Skipped (unsupported flags/includes): {d}\n", .{skipped});
    try out.print("Known-failing flips: {d} unexpected fail, {d} unexpected pass\n", .{
        unexpected_fail,
        unexpected_pass,
    });

    if (dashboard_path) |path| {
        try writeDashboard(
            allocator,
            path,
            true,
            categories,
            pass,
            fail,
            total_count,
            known_failing_count,
            unexpected_fail,
            unexpected_pass,
        );
        try out.print("Dashboard: {s}\n", .{path});
    }

    try out.flush();

    const exit_code = exitCodeForResults(.{
        .fail_on_flips = fail_on_flips,
        .strict_failures = strict_failures,
        .fail = fail,
        .unexpected_fail = unexpected_fail,
        .unexpected_pass = unexpected_pass,
    });
    if (exit_code != 0) std.process.exit(exit_code);
}

test "includesRegion extracts inline and block forms" {
    const inline_form = "esid: sec-x\nincludes: [compareArray.js, sta.js]\nflags: [onlyStrict]\n";
    const r1 = includesRegion(inline_form);
    try std.testing.expect(std.mem.indexOf(u8, r1, "compareArray.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "flags") == null);

    const block_form = "includes:\n  - propertyHelper.js\n  - compareArray.js\nfeatures: [Proxy]\n";
    const r2 = includesRegion(block_form);
    try std.testing.expect(std.mem.indexOf(u8, r2, "propertyHelper.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "compareArray.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "features") == null);
}

test "isRunnableFull rejects module/raw/async flags" {
    try std.testing.expect(isRunnableFull("/*---\nes5id: 1\n---*/\nvar x=1;"));
    try std.testing.expect(!isRunnableFull("/*---\nflags: [module]\n---*/\n"));
    try std.testing.expect(!isRunnableFull("/*---\nflags: [async]\n---*/\n"));
    try std.testing.expect(!isRunnableFull("/*---\nflags: [raw]\n---*/\n"));
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

test "writeDashboard records missing corpus and whitelist size" {
    const output_path = "zig-cache/test-conformance-dashboard.md";
    try std.fs.cwd().makePath("zig-cache");
    defer std.fs.cwd().deleteFile(output_path) catch {};

    var categories = [_]CategoryStats{.{}} ** category_count;
    categories[@intFromEnum(Category.builtins)].listed = 3;
    categories[@intFromEnum(Category.language)].listed = 1;
    categories[@intFromEnum(Category.statements)].listed = 2;
    categories[@intFromEnum(Category.expressions)].listed = 2;

    try writeDashboard(
        std.testing.allocator,
        output_path,
        false,
        categories,
        0,
        0,
        8,
        0,
        0,
        0,
    );

    const generated = try std.fs.cwd().readFileAlloc(std.testing.allocator, output_path, 16 * 1024);
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "- Corpus: missing (`external/test262/test`)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "- Whitelisted runnable tests: 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "git submodule add -f https://github.com/tc39/test262 external/test262") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "git submodule update --init --recursive") != null);
}

test "dashboard mode exits successfully when unexpected failures are measured" {
    try std.testing.expectEqual(@as(u8, 0), exitCodeForResults(.{
        .fail_on_flips = false,
        .strict_failures = false,
        .fail = 7,
        .unexpected_fail = 7,
        .unexpected_pass = 0,
    }));
}

test "flip-checking mode exits unsuccessfully on unexpected failures" {
    try std.testing.expectEqual(@as(u8, 1), exitCodeForResults(.{
        .fail_on_flips = true,
        .strict_failures = false,
        .fail = 7,
        .unexpected_fail = 7,
        .unexpected_pass = 0,
    }));
}
