// SPDX-License-Identifier: MIT
//! Bytecode register VM for Phase 2/3a/3b.
//! Semantics must match the tree-walker (vm.zig) exactly.
//! All arithmetic, equality, typeof, etc. delegate to the same
//! helper logic as vm.zig (duplicated here with same logic to avoid
//! circular imports; must be kept in sync).
//! Phase 3b: NEW_OBJECT/NEW_ARRAY allocate on the GC heap when present.
const std = @import("std");
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const JsValue = val_mod.JsValue;
const JsObject = @import("../object/object.zig").JsObject;
const Op = @import("../bytecode/opcodes.zig").Op;
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const BcClosure = @import("../bytecode/function.zig").BcClosure;
const Environment = @import("../runtime/execution_context.zig").Environment;
const Realm = @import("../runtime/realm.zig").Realm;
const Heap = @import("../gc/heap.zig").Heap;
const gc_mod = @import("../gc/gc.zig");
const ic_mod = @import("./ic.zig");

/// Phase 4a: a try entry pushed by PUSH_TRY.
pub const TryEntry = struct {
    /// Register index that receives the caught exception value (0xFF = no catch).
    rexc: u8,
    /// Absolute PC of the catch/finally handler.
    handler_pc: usize,
};

pub const BcCallFrame = struct {
    func: *const BcFunction,
    pc: usize,
    registers: []Value,
    env: *Environment,
    return_dst: u8,
    caller_idx: ?usize,
    /// Phase 3a: the `this` value for this frame.
    this_val: Value = Value{},
    /// Phase 4a: try stack (pushed by PUSH_TRY, popped by POP_TRY/THROW).
    try_stack: std.ArrayListUnmanaged(TryEntry) = .empty,
};

pub const RunOutcome = union(enum) {
    ok: Value,
    exception: []const u8,
    exception_value: struct { msg: []const u8, value: Value },
};

