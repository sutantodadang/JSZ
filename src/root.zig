// SPDX-License-Identifier: MIT
//! jsz public API. Phase 3b: eval + manual mark-sweep GC.
//! Memory model: Values are handles valid until the owning Context is destroyed.
//! Strings passed into jsz are copied. Strings returned from jsz are borrowed
//! (valid until the next eval call). Use toOwnedSlice() to detach.
//!
//! ## API stability (1.0 target)
//! STABLE (frozen for 1.0 — semver-governed): `version`, `Isolate`
//! (`init`/`deinit`/`newContext`), `Context` (`deinit`, `eval`, `registerNativeFn`,
//! `globalObject`, `getProperty`, `makeNumber`/`makeString`/`makeBool`/`makeUndefined`/
//! `makeNull`, `gc`, `gcStats`, `setLimits`), `Value` (`toI32`/`toF64`/`toString`),
//! and the result/option types (`EvalResult`, `Exception`, `ParseError`, `StackFrame`,
//! `GcStats`, `Limits`, `NativeFn`, `NativeResult`), plus `valueToDisplayString`.
//! EXPERIMENTAL (may change before 1.0; not semver-governed): bytecode snapshot
//! (`compileSnapshot`/`evalSnapshot`/`snapshot`), `dumpBytecode`, `sourceMap`,
//! `debug`, the JIT surface (`JitMode`, `JitProfile`, `setJitMode`, `lastJitProfile`,
//! `lastFrameHighWater`, `installNativeCountLoop`/`installNativeAccumulateLoop` and
//! their fn types), and `_regex`.
//!
//! ## Memory ownership
//! `Value` handles are valid until the owning `Context`/`Isolate` is destroyed.
//! Strings passed in are copied; strings returned (e.g. `Value.toString`,
//! `valueToDisplayString`) are borrowed and valid until the next `eval` on that
//! Context — copy them (e.g. `allocator.dupe`) to retain. Host registrations
//! (`registerNativeFn`) live for the Isolate's lifetime.

const std = @import("std");
const isolate_mod = @import("./vm/isolate.zig");
const IsolateImpl = isolate_mod.IsolateImpl;
const val_mod = @import("./value/value.zig");
const realm_mod = @import("./runtime/realm.zig");

pub const version = "0.0.0-phase9-scaffold";

/// Interpreter mode: bytecode VM (only remaining engine).
pub const InterpMode = isolate_mod.InterpMode;

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 9: JIT profiling mode.
pub const JitMode = @import("./jit/jit.zig").JitMode;

const loop_jit = @import("./jit/loop_jit.zig");

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 9: native count-loop kernel type (`fn(start,limit,step)->final`).
pub const NativeCountLoopFn = loop_jit.CountLoopFn;

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 9: install a native (Cranelift-compiled) count-loop kernel for the
/// experimental hot-loop JIT. Without it the pure-Zig fallback is used. The CLI
/// calls this at startup when built with `-Djit=true`.
pub fn installNativeCountLoop(f: NativeCountLoopFn) void {
    loop_jit.native_count_loop = f;
}

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 9: native summation accumulator-loop kernel type + installer.
pub const NativeAccumulateLoopFn = loop_jit.AccumulateLoopFn;

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Install a native (Cranelift-compiled) accumulator-loop kernel for the
/// experimental hot-loop JIT. Without it the pure-Zig fallback is used.
pub fn installNativeAccumulateLoop(f: NativeAccumulateLoopFn) void {
    loop_jit.native_accumulate_loop = f;
}

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 9: JIT profile snapshot (hot sites / compiled / deopts) from the most recent bc eval.
pub const JitProfile = isolate_mod.JitProfile;
pub const IcProfile = isolate_mod.IcProfile;

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

