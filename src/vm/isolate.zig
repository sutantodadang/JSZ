// SPDX-License-Identifier: MIT
//! IsolateImpl: holds arenas, realm, GC heap, and the parser for one Isolate.
//! The public Isolate (root.zig) stores a *IsolateImpl via _impl: ?*anyopaque.
const std = @import("std");
const compiler_mod = @import("../bytecode/compiler.zig");
const BcVm = @import("./bc_vm.zig").BcVm;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const Heap = @import("../gc/heap.zig").Heap;
const CollectStats = @import("../gc/heap.zig").CollectStats;
const promise_mod = @import("../runtime/builtins/promise.zig");
const jit_mod = @import("../jit/jit.zig");

pub const InterpMode = enum { bc };

/// W3: an allocator wrapper enforcing a live-bytes budget. When `limit` is
/// non-zero, allocations that would push live bytes past it fail with OOM,
/// which propagates up as a catchable host error (never a crash).
pub const LimitAllocator = struct {
    child: std.mem.Allocator,
    limit: usize = 0,
    used: usize = 0,

    pub fn init(child: std.mem.Allocator, limit: usize) LimitAllocator {
        return .{ .child = child, .limit = limit };
    }

    pub fn allocator(self: *LimitAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (self.limit != 0 and self.used + len > self.limit) return null;
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len and self.limit != 0 and self.used + (new_len - buf.len) > self.limit) return false;
        if (!self.child.rawResize(buf, a, new_len, ra)) return false;
        self.used = self.used - buf.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len and self.limit != 0 and self.used + (new_len - buf.len) > self.limit) return null;
        const p = self.child.rawRemap(buf, a, new_len, ra) orelse return null;
        self.used = self.used - buf.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
        self.used -= buf.len;
    }
};

/// Phase 9: snapshot of JIT profiling data from the most recent bc-mode eval.
pub const JitProfile = struct {
    hot_sites: usize = 0,
    compiled: usize = 0,
    deopts: usize = 0,
};

