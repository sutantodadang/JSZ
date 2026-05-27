// SPDX-License-Identifier: MIT
//! IsolateImpl: holds arenas, realm, GC heap, and the parser for one Isolate.
//! The public Isolate (root.zig) stores a *IsolateImpl via _impl: ?*anyopaque.
const std = @import("std");
const Vm = @import("./vm.zig").Vm;
const compiler_mod = @import("../bytecode/compiler.zig");
const BcVm = @import("./bc_vm.zig").BcVm;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const Heap = @import("../gc/heap.zig").Heap;
const CollectStats = @import("../gc/heap.zig").CollectStats;
const promise_mod = @import("../runtime/builtins/promise.zig");

pub const InterpMode = enum { tree, bc };

/// Internal implementation of the public Isolate.
pub const IsolateImpl = struct {
    /// Base allocator (owns the eval arena and the GC heap).
    backing: std.mem.Allocator,
    /// Arena for a single eval call. Reset after each eval().
    eval_arena: std.heap.ArenaAllocator,
    /// Phase 3b: GC heap. Owned by the IsolateImpl.
    heap: Heap,

    pub fn init(backing: std.mem.Allocator) !*IsolateImpl {
        const impl = try backing.create(IsolateImpl);
        impl.* = IsolateImpl{
            .backing = backing,
            .eval_arena = std.heap.ArenaAllocator.init(backing),
            .heap = Heap.init(backing),
        };
        return impl;
    }

    pub fn deinit(self: *IsolateImpl) void {
        self.heap.deinit();
        self.eval_arena.deinit();
        self.backing.destroy(self);
    }

    /// Manually trigger a GC cycle. Returns stats.
    pub fn gc(self: *IsolateImpl) CollectStats {
        return self.heap.collect();
    }

    /// Heap stats snapshot (cumulative).
    pub fn heapStats(self: *IsolateImpl) struct {
        collections: usize,
        bytes_allocated: usize,
        bytes_freed: usize,
        objects_alive: usize,
    } {
        return .{
            .collections = self.heap.collections,
            .bytes_allocated = self.heap.bytes_allocated,
            .bytes_freed = self.heap.bytes_freed,
            .objects_alive = self.heap.objects_alive,
        };
    }

    /// Run one eval call in tree mode (Phase 1 default). Resets the eval arena on entry.
    pub fn eval(self: *IsolateImpl, source: []const u8) !EvalOutcome {
        return self.evalWithMode(source, .tree);
    }

    pub fn evalWithMode(self: *IsolateImpl, source: []const u8, mode: InterpMode) !EvalOutcome {
        _ = self.eval_arena.reset(.free_all);
        promise_mod.clearMicrotasks();
        const arena = self.eval_arena.allocator();
        const transformed_source = try rewriteTemplateLiterals(arena, source);

        const parser_mod = @import("../parser/parser.zig");
        var p = parser_mod.Parser.init(transformed_source, arena);
        const parse_result = p.parseScript();
        const stmts = switch (parse_result) {
            .ok => |s| s,
            .err => |e| return EvalOutcome{ .parse_error = .{
                .message = e.message,
                .line = e.line,
                .column = e.column,
            } },
        };

        switch (mode) {
            .tree => {
                var vm = try Vm.initWithHeap(arena, &self.heap);
                // Register roots AFTER vm is in final stack location.
                try vm.realm.registerRoots();
                try vm.registerHeapCallback(&self.heap);
                defer vm.unregisterHeapCallback(&self.heap);
                const r = try vm.runScript(stmts);
                promise_mod.runMicrotasks(arena);
                return switch (r) {
                    .value => |v| EvalOutcome{ .ok = v },
                    .exception => |ex| EvalOutcome{ .exception = ex.message },
                    .return_ => |v| EvalOutcome{ .ok = v },
                    .break_ => EvalOutcome{ .ok = try val_mod.makeUndefined(arena) },
                    .continue_ => EvalOutcome{ .ok = try val_mod.makeUndefined(arena) },
                    .yield_suspend => EvalOutcome{ .ok = try val_mod.makeUndefined(arena) },
                };
            },
            .bc => {
                // Compile to bytecode.
                const ast_mod = @import("../parser/ast.zig");
                const prog = ast_mod.Program{ .body = stmts };
                const main_func = compiler_mod.compileProgram(arena, &prog, "<eval>") catch |e| {
                    return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };

                // Set up realm with ES5 globals + Phase 3a/3b intrinsics.
                const Realm = @import("../runtime/realm.zig").Realm;
                var realm = try Realm.init(arena);
                try realm.activateHeap(&self.heap);
                defer realm.deinit();

                const nan_val = try val_mod.makeNumber(arena, std.math.nan(f64));
                const inf_val = try val_mod.makeNumber(arena, std.math.inf(f64));
                const undef_val = try val_mod.makeUndefined(arena);
                try realm.global_env.define("NaN", nan_val);
                try realm.global_env.define("Infinity", inf_val);
                try realm.global_env.define("undefined", undef_val);

                // Expose __gc__ native function for JS-side collection trigger.
                const gc_fn = try val_mod.makeNativeFunction(arena, nativeGcCollect);
                try realm.global_env.define("__gc__", gc_fn);
                const microtask_fn = try val_mod.makeNativeFunction(arena, promise_mod.nativeRunMicrotasks);
                try realm.global_env.define("__runMicrotasks__", microtask_fn);

                var bc_vm = BcVm.initWithHeap(arena, &realm, &self.heap);
                // Register roots AFTER bc_vm/realm are in final stack location.
                try realm.registerRoots();
                try bc_vm.registerHeapCallback(&self.heap);
                defer bc_vm.unregisterHeapCallback(&self.heap);
                const outcome = try bc_vm.run(main_func, @ptrCast(realm.global_env));
                promise_mod.runMicrotasks(arena);
                return switch (outcome) {
                    .ok => |v| EvalOutcome{ .ok = v },
                    .exception => |msg| EvalOutcome{ .exception = msg },
                    .exception_value => |ev| EvalOutcome{ .exception = ev.msg },
                };
            },
        }
    }
};

