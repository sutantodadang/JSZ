// SPDX-License-Identifier: Apache-2.0
//! Phase 12 — runtime driver that JITs pure-integer leaf bytecode functions.
//!
//! This is the bc_vm-side glue over the general int-block compiler in
//! `native.zig` (Cranelift). It is reachable ONLY when the binary is built with
//! `-Djit=true` (so the Rust cdylib is linked) AND the JIT tier is in
//! `.experimental` mode — the default build/tests/conformance never touch it.
//!
//! ## Soundness gate (`analyze`)
//! A function is JITed only when every value it stores or returns is a genuine
//! integer, so the result can be re-boxed losslessly. The analyzer rejects a
//! function unless ALL hold:
//!   * every opcode is in the int subset (no calls, property access, etc.);
//!   * every `GET_GLOBAL`/`SET_GLOBAL`/`DEFINE_GLOBAL` names a function-LOCAL
//!     (param or `var`/hoisted name) — never a true global or captured var;
//!   * every `LOAD_K` constant is an integral number in i64-safe range;
//!   * every comparison/`NOT` result is consumed by the IMMEDIATELY following
//!     `JMP_IF_TRUE`/`JMP_IF_FALSE` on the same register — so a boolean never
//!     escapes into a stored/returned value (it only gates a branch).
//!   * not a generator/async function.
//!
//! ## Overflow handling (exact, no speculative boundary)
//! Each arithmetic op in the native code computes in i128 and guards its result
//! against ±2^53 (the f64-exact integer range). If any intermediate escapes, the
//! native function sets an out-flag and returns early; `run` then reports a deopt
//! (returns null) and the caller re-runs the call in the interpreter. Because a
//! JITed function is a side-effect-free pure-int leaf, re-interpreting from
//! scratch is sound. So the fast path is bit-exact with JS number semantics.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const opcodes = @import("../bytecode/opcodes.zig");
const Op = opcodes.Op;

// Cranelift backend FFI (declared here rather than imported from native.zig so
// this file belongs solely to the `jsz` module; native.zig stays owned by the
// CLI root module). Referenced only under -Djit=true (the caller is comptime
// gated), so default builds never link the cdylib.
extern fn jsz_clif_compile_int_block(
    code: [*]const u8,
    len: usize,
    kidx_to_slot: ?[*]const i32,
    n_kidx: usize,
) ?*const anyopaque;
extern fn jsz_clif_compile_boxed_block(
    code: [*]const u8,
    len: usize,
    kidx_to_slot: ?[*]const i32,
    n_kidx: usize,
    prop_sites: ?[*]const PropSite,
    n_prop_sites: usize,
    get_helper: u64,
    set_helper: u64,
    call_helper: u64,
) ?*const anyopaque;

/// One property-access site, baked into the native code (mirror of the Rust
/// `PropSite`). At bytecode offset `pc` a `GET_PROP` reads property `key` (a
/// stable arena string) consulting the live inline cache `ic`.
pub const PropSite = extern struct { pc: u32, key_len: u32, key_ptr: u64, ic_ptr: u64 };

const JsObject = @import("../object/object.zig").JsObject;
const ic_mod = @import("../vm/ic.zig");

