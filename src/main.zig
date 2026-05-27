// SPDX-License-Identifier: MIT
const std = @import("std");
const jsz = @import("jsz");

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

const Mode = enum { help, version, eval, interactive, script };

const Args = struct {
    mode: Mode,
    expr: []const u8 = "",
    script_path: []const u8 = "",
    interp: jsz.InterpMode = .tree,
    dump_bytecode: bool = false,
    gc_stats: bool = false,
    gc_after_eval: bool = false,
};

fn parseArgs(argv: []const []const u8) Args {
    if (argv.len == 0) return .{ .mode = .help };

    var args = Args{ .mode = .help };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{ .mode = .help };
        }
        if (std.mem.eql(u8, arg, "--version")) {
            args.mode = .version;
            continue;
        }
        if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= argv.len) return .{ .mode = .help };
            args.mode = .eval;
            args.expr = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            args.mode = .interactive;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interp=tree")) {
            args.interp = .tree;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interp=bc")) {
            args.interp = .bc;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-bytecode")) {
            args.dump_bytecode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gc-stats")) {
            args.gc_stats = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gc-after-eval")) {
            args.gc_after_eval = true;
            continue;
        }
        // Positional: treat as script path.
        if (!std.mem.startsWith(u8, arg, "-")) {
            args.mode = .script;
            args.script_path = arg;
            continue;
        }
    }
    return args;
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\jsz {s} — a JavaScript engine in Zig
        \\
        \\Usage:
        \\  jsz [options] [script.js]
        \\
        \\Options:
        \\  --version              Print version and exit
        \\  -h, --help             Print this help and exit
        \\  -e <expr>              Evaluate an expression and print result
        \\  -i, --interactive      Start interactive REPL
        \\  --interp=tree|bc       Choose interpreter: tree-walker (default) or bytecode VM
        \\  --dump-bytecode        Compile and disassemble to stdout, then exit
        \\  --gc-stats             Print GC stats after eval
        \\  --gc-after-eval        Trigger a GC cycle before printing stats
        \\
        \\Examples:
        \\  jsz --version
        \\  jsz -e "1 + 1"
        \\  jsz -e "1 + 1" --interp=bc
        \\  jsz script.js
        \\
    , .{jsz.version});
}

fn runEval(allocator: std.mem.Allocator, source: []const u8, source_name: []const u8, interp: jsz.InterpMode, dump_bc: bool, show_gc_stats: bool, gc_after: bool) !void {
    if (dump_bc) {
        // Compile and disassemble: delegate to jsz public API for dump.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var buf: [8192]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const out = &w.interface;
        try jsz.dumpBytecode(arena.allocator(), source, source_name, out);
        try out.flush();
        return;
    }

    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(interp);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var uncaught = false;
    switch (ctx.eval(source, source_name)) {
        .ok => |v| {
            const s = jsz.valueToDisplayString(arena.allocator(), v) catch "?";
            try out.print("{s}\n", .{s});
        },
        .exception => |e| {
            try out.print("Uncaught {s}\n", .{e.message});
            uncaught = true;
        },
        .parse_error => |e| {
            try out.print("SyntaxError: {s} (line {d}:{d})\n", .{ e.message, e.line, e.column });
            uncaught = true;
        },
    }

    if (gc_after) {
        _ = ctx.gc();
    }

    if (show_gc_stats) {
        const stats = ctx.gcStats();
        try out.print("=== GC stats ===\n", .{});
        try out.print("collections: {d}\n", .{stats.collections});
        try out.print("bytes_allocated: {d}\n", .{stats.bytes_allocated});
        try out.print("bytes_freed: {d}\n", .{stats.bytes_freed});
        try out.print("objects_alive: {d}\n", .{stats.objects_alive});
    }

    try out.flush();
    if (uncaught) std.process.exit(1);
}

fn runRepl(allocator: std.mem.Allocator, interp: jsz.InterpMode) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(interp);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var rbuf: [4096]u8 = undefined;
    var r = std.fs.File.stdin().reader(&rbuf);
    const in = &r.interface;

    while (true) {
        try out.print(">> ", .{});
        try out.flush();

        const line = in.takeDelimiterExclusive('\n') catch break;
        const trimmed = std.mem.trimRight(u8, line, "\r\n ");
        if (std.mem.eql(u8, trimmed, ".exit")) break;
        if (trimmed.len == 0) continue;

        switch (ctx.eval(trimmed, "<repl>")) {
            .ok => |v| {
                const s = jsz.valueToDisplayString(arena.allocator(), v) catch "?";
                try out.print("{s}\n", .{s});
            },
            .exception => |e| {
                try out.print("{s}\n", .{e.message});
            },
            .parse_error => |e| {
                try out.print("SyntaxError: {s} (line {d}:{d})\n", .{ e.message, e.line, e.column });
            },
        }
        try out.flush();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv_raw);

    const argv = if (argv_raw.len > 1) argv_raw[1..] else argv_raw[0..0];
    const args = parseArgs(argv);

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    var errbuf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&errbuf);
    const stderr = &stderr_writer.interface;

    switch (args.mode) {
        .version => {
            try stdout.print("jsz {s}\n", .{jsz.version});
            try stdout.flush();
        },
        .help => {
            try printHelp(stdout);
            try stdout.flush();
            if (argv.len == 0) {
                std.process.exit(1);
            }
        },
        .eval => {
            try runEval(allocator, args.expr, "<eval>", args.interp, args.dump_bytecode, args.gc_stats, args.gc_after_eval);
        },
        .interactive => {
            try runRepl(allocator, args.interp);
        },
        .script => {
            const file_source = std.fs.cwd().readFileAlloc(allocator, args.script_path, 10 * 1024 * 1024) catch |err| {
                try stderr.print("jsz: cannot read '{s}': {s}\n", .{ args.script_path, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            defer allocator.free(file_source);
            try runEval(allocator, file_source, args.script_path, args.interp, args.dump_bytecode, args.gc_stats, args.gc_after_eval);
        },
    }
}

test "parseArgs --version" {
    const argv = [_][]const u8{"--version"};
    const a = parseArgs(&argv);
    try std.testing.expectEqual(Mode.version, a.mode);
}

test "parseArgs -e" {
    const argv = [_][]const u8{ "-e", "1+1" };
    const a = parseArgs(&argv);
    try std.testing.expectEqual(Mode.eval, a.mode);
    try std.testing.expectEqualStrings("1+1", a.expr);
}

test "parseArgs no args" {
    const a = parseArgs(&[_][]const u8{});
    try std.testing.expectEqual(Mode.help, a.mode);
}

test "parseArgs --interp=bc" {
    const argv = [_][]const u8{ "-e", "1+1", "--interp=bc" };
    const a = parseArgs(&argv);
    try std.testing.expectEqual(jsz.InterpMode.bc, a.interp);
}