pub const BcVm = struct {
    arena: std.mem.Allocator,
    realm: *Realm,
    /// Phase 3b: optional GC heap.
    heap: ?*Heap = null,
    frames: std.ArrayListUnmanaged(BcCallFrame) = .empty,
    result: Value = Value{},
    exception: ?[]const u8 = null,
    /// Phase 4a: the last thrown JS value (for catch binding).
    last_exception_value: Value = Value{},
    /// Phase 4d: context for re-entry from native callbacks.
    context: @import("../runtime/realm.zig").Context = undefined,

    pub fn init(arena: std.mem.Allocator, realm: *Realm) BcVm {
        return BcVm{
            .arena = arena,
            .realm = realm,
        };
    }

    /// Init with an attached GC heap. Object/array allocations go to heap.
    /// NOTE: After calling this, call registerHeapCallback(heap) once you have
    /// the final stack address of the BcVm (i.e., after assignment to a named var).
    pub fn initWithHeap(arena: std.mem.Allocator, realm: *Realm, heap: *Heap) BcVm {
        return BcVm{
            .arena = arena,
            .realm = realm,
            .heap = heap,
        };
    }

    /// Register this BcVm as a GC root-scan source.
    /// Call once, after the BcVm is in its final stack location.
    pub fn registerHeapCallback(self: *BcVm, heap: *Heap) !void {
        try heap.addScanCallback(.{
            .ctx = self,
            .scan = bcVmScanCallback,
        });
    }

    pub fn unregisterHeapCallback(self: *BcVm, heap: *Heap) void {
        heap.removeScanCallback(self);
    }

    /// Phase 4d: Context re-entry — called by invokeCallback for JS functions.
    fn bcInvokeJs(ptr: *anyopaque, arena: std.mem.Allocator, this_val: Value, fn_val: Value, args: []const Value) anyerror!Value {
        _ = arena;
        const self: *BcVm = @ptrCast(@alignCast(ptr));
        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
        if (fn_val.bits == 0) return error.JsException;
        const inner = fn_val.toPtr().*;
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));
                const call_env = try Environment.init(self.arena, def_env);
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        new_regs[i] = if (i < args.len) args[i] else try val_mod.makeUndefined(self.arena);
                    }
                }
                const caller_idx = if (self.frames.items.len > 0) self.frames.items.len - 1 else 0;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = 255,
                    .caller_idx = if (self.frames.items.len > 0) caller_idx else null,
                    .this_val = this_val,
                });
                // Run until this frame returns.
                const frames_before = self.frames.items.len - 1;
                while (self.frames.items.len > frames_before) {
                    const outcome = try self.runLoop();
                    switch (outcome) {
                        .ok => |v| return v,
                        .exception => |msg| {
                            const realm_mod = @import("../runtime/realm.zig");
                            realm_mod.pending_exception = self.last_exception_value;
                            _ = msg;
                            return error.JsException;
                        },
                        .exception_value => |ev| {
                            const realm_mod = @import("../runtime/realm.zig");
                            realm_mod.pending_exception = ev.value;
                            return error.JsException;
                        },
                    }
                }
                return self.result;
            },
            .native_function => |fn_ptr| {
                return fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) return error.JsException;
                    return error.OutOfMemory;
                };
            },
            .object => |obj| {
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var combined = try self.arena.alloc(Value, bd.prefix.len + args.len);
                        for (bd.prefix, 0..) |v, i| combined[i] = v;
                        for (args, 0..) |v, i| combined[bd.prefix.len + i] = v;
                        return bcInvokeJs(ptr, self.arena, bd.this_val, bd.target, combined);
                    }
                }
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = Value{};
                return error.JsException;
            },
            else => {
                const realm_mod = @import("../runtime/realm.zig");
                realm_mod.pending_exception = Value{};
                return error.JsException;
            },
        }
    }

    fn activateContext(self: *BcVm) void {
        const realm_mod = @import("../runtime/realm.zig");
        self.context = realm_mod.Context{
            .ptr = self,
            .invoke_fn = bcInvokeJs,
        };
        realm_mod.active_context = &self.context;
    }

    fn deactivateContext(_: *BcVm) void {
        @import("../runtime/realm.zig").active_context = null;
    }

    pub fn run(
        self: *BcVm,
        main_func: *const BcFunction,
        captured_env: *anyopaque,
    ) !RunOutcome {
        self.activateContext();
        defer self.deactivateContext();

        // Create top-level frame.
        const global_env: *Environment = @ptrCast(@alignCast(captured_env));
        const regs = try self.arena.alloc(Value, if (main_func.num_regs > 0) main_func.num_regs else 1);
        for (regs) |*r| r.* = Value{};

        try self.frames.append(self.arena, BcCallFrame{
            .func = main_func,
            .pc = 0,
            .registers = regs,
            .env = global_env,
            .return_dst = 0,
            .caller_idx = null,
            .this_val = Value{}, // global this = undefined
        });

        return self.runLoop();
    }

    fn runLoop(self: *BcVm) !RunOutcome {
        while (self.frames.items.len > 0) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const code = frame.func.chunk.code;
            const op: Op = @enumFromInt(code[frame.pc]);
            frame.pc += 1;

            switch (op) {
                .LOAD_K => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    frame.registers[rdst] = frame.func.chunk.constants[kidx];
                },
                .LOAD_TRUE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, true);
                },
                .LOAD_FALSE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, false);
                },
                .LOAD_NULL => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeNull(self.arena);
                },
                .LOAD_UNDEF => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeUndefined(self.arena);
                },
                .MOVE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = frame.registers[rsrc];
                },
                .GET_GLOBAL => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const name_val = frame.func.chunk.constants[kidx];
                    const name = name_val.toPtr().string;
                    // Look up in frame env (which chains up to global).
                    frame.registers[rdst] = frame.env.lookup(name) catch blk: {
                        // Not in env chain: also try realm global directly.
                        break :blk self.realm.global_env.lookup(name) catch
                            try val_mod.makeUndefined(self.arena);
                    };
                },
                .SET_GLOBAL => {
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const name_val = frame.func.chunk.constants[kidx];
                    const name = name_val.toPtr().string;
                    const value = frame.registers[rsrc];
                    const cur_is_strict = frame.func.is_strict;
                    // Try to assign in env chain (covers locals and upvalues).
                    frame.env.assign(name, value) catch {
                        // Not found in chain.
                        if (cur_is_strict) {
                            // Phase 4d: strict mode — undeclared variable assignment is a ReferenceError.
                            const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
                            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
                            self.last_exception_value = exc_val;
                            const found = try self.throwException(exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        } else if (frame.env.parent == null) {
                            // Already at global env.
                            frame.env.define(name, value) catch return error.OutOfMemory;
                        } else {
                            // Function-local env: define locally (var hoisting into current env).
                            frame.env.define(name, value) catch return error.OutOfMemory;
                        }
                    };
                },
                .DEFINE_GLOBAL => {
                    // Phase 4d: always define (never throws ReferenceError in strict mode).
                    // Used for var declarations, catch-variable bindings, function declarations.
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const name_val = frame.func.chunk.constants[kidx];
                    const name = name_val.toPtr().string;
                    const value = frame.registers[rsrc];
                    // Try assign first (update existing binding), else define.
                    frame.env.assign(name, value) catch {
                        if (frame.env.parent == null) {
                            frame.env.define(name, value) catch return error.OutOfMemory;
                        } else {
                            frame.env.define(name, value) catch return error.OutOfMemory;
                        }
                    };
                },
                .GET_LOCAL => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const slot = code[frame.pc];
                    frame.pc += 1;
                    // GET_LOCAL reads from registers[slot]. Also sync from env if defined there.
                    frame.registers[rdst] = frame.registers[slot];
                },
                .SET_LOCAL => {
                    const slot = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[slot] = frame.registers[rsrc];
                },
                .ADD => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv)) {
                        frame.registers[rdst] = try val_mod.makeNumber(self.arena, lv.toPtr().number + rv.toPtr().number);
                    } else {
                        frame.registers[rdst] = try self.jsAdd(lv, rv);
                        ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    }
                },
                .SUB => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        lv.toPtr().number - rv.toPtr().number
                    else
                        toNumber(lv) - toNumber(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                },
                .MUL => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        lv.toPtr().number * rv.toPtr().number
                    else
                        toNumber(lv) * toNumber(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                },
                .DIV => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        lv.toPtr().number / rv.toPtr().number
                    else
                        toNumber(lv) / toNumber(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                },
                .MOD => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        lv.toPtr().number
                    else
                        toNumber(lv);
                    const r = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        rv.toPtr().number
                    else
                        toNumber(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const res = std.math.mod(f64, l, r) catch std.math.nan(f64);
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, res);
                },
                .EXP => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, std.math.pow(f64, toNumber(lv), toNumber(rv)));
                },
                .NEG => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, -toNumber(frame.registers[rsrc]));
                },
                .BIT_AND => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toInt32(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: i32 = l & r0;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .BIT_OR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toInt32(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: i32 = l | r0;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .BIT_XOR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const r0 = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toInt32(rv);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: i32 = l ^ r0;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .SHL => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(u32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toUint32(rv)) & 0x1F);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: i32 = l << shift;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .SHR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(u32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toUint32(rv)) & 0x1F);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: i32 = l >> shift;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .USHR => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lv = frame.registers[rlhs];
                    const rv = frame.registers[rrhs];
                    const ac = &@constCast(frame.func.arith_ic_table)[site_pc];
                    const l = if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(i32, @intFromFloat(@trunc(lv.toPtr().number)))
                    else
                        toInt32(lv);
                    const u: u32 = @bitCast(l);
                    const shift: u5 = @intCast((if (ac.mode == .number_pair and isNumberValue(lv) and isNumberValue(rv))
                        @as(u32, @intFromFloat(@trunc(rv.toPtr().number)))
                    else
                        toUint32(rv)) & 0x1F);
                    ac.mode = if (isNumberValue(lv) and isNumberValue(rv)) .number_pair else .unknown;
                    const r: u32 = u >> shift;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .BIT_NOT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const r: i32 = ~toInt32(frame.registers[rsrc]);
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, @floatFromInt(r));
                },
                .INC => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const r = toNumber(frame.registers[rsrc]) + 1.0;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                },
                .DEC => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const r = toNumber(frame.registers[rsrc]) - 1.0;
                    frame.registers[rdst] = try val_mod.makeNumber(self.arena, r);
                },
                .EQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = jsAbstractEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .NEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = !jsAbstractEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .SEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .SNEQ => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = !jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs]);
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .LT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = jsLessThan(frame.registers[rlhs], frame.registers[rrhs]) orelse false;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .LE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    // a <= b == !(b < a)
                    const r2 = jsLessThan(frame.registers[rrhs], frame.registers[rlhs]);
                    const r = if (r2) |v| !v else false;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .GT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const r = jsLessThan(frame.registers[rrhs], frame.registers[rlhs]) orelse false;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .GE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    // a >= b == !(a < b)
                    const r2 = jsLessThan(frame.registers[rlhs], frame.registers[rrhs]);
                    const r = if (r2) |v| !v else false;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, r);
                },
                .NOT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, !isTruthy(frame.registers[rsrc]));
                },
                .TYPEOF => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const tv = frame.registers[rsrc];
                    const info = classifyTypeof(tv);
                    const cache = &@constCast(frame.func.typeof_ic_table)[site_pc];
                    const hit = cache.initialized and cache.tag == info.tag and
                        (info.shape == null or cache.shape == info.shape);
                    const ts = if (hit) cache.result else info.result;
                    if (!hit) {
                        cache.initialized = true;
                        cache.tag = info.tag;
                        cache.shape = info.shape;
                        cache.result = info.result;
                    }
                    frame.registers[rdst] = try val_mod.makeString(self.arena, ts);
                },
                .JMP => {
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    const new_pc: i64 = @intCast(frame.pc);
                    frame.pc = @intCast(new_pc + offset);
                },
                .JMP_IF_TRUE => {
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (isTruthy(frame.registers[rcond])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .JMP_IF_FALSE => {
                    const rcond = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (!isTruthy(frame.registers[rcond])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .JSEQ => {
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    if (jsStrictEqual(frame.registers[rlhs], frame.registers[rrhs])) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .JGE => {
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    const lt = jsLessThan(frame.registers[rlhs], frame.registers[rrhs]);
                    const ge = if (lt) |v| !v else false;
                    if (ge) {
                        const new_pc: i64 = @intCast(frame.pc);
                        frame.pc = @intCast(new_pc + offset);
                    }
                },
                .NEW_CLOSURE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const fidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const child_fn = frame.func.child_functions[fidx];
                    const closure = try self.arena.create(BcClosure);
                    closure.* = BcClosure{
                        .func = child_fn,
                        .env = @ptrCast(frame.env),
                    };
                    const jsv = try self.arena.create(JsValue);
                    jsv.* = JsValue{ .bc_function = closure };
                    frame.registers[rdst] = Value.fromPtr(jsv);
                },
                .CALL => {
                    const base = code[frame.pc];
                    frame.pc += 1;
                    const nargs = code[frame.pc];
                    frame.pc += 1;
                    const ret_dst = code[frame.pc];
                    frame.pc += 1;

                    const callee_val = frame.registers[base];
                    const this_val = try val_mod.makeUndefined(self.arena); // CALL: this = undefined

                    const outcome = try self.doCall(callee_val, this_val, base, nargs, ret_dst);
                    if (outcome) |msg| {
                        if (std.mem.eql(u8, msg, "__js_exception__")) {
                            // Native threw a JS exception; last_exception_value already set.
                            const exc_val = self.last_exception_value;
                            const found = try self.throwException(exc_val);
                            const exc_msg = try formatExceptionMessage(self.arena, exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
                        } else {
                            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                            self.last_exception_value = exc_val;
                            const found = try self.throwException(exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        }
                    }
                },
                .METHOD_CALL => {
                    const base = code[frame.pc];
                    frame.pc += 1;
                    const nargs = code[frame.pc];
                    frame.pc += 1;
                    const ret_dst = code[frame.pc];
                    frame.pc += 1;

                    // R[base] = this object, R[base+1] = function value
                    const this_val = frame.registers[base];
                    const callee_val = frame.registers[base + 1];

                    const outcome = try self.doMethodCall(callee_val, this_val, base, nargs, ret_dst);
                    if (outcome) |msg| {
                        if (std.mem.eql(u8, msg, "__js_exception__")) {
                            const exc_val = self.last_exception_value;
                            const found = try self.throwException(exc_val);
                            const exc_msg = try formatExceptionMessage(self.arena, exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc_val } };
                        } else {
                            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                            self.last_exception_value = exc_val;
                            const found = try self.throwException(exc_val);
                            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        }
                    }
                },
                .RETURN => {
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const result = frame.registers[rsrc];
                    const caller_idx = frame.caller_idx;
                    const ret_dst = frame.return_dst;
                    _ = self.frames.pop();

                    if (caller_idx == null or self.frames.items.len == 0) {
                        self.result = result;
                        return RunOutcome{ .ok = result };
                    }
                    if (ret_dst == 0xFF) {
                        // Sentinel: re-entrant callback result — store in self.result and exit loop.
                        self.result = result;
                        return RunOutcome{ .ok = result };
                    }
                    const caller = &self.frames.items[self.frames.items.len - 1];
                    caller.registers[ret_dst] = result;
                },
                .RETURN_UNDEF => {
                    const result = try val_mod.makeUndefined(self.arena);
                    const caller_idx = frame.caller_idx;
                    const ret_dst = frame.return_dst;
                    _ = self.frames.pop();

                    if (caller_idx == null or self.frames.items.len == 0) {
                        self.result = result;
                        return RunOutcome{ .ok = result };
                    }
                    if (ret_dst == 0xFF) {
                        self.result = result;
                        return RunOutcome{ .ok = result };
                    }
                    const caller = &self.frames.items[self.frames.items.len - 1];
                    caller.registers[ret_dst] = result;
                },
                .HALT => {
                    return RunOutcome{ .ok = self.result };
                },
                // -------------------------------------------------------- Phase 3a/3b ---
                .NEW_OBJECT => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const obj = if (self.heap) |heap|
                        try JsObject.createOnHeap(heap, self.realm.object_prototype)
                    else
                        try JsObject.create(self.arena, self.realm.object_prototype);
                    frame.registers[rdst] = try val_mod.makeObject(self.arena, obj);
                },
                .NEW_ARRAY => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    _ = code[frame.pc];
                    frame.pc += 1; // length hint (unused in runtime)
                    const arr = if (self.heap) |heap|
                        try JsObject.createArrayOnHeap(heap, self.realm.array_prototype)
                    else
                        try JsObject.createArray(self.arena, self.realm.array_prototype);
                    frame.registers[rdst] = try val_mod.makeObject(self.arena, arr);
                },
                .GET_PROP => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const key_val = frame.func.chunk.constants[kidx];
                    const key = key_val.toPtr().string;
                    const obj_val = frame.registers[robj];
                    const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                    if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                            if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                                if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                                    frame.registers[rdst] = cached;
                                    continue;
                                }
                            }
                        }
                    }

                    const result = try self.getProp(obj_val, key);
                    frame.registers[rdst] = result;
                    if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                            if (obj.resolveOwnSlot(key)) |slot| {
                                site_cache.record(key, obj.shapePtr(), slot);
                            }
                        }
                    }
                },
                .GET_PROP_DYN => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const key_val = frame.registers[rkey];
                    if (key_val.bits != 0 and key_val.toPtr().* == .string) {
                        const key = key_val.toPtr().string;
                        const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                        if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                                    if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                                        frame.registers[rdst] = cached;
                                        continue;
                                    }
                                }
                            }
                        }
                        const result = try self.getProp(obj_val, key);
                        frame.registers[rdst] = result;
                        if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (obj.resolveOwnSlot(key)) |slot| {
                                    site_cache.record(key, obj.shapePtr(), slot);
                                }
                            }
                        }
                    } else {
                        const key = try valueToStringArena(self.arena, key_val);
                        frame.registers[rdst] = try self.getProp(obj_val, key);
                    }
                },
                .SET_PROP => {
                    const site_pc = frame.pc - 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
                    const rval = code[frame.pc];
                    frame.pc += 1;
                    const key_val = frame.func.chunk.constants[kidx];
                    const key = key_val.toPtr().string;
                    const obj_val = frame.registers[robj];
                    const val = frame.registers[rval];
                    try self.setProp(obj_val, key, val);
                    const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                    if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                        const obj = obj_val.toPtr().object;
                        if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                            if (obj.resolveOwnSlot(key)) |slot| {
                                site_cache.record(key, obj.shapePtr(), slot);
                            }
                        }
                    }
                },
                .SET_PROP_DYN => {
                    const site_pc = frame.pc - 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const rkey = code[frame.pc];
                    frame.pc += 1;
                    const rval = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const key_val = frame.registers[rkey];
                    const val = frame.registers[rval];
                    if (key_val.bits != 0 and key_val.toPtr().* == .string) {
                        const key = key_val.toPtr().string;
                        try self.setProp(obj_val, key, val);
                        const site_cache = &@constCast(frame.func.ic_table)[site_pc];
                        if (obj_val.bits != 0 and obj_val.toPtr().* == .object) {
                            const obj = obj_val.toPtr().object;
                            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                                if (obj.resolveOwnSlot(key)) |slot| {
                                    site_cache.record(key, obj.shapePtr(), slot);
                                }
                            }
                        }
                    } else {
                        const key = try valueToStringArena(self.arena, key_val);
                        try self.setProp(obj_val, key, val);
                    }
                },
                .GET_THIS => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    frame.registers[rdst] = frame.this_val;
                },
                // -------------------------------------------------------- Phase 4a ---
                .THROW => {
                    const rsrc = code[frame.pc];
                    frame.pc += 1;
                    const thrown_val = frame.registers[rsrc];
                    self.last_exception_value = thrown_val;

                    // Walk frame stack looking for a PUSH_TRY entry.
                    var found_handler = false;
                    var fi: usize = self.frames.items.len;
                    while (fi > 0) {
                        fi -= 1;
                        const f = &self.frames.items[fi];
                        if (f.try_stack.items.len > 0) {
                            const entry = f.try_stack.pop().?;
                            // Jump to handler in that frame.
                            f.pc = entry.handler_pc;
                            // Store exception in target register.
                            if (entry.rexc != 0xFF) {
                                f.registers[entry.rexc] = thrown_val;
                            }
                            // Pop all frames above fi.
                            while (self.frames.items.len > fi + 1) {
                                _ = self.frames.pop();
                            }
                            found_handler = true;
                            break;
                        }
                    }
                    if (!found_handler) {
                        // Uncaught exception. Format Error-like objects nicely.
                        const msg = try formatExceptionMessage(self.arena, thrown_val);
                        return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown_val } };
                    }
                },
                .PUSH_TRY => {
                    const rexc = code[frame.pc];
                    frame.pc += 1;
                    const lo = code[frame.pc];
                    frame.pc += 1;
                    const hi = code[frame.pc];
                    frame.pc += 1;
                    const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                    const handler_pc: usize = @intCast(@as(i64, @intCast(frame.pc)) + offset);
                    try frame.try_stack.append(self.arena, TryEntry{
                        .rexc = rexc,
                        .handler_pc = handler_pc,
                    });
                },
                .POP_TRY => {
                    if (frame.try_stack.items.len > 0) {
                        _ = frame.try_stack.pop();
                    }
                },
                .NEW_INSTANCE => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const base = code[frame.pc];
                    frame.pc += 1;
                    const nargs = code[frame.pc];
                    frame.pc += 1;
                    const callee_val = frame.registers[base];
                    const outcome = try self.doConstruct(callee_val, base, nargs, rdst);
                    if (outcome) |msg| {
                        // doConstruct returned error string: throw it.
                        // "__js_exception__" is the sentinel for a JS exception already in last_exception_value.
                        const thrown_val = if (std.mem.eql(u8, msg, "__js_exception__"))
                            self.last_exception_value
                        else blk: {
                            self.last_exception_value = try self.makeErrorObjectBc("TypeError", msg);
                            break :blk self.last_exception_value;
                        };
                        const found = try self.throwException(thrown_val);
                        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = thrown_val } };
                    }
                },
                .INSTANCEOF => {
                    const site_pc = frame.pc - 1;
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const rlhs = code[frame.pc];
                    frame.pc += 1;
                    const rrhs = code[frame.pc];
                    frame.pc += 1;
                    const lhs = frame.registers[rlhs];
                    const rhs = frame.registers[rrhs];
                    var result = false;
                    const cache = &@constCast(frame.func.instanceof_ic_table)[site_pc];
                    if (rhs.bits != 0 and rhs.toPtr().* == .object) {
                        const rhs_obj = rhs.toPtr().object;
                        var target_proto: ?*JsObject = null;
                        if (cache.initialized and cache.rhs_obj != null and cache.rhs_obj.? == @as(*anyopaque, @ptrCast(rhs_obj))) {
                            if (cache.target_proto) |tp| target_proto = @ptrCast(@alignCast(tp));
                        } else {
                            if (rhs_obj.get("prototype")) |pv| {
                                if (pv.bits != 0 and pv.toPtr().* == .object) target_proto = pv.toPtr().object;
                            }
                            cache.initialized = true;
                            cache.rhs_obj = @ptrCast(rhs_obj);
                            cache.target_proto = if (target_proto) |tp| @ptrCast(tp) else null;
                        }
                        result = jsInstanceofWithTarget(lhs, target_proto);
                    } else {
                        result = false;
                    }
                    frame.registers[rdst] = try val_mod.makeBool(self.arena, result);
                },
                // Phase 4d
                .GET_KEYS => {
                    const rdst = code[frame.pc];
                    frame.pc += 1;
                    const robj = code[frame.pc];
                    frame.pc += 1;
                    const obj_val = frame.registers[robj];
                    const arr_obj = if (self.heap) |heap|
                        try JsObject.createOnHeap(heap, self.realm.array_prototype)
                    else
                        try JsObject.create(self.arena, self.realm.array_prototype);
                    arr_obj.is_array = true;
                    var count: u32 = 0;
                    if (obj_val.bits != 0) {
                        const iv = obj_val.toPtr().*;
                        if (iv == .object) {
                            var it = iv.object.props.iterator();
                            while (it.next()) |entry| {
                                const key_str = entry.key_ptr.*;
                                const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                                const key_val = try val_mod.makeString(self.arena, key_str);
                                arr_obj.set(idx_str, key_val) catch {};
                                count += 1;
                            }
                        }
                    }
                    const len_val = try val_mod.makeNumber(self.arena, @floatFromInt(count));
                    arr_obj.set("length", len_val) catch {};
                    frame.registers[rdst] = try val_mod.makeObject(self.arena, arr_obj);
                },
            }
        }
        return RunOutcome{ .ok = try val_mod.makeUndefined(self.arena) };
    }

    /// Throw helper: walk frame stack for a try entry and dispatch. Returns true if handled.
    fn throwException(self: *BcVm, thrown_val: Value) !bool {
        var fi: usize = self.frames.items.len;
        while (fi > 0) {
            fi -= 1;
            const f = &self.frames.items[fi];
            if (f.try_stack.items.len > 0) {
                const entry = f.try_stack.pop().?;
                f.pc = entry.handler_pc;
                if (entry.rexc != 0xFF) {
                    f.registers[entry.rexc] = thrown_val;
                }
                while (self.frames.items.len > fi + 1) {
                    _ = self.frames.pop();
                }
                return true;
            }
        }
        return false;
    }

    /// [[Construct]]: R[base] = constructor, R[base+1..base+nargs] = args.
    fn doConstruct(self: *BcVm, callee_val: Value, base: u8, nargs: u8, rdst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return "undefined is not a constructor";
        }
        switch (callee_val.toPtr().*) {
            .bc_function, .function => {
                // User-defined constructor.
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const proto = self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                // Dispatch as a call, expect result.
                const err = try self.doCallWithThis(callee_val, this_val, base, nargs, rdst);
                if (err != null) return err;
                // The called function will push a new frame. When that frame RETURNs,
                // its result goes to rdst. If result is not an object, we should return this_val.
                // This is complex to handle perfectly without extra plumbing; for now
                // the caller gets whatever the constructor function returned (or undefined).
                // The native Error ctors above are handled separately.
                return null;
            },
            .native_function => |fn_ptr| {
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const proto = self.realm.object_prototype;
                const new_obj = if (self.heap) |heap|
                    try JsObject.createOnHeap(heap, proto)
                else
                    try JsObject.create(self.arena, proto);
                const this_val = try val_mod.makeObject(self.arena, new_obj);
                const result = fn_ptr.invoke(self.arena, this_val, args) catch {
                    return "native constructor threw";
                };
                frame.registers[rdst] = if (result.bits != 0 and result.toPtr().* == .object) result else this_val;
                return null;
            },
            .object => |obj| {
                // Error constructor object: has __call__ and prototype.
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.toPtr().* == .native_function) {
                        const fn_ptr = call_val.toPtr().native_function;
                        var proto: ?*JsObject = self.realm.object_prototype;
                        if (obj.get("prototype")) |pv| {
                            if (pv.bits != 0 and pv.toPtr().* == .object) {
                                proto = pv.toPtr().object;
                            }
                        }
                        var args = try self.arena.alloc(Value, nargs);
                        for (0..nargs) |i| {
                            args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        const new_obj = if (self.heap) |heap|
                            try JsObject.createOnHeap(heap, proto)
                        else
                            try JsObject.create(self.arena, proto);
                        const this_val = try val_mod.makeObject(self.arena, new_obj);
                        const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_m = @import("../runtime/realm.zig");
                                if (realm_m.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_m.pending_exception;
                                    realm_m.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return "native constructor threw";
                        };
                        const final_r = if (result.bits != 0 and result.toPtr().* == .object) result else this_val;
                        self.frames.items[self.frames.items.len - 1].registers[rdst] = final_r;
                        return null;
                    }
                }
                return "object is not a constructor";
            },
            else => return try std.fmt.allocPrint(self.arena, "{s} is not a constructor", .{typeofValue(callee_val)}),
        }
    }

    fn doCallWithThis(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        switch (callee_val.toPtr().*) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));
                const call_env = try Environment.init(self.arena, def_env);
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 1 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};
                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            else => return "not a callable",
        }
    }

    fn makeErrorObjectBc(self: *BcVm, name: []const u8, message: []const u8) !Value {
        const proto_name = try std.fmt.allocPrint(self.arena, "__{s}Proto__", .{name});
        var proto: ?*JsObject = self.realm.object_prototype;
        if (self.realm.global_env.lookup(proto_name)) |pv| {
            if (pv.bits != 0 and pv.toPtr().* == .object) proto = pv.toPtr().object;
        } else |_| {}
        const obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, proto)
        else
            try JsObject.create(self.arena, proto);
        const msg_val = try val_mod.makeString(self.arena, message);
        const name_val = try val_mod.makeString(self.arena, name);
        try obj.set("message", msg_val);
        try obj.set("name", name_val);
        return val_mod.makeObject(self.arena, obj);
    }

    fn getProp(self: *BcVm, obj_val: Value, key: []const u8) !Value {
        if (obj_val.bits == 0) return val_mod.makeUndefined(self.arena);
        switch (obj_val.toPtr().*) {
            .object => |obj| {
                // Special case: "length" on arrays.
                if (obj.is_array and std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(obj.getArrayLength()));
                }
                // ES2015 virtual "size" accessor on Map/Set.
                if (std.mem.eql(u8, key, "size")) {
                    if (@import("../runtime/builtins/es2015_collections.zig").collectionSize(obj)) |n| {
                        return val_mod.makeNumber(self.arena, @floatFromInt(n));
                    }
                }
                if (obj.resolveOwnSlot(key)) |slot| {
                    if (obj.getOwnBySlot(obj.shapePtr(), slot)) |v| return v;
                }
                if (obj.get(key)) |v| return v;
                return val_mod.makeUndefined(self.arena);
            },
            .string => |s| {
                // Phase 4b: autoboxing for string primitives.
                if (std.mem.eql(u8, key, "length")) {
                    return val_mod.makeNumber(self.arena, @floatFromInt(s.len));
                }
                // Delegate to String.prototype
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_string_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            .function, .bc_function, .native_function => {
                // Phase 4d: delegate to Function.prototype (call, apply, bind).
                const realm_mod = @import("../runtime/realm.zig");
                if (realm_mod.active_function_proto) |proto| {
                    if (proto.get(key)) |v| return v;
                }
                return val_mod.makeUndefined(self.arena);
            },
            else => return val_mod.makeUndefined(self.arena),
        }
    }

    fn setProp(self: *BcVm, obj_val: Value, key: []const u8, value: Value) !void {
        if (obj_val.bits == 0) return;
        switch (obj_val.toPtr().*) {
            .object => |obj| {
                if (obj.resolveOwnSlot(key)) |slot| {
                    if (obj.setOwnBySlot(obj.shapePtr(), slot, value)) {
                        try obj.props.put(obj.arena, key, value);
                        return;
                    }
                }
                try obj.set(key, value);
            },
            else => {},
        }
        _ = self;
    }

    /// Execute a regular CALL: reads callee from R[base], args from R[base+1..base+1+nargs].
    fn doCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return try std.fmt.allocPrint(self.arena, "TypeError: undefined is not a function", .{});
        }
        const inner = callee_val.toPtr().*;
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));

                // Create call environment.
                const call_env = try Environment.init(self.arena, def_env);

                // Bind parameters.
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 1 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }

                // NFE self-binding.
                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        call_env.define(fname, callee_val) catch {};
                    }
                }

                // Allocate registers for new frame.
                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};

                // Copy param values into register slots.
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        const av: Value = if (i < nargs)
                            frame.registers[base + 1 + @as(u8, @intCast(i))]
                        else
                            try val_mod.makeUndefined(self.arena);
                        new_regs[i] = av;
                    }
                }

                // NFE slot.
                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        const nfe_slot = fn_ptr.param_names.len;
                        if (nfe_slot < num_regs) {
                            new_regs[nfe_slot] = callee_val;
                        }
                    }
                }

                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            .native_function => |fn_ptr| {
                // Collect args.
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                }
                const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) {
                        // Phase 4b: check pending_exception (e.g. JSON.parse).
                        const realm_mod = @import("../runtime/realm.zig");
                        if (realm_mod.pending_exception.bits != 0) {
                            self.last_exception_value = realm_mod.pending_exception;
                            realm_mod.pending_exception = Value{};
                        }
                        // Use sentinel: return "__js_exception__" to tell caller
                        // to use last_exception_value rather than build a new TypeError.
                        return "__js_exception__";
                    }
                    return try std.fmt.allocPrint(self.arena, "TypeError: native function threw", .{});
                };
                // Re-read frame after native call (may have triggered re-entrant frames + realloc).
                self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                return null;
            },
            .function => {
                // Tree-walker function called from bc mode — not supported in Phase 2.
                return "TypeError: cannot call tree-walker function from bc mode";
            },
            .object => |obj| {
                // Phase 4d: bound function.
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var args = try self.arena.alloc(Value, bd.prefix.len + nargs);
                        for (bd.prefix, 0..) |v, i| args[i] = v;
                        for (0..nargs) |i| {
                            args[bd.prefix.len + i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        const res = bcInvokeJs(self, self.arena, bd.this_val, bd.target, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return try std.fmt.allocPrint(self.arena, "TypeError: bound call threw", .{});
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        return null;
                    }
                }
                if (obj.get("__call__")) |call_val| {
                    if (call_val.bits != 0 and call_val.toPtr().* == .native_function) {
                        const fn_ptr = call_val.toPtr().native_function;
                        // Collect args.
                        var args = try self.arena.alloc(Value, nargs);
                        for (0..nargs) |i| {
                            args[i] = frame.registers[base + 1 + @as(u8, @intCast(i))];
                        }
                        if (obj.get("prototype") != null) {
                            // Preserve legacy behavior for Error-like constructor objects.
                            var proto: ?*JsObject = self.realm.object_prototype;
                            if (obj.get("prototype")) |pv| {
                                if (pv.bits != 0 and pv.toPtr().* == .object) proto = pv.toPtr().object;
                            }
                            const new_obj = if (self.heap) |heap|
                                try JsObject.createOnHeap(heap, proto)
                            else
                                try JsObject.create(self.arena, proto);
                            const this_val_call = try val_mod.makeObject(self.arena, new_obj);
                            const result = fn_ptr.invoke(self.arena, this_val_call, args) catch {
                                return "TypeError: Error constructor threw";
                            };
                            const final_result = if (result.bits != 0 and result.toPtr().* == .object) result else this_val_call;
                            self.frames.items[self.frames.items.len - 1].registers[ret_dst] = final_result;
                            return null;
                        }
                        const result = fn_ptr.invoke(self.arena, callee_val, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return "TypeError: object call threw";
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                        return null;
                    }
                }
                return try std.fmt.allocPrint(self.arena, "TypeError: object is not a function", .{});
            },
            else => {
                return try std.fmt.allocPrint(self.arena, "TypeError: {s} is not a function", .{typeofValue(callee_val)});
            },
        }
    }

    /// Execute a METHOD_CALL: R[base]=this, R[base+1]=fn, args from R[base+2..base+1+nargs].
    fn doMethodCall(self: *BcVm, callee_val: Value, this_val: Value, base: u8, nargs: u8, ret_dst: u8) !?[]const u8 {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (callee_val.bits == 0) {
            return try std.fmt.allocPrint(self.arena, "TypeError: undefined is not a function", .{});
        }
        const inner = callee_val.toPtr().*;
        switch (inner) {
            .bc_function => |closure| {
                const fn_ptr = closure.func;
                const def_env: *Environment = @ptrCast(@alignCast(closure.env));

                const call_env = try Environment.init(self.arena, def_env);

                // Bind parameters. Args are at R[base+2..base+1+nargs].
                for (fn_ptr.param_names, 0..) |pname, i| {
                    const av: Value = if (i < nargs)
                        frame.registers[base + 2 + @as(u8, @intCast(i))]
                    else
                        try val_mod.makeUndefined(self.arena);
                    try call_env.define(pname, av);
                }

                // NFE self-binding.
                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        call_env.define(fname, callee_val) catch {};
                    }
                }

                const num_regs = if (fn_ptr.num_regs > 0) fn_ptr.num_regs else 1;
                const new_regs = try self.arena.alloc(Value, num_regs);
                for (new_regs) |*r| r.* = Value{};

                // Copy param values into register slots.
                for (fn_ptr.param_names, 0..) |_, i| {
                    if (i < num_regs) {
                        const av: Value = if (i < nargs)
                            frame.registers[base + 2 + @as(u8, @intCast(i))]
                        else
                            try val_mod.makeUndefined(self.arena);
                        new_regs[i] = av;
                    }
                }

                if (fn_ptr.name) |fname| {
                    var is_param = false;
                    for (fn_ptr.param_names) |p| {
                        if (std.mem.eql(u8, p, fname)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) {
                        const nfe_slot = fn_ptr.param_names.len;
                        if (nfe_slot < num_regs) {
                            new_regs[nfe_slot] = callee_val;
                        }
                    }
                }

                const caller_idx = self.frames.items.len - 1;
                try self.frames.append(self.arena, BcCallFrame{
                    .func = fn_ptr,
                    .pc = 0,
                    .registers = new_regs,
                    .env = call_env,
                    .return_dst = ret_dst,
                    .caller_idx = caller_idx,
                    .this_val = this_val,
                });
                return null;
            },
            .native_function => |fn_ptr| {
                var args = try self.arena.alloc(Value, nargs);
                for (0..nargs) |i| {
                    args[i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                }
                const result = fn_ptr.invoke(self.arena, this_val, args) catch |e| {
                    if (e == error.JsException) {
                        // Phase 4b: check pending_exception.
                        const realm_mod = @import("../runtime/realm.zig");
                        if (realm_mod.pending_exception.bits != 0) {
                            self.last_exception_value = realm_mod.pending_exception;
                            realm_mod.pending_exception = Value{};
                        }
                        return "__js_exception__";
                    }
                    return try std.fmt.allocPrint(self.arena, "TypeError: native function threw", .{});
                };
                // Re-read frame after native call (may have triggered re-entrant frames + realloc).
                self.frames.items[self.frames.items.len - 1].registers[ret_dst] = result;
                return null;
            },
            .function => {
                return "TypeError: cannot call tree-walker function from bc mode";
            },
            .object => |obj| {
                // Phase 4d: bound function in method call context.
                if (obj.internal_kind == .bound_function) {
                    if (obj.internal_slot) |slot| {
                        const function_proto_mod = @import("../runtime/builtins/function_proto.zig");
                        const bd: *function_proto_mod.BoundData = @ptrCast(@alignCast(slot));
                        var args = try self.arena.alloc(Value, bd.prefix.len + nargs);
                        for (bd.prefix, 0..) |v, i| args[i] = v;
                        for (0..nargs) |i| {
                            args[bd.prefix.len + i] = frame.registers[base + 2 + @as(u8, @intCast(i))];
                        }
                        const res = bcInvokeJs(self, self.arena, bd.this_val, bd.target, args) catch |e| {
                            if (e == error.JsException) {
                                const realm_mod = @import("../runtime/realm.zig");
                                if (realm_mod.pending_exception.bits != 0) {
                                    self.last_exception_value = realm_mod.pending_exception;
                                    realm_mod.pending_exception = Value{};
                                }
                                return "__js_exception__";
                            }
                            return try std.fmt.allocPrint(self.arena, "TypeError: bound call threw", .{});
                        };
                        self.frames.items[self.frames.items.len - 1].registers[ret_dst] = res;
                        return null;
                    }
                }
                return try std.fmt.allocPrint(self.arena, "TypeError: object is not a function", .{});
            },
            else => {
                return try std.fmt.allocPrint(self.arena, "TypeError: {s} is not a function", .{typeofValue(callee_val)});
            },
        }
    }

    fn jsAdd(self: *BcVm, left: Value, right: Value) !Value {
        const ls = isStringOrObject(left);
        const rs = isStringOrObject(right);
        if (ls or rs) {
            const ls_str = try valueToString(self.arena, left);
            const rs_str = try valueToString(self.arena, right);
            const combined = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls_str, rs_str });
            return val_mod.makeString(self.arena, combined);
        }
        return val_mod.makeNumber(self.arena, toNumber(left) + toNumber(right));
    }
};

