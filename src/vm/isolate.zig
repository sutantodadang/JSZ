// SPDX-License-Identifier: Apache-2.0
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
    direct_calls: usize = 0,
};

/// Phase 11: snapshot of IC hit-rate counters from the most recent bc eval.
pub const IcProfile = struct {
    own_hits: u64 = 0,
    proto_hits: u64 = 0,
    misses: u64 = 0,
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
    /// Phase 11: enable IC instrumentation for the next bc eval.
    ic_stats_enabled: bool = false,
    /// Phase 11: IC profile snapshot from the most recent bc eval.
    last_ic_profile: IcProfile = .{},
    /// W3: gas (instruction) budget and wall-clock budget (ms) for the next
    /// bc-mode eval. 0 = unlimited.
    gas_limit: u64 = 0,
    time_limit_ms: u64 = 0,
    /// W6: the persistent Realm (global scope + intrinsics), built once on the
    /// first eval and reused across evals so top-level declarations persist.
    realm: ?*@import("../runtime/realm.zig").Realm = null,
    /// Milestone 16 (ESM) — Phase 1: cache of evaluated module records, keyed by
    /// canonical specifier. Lazily created on the first `evalModule`; lives in
    /// the (persistent) eval arena alongside the realm.
    module_registry: ?@import("../runtime/module.zig").ModuleRegistry = null,

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
        applyGcEnv(&impl.heap, backing);
        return impl;
    }

    /// M19: tune the GC auto-trigger from environment variables. Off by default
    /// (the built-in defaults apply). `JSZ_GC_OFF=1` disables automatic GC;
    /// `JSZ_GC_STRESS=1` forces a very low watermark so a collection fires on
    /// nearly every allocation — used to flush out unrooted-local bugs across the
    /// conformance/fuzz corpus. `JSZ_GC_STRESS=<bytes>` sets an explicit watermark.
    fn applyGcEnv(heap: *Heap, alloc: std.mem.Allocator) void {
        if (std.process.getEnvVarOwned(alloc, "JSZ_GC_OFF")) |v| {
            alloc.free(v);
            heap.gc_enabled = false;
            return;
        } else |_| {}
        if (std.process.getEnvVarOwned(alloc, "JSZ_GC_STRESS")) |v| {
            defer alloc.free(v);
            const bytes = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
            // Tiny nursery → a collection fires on nearly every allocation, flushing
            // out unrooted-local / missed-barrier bugs across the corpus.
            heap.nursery_bytes = if (bytes >= 4096) bytes else 64 * 1024;
        } else |_| {}
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

    /// Benchmark/embedding GC tuning. `nursery_bytes` is the fixed nursery size
    /// (bytes of young allocation between collections); `major_period` is the
    /// number of minor collections between full majors (0 ⇒ every auto-collect is
    /// a major ⇒ non-generational mark-sweep). `pause_log` records pauses.
    pub fn gcConfigure(self: *IsolateImpl, nursery_bytes: usize, major_period: usize, pause_log: bool) void {
        self.heap.nursery_bytes = nursery_bytes;
        self.heap.major_period = major_period;
        self.heap.pause_log_enabled = pause_log;
    }

    /// Recorded per-collection pauses (ns), if pause logging was enabled.
    pub fn gcPauses(self: *IsolateImpl) []const u64 {
        return self.heap.pause_log.items;
    }

    /// (minor, major) collection counts.
    pub fn gcGenCounts(self: *IsolateImpl) struct { minor: usize, major: usize } {
        return .{ .minor = self.heap.minor_collections, .major = self.heap.major_collections };
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

    pub fn setIcStats(self: *IsolateImpl, on: bool) void {
        self.ic_stats_enabled = on;
    }

    /// Run one eval call in the bytecode VM (W2: bc is the default engine).
    /// Does NOT reset the eval arena so top-level declarations persist (W6).
    pub fn eval(self: *IsolateImpl, source: []const u8) !EvalOutcome {
        return self.evalWithMode(source, .bc, &[_]val_mod.NativeBinding{});
    }

    pub fn evalWithMode(self: *IsolateImpl, source: []const u8, mode: InterpMode, native_bindings: []const val_mod.NativeBinding) !EvalOutcome {
        _ = native_bindings;
        promise_mod.clearMicrotasks();
        @import("../runtime/realm.zig").resetAsyncDone();
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
                const prog = ast_mod.Program{ .body = stmts, .is_strict = @import("../parser/parser.zig").hasUseStrict(stmts) };
                const main_func = compiler_mod.compileProgram(arena, &prog, "<eval>") catch |e| {
                    return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
                return self.runMainBc(arena, main_func);
            },
        }
    }

    /// Milestone 16 (ESM) — Phase 1: evaluate `source` as ES-module code.
    /// Mirrors `evalWithMode(.bc)` but parses via `Parser.parseModule` and
    /// compiles via `compiler.compileModule` so module code runs strict
    /// (§11.2.2); the import/export → CommonJS desugar already happened in the
    /// parser. The run is tracked on a `ModuleRecord` in `self.module_registry`
    /// keyed by `module_id`, transitioning its status across the evaluation.

    pub fn evalModule(self: *IsolateImpl, source: []const u8, module_id: []const u8) !EvalOutcome {
        promise_mod.clearMicrotasks();
        @import("../runtime/realm.zig").resetAsyncDone();
        const arena = self.eval_arena.allocator();
        const transformed_source = try rewriteTemplateLiterals(arena, source);

        const module_mod = @import("../runtime/module.zig");
        if (self.module_registry == null) self.module_registry = module_mod.ModuleRegistry.init(arena);
        const rec = try self.module_registry.?.getOrCreate(try arena.dupe(u8, module_id), transformed_source);
        rec.status = .evaluating;

        const parser_mod = @import("../parser/parser.zig");
        var p = parser_mod.Parser.init(transformed_source, arena);
        const parse_result = p.parseModule();
        const stmts = switch (parse_result) {
            .ok => |s| s,
            .err => |e| {
                rec.status = .errored;
                return EvalOutcome{ .parse_error = .{
                    .message = e.message,
                    .line = e.line,
                    .column = e.column,
                } };
            },
        };
        rec.body = stmts;

        const ast_mod = @import("../parser/ast.zig");
        // M16 TLA: a module with top-level await compiles its top-level body as
        // async so `await` truly suspends (runMainBc drives it as a coroutine).
        const prog = ast_mod.Program{ .body = stmts, .is_strict = true, .is_module = true, .has_tla = p.saw_top_level_await };
        const main_func = compiler_mod.compileModule(arena, &prog, module_id) catch |e| {
            rec.status = .errored;
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        rec.func = main_func;
        rec.status = .linked;

        // M16 Phase 3: point the module-scoped `import.meta` binding at this
        // module's specifier before evaluation (HostGetImportMetaProperties → url).
        const realm = try self.ensureRealm(arena);
        if (realm.global_env.lookup("__import_meta__")) |meta_val| {
            if (meta_val.bits != 0 and meta_val.unbox() == .object) {
                try meta_val.toPtr().object.set("url", try val_mod.makeString(arena, module_id));
            }
        } else |_| {}

        const outcome = try self.runMainBc(arena, main_func);
        switch (outcome) {
            .ok => |v| {
                rec.namespace = v;
                rec.status = .evaluated;
            },
            else => rec.status = .errored,
        }
        return outcome;
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
        // Cross-realm: record the primary realm's intrinsic prototypes so that a
        // local NewTarget hitting GetPrototypeFromConstructor's GetFunctionRealm
        // fallback resolves to the same (local) prototypes it would default to.
        realm.captureIntrinsics();

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
        try realm.global_env.define("__requireObjectCoercible__", try val_mod.makeNativeFunction(arena, es2015.nativeRequireObjectCoercible));
        try realm.global_env.define("__destrIterStep__", try val_mod.makeNativeFunction(arena, es2015.nativeDestrIterStep));
        try realm.global_env.define("__destrIterRest__", try val_mod.makeNativeFunction(arena, es2015.nativeDestrIterRest));
        try realm.global_env.define("__destrIterClose__", try val_mod.makeNativeFunction(arena, es2015.nativeDestrIterClose));
        try realm.global_env.define("__destrIterCloseThrow__", try val_mod.makeNativeFunction(arena, es2015.nativeDestrIterCloseThrow));
        try realm.global_env.define("__destrObjRest__", try val_mod.makeNativeFunction(arena, es2015.nativeDestrObjRest));
        try realm.global_env.define("__objSpreadInto__", try val_mod.makeNativeFunction(arena, es2015.nativeObjSpreadInto));
        try realm.global_env.define("__defineNamedMethod__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/object_methods.zig").nativeDefineNamedMethod));
        try realm.global_env.define("__nameFn__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/object_methods.zig").nativeNameFn));
        try realm.global_env.define("__toPropertyKey__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/object_methods.zig").nativeToPropertyKey));
        try realm.global_env.define("__makeNamespace__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeMakeNamespace));
        // Explicit resource management: `using`/`await using` scope desugar.
        try realm.global_env.define("__usingStackInit__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/disposable_stack.zig").nativeUsingStackInit));
        try realm.global_env.define("__usingAdd__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/disposable_stack.zig").nativeUsingAdd));
        try realm.global_env.define("__usingDispose__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/disposable_stack.zig").nativeUsingDispose));
        // import-defer: `import defer * as ns` desugars to `__importDefer__(spec)`;
        // dynamic `import.defer(spec)` routes through `__importDeferDyn__`.
        try realm.global_env.define("__importDefer__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeImportDefer));
        try realm.global_env.define("__importDeferDyn__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeImportDeferDynamic));
        // source-phase imports: `import.source(spec)` → a promise that rejects
        // with a SyntaxError (source text modules have no [[ModuleSource]]).
        try realm.global_env.define("__importSourceDyn__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeImportSourceDynamic));
        try realm.global_env.define("__initExports__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeInitExports));
        try realm.global_env.define("__iterStep__", try val_mod.makeNativeFunction(arena, es2015.nativeIterStep));
        // W2-asyncgen: for-await-of helpers (async-iterator protocol).
        try realm.global_env.define("__getAsyncIterator__", try val_mod.makeNativeFunction(arena, es2015.nativeGetAsyncIterator));
        try realm.global_env.define("__asyncIterStep__", try val_mod.makeNativeFunction(arena, es2015.nativeAsyncIterStep));
        // yield* delegation step + return-completion value extractor.
        try realm.global_env.define("__yieldStarStep__", try val_mod.makeNativeFunction(arena, es2015.nativeYieldStarStep));
        // Async `yield*` delegation: iterator-record init, per-step method call,
        // and post-await result interpretation.
        try realm.global_env.define("__asyncDelegInit__", try val_mod.makeNativeFunction(arena, es2015.nativeAsyncDelegInit));
        try realm.global_env.define("__asyncDelegCall__", try val_mod.makeNativeFunction(arena, es2015.nativeAsyncDelegCall));
        try realm.global_env.define("__asyncDelegStep__", try val_mod.makeNativeFunction(arena, es2015.nativeAsyncDelegStep));
        try realm.global_env.define("__retComplVal__", try val_mod.makeNativeFunction(arena, es2015.nativeRetComplVal));
        // Explicit Resource Management: the disposal step of a `using` scope's
        // try/finally desugar (seeds a body error into the SuppressedError chain).
        try realm.global_env.define("__usingDispose__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/disposable_stack.zig").nativeUsingDispose));
        try realm.global_env.define("__usingDisposeAsync__", try val_mod.makeNativeFunction(arena, @import("../runtime/builtins/disposable_stack.zig").nativeUsingDisposeAsync));
        // Class desugar: the return-override rule for a derived constructor.
        try realm.global_env.define("__derivedReturn__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeDerivedReturn));
        // M16 Phase 3: dynamic import() native + the import.meta object binding.
        try realm.global_env.define("__import__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeImport));
        try realm.global_env.define("__import_meta__", try @import("../runtime/realm.zig").makeImportMeta(arena, ""));
        // M16 TLA: async-dependency evaluation barrier used by async-module factories.
        try realm.global_env.define("__awaitDeps__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeAwaitDeps));
        // M16 TLA: `[module, async]` completion signals wired to the harness $DONE.
        try realm.global_env.define("__jszCreateRealm__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeCreateRealm));
        try realm.global_env.define("__jszEvalScript__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeEvalScript));
        try realm.global_env.define("__jszAsyncDone__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeAsyncDone));
        try realm.global_env.define("__jszAsyncFail__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeAsyncFail));
        try realm.global_env.define("__jszModuleReject__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeModuleReject));
        // Annex B.3.6 `document.all` stand-in, built on request so the exotic
        // never exists unless a host (the test262 $262 shim) asks for it.
        try realm.global_env.define("__jszMakeHTMLDDA__", try val_mod.makeNativeFunction(arena, @import("../runtime/realm.zig").nativeMakeHTMLDDA));

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
        bc_vm.ic_stats_enabled = self.ic_stats_enabled;
        if (self.time_limit_ms != 0)
            bc_vm.deadline_ns = std.time.nanoTimestamp() + @as(i128, self.time_limit_ms) * std.time.ns_per_ms;
        // Mirror the deadline so long native loops (Array.prototype methods over a
        // huge/sparse length, etc.) can self-interrupt like bytecode loops do.
        @import("../runtime/realm.zig").native_deadline_ns = bc_vm.deadline_ns;
        defer @import("../runtime/realm.zig").native_deadline_ns = 0;
        // Phase 9: attach JIT profiler when a mode other than .off is requested.
        var jc: jit_mod.JitCompiler = undefined;
        if (self.jit_mode != .off) {
            jc = jit_mod.JitCompiler.initMode(arena, self.jit_mode);
            bc_vm.jit = &jc;
        }
        // Register roots AFTER bc_vm/realm are in final stack location.
        try bc_vm.registerHeapCallback(&self.heap);
        defer bc_vm.unregisterHeapCallback(&self.heap);
        // M16 TLA: a module top-level compiled as async (top-level await) is
        // driven as a coroutine so its awaits truly suspend and interleave with
        // the microtask queue, rather than synchronously draining at each await.
        const outcome = if (main_func.is_async)
            try bc_vm.runMainAsync(main_func, @ptrCast(realm.global_env))
        else
            try bc_vm.run(main_func, @ptrCast(realm.global_env));
        self.last_frame_high_water = bc_vm.frame_high_water;
        // Phase 9: capture JIT profile snapshot.
        if (self.jit_mode != .off) {
            self.last_jit_profile = .{
                .hot_sites = jc.hotCount(),
                .compiled = jc.compiled,
                .deopts = jc.deopts,
                .direct_calls = jc.direct_calls,
            };
        } else {
            self.last_jit_profile = .{};
        }
        if (self.ic_stats_enabled) {
            self.last_ic_profile = .{
                .own_hits = bc_vm.ic_own_hits,
                .proto_hits = bc_vm.ic_proto_hits,
                .misses = bc_vm.ic_misses,
            };
        } else {
            self.last_ic_profile = .{};
        }
        // M16 TLA: drain microtasks with the VM context active so ordinary
        // promise reactions (`.then` callbacks, e.g. `.then($DONE)`) can re-enter
        // JS — the top-level run already deactivated the context on return.
        bc_vm.drainMicrotasks();
        const realm_mod = @import("../runtime/realm.zig");
        // M16 TLA: surface the entry module's async evaluation rejection (spec
        // Evaluate() promise rejection), then a failure signalled by $DONE from a
        // microtask. Only when the synchronous run itself completed `.ok`.
        if (outcome == .ok and realm_mod.module_eval_error.bits != 0) {
            return EvalOutcome{ .exception = realm_mod.errorValueMessage(arena, realm_mod.module_eval_error) };
        }
        if (outcome == .ok and realm_mod.async_done_error.bits != 0) {
            return EvalOutcome{ .exception = realm_mod.errorValueMessage(arena, realm_mod.async_done_error) };
        }
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

/// Monotonic id assigned to each textual tagged-template site during source
/// rewriting; the realm's template cache is keyed by it so repeated evaluations
/// of one source position share a single frozen template object.
var g_template_site_id: u64 = 0;

pub fn rewriteTemplateLiterals(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < source.len) {
        const c0 = source[i];
        // Pass quoted strings through verbatim so a backtick inside a single/
        // double-quoted string is not mistaken for a template literal.
        if (c0 == '\'' or c0 == '"') {
            try out.append(arena, c0);
            i += 1;
            while (i < source.len) {
                const d = source[i];
                if (d == '\\' and i + 1 < source.len) {
                    try out.append(arena, d);
                    try out.append(arena, source[i + 1]);
                    i += 2;
                    continue;
                }
                try out.append(arena, d);
                i += 1;
                if (d == c0 or d == '\n') break; // close (or unterminated → lexer errors)
            }
            continue;
        }
        // Pass line comments through verbatim.
        if (c0 == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(arena, source[i]);
                i += 1;
            }
            continue;
        }
        // Pass block comments through verbatim.
        if (c0 == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.append(arena, source[i]);
            try out.append(arena, source[i + 1]);
            i += 2;
            while (i < source.len) {
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    try out.appendSlice(arena, "*/");
                    i += 2;
                    break;
                }
                try out.append(arena, source[i]);
                i += 1;
            }
            continue;
        }
        // Pass regex literals through verbatim. A backtick, quote, or `//`-looking
        // sequence inside a regex body (`/a`b/`, `/'/`, `/[/]/`) must not be
        // mistaken for a template, string, or comment. Only enter this when the
        // `/` is unambiguously in expression position (regex, not division) — a
        // division slash is harmless to copy through as an ordinary character.
        if (c0 == '/' and slashStartsRegex(source, i)) {
            try out.append(arena, '/');
            i += 1;
            var in_class = false;
            while (i < source.len) {
                const d = source[i];
                if (d == '\n' or d == '\r') break; // unterminated; the lexer errors
                try out.append(arena, d);
                i += 1;
                if (d == '\\') {
                    if (i < source.len and source[i] != '\n' and source[i] != '\r') {
                        try out.append(arena, source[i]);
                        i += 1;
                    }
                    continue;
                }
                if (d == '[') {
                    in_class = true;
                } else if (d == ']') {
                    in_class = false;
                } else if (d == '/' and !in_class) {
                    break; // closing slash consumed
                }
            }
            // Flags.
            while (i < source.len and isIdentChar(source[i])) {
                try out.append(arena, source[i]);
                i += 1;
            }
            continue;
        }
        if (c0 != '`') {
            try out.append(arena, source[i]);
            i += 1;
            continue;
        }
        // Tagged template `tag`...`` desugars to a call passing the template
        // strings object (cooked + raw) followed by the substitution values.
        if (isTaggedTemplate(source, i)) {
            i = try rewriteTaggedTemplate(arena, &out, source, i);
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
                // A template substitution is coerced with ToString (string hint:
                // toString before valueOf, and a TypeError for Symbols), NOT with
                // the `+` operator's default-hint ToPrimitive (valueOf first).
                // `"".concat(expr)` is exactly ToString applied to each argument,
                // so wrap the substitution in it rather than emitting a bare `+`
                // operand — otherwise objects with a throwing/number valueOf (e.g.
                // every Temporal type) would coerce incorrectly.
                try out.appendSlice(arena, "\"\".concat((");
                if (expr_end >= expr_start and expr_end <= source.len) {
                    // The substitution expression may itself contain template
                    // literals (e.g. `a${cond ? `x${y}` : ""}b`), so rewrite it
                    // recursively rather than copying it through verbatim — an
                    // un-rewritten nested backtick would reach the lexer and fail.
                    const inner = try rewriteTemplateLiterals(arena, source[expr_start..expr_end]);
                    try out.appendSlice(arena, inner);
                }
                try out.appendSlice(arena, "))");
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
    // The segment preserves the template's backslash escapes verbatim (see the
    // scan loop in rewriteTemplateLiterals). Re-emit it as the body of a
    // double-quoted string literal: escape sequences pass through unchanged (the
    // string lexer cooks them, and template/string escape semantics coincide),
    // while raw characters that a `"..."` literal cannot contain — line
    // terminators and an unescaped quote — are escaped here. This is what lets a
    // multi-line template (whose segment holds raw newline bytes) round-trip.
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const ch = segment[i];
        if (ch == '\\' and i + 1 < segment.len) {
            try out.append(arena, '\\');
            try out.append(arena, segment[i + 1]);
            i += 1;
            continue;
        }
        switch (ch) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\\' => try out.appendSlice(arena, "\\\\"), // a lone trailing backslash
            else => try out.append(arena, ch),
        }
    }
    try out.append(arena, '"');
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// A backtick at `btick` begins a TAGGED template when the immediately preceding
/// significant token is a value-producing expression (an identifier that is not
/// a reserved word, or a `)` / `]` closing a call/member expression). After an
/// operator, `(`, `,`, `=`, `return`, `typeof`, etc., the template is untagged.
fn isTaggedTemplate(source: []const u8, btick: usize) bool {
    if (btick == 0) return false;
    var j: isize = @as(isize, @intCast(btick)) - 1;
    while (j >= 0) : (j -= 1) {
        const ch = source[@intCast(j)];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') continue;
        break;
    }
    if (j < 0) return false;
    const ch = source[@intCast(j)];
    if (ch == ')' or ch == ']') return true;
    if (!isIdentChar(ch)) return false;
    // Extract the identifier word ending at j.
    var start: isize = j;
    while (start >= 0 and isIdentChar(source[@intCast(start)])) : (start -= 1) {}
    const word = source[@intCast(start + 1) .. @intCast(j + 1)];
    // Keywords/operators that introduce an (untagged) template expression.
    const non_tag_words = [_][]const u8{
        "return", "typeof", "void", "delete", "instanceof", "in", "of", "new",
        "do", "else", "yield", "await", "case", "throw", "default", "extends",
    };
    for (non_tag_words) |w| {
        if (std.mem.eql(u8, word, w)) return false;
    }
    return true;
}

/// Decide whether a `/` at `slash_idx` begins a regex literal (vs. division),
/// using the same previous-significant-token heuristic as the lexer. Only clear
/// expression-position contexts return true; anything value-like (identifier,
/// number, `)`, `]`, `}`, string/template close) returns false so a division
/// slash is left to copy through as an ordinary character. Comment skip-back is
/// not attempted (a `/` right after a comment is vanishingly rare in eval text).
fn slashStartsRegex(source: []const u8, slash_idx: usize) bool {
    if (slash_idx == 0) return true;
    var j: isize = @as(isize, @intCast(slash_idx)) - 1;
    while (j >= 0) : (j -= 1) {
        const ch = source[@intCast(j)];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') continue;
        break;
    }
    if (j < 0) return true;
    const ch = source[@intCast(j)];
    // A value-producing close → division.
    if (ch == ')' or ch == ']' or ch == '}' or ch == '"' or ch == '\'' or ch == '`') return false;
    if (isIdentChar(ch)) {
        // A number or plain identifier is a value → division. Only the operator-
        // position keywords admit a following regex.
        var start: isize = j;
        while (start >= 0 and isIdentChar(source[@intCast(start)])) : (start -= 1) {}
        const word = source[@intCast(start + 1) .. @intCast(j + 1)];
        const regex_words = [_][]const u8{
            "return",  "typeof", "void",  "delete", "instanceof", "in",
            "of",      "new",    "do",    "else",   "yield",      "await",
            "case",    "throw",  "default", "extends", "void",
        };
        for (regex_words) |w| {
            if (std.mem.eql(u8, word, w)) return true;
        }
        return false;
    }
    // An operator, `(`, `,`, `{`, `;`, `:`, `=`, etc. → regex.
    return true;
}

/// Emit `segment` (raw template text with backslash escapes preserved verbatim)
/// as the body of a `"..."` literal whose VALUE is the raw text — every
/// backslash is doubled so escape sequences survive uncooked (for `.raw`).
fn emitRawSegment(arena: std.mem.Allocator, out: *std.ArrayList(u8), segment: []const u8) !void {
    try out.append(arena, '"');
    for (segment) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(arena, "\\\\"),
            '"' => try out.appendSlice(arena, "\\\""),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            else => try out.append(arena, ch),
        }
    }
    try out.append(arena, '"');
}

/// Rewrite a tagged template starting at the opening backtick `btick` (the tag
/// expression has already been emitted to `out`). Appends
/// `(__jsztag([cooked…],[raw…]), (sub1), (sub2)…)` after the tag and returns the
/// source index just past the closing backtick.
fn rewriteTaggedTemplate(arena: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, btick: usize) error{OutOfMemory}!usize {
    var i = btick + 1; // consume opening backtick
    var cooked = std.ArrayList([]const u8){};
    var raw = std.ArrayList([]const u8){};
    var subs = std.ArrayList([]const u8){};
    var literal_buf = std.ArrayList(u8){};
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            try literal_buf.append(arena, source[i]);
            try literal_buf.append(arena, source[i + 1]);
            i += 2;
            continue;
        }
        if (source[i] == '$' and i + 1 < source.len and source[i + 1] == '{') {
            try cooked.append(arena, try arena.dupe(u8, literal_buf.items));
            try raw.append(arena, try arena.dupe(u8, literal_buf.items));
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
                        i += 1;
                        break;
                    }
                }
                i += 1;
            }
            const inner = try rewriteTemplateLiterals(arena, source[expr_start..expr_end]);
            try subs.append(arena, inner);
            continue;
        }
        if (source[i] == '`') {
            i += 1; // consume closing backtick
            break;
        }
        try literal_buf.append(arena, source[i]);
        i += 1;
    }
    try cooked.append(arena, try arena.dupe(u8, literal_buf.items));
    try raw.append(arena, try arena.dupe(u8, literal_buf.items));

    // Each textual template site gets a stable id so the realm's template cache
    // (§13.2.8.4: the same source position yields the same frozen object across
    // evaluations) returns one object for repeated calls of the enclosing
    // function. Assigned once per source rewrite in source order.
    const site_id = g_template_site_id;
    g_template_site_id += 1;
    try out.appendSlice(arena, "(__jsztag(");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{site_id}));
    try out.appendSlice(arena, ",[");
    for (cooked.items, 0..) |seg, k| {
        if (k > 0) try out.appendSlice(arena, ",");
        try emitTemplateLiteralSegment(arena, out, seg, false);
    }
    try out.appendSlice(arena, "],[");
    for (raw.items, 0..) |seg, k| {
        if (k > 0) try out.appendSlice(arena, ",");
        try emitRawSegment(arena, out, seg);
    }
    try out.appendSlice(arena, "])");
    for (subs.items) |s| {
        try out.appendSlice(arena, ",(");
        try out.appendSlice(arena, s);
        try out.appendSlice(arena, ")");
    }
    try out.appendSlice(arena, ")");
    return i;
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
