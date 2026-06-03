// SPDX-License-Identifier: MIT
//! jsz public API. Phase 3b: eval + manual mark-sweep GC.
//! Memory model: Values are handles valid until the owning Context is destroyed.
//! Strings passed into jsz are copied. Strings returned from jsz are borrowed
//! (valid until the next eval call). Use toOwnedSlice() to detach.

const std = @import("std");
const isolate_mod = @import("./vm/isolate.zig");
const IsolateImpl = isolate_mod.IsolateImpl;
const val_mod = @import("./value/value.zig");

pub const version = "0.0.0-phase9-scaffold";

/// Interpreter mode: tree-walker (default) or bytecode VM.
pub const InterpMode = isolate_mod.InterpMode;

/// Phase 9: JIT profiling mode.
pub const JitMode = @import("./jit/jit.zig").JitMode;

const loop_jit = @import("./jit/loop_jit.zig");

/// Phase 9: native count-loop kernel type (`fn(start,limit,step)->final`).
pub const NativeCountLoopFn = loop_jit.CountLoopFn;

/// Phase 9: install a native (Cranelift-compiled) count-loop kernel for the
/// experimental hot-loop JIT. Without it the pure-Zig fallback is used. The CLI
/// calls this at startup when built with `-Djit=true`.
pub fn installNativeCountLoop(f: NativeCountLoopFn) void {
    loop_jit.native_count_loop = f;
}

/// Phase 9: native summation accumulator-loop kernel type + installer.
pub const NativeAccumulateLoopFn = loop_jit.AccumulateLoopFn;

/// Install a native (Cranelift-compiled) accumulator-loop kernel for the
/// experimental hot-loop JIT. Without it the pure-Zig fallback is used.
pub fn installNativeAccumulateLoop(f: NativeAccumulateLoopFn) void {
    loop_jit.native_accumulate_loop = f;
}

/// Phase 9: JIT profile snapshot (hot sites / compiled / deopts) from the most recent bc eval.
pub const JitProfile = isolate_mod.JitProfile;

/// Error set for all jsz operations.
pub const JszError = error{ NotImplemented, OutOfMemory };

/// Opaque handle to a JS value. In Phase 1, bits = pointer to internal JsValue.
/// Valid until the owning Context is destroyed.
pub const Value = extern struct {
    bits: u64 = 0,

    pub fn toI32(self: Value) i32 {
        const v = val_mod.Value{ .bits = self.bits };
        return v.toI32();
    }

    pub fn toF64(self: Value) f64 {
        const v = val_mod.Value{ .bits = self.bits };
        return v.toF64();
    }

    pub fn toString(self: Value) []const u8 {
        const v = val_mod.Value{ .bits = self.bits };
        return v.toString();
    }
};

/// A single JS stack frame in an exception trace.
pub const StackFrame = struct {
    function_name: []const u8,
    source_name: []const u8,
    line: u32,
    column: u32,
};

/// A JS-level thrown exception.
pub const Exception = struct {
    value: Value,
    message: []const u8,
    stack: []const StackFrame,
};

/// A host-visible parse (SyntaxError) from the JS source.
pub const ParseError = struct {
    message: []const u8,
    line: u32,
    column: u32,
};

/// Result of Context.eval. Never a Zig error — eval failures are values.
pub const EvalResult = union(enum) {
    ok: Value,
    exception: Exception,
    parse_error: ParseError,
};

/// Stats returned by Context.gc() and available via Context.gcStats().
pub const GcStats = struct {
    /// Number of collect() cycles run so far (cumulative).
    collections: usize,
    /// Cumulative bytes allocated through GC (monotone).
    bytes_allocated: usize,
    /// Cumulative bytes freed by GC (monotone).
    bytes_freed: usize,
    /// Currently live GC-managed objects.
    objects_alive: usize,
};

/// Signature for a native function callable from JS.
pub const NativeFn = *const fn (*Context, []const Value) NativeResult;