fn rewriteTemplateLiterals(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] != '`') {
            try out.append(arena, source[i]);
            i += 1;
            continue;
        }
        i += 1; // consume opening backtick
        try out.appendSlice(arena, "(");
        var emitted_any = false;
        var literal_buf = std.ArrayList(u8){};
        while (i < source.len) {
            if (source[i] == '\\' and i + 1 < source.len) {
                try literal_buf.append(arena, source[i]);
                try literal_buf.append(arena, source[i + 1]);
                i += 2;
                continue;
            }
            if (source[i] == '$' and i + 1 < source.len and source[i + 1] == '{') {
                try emitTemplateLiteralSegment(arena, &out, literal_buf.items, emitted_any);
                emitted_any = true;
                literal_buf.clearRetainingCapacity();
                i += 2; // skip ${
                var depth: usize = 1;
                const expr_start = i;
                var expr_end = expr_start;
                while (i < source.len and depth > 0) {
                    const ch = source[i];
                    if (ch == '{') {
                        depth += 1;
                    } else if (ch == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            expr_end = i;
                            i += 1; // consume closing }
                            break;
                        }
                    }
                    i += 1;
                }
                if (emitted_any) try out.appendSlice(arena, " + ");
                try out.appendSlice(arena, "(");
                if (expr_end >= expr_start and expr_end <= source.len) {
                    try out.appendSlice(arena, source[expr_start..expr_end]);
                }
                try out.appendSlice(arena, ")");
                emitted_any = true;
                continue;
            }
            if (source[i] == '`') {
                i += 1; // consume closing backtick
                break;
            }
            try literal_buf.append(arena, source[i]);
            i += 1;
        }
        try emitTemplateLiteralSegment(arena, &out, literal_buf.items, emitted_any);
        try out.appendSlice(arena, ")");
    }
    return out.items;
}

fn emitTemplateLiteralSegment(arena: std.mem.Allocator, out: *std.ArrayList(u8), segment: []const u8, emitted_any: bool) !void {
    if (segment.len == 0 and emitted_any) return;
    if (emitted_any) try out.appendSlice(arena, " + ");
    try out.append(arena, '"');
    for (segment) |ch| {
        if (ch == '"' or ch == '\\') {
            try out.append(arena, '\\');
        }
        try out.append(arena, ch);
    }
    try out.append(arena, '"');
}

/// Native function exposed as __gc__() in JS. Triggers a manual collect.
fn nativeGcCollect(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    const realm_mod = @import("../runtime/realm.zig");
    if (realm_mod.active_heap) |heap| {
        _ = heap.collect();
    }
    return val_mod.makeUndefined(arena);
}

pub const EvalOutcome = union(enum) {
    ok: Value,
    exception: []const u8,
    parse_error: ParseErrorInfo,
};

pub const ParseErrorInfo = struct {
    message: []const u8,
    line: u32,
    column: u32,
};

test "IsolateImpl eval 1+2" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    const r = try impl.eval("1+2");
    switch (r) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 3), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "IsolateImpl bc eval 1+2" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    const r = try impl.evalWithMode("1+2", .bc);
    switch (r) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 3), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "IsolateImpl bc eval fib(10)" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    const r = try impl.evalWithMode(
        "(function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); })(10)",
        .bc,
    );
    switch (r) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 55), v.toF64()),
        else => |x| {
            switch (x) {
                .exception => |msg| std.debug.print("bc exception: {s}\n", .{msg}),
                .parse_error => |e| std.debug.print("bc parse error: {s}\n", .{e.message}),
                else => {},
            }
            return error.UnexpectedResult;
        },
    }
}

test "IsolateImpl: gc() returns stats" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    const stats = impl.gc();
    try std.testing.expectEqual(@as(usize, 0), stats.freed_objects);
}