// ---------------------------------------------------------------- GC scan callback ---

/// GC root-scan callback for the bytecode VM.
/// Walks all register arrays and env chains in open call frames.
fn bcVmScanCallback(ctx: *anyopaque, mark_fn: *const fn (*JsObject) void) void {
    const vm: *BcVm = @ptrCast(@alignCast(ctx));
    for (vm.frames.items) |*frame| {
        // Registers
        for (frame.registers) |reg| {
            gc_mod.traceValue(reg, mark_fn);
        }
        // this_val
        gc_mod.traceValue(frame.this_val, mark_fn);
        // Environment chain
        gc_mod.traceEnvironment(frame.env, mark_fn);
    }
}

// ---------------------------------------------------------------- semantics helpers ---
// Mirror vm.zig exactly. These MUST stay in sync.

fn isNumberValue(v: Value) bool {
    return v.bits != 0 and v.toPtr().* == .number;
}

fn classifyTypeof(v: Value) struct {
    tag: ic_mod.TypeofTag,
    shape: ?*anyopaque,
    result: []const u8,
} {
    if (v.bits == 0) return .{ .tag = .undefined_, .shape = null, .result = "undefined" };
    return switch (v.toPtr().*) {
        .undefined_ => .{ .tag = .undefined_, .shape = null, .result = "undefined" },
        .null_ => .{ .tag = .null_, .shape = null, .result = "object" },
        .boolean => .{ .tag = .boolean, .shape = null, .result = "boolean" },
        .number => .{ .tag = .number, .shape = null, .result = "number" },
        .string => .{ .tag = .string, .shape = null, .result = "string" },
        .function, .bc_function, .native_function => .{ .tag = .function_like, .shape = null, .result = "function" },
        .object => |obj| blk: {
            const callable = obj.get("__call__") != null;
            break :blk .{
                .tag = if (callable) .function_like else .object_like,
                .shape = obj.shapePtr(),
                .result = if (callable) "function" else "object",
            };
        },
    };
}