/// Internal implementation of the public Isolate.
pub const IsolateImpl = struct {
    /// Base allocator (owns the eval arena and the GC heap).
    backing: std.mem.Allocator,
    /// W3: memory-budget wrapper around `backing`. The arena + heap allocate
    /// through this, so the limit covers parser, compiler, VM, and GC alike.
    limiter: LimitAllocator,
    /// Arena for a single eval call. Reset after each eval().
    eval_arena: std.heap.ArenaAllocator,
    /// Phase 3b: GC heap. Owned by the IsolateImpl.
    heap: Heap,
    /// Phase 8: call-frame depth high-water mark of the most recent bc-mode
    /// eval. Exposed for tail-call tests (stays small when PTC engages).
    last_frame_high_water: usize = 0,
    /// Phase 9: JIT mode for the next eval call.
    jit_mode: jit_mod.JitMode = .off,
    /// Phase 9: profile snapshot from the most recent bc-mode eval.
    last_jit_profile: JitProfile = .{},
    /// W3: gas (instruction) budget and wall-clock budget (ms) for the next
    /// bc-mode eval. 0 = unlimited.
    gas_limit: u64 = 0,
    time_limit_ms: u64 = 0,
    /// W6: the persistent Realm (global scope + intrinsics), built once on the
    /// first eval and reused across evals so top-level declarations persist.
    realm: ?*@import("../runtime/realm.zig").Realm = null,

    pub fn init(backing: std.mem.Allocator) !*IsolateImpl {
        const impl = try backing.create(IsolateImpl);
        impl.* = IsolateImpl{
            .backing = backing,
            .limiter = LimitAllocator.init(backing, 0),
            .eval_arena = undefined,
            .heap = undefined,
        };
        const lim = impl.limiter.allocator();
        impl.eval_arena = std.heap.ArenaAllocator.init(lim);
        impl.heap = Heap.init(lim);
        return impl;
    }

    /// W3: set resource limits. 0 = unlimited. Memory applies isolate-wide
    /// immediately; gas/time apply to subsequent bc-mode evals.
    pub fn setLimits(self: *IsolateImpl, mem_bytes: usize, gas: u64, time_ms: u64) void {
        self.limiter.limit = mem_bytes;
        self.gas_limit = gas;
        self.time_limit_ms = time_ms;
    }

    pub fn deinit(self: *IsolateImpl) void {
        if (self.realm) |r| r.deinit();
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

    /// Phase 9: set the JIT mode for the next eval call.
    pub fn setJitMode(self: *IsolateImpl, m: jit_mod.JitMode) void {
        self.jit_mode = m;
    }

    /// Run one eval call in the bytecode VM (W2: bc is the default engine).
    /// Does NOT reset the eval arena so top-level declarations persist (W6).
    pub fn eval(self: *IsolateImpl, source: []const u8) !EvalOutcome {
        return self.evalWithMode(source, .bc, &[_]val_mod.NativeBinding{});
    }

    pub fn evalWithMode(self: *IsolateImpl, source: []const u8, mode: InterpMode, native_bindings: []const val_mod.NativeBinding) !EvalOutcome {
        _ = native_bindings;
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
            .bc => {
                // Compile to bytecode.
                const ast_mod = @import("../parser/ast.zig");
                const prog = ast_mod.Program{ .body = stmts };
                const main_func = compiler_mod.compileProgram(arena, &prog, "<eval>") catch |e| {
                    return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
                return self.runMainBc(arena, main_func);
            },
        }
    }

    /// W6: build the persistent Realm on first use; reuse it thereafter so
    /// global declarations survive across eval calls. Realm + globals live in
    /// the (now non-reset) eval arena.
    fn ensureRealm(self: *IsolateImpl, arena: std.mem.Allocator) !*@import("../runtime/realm.zig").Realm {
        if (self.realm) |r| return r;
        const Realm = @import("../runtime/realm.zig").Realm;
        const realm = try arena.create(Realm);
        realm.* = try Realm.init(arena);
        try realm.activateHeap(&self.heap);

        const nan_val = try val_mod.makeNumber(arena, std.math.nan(f64));
        const inf_val = try val_mod.makeNumber(arena, std.math.inf(f64));
        const undef_val = try val_mod.makeUndefined(arena);
        try realm.global_env.define("NaN", nan_val);
        try realm.global_env.define("Infinity", inf_val);
        try realm.global_env.define("undefined", undef_val);
        try realm.global_env.define("__gc__", try val_mod.makeNativeFunction(arena, nativeGcCollect));
        try realm.global_env.define("__runMicrotasks__", try val_mod.makeNativeFunction(arena, promise_mod.nativeRunMicrotasks));
        try realm.global_env.define("__await__", try val_mod.makeNativeFunction(arena, promise_mod.nativeAwait));
        const es2015 = @import("../runtime/builtins/es2015_collections.zig");
        try realm.global_env.define("__getIterator__", try val_mod.makeNativeFunction(arena, es2015.nativeGetIterator));
        try realm.global_env.define("__iterStep__", try val_mod.makeNativeFunction(arena, es2015.nativeIterStep));

        try realm.registerRoots();
        self.realm = realm;
        return realm;
    }

    /// Run a compiled `main_func` in the bytecode VM against the persistent realm.
    /// Shared by `evalWithMode(.bc)` and snapshot restore.
    fn runMainBc(self: *IsolateImpl, arena: std.mem.Allocator, main_func: *const @import("../bytecode/function.zig").BcFunction) !EvalOutcome {
        const realm = try self.ensureRealm(arena);

        var bc_vm = BcVm.initWithHeap(arena, realm, &self.heap);
        // W3: apply resource limits to this run.
        bc_vm.gas_limit = self.gas_limit;
        if (self.time_limit_ms != 0)
            bc_vm.deadline_ns = std.time.nanoTimestamp() + @as(i128, self.time_limit_ms) * std.time.ns_per_ms;
        // Phase 9: attach JIT profiler when a mode other than .off is requested.
        var jc: jit_mod.JitCompiler = undefined;
        if (self.jit_mode != .off) {
            jc = jit_mod.JitCompiler.initMode(arena, self.jit_mode);
            bc_vm.jit = &jc;
        }
        // Register roots AFTER bc_vm/realm are in final stack location.
        try bc_vm.registerHeapCallback(&self.heap);
        defer bc_vm.unregisterHeapCallback(&self.heap);
        const outcome = try bc_vm.run(main_func, @ptrCast(realm.global_env));
        self.last_frame_high_water = bc_vm.frame_high_water;
        // Phase 9: capture JIT profile snapshot.
        if (self.jit_mode != .off) {
            self.last_jit_profile = .{
                .hot_sites = jc.hotCount(),
                .compiled = jc.compiled,
                .deopts = jc.deopts,
            };
        } else {
            self.last_jit_profile = .{};
        }
        promise_mod.runMicrotasks(arena);
        return switch (outcome) {
            .ok => |v| EvalOutcome{ .ok = v },
            .exception => |msg| EvalOutcome{ .exception = msg },
            .exception_value => |ev| EvalOutcome{ .exception = ev.msg },
        };
    }

    /// Phase 8: compile `source` to a sourceless bytecode image (snapshot).
    /// Caller owns the returned bytes (allocated with `out_allocator`).
    pub fn compileSnapshot(self: *IsolateImpl, out_allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        var tmp = std.heap.ArenaAllocator.init(self.backing);
        defer tmp.deinit();
        const arena = tmp.allocator();
        const transformed = try rewriteTemplateLiterals(arena, source);
        const parser_mod = @import("../parser/parser.zig");
        var p = parser_mod.Parser.init(transformed, arena);
        const stmts = switch (p.parseScript()) {
            .ok => |s| s,
            .err => return error.SnapshotParseError,
        };
        const ast_mod = @import("../parser/ast.zig");
        const prog = ast_mod.Program{ .body = stmts };
        const main_func = try compiler_mod.compileProgram(arena, &prog, "<snapshot>");
        const snapshot_mod = @import("../bytecode/snapshot.zig");
        return snapshot_mod.serialize(out_allocator, main_func);
    }

    /// W6: persistent allocator for host-owned registrations (freed on deinit).
    pub fn persistentAllocator(self: *IsolateImpl) std.mem.Allocator {
        return self.eval_arena.allocator();
    }

    /// W6: define a native function in the persistent global scope.
    pub fn registerNative(self: *IsolateImpl, name: []const u8, fn_ptr: val_mod.NativeFnPtr, data: ?*anyopaque) !void {
        const arena = self.eval_arena.allocator();
        const realm = try self.ensureRealm(arena);
        const name_dup = try arena.dupe(u8, name);
        const fnv = try val_mod.makeNativeFunctionData(arena, fn_ptr, data);
        try realm.global_env.define(name_dup, fnv);
    }

    /// W6: snapshot the current global scope as a plain JS object (reflects
    /// JS-defined globals at call time; `__`-prefixed internals are hidden).
    pub fn globalSnapshot(self: *IsolateImpl) !val_mod.Value {
        const arena = self.eval_arena.allocator();
        const realm = try self.ensureRealm(arena);
        const JsObject = @import("../object/object.zig").JsObject;
        const obj = try JsObject.create(arena, realm.object_prototype);
        var it = realm.global_env.bindings.iterator();
        while (it.next()) |entry| {
            const nm = entry.key_ptr.*;
            if (nm.len >= 2 and nm[0] == '_' and nm[1] == '_') continue;
            try obj.set(nm, entry.value_ptr.value);
        }
        return val_mod.makeObject(arena, obj);
    }

    /// Phase 8: restore a bytecode image and run it (bytecode VM).
    pub fn evalSnapshot(self: *IsolateImpl, image: []const u8) !EvalOutcome {
        promise_mod.clearMicrotasks();
        const arena = self.eval_arena.allocator();
        const snapshot_mod = @import("../bytecode/snapshot.zig");
        const main_func = snapshot_mod.deserialize(arena, image) catch |e| {
            return EvalOutcome{ .exception = switch (e) {
                error.BadMagic => "snapshot: bad magic",
                error.UnsupportedVersion => "snapshot: unsupported version",
                error.Truncated => "snapshot: truncated image",
                error.UnsupportedConstant => "snapshot: unsupported constant",
                error.OutOfMemory => return error.OutOfMemory,
            } };
        };
        return self.runMainBc(arena, main_func);
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
    const r = try impl.evalWithMode("1+2", .bc, &[_]val_mod.NativeBinding{});
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
        &[_]val_mod.NativeBinding{},
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

test "W3: gas limit interrupts an infinite loop (bc)" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    impl.setLimits(0, 100_000, 0);
    const r = try impl.evalWithMode("while(true){}", .bc, &[_]val_mod.NativeBinding{});
    try std.testing.expect(r == .exception);
    try std.testing.expectEqualStrings("interrupted: gas limit exceeded", r.exception);
}

test "W3: time limit interrupts an infinite loop (bc)" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    impl.setLimits(0, 0, 10);
    const r = try impl.evalWithMode("while(true){}", .bc, &[_]val_mod.NativeBinding{});
    try std.testing.expect(r == .exception);
    try std.testing.expectEqualStrings("interrupted: time limit exceeded", r.exception);
}

test "W3: LimitAllocator enforces a live-byte budget" {
    var lim = LimitAllocator.init(std.testing.allocator, 128);
    const a = lim.allocator();
    const p = try a.alloc(u8, 100);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 100));
    a.free(p);
    const q = try a.alloc(u8, 100); // budget freed up
    a.free(q);
}

test "W6: globals persist across evals on one isolate" {
    const impl = try IsolateImpl.init(std.testing.allocator);
    defer impl.deinit();
    _ = try impl.eval("var x = 41;");
    const r = try impl.eval("x + 1");
    switch (r) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}