/// Native fast-path callback the boxed JIT invokes at each `GET_PROP`. Mirrors the
/// interpreter's NON-re-entrant property fast path exactly: the own inline-cache
/// lookup (`ic.lookup` covers monomorphic / polymorphic / megamorphic data slots)
/// and the proto-chain method-dispatch cache. Returns the resolved DATA value as
/// boxed bits, or sets `miss.* = 1` for anything that would require running JS or
/// the full slow path — accessors, an uncached shape, arrays / `length`, or a
/// non-object — in which case the region coarse-deopts and the interpreter handles
/// it (and updates the IC, which this helper reads live on the next call). Because
/// it runs NO getter and allocates nothing, it triggers no GC and needs no root
/// registration of the JIT register buffers.
fn jsz_jit_get_prop(recv_bits: u64, key_ptr: [*]const u8, key_len: usize, ic_raw: *anyopaque, miss: *i32) callconv(.c) u64 {
    const v = Value{ .bits = recv_bits };
    if (v.bits == 0 or v.unbox() != .object) {
        miss.* = 1;
        return 0;
    }
    const obj = v.toPtr().object;
    const key = key_ptr[0..key_len];
    // The interpreter special-cases arrays + `length`/`size`; defer those.
    if (obj.is_array or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "size")) {
        miss.* = 1;
        return 0;
    }
    const ic: *const ic_mod.InlineCache = @ptrCast(@alignCast(ic_raw));
    const shape = obj.shapePtr();
    // Own property via the inline cache (mono / poly / mega).
    if (ic.lookup(key, shape)) |slot| {
        if (slot < obj.attrs.items.len and obj.attrs.items[slot].is_accessor) {
            miss.* = 1; // accessor — let the interpreter run the getter
            return 0;
        }
        if (obj.getOwnBySlot(shape, slot)) |val| {
            miss.* = 0;
            return val.bits;
        }
    }
    // Proto-chain cache (inherited data property / method dispatch).
    if (ic.protoKeyMatches(key) and ic.proto_recv_shape == shape) {
        var cur: *JsObject = obj;
        var n: u8 = 0;
        var ok = true;
        while (n < ic.proto_chain_len) : (n += 1) {
            const nxt = cur.proto orelse {
                ok = false;
                break;
            };
            const g = ic.proto_chain[n];
            if (@as(*anyopaque, @ptrCast(nxt)) != g.obj or nxt.shapePtr() != g.shape) {
                ok = false;
                break;
            }
            cur = nxt;
        }
        if (ok) {
            const hshape = ic.proto_chain[ic.proto_chain_len - 1].shape;
            const hslot = ic.proto_slot;
            if (hslot < cur.attrs.items.len and cur.attrs.items[hslot].is_accessor) {
                miss.* = 1;
                return 0;
            }
            if (cur.getOwnBySlot(hshape, hslot)) |val| {
                miss.* = 0;
                return val.bits;
            }
        }
    }
    miss.* = 1;
    return 0;
}

/// Native fast-path callback for `SET_PROP` — stores `val` into an EXISTING own
/// writable data slot resolved via the live inline cache. Sets `miss.* = 1`
/// (BEFORE any store, so a miss has no side effect) for anything needing the slow
/// path: a non-object, array / `length`, an uncached shape, a property not yet
/// own (the interpreter performs the shape transition), an accessor (runs the
/// setter), or a read-only data property. Non-re-entrant + non-allocating.
fn jsz_jit_set_own(recv_bits: u64, key_ptr: [*]const u8, key_len: usize, ic_raw: *anyopaque, val_bits: u64, miss: *i32) callconv(.c) void {
    const v = Value{ .bits = recv_bits };
    if (v.bits == 0 or v.unbox() != .object) {
        miss.* = 1;
        return;
    }
    const obj = v.toPtr().object;
    const key = key_ptr[0..key_len];
    if (obj.is_array or std.mem.eql(u8, key, "length")) {
        miss.* = 1;
        return;
    }
    const ic: *const ic_mod.InlineCache = @ptrCast(@alignCast(ic_raw));
    const shape = obj.shapePtr();
    if (ic.lookup(key, shape)) |slot| {
        if (slot < obj.attrs.items.len) {
            const a = obj.attrs.items[slot];
            if (a.is_accessor or !a.writable) {
                miss.* = 1; // setter / read-only — let the interpreter handle it
                return;
            }
        }
        if (obj.setOwnBySlot(shape, slot, Value{ .bits = val_bits })) {
            miss.* = 0;
            return;
        }
    }
    miss.* = 1; // not an existing own slot of this shape
}