fn jsInstanceofWithTarget(lhs: Value, target_proto: ?*JsObject) bool {
    if (lhs.bits == 0 or target_proto == null) return false;
    if (lhs.toPtr().* != .object) return false;
    var cur: ?*JsObject = lhs.toPtr().object;
    while (cur) |obj| {
        if (obj == target_proto.?) return true;
        cur = obj.proto;
    }
    return false;
}

pub fn isTruthy(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.toPtr().*) {
        .undefined_ => false,
        .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0.0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .function => true,
        .bc_function => true,
        .object => true,
        .native_function => true,
    };
}

fn isString(v: Value) bool {
    if (v.bits == 0) return false;
    return v.toPtr().* == .string;
}

fn isStringOrObject(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.toPtr().*) {
        .string => true,
        .object => true,
        else => false,
    };
}

pub fn typeofValue(v: Value) []const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.toPtr().*) {
        .undefined_ => "undefined",
        .null_ => "object",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .function => "function",
        .bc_function => "function",
        .object => |obj| if (obj.get("__call__") != null) "function" else "object",
        .native_function => "function",
    };
}

pub fn toInt32(v: Value) i32 {
    const n = toNumber(v);
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const m = @mod(@trunc(n), 4294967296.0); // [0, 2^32)
    const u: u32 = @intFromFloat(m);
    return @bitCast(u);
}