/// W3: resource limits for untrusted execution. 0 = unlimited.
/// `mem_bytes` caps live heap+arena bytes (all interp modes); `gas` caps
/// executed bytecode instructions and `time_ms` caps wall-clock — both enforced
/// in the bytecode VM, so set `interp_mode = .bc` when relying on them. Limit
/// breaches surface as `EvalResult.exception`, never a crash.
pub const Limits = struct {
    mem_bytes: usize = 0,
    gas: u64 = 0,
    time_ms: u64 = 0,
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

/// W6: binds a host `NativeFn` + its owning Context to the internal native ABI.
const HostNativeReg = struct { func: NativeFn, ctx: *Context };

/// Internal-ABI trampoline: recovers the HostNativeReg from the active-native
/// side channel, calls the host fn, and maps NativeResult back (throw → JS exception).
fn hostNativeTrampoline(arena: std.mem.Allocator, this_val: val_mod.Value, args: []const val_mod.Value) anyerror!val_mod.Value {
    _ = this_val;
    const data = val_mod.g_active_native_data orelse return error.JsException;
    const reg: *HostNativeReg = @ptrCast(@alignCast(data));
    const rargs = try arena.alloc(Value, args.len);
    for (args, 0..) |a, i| rargs[i] = Value{ .bits = a.bits };
    return switch (reg.func(reg.ctx, rargs)) {
        .ok => |v| val_mod.Value{ .bits = v.bits },
        .throw => |v| {
            realm_mod.pending_exception = val_mod.Value{ .bits = v.bits };
            return error.JsException;
        },
    };
}

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
            break :blk val_mod.formatNumber(arena, n);
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
                        const elem_inner = val_mod.Value{ .bits = elem.bits };
                        if (elem_inner.bits != 0) {
                            switch (elem_inner.unbox()) {
                                .number => |n| {
                                    const s2 = try val_mod.formatNumber(arena, n);
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
        .symbol => |sd| try std.fmt.allocPrint(arena, "Symbol({s})", .{sd.description orelse ""}),
    };
}

/// EXPERIMENTAL (unstable, may change before 1.0).
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

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 8: debugger + source-map surface.
pub const debug = @import("./runtime/debugger.zig");

/// EXPERIMENTAL (unstable, may change before 1.0).
/// W5: internal regex engine, exposed for the fuzz harness. Not a stable API.
pub const _regex = @import("./runtime/builtins/regexp.zig");

/// EXPERIMENTAL (unstable, may change before 1.0).
/// Phase 8: bytecode snapshot (cache) serializer/deserializer. Advanced
/// embedding surface; most users go through `Context.compileSnapshot`/`evalSnapshot`.
pub const snapshot = @import("./bytecode/snapshot.zig");

/// EXPERIMENTAL (unstable, may change before 1.0).
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
    // The bytecode VM is the only engine.
    interp_mode: InterpMode = .bc,
    jit_mode: JitMode = .off,
    limits: Limits = .{},
    ic_stats: bool = false,

    pub fn setInterpMode(self: *Context, m: InterpMode) void {
        self.interp_mode = m;
    }

    /// STABLE (1.0).
    /// W3: set resource limits for subsequent evals (see `Limits`).
    pub fn setLimits(self: *Context, l: Limits) void {
        self.limits = l;
    }

    /// EXPERIMENTAL (unstable, may change before 1.0).
    /// Phase 9: set the JIT profiling mode. .count and .experimental imply bc interp.
    pub fn setJitMode(self: *Context, m: JitMode) void {
        self.jit_mode = m;
    }

    /// EXPERIMENTAL. Phase 11: enable IC hit-rate instrumentation for next eval.
    pub fn setIcStats(self: *Context, on: bool) void {
        self.ic_stats = on;
    }

    pub fn deinit(self: *Context) void {
        self._isolate.allocator.destroy(self);
    }

    /// STABLE (1.0).
    pub fn eval(self: *Context, source: []const u8, source_name: []const u8) EvalResult {
        _ = source_name;
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        impl.setJitMode(self.jit_mode);
        impl.setIcStats(self.ic_stats);
        impl.setLimits(self.limits.mem_bytes, self.limits.gas, self.limits.time_ms);
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

    /// STABLE (1.0).
    /// Trigger a manual mark-sweep GC cycle.
    /// Returns cumulative heap stats after the cycle.
    pub fn gc(self: *Context) GcStats {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        _ = impl.gc();
        return self.gcStats();
    }

    /// STABLE (1.0).
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

    /// EXPERIMENTAL (unstable, may change before 1.0).
    /// Phase 8: call-frame depth high-water mark of the most recent bc-mode
    /// eval. Mainly a test/inspection hook for proper tail calls: a strict
    /// tail-recursive function keeps this O(1) regardless of recursion depth.
    pub fn lastFrameHighWater(self: *Context) usize {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.last_frame_high_water;
    }

    /// EXPERIMENTAL (unstable, may change before 1.0).
    /// Phase 9: JIT profile (hot sites / compiled / deopts) from the most recent
    /// bc-mode eval. All zero unless a JIT mode other than .off was set.
    pub fn lastJitProfile(self: *Context) JitProfile {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.last_jit_profile;
    }

    /// EXPERIMENTAL. Phase 11: IC profile (own/proto hits, misses) from the most
    /// recent bc eval. All zero unless setIcStats(true) was called.
    pub fn lastIcProfile(self: *Context) IcProfile {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.last_ic_profile;
    }

    /// EXPERIMENTAL (unstable, may change before 1.0).
    /// Phase 8: compile `source` to a sourceless bytecode image (snapshot).
    /// The returned bytes are allocated with `out_allocator` and owned by the
    /// caller — they outlive the Context and can be persisted to disk.
    pub fn compileSnapshot(self: *Context, out_allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        return impl.compileSnapshot(out_allocator, source);
    }

    /// EXPERIMENTAL (unstable, may change before 1.0).
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

    /// STABLE (1.0).
    pub fn registerNativeFn(self: *Context, name: []const u8, func: NativeFn) JszError!void {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const reg = impl.persistentAllocator().create(HostNativeReg) catch return JszError.OutOfMemory;
        reg.* = .{ .func = func, .ctx = self };
        impl.registerNative(name, hostNativeTrampoline, reg) catch return JszError.OutOfMemory;
    }

    /// STABLE (1.0).
    pub fn globalObject(self: *Context) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = impl.globalSnapshot() catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    pub fn makeNumber(self: *Context, n: f64) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = val_mod.makeNumber(impl.persistentAllocator(), n) catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    pub fn makeString(self: *Context, s: []const u8) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = val_mod.makeString(impl.persistentAllocator(), s) catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    pub fn makeBool(self: *Context, b: bool) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = val_mod.makeBool(impl.persistentAllocator(), b) catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    pub fn makeUndefined(self: *Context) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = val_mod.makeUndefined(impl.persistentAllocator()) catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    pub fn makeNull(self: *Context) Value {
        const impl: *IsolateImpl = @ptrCast(@alignCast(self._isolate._impl.?));
        const v = val_mod.makeNull(impl.persistentAllocator()) catch return Value{};
        return Value{ .bits = v.bits };
    }

    /// STABLE (1.0).
    /// Read an own/inherited property from an object Value (undefined-Value if absent/non-object).
    pub fn getProperty(self: *Context, obj: Value, name: []const u8) Value {
        _ = self;
        const inner = val_mod.Value{ .bits = obj.bits };
        if (inner.bits == 0) return Value{};
        return switch (inner.unbox()) {
            .object => |o| if (o.get(name)) |v| Value{ .bits = v.bits } else Value{},
            else => Value{},
        };
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

test "W6: registerNativeFn callable from JS" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const H = struct {
        fn addOne(c: *Context, args: []const Value) NativeResult {
            const n = if (args.len > 0) args[0].toF64() else 0;
            return .{ .ok = c.makeNumber(n + 1) };
        }
    };
    try ctx.registerNativeFn("addOne", H.addOne);
    const r = ctx.eval("addOne(41)", "<test>");
    switch (r) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "W6: globalObject reflects JS-defined globals" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    _ = ctx.eval("var answer = 42;", "<test>");
    const g = ctx.globalObject();
    try std.testing.expect(g.bits != 0);
    const a = ctx.getProperty(g, "answer");
    try std.testing.expectEqual(@as(f64, 42), a.toF64());
}
