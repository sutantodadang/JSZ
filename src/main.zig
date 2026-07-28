// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const jsz = @import("jsz");
const build_options = @import("build_options");

/// Phase 9: when built with `-Djit=true`, compile the Cranelift native count-loop
/// kernel and install it so the experimental hot-loop JIT runs native code.
/// Compiled out entirely otherwise (no cargo/DLL dependency).
fn installNativeJit() void {
    if (comptime build_options.jit_enabled) {
        const native = @import("jit/native.zig");
        if (native.compileCountLoop()) |f| jsz.installNativeCountLoop(f);
        if (native.compileAccumulateLoop()) |f| jsz.installNativeAccumulateLoop(f);
    }
}

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

const Mode = enum { help, version, eval, interactive, script, run_bytecode };

const Args = struct {
    mode: Mode,
    expr: []const u8 = "",
    script_path: []const u8 = "",
    interp: jsz.InterpMode = .bc,
    dump_bytecode: bool = false,
    source_map: bool = false,
    debug: bool = false,
    emit_bc_path: []const u8 = "",
    run_bc_path: []const u8 = "",
    gc_stats: bool = false,
    gc_after_eval: bool = false,
    jit_mode: jsz.JitMode = .off,
    limits: jsz.Limits = .{},
    ic_stats: bool = false,
    /// M16: run the entry as an ES module (strict; import/export desugar).
    module: bool = false,
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
        if (std.mem.eql(u8, arg, "--interp=bc")) {
            args.interp = .bc;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-bytecode")) {
            args.dump_bytecode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--source-map")) {
            args.source_map = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--debug")) {
            args.debug = true;
            args.interp = .bc; // DEBUGGER opcode only fires in the bytecode VM
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit-bytecode")) {
            i += 1;
            if (i >= argv.len) return .{ .mode = .help };
            args.emit_bc_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--run-bytecode")) {
            i += 1;
            if (i >= argv.len) return .{ .mode = .help };
            args.run_bc_path = argv[i];
            args.mode = .run_bytecode;
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
        if (std.mem.eql(u8, arg, "--ic-stats")) {
            args.ic_stats = true;
            args.interp = .bc;
            continue;
        }
        if (std.mem.eql(u8, arg, "--module")) {
            args.module = true;
            args.interp = .bc; // module eval runs in the bytecode VM
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit=off")) {
            args.jit_mode = .off;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit=count")) {
            args.jit_mode = .count;
            args.interp = .bc; // profiler only runs in bc VM
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit=experimental")) {
            args.jit_mode = .experimental;
            args.interp = .bc; // profiler only runs in bc VM
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--mem-limit=")) {
            args.limits.mem_bytes = std.fmt.parseInt(usize, arg["--mem-limit=".len..], 10) catch 0;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--gas-limit=")) {
            args.limits.gas = std.fmt.parseInt(u64, arg["--gas-limit=".len..], 10) catch 0;
            args.interp = .bc; // gas is enforced in the bytecode VM
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--time-limit=")) {
            args.limits.time_ms = std.fmt.parseInt(u64, arg["--time-limit=".len..], 10) catch 0;
            args.interp = .bc; // wall-clock deadline is enforced in the bytecode VM
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
        \\  --interp=bc            Select the bytecode VM (default and only engine)
        \\  --dump-bytecode        Compile and disassemble to stdout, then exit
        \\  --source-map           Print a bytecode->source JSON source map, then exit
        \\  --debug                Attach a stub debugger (prints on `debugger;`); implies --interp=bc
        \\  --emit-bytecode <path> Compile source to a bytecode snapshot file, then exit
        \\  --run-bytecode <path>  Load and run a bytecode snapshot file (bytecode VM)
        \\  --gc-stats             Print GC stats after eval
        \\  --gc-after-eval        Trigger a GC cycle before printing stats
        \\  --ic-stats             Print inline-cache hit-rate stats after eval
        \\  --jit=off|count|experimental  Profile hot bytecode sites (count) or attempt native compile (experimental); implies --interp=bc
        \\  --mem-limit=<bytes>    Cap live memory; over-budget eval throws instead of crashing
        \\  --gas-limit=<n>        Cap executed bytecode instructions (implies --interp=bc)
        \\  --time-limit=<ms>      Cap wall-clock execution time (implies --interp=bc)
        \\  --module               Run the entry as an ES module (strict; import/export)
        \\
        \\Examples:
        \\  jsz --version
        \\  jsz -e "1 + 1"
        \\  jsz -e "1 + 1" --interp=bc
        \\  jsz script.js
        \\
    , .{jsz.version});
}

/// Source text for the active --debug session, used by debugHook to map offsets.
var dbg_source: []const u8 = "";

/// Phase 8: stub debug hook installed by --debug. Prints the pause location when
/// a `debugger;` statement executes in the bytecode VM.
fn debugHook(_: ?*anyopaque, stop: jsz.debug.DebugStop) void {
    const pos = jsz.debug.offsetToLineCol(dbg_source, stop.source_offset);
    var ebuf: [256]u8 = undefined;
    var ew = std.fs.File.stderr().writerStreaming(&ebuf);
    const e = &ew.interface;
    e.print("[debugger] paused at {s}:{d}:{d} in {s} (pc={d})\n", .{
        stop.source_name, pos.line, pos.column, stop.function_name, stop.pc,
    }) catch {};
    e.flush() catch {};
}

fn runEval(allocator: std.mem.Allocator, source: []const u8, source_name: []const u8, interp: jsz.InterpMode, dump_bc: bool, source_map: bool, debug: bool, emit_bc_path: []const u8, show_gc_stats: bool, gc_after: bool, jit_mode: jsz.JitMode, limits: jsz.Limits, ic_stats: bool, is_module: bool) !void {
    if (dump_bc or source_map) {
        // Compile-only modes: delegate to the jsz public API and exit.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var buf: [8192]u8 = undefined;
        var w = std.fs.File.stdout().writerStreaming(&buf);
        const out = &w.interface;
        if (dump_bc) {
            try jsz.dumpBytecode(arena.allocator(), source, source_name, out);
        } else {
            try jsz.sourceMap(arena.allocator(), source, source_name, out);
        }
        try out.flush();
        return;
    }

    if (emit_bc_path.len > 0) {
        // Compile to a bytecode snapshot and write it to disk, then exit.
        var iso = try jsz.Isolate.init(allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        const image = try ctx.compileSnapshot(allocator, source);
        defer allocator.free(image);
        try std.fs.cwd().writeFile(.{ .sub_path = emit_bc_path, .data = image });
        var ebuf: [256]u8 = undefined;
        var ew = std.fs.File.stderr().writerStreaming(&ebuf);
        const e = &ew.interface;
        try e.print("wrote {d} bytes to {s}\n", .{ image.len, emit_bc_path });
        try e.flush();
        return;
    }

    if (debug) {
        dbg_source = source;
        jsz.debug.installHook(debugHook, null);
    }
    defer if (debug) jsz.debug.clearHook();

    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(interp);
    ctx.setJitMode(jit_mode);
    ctx.setIcStats(ic_stats);
    ctx.setLimits(limits);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    const out = &w.interface;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var uncaught = false;
    const result = if (is_module) ctx.evalModule(source, source_name) else ctx.eval(source, source_name);
    switch (result) {
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

    if (jit_mode != .off) {
        const prof = ctx.lastJitProfile();
        try out.print("=== JIT profile ===\n", .{});
        try out.print("mode: {s}\n", .{@tagName(jit_mode)});
        try out.print("hot_sites: {d}\n", .{prof.hot_sites});
        try out.print("compiled: {d}\n", .{prof.compiled});
        try out.print("deopts: {d}\n", .{prof.deopts});
    }

    if (ic_stats) {
        const prof = ctx.lastIcProfile();
        const total = prof.own_hits + prof.proto_hits + prof.misses;
        try out.print("=== IC stats ===\n", .{});
        try out.print("own_hits: {d}\n", .{prof.own_hits});
        try out.print("proto_hits: {d}\n", .{prof.proto_hits});
        try out.print("misses: {d}\n", .{prof.misses});
        if (total > 0) {
            const pct = @as(f64, @floatFromInt(prof.own_hits + prof.proto_hits)) * 100.0 / @as(f64, @floatFromInt(total));
            try out.print("hit_rate: {d:.1}%\n", .{pct});
        }
    }

    try out.flush();
    if (uncaught) std.process.exit(1);
}

/// Phase 8: load a bytecode snapshot file and run it (restore).
fn runSnapshot(allocator: std.mem.Allocator, path: []const u8) !void {
    const image = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |err| {
        var errbuf: [256]u8 = undefined;
        var ew = std.fs.File.stderr().writerStreaming(&errbuf);
        const e = &ew.interface;
        try e.print("jsz: cannot read snapshot '{s}': {s}\n", .{ path, @errorName(err) });
        try e.flush();
        std.process.exit(1);
    };
    defer allocator.free(image);

    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    const out = &w.interface;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var uncaught = false;
    switch (ctx.evalSnapshot(image)) {
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
    try out.flush();
    if (uncaught) std.process.exit(1);
}

fn runRepl(allocator: std.mem.Allocator, interp: jsz.InterpMode) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
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
    installNativeJit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv_raw = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv_raw);

    const argv = if (argv_raw.len > 1) argv_raw[1..] else argv_raw[0..0];
    const args = parseArgs(argv);

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&buf);
    const stdout = &stdout_writer.interface;
    var errbuf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&errbuf);
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
            try runEval(allocator, args.expr, "<eval>", args.interp, args.dump_bytecode, args.source_map, args.debug, args.emit_bc_path, args.gc_stats, args.gc_after_eval, args.jit_mode, args.limits, args.ic_stats, args.module);
        },
        .interactive => {
            try runRepl(allocator, args.interp);
        },
        .run_bytecode => {
            try runSnapshot(allocator, args.run_bc_path);
        },
        .script => {
            const file_source = std.fs.cwd().readFileAlloc(allocator, args.script_path, 10 * 1024 * 1024) catch |err| {
                try stderr.print("jsz: cannot read '{s}': {s}\n", .{ args.script_path, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            defer allocator.free(file_source);
            const cjs_wrapped = buildWrappedScript(allocator, args.script_path, file_source) catch {
                try stderr.print("jsz: out of memory wrapping script\n", .{});
                try stderr.flush();
                std.process.exit(1);
            };
            defer allocator.free(cjs_wrapped);
            try runEval(allocator, cjs_wrapped, args.script_path, args.interp, args.dump_bytecode, args.source_map, args.debug, args.emit_bc_path, args.gc_stats, args.gc_after_eval, args.jit_mode, args.limits, args.ic_stats, args.module);
        },
    }
}

// ---------------------------------------------------------------------------
// Phase 8: filesystem ES-module loader (relative specifiers, nested dirs).
// Each reachable module is registered as a CommonJS-style factory keyed by its
// canonical path (relative to the entry dir, '/'-separated, `.`/`..` resolved),
// matching what the runtime require() resolver computes. The import/export
// desugaring runs inside each factory body; a per-factory `__module_id__` makes
// nested relative imports resolve against the module's own directory.
// ---------------------------------------------------------------------------

/// Build the entry source wrapped with a `__modules__` registry of all
/// transitively reachable relative modules (delegates to the shared host
/// loader in `runtime/module.zig`). Modules absent on disk are skipped
/// (resolved at runtime). Appends a trailing `module.exports;` so the script's
/// completion value is the entry module's exports.
fn buildWrappedScript(gpa: std.mem.Allocator, script_path: []const u8, entry_src: []const u8) ![]const u8 {
    const base_dir = std.fs.path.dirname(script_path) orelse ".";
    // A HashbangComment is only a comment at offset 0, and the entry source is
    // about to be embedded in a CJS wrapper — so drop the `#!` line here (the
    // lexer's own handling never sees it at position 0). Replaced by a line
    // comment rather than deleted, to keep line numbers aligned.
    const src = if (std.mem.startsWith(u8, entry_src, "#!")) entry_src[2..] else entry_src;
    const lead = if (std.mem.startsWith(u8, entry_src, "#!")) "//" else "";
    const wrapped_src = try std.fmt.allocPrint(gpa, "{s}{s}\nmodule.exports;", .{ lead, src });
    defer gpa.free(wrapped_src);
    const entry_id = std.fs.path.basename(script_path);
    const __b = try jsz.module_loader.buildBundle(gpa, base_dir, entry_id, wrapped_src);
    if (std.process.hasEnvVarConstant("JSZ_DUMP_BUNDLE")) std.debug.print("===BUNDLE===\n{s}\n===END===\n", .{__b});
    return __b;
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

test "parseArgs --source-map" {
    const argv = [_][]const u8{ "-e", "1+1", "--source-map" };
    const a = parseArgs(&argv);
    try std.testing.expect(a.source_map);
}

test "parseArgs --debug implies bc" {
    const argv = [_][]const u8{ "-e", "1+1", "--debug" };
    const a = parseArgs(&argv);
    try std.testing.expect(a.debug);
    try std.testing.expectEqual(jsz.InterpMode.bc, a.interp);
}

test "parseArgs --emit-bytecode" {
    const argv = [_][]const u8{ "-e", "1+1", "--emit-bytecode", "out.jbc" };
    const a = parseArgs(&argv);
    try std.testing.expectEqualStrings("out.jbc", a.emit_bc_path);
}

test "parseArgs --run-bytecode" {
    const argv = [_][]const u8{ "--run-bytecode", "out.jbc" };
    const a = parseArgs(&argv);
    try std.testing.expectEqual(Mode.run_bytecode, a.mode);
    try std.testing.expectEqualStrings("out.jbc", a.run_bc_path);
}

test "parseArgs --module implies bc" {
    const argv = [_][]const u8{ "mod.js", "--module" };
    const a = parseArgs(&argv);
    try std.testing.expect(a.module);
    try std.testing.expectEqual(Mode.script, a.mode);
    try std.testing.expectEqual(jsz.InterpMode.bc, a.interp);
}

test "parseArgs --jit=count implies bc" {
    const argv = [_][]const u8{ "-e", "1+1", "--jit=count" };
    const a = parseArgs(&argv);
    try std.testing.expectEqual(jsz.JitMode.count, a.jit_mode);
    try std.testing.expectEqual(jsz.InterpMode.bc, a.interp);
}