/// S4: a node in the chain of register/local buffers belonging to JIT regions
/// that are currently on the stack (innermost first). Published by `run` so the
/// GC can scan boxed cell pointers held in native register files across a
/// re-entrant `CALL` (a callee may trigger a collection via `__gc__()`). The
/// collector is non-moving, so marking suffices.
pub const JitRootFrame = struct { regs: []i64, locals: []i64, parent: ?*JitRootFrame };
pub var active_jit_frame: ?*JitRootFrame = null;
/// The `*BcVm` driving the currently-running JIT region (single-threaded). The
/// CALL trampoline reads it to re-enter the interpreter. Set by `run`.
pub var active_jit_vm: ?*anyopaque = null;

/// Native `fn(regs, consts, locals, deopt) -> i64` produced by the int-block
/// compiler. `deopt` is set to 1 when an arithmetic result escapes ±2^53.
/// In boxed mode each slot carries a raw `Value.bits` and the return value is a
/// boxed `Value`; `deopt` also fires on a non-number arithmetic operand.
pub const IntBlockFn = *const fn (regs: [*]i64, consts: [*]const i64, locals: [*]i64, deopt: *i32) callconv(.c) i64;

fn compileNative(code: []const u8, kidx_to_slot: []const i32, boxed: bool, prop_sites: []const PropSite, call_helper: u64) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    const p = if (boxed) blk: {
        const sites_ptr: ?[*]const PropSite = if (prop_sites.len == 0) null else prop_sites.ptr;
        const get_helper: u64 = @intFromPtr(&jsz_jit_get_prop);
        const set_helper: u64 = @intFromPtr(&jsz_jit_set_own);
        break :blk jsz_clif_compile_boxed_block(code.ptr, code.len, map_ptr, kidx_to_slot.len, sites_ptr, prop_sites.len, get_helper, set_helper, call_helper);
    } else jsz_clif_compile_int_block(code.ptr, code.len, map_ptr, kidx_to_slot.len);
    return @ptrCast(p orelse return null);
}