pub fn toUint32(v: Value) u32 {
    return @bitCast(toInt32(v));
}

pub fn toNumber(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.toPtr().*) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0.0,
        .boolean => |b| if (b) 1.0 else 0.0,
        .number => |n| n,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\n\r")) catch std.math.nan(f64),
        .function => std.math.nan(f64),
        .bc_function => std.math.nan(f64),
        .object => std.math.nan(f64),
        .native_function => std.math.nan(f64),
    };
}

fn valueToString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.toPtr().*) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try formatNumber(arena, n),
        .string => |s| s,
        .function => |f| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{f.name orelse ""}),
        .bc_function => |c| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{c.func.name orelse ""}),
        .object => |obj| blk: {
            if (obj.is_array) {
                var buf = std.ArrayList(u8){};
                const len = obj.getArrayLength();
                for (0..len) |i| {
                    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                    if (i > 0) try buf.append(arena, ',');
                    if (obj.get(key)) |elem| {
                        const s = valueToString(arena, elem) catch break :blk "[object Object]";
                        try buf.appendSlice(arena, s);
                    }
                }
                break :blk buf.items;
            }
            break :blk "[object Object]";
        },
        .native_function => "function () { [native code] }",
    };
}

fn valueToStringArena(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return valueToString(arena, v);
}

