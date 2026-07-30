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
const Environment = @import("../runtime/execution_context.zig").Environment;
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
    closure_helper: u64,
) ?*const anyopaque;

/// One property-access site, baked into the native code (mirror of the Rust
/// `PropSite`). At bytecode offset `pc` a `GET_PROP` reads property `key` (a
/// stable arena string) consulting the live inline cache `ic`.
pub const PropSite = extern struct { pc: u32, key_len: u32, key_ptr: u64, ic_ptr: u64 };

const JsObject = @import("../object/object.zig").JsObject;
const ic_mod = @import("../vm/ic.zig");

/// Property-read callback the boxed JIT invokes at each `GET_PROP` (S8). Two
/// tiers:
///   1. **Fast path (non-re-entrant, non-allocating)** — the interpreter's own
///      inline-cache lookup (`ic.lookup`: mono / poly / mega data slots) plus the
///      proto-chain method-dispatch cache, read LIVE so the site self-heals as it
///      evolves without recompiling.
///   2. **Slow path (re-entrant)** — anything else (accessors, proxies, arrays /
///      `length`, autoboxed primitives, uncached shapes) runs the interpreter's
///      FULL `getProp` machinery through the active VM, exactly once — so getters
///      and traps now execute while the region stays native. The region's
///      `regs`/`locals` buffers are GC roots for the whole run (see
///      `JitRootFrame`), so a getter's allocation / `__gc__()` is safe.
/// Miss protocol (written to the region's deopt flag): 0 = ok, 2 = the
/// getter/trap threw (`realm.pending_exception` holds the value; the region
/// propagates WITHOUT re-running), 1 = no VM available (FFI tests) → fine-deopt.
fn jsz_jit_get_prop(recv_bits: u64, key_ptr: [*]const u8, key_len: usize, ic_raw: *anyopaque, miss: *i32) callconv(.c) u64 {
    const v = Value{ .bits = recv_bits };
    const key = key_ptr[0..key_len];
    fast: {
        if (v.bits == 0 or v.unbox() != .object) break :fast;
        const obj = v.toPtr().object;
        // Proxy `get` traps and array / collection-size special cases run JS or
        // bespoke interpreter logic — slow path.
        if (obj.internal_kind == .proxy) break :fast;
        if (obj.is_array or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "size")) break :fast;
        const ic: *const ic_mod.InlineCache = @ptrCast(@alignCast(ic_raw));
        const shape = obj.shapePtr();
        // Own property via the inline cache (mono / poly / mega).
        if (ic.lookup(key, shape)) |slot| {
            if (slot < obj.attrs.items.len and obj.attrs.items[slot].is_accessor) break :fast;
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
                if (hslot < cur.attrs.items.len and cur.attrs.items[hslot].is_accessor) break :fast;
                if (cur.getOwnBySlot(hshape, hslot)) |val| {
                    miss.* = 0;
                    return val.bits;
                }
            }
        }
        break :fast;
    }
    // Slow path: re-enter the interpreter's full property machinery.
    const vmptr = active_jit_vm orelse {
        miss.* = 1;
        return 0;
    };
    const bc_vm_mod = @import("../vm/bc_vm.zig");
    const bvm: *bc_vm_mod.BcVm = @ptrCast(@alignCast(vmptr));
    const out = bvm.jitGetPropSlow(v, key) catch {
        miss.* = 2; // a getter / proxy trap threw — propagate, never re-run
        return 0;
    };
    miss.* = 0;
    return out.bits;
}