/// Return type for a NativeFn.
pub const NativeResult = union(enum) {
    ok: Value,
    throw: Value,
};

/// Convert a Value to a display string (ECMAScript ToString for printing).
/// The returned slice is allocated from `arena` and valid until arena is freed.
pub fn valueToDisplayString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    const inner = val_mod.Value{ .bits = v.bits };
    if (inner.bits == 0) return "undefined";
    return switch (inner.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| blk: {
            const vm_mod = @import("./vm/vm.zig");
            break :blk vm_mod.formatNumber(arena, n);
        },
        .string => |s| try arena.dupe(u8, s),
        .function => |f| std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{f.name orelse ""}),
        .bc_function => |c| std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{c.func.name orelse ""}),
        .object => |obj| blk: {
            if (obj.is_array) {
                // Array.toString: join elements with comma.
                var buf = std.ArrayList(u8){};
                const len = obj.getArrayLength();
                for (0..len) |i| {
                    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                    if (i > 0) try buf.append(arena, ',');
                    if (obj.get(key)) |elem| {
                        const vm_mod2 = @import("./vm/vm.zig");
                        _ = vm_mod2;
                        const elem_inner = val_mod.Value{ .bits = elem.bits };
                        if (elem_inner.bits != 0) {
                            switch (elem_inner.unbox()) {
                                .number => |n| {
                                    const vm_mod3 = @import("./vm/vm.zig");
                                    const s2 = try vm_mod3.formatNumber(arena, n);
                                    try buf.appendSlice(arena, s2);
                                },
                                .string => |s2| try buf.appendSlice(arena, s2),
                                .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
                                .null_ => {},
                                .undefined_ => {},
                                else => try buf.appendSlice(arena, "[object Object]"),
                            }
                        }
                    }
                }
                break :blk try arena.dupe(u8, buf.items);
            }
            break :blk try arena.dupe(u8, "[object Object]");
        },
        .native_function => try arena.dupe(u8, "function () { [native code] }"),
    };
}

/// Compile source to bytecode and disassemble to writer.
/// Used by --dump-bytecode CLI flag.
pub fn dumpBytecode(arena: std.mem.Allocator, source: []const u8, source_name: []const u8, writer: anytype) !void {
    const parser_mod = @import("./parser/parser.zig");
    var p = parser_mod.Parser.init(source, arena);
    const parse_result = p.parseScript();
    const stmts = switch (parse_result) {
        .ok => |s| s,
        .err => |e| {
            try writer.print("SyntaxError: {s} (line {d}:{d})\n", .{ e.message, e.line, e.column });
            return;
        },
    };
    const ast_mod = @import("./parser/ast.zig");
    const prog = ast_mod.Program{ .body = stmts };
    const compiler_mod = @import("./bytecode/compiler.zig");
    const f = compiler_mod.compileProgram(arena, &prog, source_name) catch {
        try writer.print("compile error\n", .{});
        return;
    };
    const chunk_mod = @import("./bytecode/chunk.zig");
    try chunk_mod.disassemble(&f.chunk, writer);
}

/// Phase 8: debugger + source-map surface.
pub const debug = @import("./runtime/debugger.zig");

/// Phase 8: bytecode snapshot (cache) serializer/deserializer. Advanced
/// embedding surface; most users go through `Context.compileSnapshot`/`evalSnapshot`.
pub const snapshot = @import("./bytecode/snapshot.zig");