/// A compiled JIT plan for one leaf function.
pub const JitPlan = struct {
    code_fn: IntBlockFn,
    /// Constant pool parallel to `chunk.constants`: unboxed i64 in int mode, raw
    /// `Value.bits` in boxed mode.
    consts: []i64,
    /// Number of distinct function-local variable slots.
    n_slots: u16,
    num_regs: u16,
    arity: u16,
    /// Boxed mode: slots carry `Value.bits`, the result is a boxed `Value`, and
    /// arithmetic deopts on a non-number operand (vs the int mode's unboxed i64).
    boxed: bool,
};

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn isLocalName(local_names: []const []const u8, name: []const u8) ?u16 {
    for (local_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return null;
}

fn constString(c: Value) ?[]const u8 {
    if (c.bits == 0) return null;
    if (!c.isHeapPtr()) return null;
    return switch (c.unbox()) {
        .string => |s| s,
        else => null,
    };
}

/// True for the compare/NOT opcodes whose result must be consumed immediately
/// by a conditional jump (so the boolean never escapes).
fn isCompare(op: Op) bool {
    return switch (op) {
        .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => true,
        else => false,
    };
}

/// Outcome of `analyze`. `retry` means the function is structurally JIT-able but a
/// property site's inline cache is still cold — recompiling after a few more
/// interpreted calls (once the IC warms to monomorphic) may succeed; the caller
/// should not give up permanently yet. `never` is a permanent reject.
pub const AnalyzeResult = union(enum) { ok: *JitPlan, retry, never };

/// Analyze + compile `func`. In `boxed` mode the slots carry boxed `Value`s, so
/// `LOAD_K` may load ANY constant (the native code guards numericity per
/// arithmetic op); `GET_PROP` is accepted for monomorphic own-data sites (baked
/// from the inline cache) and falls back to the interpreter on any shape miss. In
/// int mode every `LOAD_K` must be an integral number and `GET_PROP` is rejected.
pub fn analyze(arena: std.mem.Allocator, func: *const BcFunction, boxed: bool, call_helper: u64) !AnalyzeResult {
    if (func.is_generator or func.is_async) return .never;
    const code = func.chunk.code;
    const constants = func.chunk.constants;
    if (code.len == 0 or constants.len == 0) return .never;

    // ---- Pass A: collect function-local names (params first → slots 0..arity-1,
    // matching the marshalling), then DEFINE_GLOBAL / HOIST_VAR names. ----
    var local_names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (func.param_names) |p| {
        if (isLocalName(local_names.items, p) == null) try local_names.append(arena, p);
    }
    // Also collect jump targets, so an unreachable trailing RETURN_UNDEF epilogue
    // (emitted after an explicit `return`) can be told apart from a live one.
    var jump_targets: std.ArrayListUnmanaged(usize) = .empty;
    var has_back_edge = false; // any backward jump (a loop) — blocks SET_PROP (S3e)
    {
        var pc: usize = 0;
        while (pc < code.len) {
            const op: Op = @enumFromInt(code[pc]);
            const size = opcodes.instrSize(op);
            if (pc + size > code.len) return .never;
            const next = pc + size;
            switch (op) {
                .DEFINE_GLOBAL, .HOIST_VAR => {
                    const kidx = readU16(code, pc + 1);
                    if (kidx < constants.len) {
                        if (constString(constants[kidx])) |nm| {
                            if (isLocalName(local_names.items, nm) == null)
                                try local_names.append(arena, nm);
                        }
                    }
                },
                .JMP => {
                    const rel: i16 = @bitCast(readU16(code, pc + 1));
                    const target: isize = @as(isize, @intCast(next)) + rel;
                    if (target <= @as(isize, @intCast(pc))) has_back_edge = true;
                    try jump_targets.append(arena, @intCast(target));
                },
                .JMP_IF_TRUE, .JMP_IF_FALSE => {
                    const rel: i16 = @bitCast(readU16(code, pc + 2));
                    const target: isize = @as(isize, @intCast(next)) + rel;
                    if (target <= @as(isize, @intCast(pc))) has_back_edge = true;
                    try jump_targets.append(arena, @intCast(target));
                },
                else => {},
            }
            pc += size;
        }
    }
    const isJumpTarget = struct {
        fn f(targets: []const usize, off: usize) bool {
            for (targets) |t| if (t == off) return true;
            return false;
        }
    }.f;
    const n_slots: u16 = @intCast(local_names.items.len);

    // ---- Pass B: build kidx→slot map (-1 = not a local) and the i64 const pool. ----
    const kidx_to_slot = try arena.alloc(i32, constants.len);
    const consts_i64 = try arena.alloc(i64, constants.len);
    for (constants, 0..) |c, k| {
        kidx_to_slot[k] = -1;
        consts_i64[k] = 0;
        if (constString(c)) |nm| {
            if (isLocalName(local_names.items, nm)) |slot| kidx_to_slot[k] = slot;
        }
        if (boxed) {
            // Boxed pool: store the raw Value bits; LOAD_K stores them verbatim.
            consts_i64[k] = @bitCast(c.bits);
        } else if (c.bits != 0 and c.unbox() == .number) {
            const n = c.unbox().number;
            if (n == @trunc(n) and @abs(n) < 9007199254740992.0) { // integral, < 2^53
                consts_i64[k] = @intFromFloat(n);
            }
        }
    }

    // ---- Pass C: validate opcode subset + name locality + LOAD_K integrality +
    // the compare-then-jump boolean-containment rule; collect property sites. ----
    var prop_sites: std.ArrayListUnmanaged(PropSite) = .empty;
    var pc: usize = 0;
    var prev_terminates = false; // previous op was an unconditional RETURN/JMP
    var seen_commit = false; // a SET_PROP or CALL committed — no coarse-deopt op after
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const size = opcodes.instrSize(op);
        if (pc + size > code.len) return .never;
        switch (op) {
            .RETURN_UNDEF => {
                // In BOXED mode `RETURN_UNDEF` returns 0 — exactly the `undefined`
                // Value — so a LIVE one (a function with no explicit `return`) is
                // correct. In INT mode 0 means the integer 0, not `undefined`, so
                // only a DEAD trailing epilogue (after an explicit `return`) is
                // allowed: not a jump target and preceded by a RETURN/JMP.
                if (!boxed and (isJumpTarget(jump_targets.items, pc) or !prev_terminates)) return .never;
            },
            .LOAD_K => {
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len) return .never;
                if (!boxed) {
                    // Int mode: the loaded constant must be an integral number.
                    const c = constants[kidx];
                    if (c.bits == 0 or c.unbox() != .number) return .never;
                    const n = c.unbox().number;
                    if (n != @trunc(n) or @abs(n) >= 9007199254740992.0) return .never;
                }
            },
            .GET_GLOBAL => {
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len or kidx_to_slot[kidx] < 0) return .never;
            },
            .SET_GLOBAL, .DEFINE_GLOBAL => {
                const kidx = readU16(code, pc + 1);
                if (kidx >= constants.len or kidx_to_slot[kidx] < 0) return .never;
            },
            .GET_PROP => {
                // Boxed-only. The native helper reads the LIVE inline cache (own
                // mono/poly/mega + proto-chain data); accept once the site IC is
                // warm — a still-cold IC → retry after it warms via interpretation.
                if (!boxed) return .never;
                if (seen_commit) return .never; // fallible op after a committed store
                const kidx = readU16(code, pc + 3);
                if (kidx >= constants.len) return .never;
                const key = constString(constants[kidx]) orelse return .never;
                if (pc >= func.ic_table.len) return .never;
                const ic = &func.ic_table[pc];
                if (ic.state == .uninitialized and ic.proto_chain_len == 0) return .retry;
                try prop_sites.append(arena, .{
                    .pc = @intCast(pc),
                    .key_len = @intCast(key.len),
                    .key_ptr = @intFromPtr(key.ptr),
                    .ic_ptr = @intFromPtr(ic),
                });
            },
            .SET_PROP => {
                // Boxed tier S3e: own-data store. Sound under coarse deopt only
                // when no fallible op runs after a committed store, so: reject
                // loops (`has_back_edge`) and any second store / post-store fallible
                // op (`seen_commit` guards on every fallible arm). Robj=pc+1,
                // Kname=pc+2..3, Rval=pc+4.
                if (!boxed) return .never;
                if (seen_commit or has_back_edge) return .never;
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len) return .never;
                const key = constString(constants[kidx]) orelse return .never;
                if (pc >= func.ic_table.len) return .never;
                const ic = &func.ic_table[pc];
                if (ic.state == .uninitialized) return .retry; // IC must know the slot
                try prop_sites.append(arena, .{
                    .pc = @intCast(pc),
                    .key_len = @intCast(key.len),
                    .key_ptr = @intFromPtr(key.ptr),
                    .ic_ptr = @intFromPtr(ic),
                });
                seen_commit = true;
            },
            .CALL => {
                // Boxed tier S4: re-enter the interpreter for a call. A CALL is a
                // committing side effect (and may throw — propagated, never
                // re-run), so like a store it requires no loop (`has_back_edge`)
                // and no coarse-deopt op after it (`seen_commit` guards). Multiple
                // CALLs in sequence are fine (each either succeeds or throws-and-
                // propagates). Encoding: op, base, nargs, retDst.
                if (!boxed) return .never;
                if (has_back_edge) return .never;
                seen_commit = true;
            },
            .HOIST_VAR => {},
            .ADD, .SUB, .MUL, .INC, .DEC => {
                if (seen_commit) return .never; // arithmetic can deopt — not after a commit
            },
            .MOVE, .RETURN, .JMP, .JMP_IF_TRUE, .JMP_IF_FALSE => {},
            .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => {
                if (seen_commit) return .never; // compares can deopt on a non-number
                // Boolean containment: the result reg (operand 0) must be read by
                // the very next instruction, which must be a conditional jump on it.
                const rdst = code[pc + 1];
                const next = pc + size;
                if (next >= code.len) return .never;
                const nop: Op = @enumFromInt(code[next]);
                if (nop != .JMP_IF_TRUE and nop != .JMP_IF_FALSE) return .never;
                if (code[next + 1] != rdst) return .never;
            },
            else => return .never, // unsupported opcode → bail
        }
        prev_terminates = (op == .RETURN or op == .JMP);
        pc += size;
    }

    // ---- Compile via Cranelift (int or boxed register model). ----
    const code_fn = compileNative(code, kidx_to_slot, boxed, prop_sites.items, call_helper) orelse return .never;
    const plan = try arena.create(JitPlan);
    plan.* = .{
        .code_fn = code_fn,
        .consts = consts_i64,
        .n_slots = n_slots,
        .num_regs = func.num_regs,
        .arity = func.arity,
        .boxed = boxed,
    };
    return .{ .ok = plan };
}