/// Property-store callback for `SET_PROP` (S8). Fast path stores `val` into an
/// EXISTING own writable data slot resolved via the live inline cache
/// (non-re-entrant, no allocation). Everything else — a setter, a proxy trap, a
/// shape transition (new own property), arrays / `length`, read-only slots —
/// runs the interpreter's FULL `setProp` re-entrantly, exactly once. The helper
/// performs NO partial store before signalling: on `miss.* != 0` the heap is
/// untouched by this op. Miss protocol matches `jsz_jit_get_prop`.
fn jsz_jit_set_own(recv_bits: u64, key_ptr: [*]const u8, key_len: usize, ic_raw: *anyopaque, val_bits: u64, miss: *i32) callconv(.c) void {
    const v = Value{ .bits = recv_bits };
    const key = key_ptr[0..key_len];
    fast: {
        if (v.bits == 0 or v.unbox() != .object) break :fast;
        const obj = v.toPtr().object;
        if (obj.internal_kind == .proxy) break :fast;
        if (obj.is_array or std.mem.eql(u8, key, "length")) break :fast;
        const ic: *const ic_mod.InlineCache = @ptrCast(@alignCast(ic_raw));
        const shape = obj.shapePtr();
        if (ic.lookup(key, shape)) |slot| {
            if (slot < obj.attrs.items.len) {
                const a = obj.attrs.items[slot];
                if (a.is_accessor or !a.writable) break :fast;
            }
            if (obj.setOwnBySlot(shape, slot, Value{ .bits = val_bits })) {
                miss.* = 0;
                return;
            }
        }
        break :fast;
    }
    // Slow path: full interpreter setProp (setters, proxies, shape transitions).
    const vmptr = active_jit_vm orelse {
        miss.* = 1;
        return;
    };
    const bc_vm_mod = @import("../vm/bc_vm.zig");
    const bvm: *bc_vm_mod.BcVm = @ptrCast(@alignCast(vmptr));
    bvm.jitSetPropSlow(v, key, Value{ .bits = val_bits }) catch {
        miss.* = 2; // a setter / proxy trap threw — propagate, never re-run
        return;
    };
    miss.* = 0;
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

pub const IntBlockFn = *const fn (regs: [*]i64, consts: [*]const i64, locals: [*]i64, deopt: *i32, out_resume_pc: *u32) callconv(.c) i64;

fn compileNative(code: []const u8, kidx_to_slot: []const i32, boxed: bool, prop_sites: []const PropSite, call_helper: u64, closure_helper: u64) ?IntBlockFn {
    const map_ptr: ?[*]const i32 = if (kidx_to_slot.len == 0) null else kidx_to_slot.ptr;
    const p = if (boxed) blk: {
        const sites_ptr: ?[*]const PropSite = if (prop_sites.len == 0) null else prop_sites.ptr;
        const get_helper: u64 = @intFromPtr(&jsz_jit_get_prop);
        const set_helper: u64 = @intFromPtr(&jsz_jit_set_own);
        break :blk jsz_clif_compile_boxed_block(code.ptr, code.len, map_ptr, kidx_to_slot.len, sites_ptr, prop_sites.len, get_helper, set_helper, call_helper, closure_helper);
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
    /// Prefix of `local_names` owned by the function. Remaining slots are
    /// read-only captures refreshed from the defining environment on every run.
    n_owned_slots: u16,
    num_regs: u16,
    arity: u16,
    /// Boxed mode: slots carry `Value.bits`, the result is a boxed `Value`, and
    /// arithmetic deopts on a non-number operand (vs the int mode's unboxed i64).
    boxed: bool,
    /// Function-local variable names in slot order (params first, then
    /// `DEFINE_GLOBAL`/`HOIST_VAR` names) — needed by the fine-deopt resume to
    /// rebuild the callee's environment from the native `locals` buffer.
    local_names: []const []const u8,
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
/// arithmetic op); `GET_PROP`/`SET_PROP` sites consult their LIVE inline cache at
/// run time (fast data path) and fall back to the re-entrant interpreter helper
/// (accessors / proxies / transitions). A site whose IC is still cold returns
/// `.retry` so it can warm over a few interpreted calls — unless `allow_cold` is
/// set (warmup exhausted: accessor-only sites never warm their data IC, so the
/// site is compiled anyway and served by the helper's slow path). In int mode
/// every `LOAD_K` must be an integral number and `GET_PROP` is rejected.
pub fn analyze(arena: std.mem.Allocator, func: *const BcFunction, boxed: bool, call_helper: u64, closure_helper: u64, allow_cold: bool) !AnalyzeResult {
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
    var has_back_edge = false;
    {
        var pc: usize = 0;
        while (pc < code.len) {
            const op: Op = @enumFromInt(code[pc]);
            const size = opcodes.instrSize(op);
            if (pc + size > code.len) return .never;
            const next = pc + size;
            switch (op) {
                .DEFINE_GLOBAL, .HOIST_VAR, .HOIST_LEX, .INIT_LEX => {
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
    const n_owned_slots: u16 = @intCast(local_names.items.len);
    if (boxed) {
        var capture_pc: usize = 0;
        while (capture_pc < code.len) {
            const capture_op: Op = @enumFromInt(code[capture_pc]);
            const capture_size = opcodes.instrSize(capture_op);
            if (capture_pc + capture_size > code.len) return .never;
            if (capture_op == .GET_GLOBAL) {
                const kidx = readU16(code, capture_pc + 2);
                if (kidx >= constants.len) return .never;
                const name = constString(constants[kidx]) orelse return .never;
                if (isLocalName(local_names.items, name) == null)
                    try local_names.append(arena, name);
            }
            capture_pc += capture_size;
        }
    }
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
    var prev_terminates = false;
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
                if (kidx >= constants.len or kidx_to_slot[kidx] < 0 or kidx_to_slot[kidx] >= n_owned_slots) return .never;
            },
            .GET_PROP => {
                if (!boxed) return .never;
                const kidx = readU16(code, pc + 3);
                if (kidx >= constants.len) return .never;
                const key = constString(constants[kidx]) orelse return .never;
                if (pc >= func.ic_table.len) return .never;
                const ic = &func.ic_table[pc];
                if (!allow_cold and ic.state == .uninitialized and ic.proto_chain_len == 0) return .retry;
                try prop_sites.append(arena, .{
                    .pc = @intCast(pc),
                    .key_len = @intCast(key.len),
                    .key_ptr = @intFromPtr(key.ptr),
                    .ic_ptr = @intFromPtr(ic),
                });
            },
            .SET_PROP => {
                if (!boxed) return .never;
                const kidx = readU16(code, pc + 2);
                if (kidx >= constants.len) return .never;
                const key = constString(constants[kidx]) orelse return .never;
                if (pc >= func.ic_table.len) return .never;
                const ic = &func.ic_table[pc];
                if (!allow_cold and ic.state == .uninitialized) return .retry; // let the data IC warm
                try prop_sites.append(arena, .{
                    .pc = @intCast(pc),
                    .key_len = @intCast(key.len),
                    .key_ptr = @intFromPtr(key.ptr),
                    .ic_ptr = @intFromPtr(ic),
                });
            },
            .CALL => {
                if (!boxed) return .never;
            },
            .NEW_CLOSURE => {
                if (!boxed) return .never;
            },
            .HOIST_VAR => {},
            .HOIST_LEX => {},
            .INIT_LEX => {},
            .ADD, .SUB, .MUL, .BIT_AND, .BIT_OR, .BIT_XOR, .SHL, .SHR, .USHR, .BIT_NOT, .TO_NUMERIC, .INC, .DEC => {},
            .DIV, .MOD, .NEG => if (!boxed) return .never,
            .MOVE, .RETURN, .JMP, .JMP_IF_TRUE, .JMP_IF_FALSE => {},
            .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE, .NOT => {
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
    const code_fn = compileNative(code, kidx_to_slot, boxed, prop_sites.items, call_helper, closure_helper) orelse return .never;
    const plan = try arena.create(JitPlan);
    plan.* = .{
        .code_fn = code_fn,
        .consts = consts_i64,
        .n_slots = n_slots,
        .n_owned_slots = n_owned_slots,
        .num_regs = func.num_regs,
        .arity = func.arity,
        .boxed = boxed,
        .local_names = local_names.items,
    };
    return .{ .ok = plan };
}

pub const RunOut = union(enum) {
    value: Value,
    deopt,
    threw,
    /// S2 fine deopt: the region stopped at bytecode `pc` with its boxed register
    /// file in `regs` and its env-local slots in `locals` (both arena-owned).
    /// The caller must resume the interpreter mid-function from EXACTLY this
    /// state (`BcVm.resumeJitFrame` pushes a real frame seeded from it). It must
    /// NOT re-run the region — a property store or call may already have
    /// committed.
    resumed: struct { regs: []i64, locals: []i64, pc: u32 },
};

/// Run `plan` for a call with `args`. Params occupy local slots 0..arity-1. In int
/// mode `args` are guaranteed SMI by the caller and the result is re-boxed; in
/// boxed mode the raw `Value.bits` flow straight through. `vm` is the `*BcVm` (for
/// re-entrant calls); the region's register/local buffers are published as a GC
/// root frame for the duration so a callee's allocation/`__gc__()` can't free
/// cells the native code still holds.
pub const RunContext = struct {
    args: []const Value,
    vm: ?*anyopaque,
    env: *Environment,
};

pub fn run(arena: std.mem.Allocator, plan: *const JitPlan, context: RunContext) !RunOut {
    const regs = try arena.alloc(i64, if (plan.num_regs > 0) plan.num_regs else 1);
    @memset(regs, 0);
    const locals = try arena.alloc(i64, if (plan.n_slots > 0) plan.n_slots else 1);
    @memset(locals, 0);
    var i: usize = 0;
    while (i < context.args.len and i < plan.n_owned_slots) : (i += 1) {
        locals[i] = if (plan.boxed) @bitCast(context.args[i].bits) else context.args[i].smiValue();
    }
    i = plan.n_owned_slots;
    while (i < plan.n_slots) : (i += 1) {
        const captured = context.env.lookup(plan.local_names[i]) catch return .deopt;
        locals[i] = @bitCast(captured.bits);
    }
    // Publish this region's buffers as GC roots (non-moving collector → mark-only)
    // and the VM for the CALL trampoline; restore the parent on exit (supports
    // nested JIT regions reached through a re-entrant call).
    var root_frame = JitRootFrame{ .regs = regs, .locals = locals, .parent = active_jit_frame };
    const saved_vm = active_jit_vm;
    active_jit_frame = &root_frame;
    active_jit_vm = context.vm;
    defer {
        active_jit_frame = root_frame.parent;
        active_jit_vm = saved_vm;
    }
    var deopt: i32 = 0;
    var resume_pc: u32 = 0xFFFFFFFF;
    const r = plan.code_fn(regs.ptr, plan.consts.ptr, locals.ptr, &deopt, &resume_pc);
    if (deopt == 2) return .threw;
    if (deopt == 3) {
        // Fine deopt: hand the exact native state back to the caller, which
        // pushes a REAL interpreter frame for the callee at `resume_pc`
        // (resumeJitFrame). The old behavior of patching the TOP frame was
        // unsound — at the call boundary the top frame is the CALLER.
        return .{ .resumed = .{ .regs = regs, .locals = locals, .pc = resume_pc } };
    }
    if (deopt != 0) return .deopt;
    if (plan.boxed) {
        return .{ .value = Value{ .bits = @bitCast(r) } };
    }
    if (r >= -2147483648 and r <= 2147483647) return .{ .value = Value.fromSmi(r) };
    return .{ .value = try val_mod.makeNumber(arena, @floatFromInt(r)) };
}