/// Format a thrown value as a user-facing exception message.
/// Error-like objects (have own `name` and `message` properties) format as
/// "Name: message" instead of the default "[object Object]" coercion.
pub fn formatExceptionMessage(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits != 0) {
        if (v.toPtr().* == .object) {
            const obj = v.toPtr().object;
            const name_v = obj.get("name");
            const msg_v = obj.get("message");
            if (name_v != null and msg_v != null) {
                const name_s = try valueToString(arena, name_v.?);
                const msg_s = try valueToString(arena, msg_v.?);
                return std.fmt.allocPrint(arena, "{s}: {s}", .{ name_s, msg_s });
            }
        }
    }
    return valueToString(arena, v);
}

pub fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (n == @trunc(n) and @abs(n) < 1e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn jsLessThan(left: Value, right: Value) ?bool {
    const lstr = if (left.bits != 0) left.toPtr().* == .string else false;
    const rstr = if (right.bits != 0) right.toPtr().* == .string else false;
    if (lstr and rstr) {
        return std.mem.lessThan(u8, left.toPtr().string, right.toPtr().string);
    }
    const ln = toNumber(left);
    const rn = toNumber(right);
    if (std.math.isNan(ln) or std.math.isNan(rn)) return null;
    return ln < rn;
}

fn jsAbstractEqual(x: Value, y: Value) bool {
    const tx = typeTag(x);
    const ty = typeTag(y);
    if (tx == ty) return jsStrictEqual(x, y);
    if ((tx == .null_ and ty == .undefined_) or (tx == .undefined_ and ty == .null_)) return true;
    if (tx == .number and ty == .string) return toNumber(x) == toNumber(y);
    if (tx == .string and ty == .number) return toNumber(x) == toNumber(y);
    if (tx == .boolean) {
        const bv = x.toPtr().boolean;
        const n: f64 = if (bv) 1.0 else 0.0;
        return n == toNumber(y);
    }
    if (ty == .boolean) {
        const bv = y.toPtr().boolean;
        const n: f64 = if (bv) 1.0 else 0.0;
        return toNumber(x) == n;
    }
    return false;
}

fn jsStrictEqual(x: Value, y: Value) bool {
    const tx = typeTag(x);
    const ty = typeTag(y);
    if (tx != ty) return false;
    switch (tx) {
        .undefined_ => return true,
        .null_ => return true,
        .number => {
            const xn = toNumber(x);
            const yn = toNumber(y);
            if (std.math.isNan(xn) or std.math.isNan(yn)) return false;
            return xn == yn;
        },
        .string => {
            return std.mem.eql(u8, x.toPtr().string, y.toPtr().string);
        },
        .boolean => {
            return x.toPtr().boolean == y.toPtr().boolean;
        },
        .function => return x.bits == y.bits,
        .bc_function => return x.bits == y.bits,
        .object => return x.bits == y.bits,
        .native_function => return x.bits == y.bits,
    }
}

const TypeTag = enum { undefined_, null_, boolean, number, string, function, bc_function, object, native_function };

fn typeTag(v: Value) TypeTag {
    if (v.bits == 0) return .undefined_;
    return switch (v.toPtr().*) {
        .undefined_ => .undefined_,
        .null_ => .null_,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .function => .function,
        .bc_function => .bc_function,
        .object => .object,
        .native_function => .native_function,
    };
}

/// Phase 4a: instanceof — walks lhs.__proto__ chain looking for rhs.prototype.
fn jsInstanceof(lhs: Value, rhs: Value) bool {
    // lhs must be an object.
    if (lhs.bits == 0) return false;
    if (lhs.toPtr().* != .object) return false;

    // rhs must be an object (or object-with-__call__) with a .prototype property.
    if (rhs.bits == 0) return false;
    const rhs_inner = rhs.toPtr().*;
    const target_proto: *JsObject = switch (rhs_inner) {
        .object => |obj| blk: {
            const pv = obj.get("prototype") orelse return false;
            if (pv.bits == 0) return false;
            if (pv.toPtr().* != .object) return false;
            break :blk pv.toPtr().object;
        },
        else => return false,
    };

    // Walk prototype chain of lhs.
    var cur: ?*JsObject = lhs.toPtr().object;
    while (cur) |obj| {
        if (obj == target_proto) return true;
        cur = obj.proto;
    }
    return false;
}

// ---------------------------------------------------------------- tests ---

test "BcVm: isTruthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const t = try val_mod.makeBool(alloc, true);
    const f = try val_mod.makeBool(alloc, false);
    try std.testing.expect(isTruthy(t));
    try std.testing.expect(!isTruthy(f));
    const undef = try val_mod.makeUndefined(alloc);
    try std.testing.expect(!isTruthy(undef));
}
