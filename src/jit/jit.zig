// SPDX-License-Identifier: MIT
//! Phase 9 JIT — profiling tier (PC hit counters + hot-site detection).
//! See docs/JIT.md for the full tiering plan.
//!
//! This file implements:
//!   - JitMode enum (.off / .count / .experimental)
//!   - JitCompiler: per-function+PC hit counters, hot-set, compile() stub
//!   - DeoptFrame: type scaffold for future type-guard deopt (step 4 in docs/JIT.md)
//!
//! Native codegen is NOT implemented here. compile() always returns NotImplemented.
//! That slot is reserved for the Cranelift/native-emit backend (deferred to Phase 9 step 3+).
const std = @import("std");

pub const JitError = error{
    NotImplemented,
    OutOfMemory,
};

/// Controls what the JIT tier does at runtime.
pub const JitMode = enum {
    /// No profiling; noteBackedge calls in bc_vm are zero-cost (jit pointer is null).
    off,
    /// Count PC hits and detect hot sites; do not attempt native compilation.
    count,
    /// Count hits, detect hot sites, and attempt native compile() on hot functions.
    /// compile() still returns NotImplemented today; the flag gates future codegen.
    experimental,
};

/// Result of a notePcHit call.
pub const HotEvent = enum {
    /// Site has not reached the hot threshold yet (or JIT is off).
    not_hot,
    /// Site just crossed the threshold for the first time.
    became_hot,
    /// Site was already in the hot set.
    already_hot,
};

/// Key that identifies one profiling site: function identity + bytecode offset.
const HotKey = struct { func_id: u64, pc: u32 };

/// Phase 9 step 4 scaffold: a deopt frame captures the interpreter state at a
/// type-guard failure so bc_vm can resume execution from the correct point.
/// See docs/JIT.md "Type-guard deopt sketch" for the full story.
pub const DeoptFrame = struct {
    /// Bytecode program counter at the guard-fail site.
    pc: u32,
    /// Opaque function identity (same value as HotKey.func_id).
    func_id: u64,
    /// Number of live registers in the register file snapshot.
    num_regs: u16,
};

/// Phase 9 JIT profiler and (future) native compiler.
/// Zero-overhead when not used: bc_vm holds a ?*JitCompiler that is null by default.
pub const JitCompiler = struct {
    mode: JitMode = .off,
    hot_threshold: u32 = 1000,
    allocator: std.mem.Allocator,
    /// Per-site hit counters keyed by (func_id, pc).
    counters: std.AutoHashMapUnmanaged(HotKey, u32) = .{},
    /// Set of sites that have crossed hot_threshold.
    hot: std.AutoHashMapUnmanaged(HotKey, void) = .{},
    /// Number of functions successfully compiled to native code (always 0 today).
    compiled: usize = 0,
    /// Number of deoptimizations triggered (always 0 today).
    deopts: usize = 0,

    /// Create a JitCompiler in .off mode.
    pub fn init(allocator: std.mem.Allocator) JitCompiler {
        return JitCompiler{ .allocator = allocator };
    }

    /// Create a JitCompiler with a specific mode.
    pub fn initMode(allocator: std.mem.Allocator, mode: JitMode) JitCompiler {
        return JitCompiler{ .allocator = allocator, .mode = mode };
    }

    /// Free counter and hot-set maps.
    pub fn deinit(self: *JitCompiler) void {
        self.counters.deinit(self.allocator);
        self.hot.deinit(self.allocator);
    }

    /// Record one execution of bytecode site (func_id, pc).
    /// Returns .not_hot when mode is .off (zero allocations).
    /// Returns .became_hot the first time a site crosses hot_threshold.
    /// Returns .already_hot on subsequent calls for a hot site.
    pub fn notePcHit(self: *JitCompiler, func_id: u64, pc: u32) JitError!HotEvent {
        if (self.mode == .off) return .not_hot;
        const key = HotKey{ .func_id = func_id, .pc = pc };
        // Fast path: already hot.
        if (self.hot.contains(key)) return .already_hot;
        // Increment counter.
        const gop = self.counters.getOrPut(self.allocator, key) catch return JitError.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (gop.value_ptr.* >= self.hot_threshold) {
            self.hot.put(self.allocator, key, {}) catch return JitError.OutOfMemory;
            return .became_hot;
        }
        return .not_hot;
    }

    /// Returns true if the given site is in the hot set.
    pub fn isHot(self: *const JitCompiler, func_id: u64, pc: u32) bool {
        return self.hot.contains(HotKey{ .func_id = func_id, .pc = pc });
    }

    /// Number of sites currently in the hot set.
    pub fn hotCount(self: *const JitCompiler) usize {
        return self.hot.count();
    }

    /// Compile a hot bytecode function to native code.
    ///
    /// *** Cranelift/native-emit slot — deferred to Phase 9 step 3+ ***
    ///
    /// This method intentionally always returns NotImplemented.  The native
    /// backend (Cranelift or custom emitter) plugs in here once the build
    /// system linkage story is settled. Do NOT gate this on `self.mode` —
    /// callers that want to guard on mode should check before calling.
    pub fn compile(self: *JitCompiler, code: []const u8) JitError!void {
        _ = self;
        _ = code;
        // Native backend not yet implemented. See docs/JIT.md step 3.
        return JitError.NotImplemented;
    }
};

// ------------------------------------------------------------------ tests ---

const testing = std.testing;

test "notePcHit off-mode is no-op" {
    var jc = JitCompiler.init(testing.allocator);
    defer jc.deinit();
    const ev = try jc.notePcHit(1, 0);
    try testing.expectEqual(HotEvent.not_hot, ev);
    try testing.expectEqual(@as(usize, 0), jc.hotCount());
}

test "notePcHit counts and crosses threshold once" {
    var jc = JitCompiler.initMode(testing.allocator, .count);
    defer jc.deinit();
    jc.hot_threshold = 3;

    const ev1 = try jc.notePcHit(1, 10);
    try testing.expectEqual(HotEvent.not_hot, ev1);

    const ev2 = try jc.notePcHit(1, 10);
    try testing.expectEqual(HotEvent.not_hot, ev2);

    const ev3 = try jc.notePcHit(1, 10);
    try testing.expectEqual(HotEvent.became_hot, ev3);

    const ev4 = try jc.notePcHit(1, 10);
    try testing.expectEqual(HotEvent.already_hot, ev4);

    try testing.expect(jc.isHot(1, 10));
    try testing.expectEqual(@as(usize, 1), jc.hotCount());
}

test "distinct sites tracked separately" {
    var jc = JitCompiler.initMode(testing.allocator, .count);
    defer jc.deinit();
    jc.hot_threshold = 2;

    _ = try jc.notePcHit(1, 10);
    _ = try jc.notePcHit(1, 10);
    _ = try jc.notePcHit(2, 20);
    _ = try jc.notePcHit(2, 20);

    try testing.expectEqual(@as(usize, 2), jc.hotCount());
}

test "compile returns NotImplemented" {
    var jc = JitCompiler.init(testing.allocator);
    defer jc.deinit();
    try testing.expectError(JitError.NotImplemented, jc.compile(&[_]u8{}));
}

test "DeoptFrame shape" {
    const df = DeoptFrame{ .pc = 42, .func_id = 0xDEAD, .num_regs = 8 };
    try testing.expectEqual(@as(u32, 42), df.pc);
    try testing.expectEqual(@as(u64, 0xDEAD), df.func_id);
    try testing.expectEqual(@as(u16, 8), df.num_regs);
}