/// Outcome of running a JIT region. `deopt` = re-run the call in the interpreter
/// (an arithmetic result escaped ±2^53, a non-number operand, or a property miss —
/// all side-effect-free, so re-running is sound). `threw` = a re-entrant `CALL`
/// inside the region threw; `realm.pending_exception` holds the value and the
/// caller must PROPAGATE it (NOT re-run — the call's side effects already happened).
pub const RunOut = union(enum) { value: Value, deopt, threw };

/// Run `plan` for a call with `args`. Params occupy local slots 0..arity-1. In int
/// mode `args` are guaranteed SMI by the caller and the result is re-boxed; in
/// boxed mode the raw `Value.bits` flow straight through. `vm` is the `*BcVm` (for
/// re-entrant calls); the region's register/local buffers are published as a GC
/// root frame for the duration so a callee's allocation/`__gc__()` can't free
/// cells the native code still holds.
pub fn run(arena: std.mem.Allocator, plan: *const JitPlan, args: []const Value, vm: ?*anyopaque) !RunOut {
    const regs = try arena.alloc(i64, if (plan.num_regs > 0) plan.num_regs else 1);
    @memset(regs, 0);
    const locals = try arena.alloc(i64, if (plan.n_slots > 0) plan.n_slots else 1);
    @memset(locals, 0);
    var i: usize = 0;
    while (i < args.len and i < plan.n_slots) : (i += 1) {
        locals[i] = if (plan.boxed) @bitCast(args[i].bits) else args[i].smiValue();
    }
    // Publish this region's buffers as GC roots (non-moving collector → mark-only)
    // and the VM for the CALL trampoline; restore the parent on exit (supports
    // nested JIT regions reached through a re-entrant call).
    var root_frame = JitRootFrame{ .regs = regs, .locals = locals, .parent = active_jit_frame };
    const saved_vm = active_jit_vm;
    active_jit_frame = &root_frame;
    active_jit_vm = vm;
    defer {
        active_jit_frame = root_frame.parent;
        active_jit_vm = saved_vm;
    }
    var deopt: i32 = 0;
    const r = plan.code_fn(regs.ptr, plan.consts.ptr, locals.ptr, &deopt);
    if (deopt == 2) return .threw; // a re-entrant CALL threw — propagate, don't re-run.
    if (deopt != 0) return .deopt; // overflow / non-number / property miss — interpret.
    if (plan.boxed) {
        return .{ .value = Value{ .bits = @bitCast(r) } }; // already a boxed Value.
    }
    // Int mode re-box: SMI when it fits i32, else a heap double (exact: |r|<=2^53).
    if (r >= -2147483648 and r <= 2147483647) return .{ .value = Value.fromSmi(r) };
    return .{ .value = try val_mod.makeNumber(arena, @floatFromInt(r)) };
}