/// Phase 8: compile `source` and write a bytecode→source JSON source map to
/// `writer`. Maps each opcode (and nested function literals) back to a
/// line/column in the original source. See `runtime/debugger.zig`.
pub fn sourceMap(arena: std.mem.Allocator, source: []const u8, source_name: []const u8, writer: anytype) !void {
    const parser_mod = @import("./parser/parser.zig");
    var p = parser_mod.Parser.init(source, arena);
    const parse_result = p.parseScript();
    const stmts = switch (parse_result) {
        .ok => |s| s,
        .err => |e| {
            try writer.print("SyntaxError: {s} (line {d}:{d})\n", .{ e.message, e.line, e.column });
            return;
        },
    };
    const ast_mod = @import("./parser/ast.zig");
    const prog = ast_mod.Program{ .body = stmts };
    const compiler_mod = @import("./bytecode/compiler.zig");
    const f = compiler_mod.compileProgram(arena, &prog, source_name) catch {
        try writer.print("compile error\n", .{});
        return;
    };
    try debug.writeSourceMap(writer, source, source_name, f);
    try writer.writeAll("\n");
}

/// The VM root object. Owns the heap, GC, atom table, and symbol registry.
pub const Isolate = struct {
    allocator: std.mem.Allocator,
    _impl: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) JszError!Isolate {
        const impl = IsolateImpl.init(allocator) catch return JszError.OutOfMemory;
        return Isolate{
            .allocator = allocator,
            ._impl = impl,
        };
    }

    pub fn deinit(self: *Isolate) void {
        if (self._impl) |impl| {
            const iso_impl: *IsolateImpl = @ptrCast(@alignCast(impl));
            iso_impl.deinit();
            self._impl = null;
        }
    }

    pub fn newContext(self: *Isolate) JszError!*Context {
        const ctx = self.allocator.create(Context) catch return JszError.OutOfMemory;
        ctx.* = Context{ ._isolate = self };
        return ctx;
    }
};

/// A JS execution context: owns the global object and intrinsics.
pub const Context = struct {
    _isolate: *Isolate,
    interp_mode: InterpMode = .tree,
    jit_mode: JitMode = .off,

    pub fn setInterpMode(self: *Context, m: InterpMode) void {
        self.interp_mode = m;
    }

    /// Phase 9: set the JIT profiling mode. .count and .experimental imply bc interp.
    pub fn setJitMode(self: *Context, m: JitMode) void {
        self.jit_mode = m;
    }

    pub fn deinit(self: *Context) void {
        self._isolate.allocator.destroy(self);
    }

    pub fn eval(self: *Context, source: []const u8, source_name: []const u8) EvalResult {
        _ = source_name;
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        impl.setJitMode(self.jit_mode);
        const outcome = impl.evalWithMode(source, self.interp_mode, &[_]val_mod.NativeBinding{}) catch {
            return EvalResult{ .exception = Exception{
                .value = Value{},
                .message = "out of memory",
                .stack = &[_]StackFrame{},
            } };
        };
        return switch (outcome) {
            .ok => |v| EvalResult{ .ok = Value{ .bits = v.bits } },
            .exception => |msg| EvalResult{ .exception = Exception{
                .value = Value{},
                .message = msg,
                .stack = &[_]StackFrame{},
            } },
            .parse_error => |pe| EvalResult{ .parse_error = ParseError{
                .message = pe.message,
                .line = pe.line,
                .column = pe.column,
            } },
        };
    }

    /// Trigger a manual mark-sweep GC cycle.
    /// Returns cumulative heap stats after the cycle.
    pub fn gc(self: *Context) GcStats {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        _ = impl.gc();
        return self.gcStats();
    }

    /// Return current GC stats without triggering a collection.
    pub fn gcStats(self: *Context) GcStats {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const s = impl.heapStats();
        return GcStats{
            .collections = s.collections,
            .bytes_allocated = s.bytes_allocated,
            .bytes_freed = s.bytes_freed,
            .objects_alive = s.objects_alive,
        };
    }

    /// Phase 8: call-frame depth high-water mark of the most recent bc-mode
    /// eval. Mainly a test/inspection hook for proper tail calls: a strict
    /// tail-recursive function keeps this O(1) regardless of recursion depth.
    pub fn lastFrameHighWater(self: *Context) usize {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.last_frame_high_water;
    }

    /// Phase 9: JIT profile (hot sites / compiled / deopts) from the most recent
    /// bc-mode eval. All zero unless a JIT mode other than .off was set.
    pub fn lastJitProfile(self: *Context) JitProfile {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.last_jit_profile;
    }

    /// Phase 8: compile `source` to a sourceless bytecode image (snapshot).
    /// The returned bytes are allocated with `out_allocator` and owned by the
    /// caller — they outlive the Context and can be persisted to disk.
    pub fn compileSnapshot(self: *Context, out_allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.compileSnapshot(out_allocator, source);
    }

    /// Phase 8: restore a bytecode image (from `compileSnapshot`) and run it in
    /// the bytecode VM against a fresh realm.
    pub fn evalSnapshot(self: *Context, image: []const u8) EvalResult {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const outcome = impl.evalSnapshot(image) catch {
            return EvalResult{ .exception = Exception{
                .value = Value{},
                .message = "out of memory",
                .stack = &[_]StackFrame{},
            } };
        };
        return switch (outcome) {
            .ok => |v| EvalResult{ .ok = Value{ .bits = v.bits } },
            .exception => |msg| EvalResult{ .exception = Exception{
                .value = Value{},
                .message = msg,
                .stack = &[_]StackFrame{},
            } },
            .parse_error => |pe| EvalResult{ .parse_error = ParseError{
                .message = pe.message,
                .line = pe.line,
                .column = pe.column,
            } },
        };
    }

    pub fn registerNativeFn(self: *Context, name: []const u8, func: NativeFn) JszError!void {
        _ = self;
        _ = name;
        _ = func;
        return JszError.NotImplemented;
    }

    pub fn globalObject(self: *Context) Value {
        _ = self;
        return Value{};
    }
};

// ------------------------------------------------------------------ test imports --
// Pull in all test-bearing modules so `zig build test` exercises them all.
comptime {
    _ = @import("./lexer/token.zig");
    _ = @import("./lexer/lexer.zig");
    _ = @import("./parser/ast.zig");
    _ = @import("./parser/precedence.zig");
    _ = @import("./parser/recovery.zig");
    _ = @import("./parser/parser.zig");
    _ = @import("./value/value.zig");
    _ = @import("./runtime/execution_context.zig");
    _ = @import("./runtime/realm.zig");
    _ = @import("./runtime/error.zig");
    _ = @import("./vm/frame.zig");
    _ = @import("./vm/vm.zig");
    _ = @import("./vm/isolate.zig");
    _ = @import("./vm/bc_vm.zig");
    _ = @import("./bytecode/opcodes.zig");
    _ = @import("./bytecode/chunk.zig");
    _ = @import("./bytecode/function.zig");
    _ = @import("./bytecode/compiler.zig");
    _ = @import("./test/integration_test.zig");
    _ = @import("./object/object.zig");
    _ = @import("./gc/heap.zig");
    _ = @import("./gc/handle.zig");
    _ = @import("./gc/gc.zig");
}

// ------------------------------------------------------------------ tests ---

test "Isolate init/deinit" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    try std.testing.expect(iso._impl != null);
}

test "Context eval 1+2 = 3" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.eval("1 + 2", "<test>");
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 3), v.toF64()),
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.UnexpectedResult;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.UnexpectedResult;
        },
    }
}

test "Context eval fib(10) = 55" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.eval("(function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); })(10)", "<test>");
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 55), v.toF64()),
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.UnexpectedResult;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.UnexpectedResult;
        },
    }
}

test "Context eval typeof null = object" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.eval("typeof null", "<test>");
    switch (result) {
        .ok => |v| {
            const inner = val_mod.Value{ .bits = v.bits };
            const s = inner.toPtr().string;
            try std.testing.expectEqualStrings("object", s);
        },
        else => return error.UnexpectedResult,
    }
}
