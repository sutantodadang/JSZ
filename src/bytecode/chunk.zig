// SPDX-License-Identifier: Apache-2.0
//! Bytecode chunk: code bytes, constant pool, line info, disassembler.
const std = @import("std");
const Value = @import("../value/value.zig").Value;
const JsValue = @import("../value/value.zig").JsValue;
const val_mod = @import("../value/value.zig");
const Op = @import("./opcodes.zig").Op;
const instrSize = @import("./opcodes.zig").instrSize;

pub const Chunk = struct {
    code: []u8,
    constants: []Value,
    lines: []u32,
    source_name: []const u8,
    num_locals: u16,
};

pub const ChunkBuilder = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    constants: std.ArrayListUnmanaged(Value) = .empty,
    lines: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) ChunkBuilder {
        return ChunkBuilder{ .allocator = allocator };
    }

    pub fn emitOp(self: *Self, op: Op, line: u32) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
        try self.lines.append(self.allocator, line);
    }

    pub fn emitU8(self: *Self, v: u8) !void {
        try self.code.append(self.allocator, v);
        // Operand bytes share the line of the preceding opcode; use last line.
        const last_line: u32 = if (self.lines.items.len > 0)
            self.lines.items[self.lines.items.len - 1]
        else
            0;
        try self.lines.append(self.allocator, last_line);
    }

    pub fn emitU16(self: *Self, v: u16) !void {
        const lo: u8 = @intCast(v & 0xFF);
        const hi: u8 = @intCast((v >> 8) & 0xFF);
        try self.emitU8(lo);
        try self.emitU8(hi);
    }

    pub fn emitI16(self: *Self, v: i16) !void {
        try self.emitU16(@bitCast(v));
    }

    /// Add a constant to the pool. Returns its index (max 65535).
    /// Deduplicates number constants and string constants when cheap.
    pub fn addConstant(self: *Self, v: Value) !u16 {
        // Deduplicate: scan existing constants.
        if (v.bits != 0) {
            const inner = v.unbox();
            for (self.constants.items, 0..) |c, i| {
                if (c.bits == 0) continue;
                const ci = c.unbox();
                switch (inner) {
                    .number => |n| switch (ci) {
                        .number => |cn| {
                            // Same bits means same value (handles NaN identity too — OK for constants).
                            if (@as(u64, @bitCast(n)) == @as(u64, @bitCast(cn))) {
                                return @intCast(i);
                            }
                        },
                        else => {},
                    },
                    .string => |s| switch (ci) {
                        .string => |cs| {
                            if (std.mem.eql(u8, s, cs)) {
                                return @intCast(i);
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
        const idx = self.constants.items.len;
        if (idx > 0xFFFF) return error.OutOfMemory; // too many constants
        try self.constants.append(self.allocator, v);
        return @intCast(idx);
    }

    pub fn currentOffset(self: *const Self) usize {
        return self.code.items.len;
    }

    /// Emit a placeholder JMP/JMP_IF_* operand that will be patched.
    /// Returns the offset of the i16 operand in the code buffer.
    /// Caller should emit the Rcond byte (if any) before calling this
    /// and pass the offset of the i16 bytes here.
    pub fn emitJumpPlaceholder(self: *Self) !usize {
        const offset = self.code.items.len;
        try self.emitI16(0);
        return offset;
    }

    /// Patch a previously emitted jump at code[at..at+2] to jump to target.
    /// offset encodes as (target - (at + 2)) as i16 LE.
    pub fn patchJump(self: *Self, at: usize, target: usize) void {
        const diff: i64 = @intCast(target);
        const base: i64 = @intCast(at + 2);
        const rel: i16 = @intCast(diff - base);
        const bytes: [2]u8 = @bitCast(rel);
        self.code.items[at] = bytes[0];
        self.code.items[at + 1] = bytes[1];
    }

    pub fn finalize(self: *Self, source_name: []const u8, num_locals: u16) !Chunk {
        return Chunk{
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .lines = try self.lines.toOwnedSlice(self.allocator),
            .source_name = source_name,
            .num_locals = num_locals,
        };
    }
};

/// Disassemble one instruction; returns new pc.
fn disasmOne(chunk: *const Chunk, pc: usize, writer: anytype) !usize {
    const code = chunk.code;
    const line: u32 = if (pc < chunk.lines.len) chunk.lines[pc] else 0;
    const op: Op = @enumFromInt(code[pc]);
    try writer.print("{d:04} ({d:4}) {s:<16}", .{ pc, line, @tagName(op) });
    var new_pc = pc + 1;
    switch (op) {
        .LOAD_K => {
            const rdst = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    const inner = cv.unbox();
                    switch (inner) {
                        .number => |n| try writer.print(" R{d} K{d}  ; const={d}", .{ rdst, kidx, n }),
                        .string => |s| try writer.print(" R{d} K{d}  ; const=\"{s}\"", .{ rdst, kidx, s }),
                        else => try writer.print(" R{d} K{d}", .{ rdst, kidx }),
                    }
                } else {
                    try writer.print(" R{d} K{d}", .{ rdst, kidx });
                }
            } else {
                try writer.print(" R{d} K{d}", .{ rdst, kidx });
            }
        },
        .LOAD_TRUE, .LOAD_FALSE, .LOAD_NULL, .LOAD_UNDEF => {
            const rdst = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{rdst});
        },
        .MOVE => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} R{d}", .{ rdst, rsrc });
        },
        .YIELD => {
            const r = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{r});
        },
        .GET_GLOBAL, .GET_GLOBAL_OPT => {
            const rdst = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    const inner = cv.unbox();
                    switch (inner) {
                        .string => |s| try writer.print(" R{d} \"{s}\"", .{ rdst, s }),
                        else => try writer.print(" R{d} K{d}", .{ rdst, kidx }),
                    }
                } else {
                    try writer.print(" R{d} K{d}", .{ rdst, kidx });
                }
            } else {
                try writer.print(" R{d} K{d}", .{ rdst, kidx });
            }
        },
        .SET_GLOBAL => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            const rsrc = code[new_pc];
            new_pc += 1;
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    const inner = cv.unbox();
                    switch (inner) {
                        .string => |s| try writer.print(" \"{s}\" R{d}", .{ s, rsrc }),
                        else => try writer.print(" K{d} R{d}", .{ kidx, rsrc }),
                    }
                } else {
                    try writer.print(" K{d} R{d}", .{ kidx, rsrc });
                }
            } else {
                try writer.print(" K{d} R{d}", .{ kidx, rsrc });
            }
        },
        .GET_LOCAL => {
            const rdst = code[new_pc];
            new_pc += 1;
            const slot = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} slot{d}", .{ rdst, slot });
        },
        .SET_LOCAL => {
            const slot = code[new_pc];
            new_pc += 1;
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" slot{d} R{d}", .{ slot, rsrc });
        },
        .ADD, .SUB, .MUL, .DIV, .MOD, .EXP, .BIT_AND, .BIT_OR, .BIT_XOR, .SHL, .SHR, .USHR, .EQ, .NEQ, .SEQ, .SNEQ, .LT, .LE, .GT, .GE => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rlhs = code[new_pc];
            new_pc += 1;
            const rrhs = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} R{d} R{d}", .{ rdst, rlhs, rrhs });
        },
        .NEG, .BIT_NOT, .NOT, .TYPEOF => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} R{d}", .{ rdst, rsrc });
        },
        .JMP => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
            const target: i64 = @intCast(new_pc);
            try writer.print(" -> {d}", .{target + offset});
        },
        .JMP_IF_TRUE, .JMP_IF_FALSE => {
            const rcond = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
            const target: i64 = @intCast(new_pc);
            try writer.print(" R{d} -> {d}", .{ rcond, target + offset });
        },
        .NEW_CLOSURE => {
            const rdst = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const fidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            try writer.print(" R{d} func[{d}]", .{ rdst, fidx });
        },
        .CALL, .TAIL_CALL => {
            const base = code[new_pc];
            new_pc += 1;
            const nargs = code[new_pc];
            new_pc += 1;
            const ret_dst = code[new_pc];
            new_pc += 1;
            try writer.print(" base=R{d} nargs={d} ret=R{d}", .{ base, nargs, ret_dst });
        },
        .RETURN => {
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{rsrc});
        },
        .RETURN_UNDEF, .HALT, .DEBUGGER => {},
        // Phase 3a
        .NEW_OBJECT => {
            const rdst = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{rdst});
        },
        .NEW_ARRAY => {
            const rdst = code[new_pc];
            new_pc += 1;
            const len = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} len={d}", .{ rdst, len });
        },
        .SET_PROP => {
            const robj = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            const rval = code[new_pc];
            new_pc += 1;
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    switch (cv.unbox()) {
                        .string => |s| try writer.print(" R{d}[\"{s}\"] = R{d}", .{ robj, s, rval }),
                        else => try writer.print(" R{d}[K{d}] = R{d}", .{ robj, kidx, rval }),
                    }
                } else {
                    try writer.print(" R{d}[K{d}] = R{d}", .{ robj, kidx, rval });
                }
            } else {
                try writer.print(" R{d}[K{d}] = R{d}", .{ robj, kidx, rval });
            }
        },
        .DEFINE_ACCESSOR => {
            const robj = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            const kind = code[new_pc];
            new_pc += 1;
            const rfn = code[new_pc];
            new_pc += 1;
            const knd: []const u8 = if (kind == 0) "get" else "set";
            if (kidx < chunk.constants.len and chunk.constants[kidx].bits != 0) {
                switch (chunk.constants[kidx].unbox()) {
                    .string => |s| try writer.print(" R{d}[\"{s}\"] {s}= R{d}", .{ robj, s, knd, rfn }),
                    else => try writer.print(" R{d}[K{d}] {s}= R{d}", .{ robj, kidx, knd, rfn }),
                }
            } else {
                try writer.print(" R{d}[K{d}] {s}= R{d}", .{ robj, kidx, knd, rfn });
            }
        },
        .ARRAY_APPEND => {
            const rarr = code[new_pc];
            new_pc += 1;
            const rval = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} += R{d}", .{ rarr, rval });
        },
        .ARRAY_SPREAD => {
            const rarr = code[new_pc];
            new_pc += 1;
            const riter = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} += ...R{d}", .{ rarr, riter });
        },
        .IN => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rkey = code[new_pc];
            new_pc += 1;
            const robj = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = R{d} in R{d}", .{ rdst, rkey, robj });
        },
        .DELETE_PROP => {
            const rdst = code[new_pc];
            new_pc += 1;
            const robj = code[new_pc];
            new_pc += 1;
            const rkey = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = delete R{d}[R{d}]", .{ rdst, robj, rkey });
        },
        .CALL_SPREAD => {
            const rcallee = code[new_pc];
            new_pc += 1;
            const rthis = code[new_pc];
            new_pc += 1;
            const rargs = code[new_pc];
            new_pc += 1;
            const rdst = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = R{d}.call(R{d}, ...R{d})", .{ rdst, rcallee, rthis, rargs });
        },
        .GET_PROP => {
            const rdst = code[new_pc];
            new_pc += 1;
            const robj = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    switch (cv.unbox()) {
                        .string => |s| try writer.print(" R{d} = R{d}[\"{s}\"]", .{ rdst, robj, s }),
                        else => try writer.print(" R{d} = R{d}[K{d}]", .{ rdst, robj, kidx }),
                    }
                } else {
                    try writer.print(" R{d} = R{d}[K{d}]", .{ rdst, robj, kidx });
                }
            } else {
                try writer.print(" R{d} = R{d}[K{d}]", .{ rdst, robj, kidx });
            }
        },
        .SET_PROP_DYN => {
            const robj = code[new_pc];
            new_pc += 1;
            const rkey = code[new_pc];
            new_pc += 1;
            const rval = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}[R{d}] = R{d}", .{ robj, rkey, rval });
        },
        .GET_PROP_DYN => {
            const rdst = code[new_pc];
            new_pc += 1;
            const robj = code[new_pc];
            new_pc += 1;
            const rkey = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = R{d}[R{d}]", .{ rdst, robj, rkey });
        },
        .GET_THIS => {
            const rdst = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{rdst});
        },
        .METHOD_CALL, .TAIL_METHOD_CALL => {
            const base = code[new_pc];
            new_pc += 1;
            const nargs = code[new_pc];
            new_pc += 1;
            const ret_dst = code[new_pc];
            new_pc += 1;
            try writer.print(" this=R{d} fn=R{d} nargs={d} ret=R{d}", .{ base, base + 1, nargs, ret_dst });
        },
        // Phase 4a opcodes
        .THROW => {
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d}", .{rsrc});
        },
        .PUSH_TRY => {
            const rexc = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
            try writer.print(" exc=R{d} handler_off={d}", .{ rexc, offset });
        },
        .POP_TRY => {},
        .ENTER_SCOPE, .EXIT_SCOPE => {},
        .NEW_INSTANCE => {
            const rdst = code[new_pc];
            new_pc += 1;
            const base = code[new_pc];
            new_pc += 1;
            const nargs = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} ctor=R{d} nargs={d}", .{ rdst, base, nargs });
        },
        .INSTANCEOF => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rlhs = code[new_pc];
            new_pc += 1;
            const rrhs = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = R{d} instanceof R{d}", .{ rdst, rlhs, rrhs });
        },
        // Phase 4d
        .GET_KEYS => {
            const rdst = code[new_pc];
            new_pc += 1;
            const robj = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} = keys(R{d})", .{ rdst, robj });
        },
        .INC, .DEC => {
            const rdst = code[new_pc];
            new_pc += 1;
            const rsrc = code[new_pc];
            new_pc += 1;
            try writer.print(" R{d} R{d}", .{ rdst, rsrc });
        },
        .JSEQ, .JGE => {
            const rlhs = code[new_pc];
            new_pc += 1;
            const rrhs = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
            const target: i64 = @intCast(new_pc);
            try writer.print(" R{d} R{d} -> {d}", .{ rlhs, rrhs, target + offset });
        },
        .HOIST_VAR => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            if (kidx < chunk.constants.len and chunk.constants[kidx].bits != 0) {
                const inner = chunk.constants[kidx].unbox();
                switch (inner) {
                    .string => |s| try writer.print(" \"{s}\"", .{s}),
                    else => try writer.print(" K{d}", .{kidx}),
                }
            } else {
                try writer.print(" K{d}", .{kidx});
            }
        },
        .HOIST_LEX => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            if (kidx < chunk.constants.len and chunk.constants[kidx].bits != 0) {
                const inner = chunk.constants[kidx].unbox();
                switch (inner) {
                    .string => |s| try writer.print(" \"{s}\"", .{s}),
                    else => try writer.print(" K{d}", .{kidx}),
                }
            } else {
                try writer.print(" K{d}", .{kidx});
            }
        },
        .INIT_LEX => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            const rsrc = code[new_pc];
            new_pc += 1;
            const is_const = code[new_pc] != 0;
            new_pc += 1;
            const kind_str: []const u8 = if (is_const) " const" else "";
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    const inner = cv.unbox();
                    switch (inner) {
                        .string => |s| try writer.print(" \"{s}\" R{d}{s}", .{ s, rsrc, kind_str }),
                        else => try writer.print(" K{d} R{d}{s}", .{ kidx, rsrc, kind_str }),
                    }
                } else {
                    try writer.print(" K{d} R{d}{s}", .{ kidx, rsrc, kind_str });
                }
            } else {
                try writer.print(" K{d} R{d}{s}", .{ kidx, rsrc, kind_str });
            }
        },
        .DEFINE_GLOBAL => {
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
            const rsrc = code[new_pc];
            new_pc += 1;
            if (kidx < chunk.constants.len) {
                const cv = chunk.constants[kidx];
                if (cv.bits != 0) {
                    const inner = cv.unbox();
                    switch (inner) {
                        .string => |s| try writer.print(" \"{s}\" R{d}", .{ s, rsrc }),
                        else => try writer.print(" K{d} R{d}", .{ kidx, rsrc }),
                    }
                } else {
                    try writer.print(" K{d} R{d}", .{ kidx, rsrc });
                }
            } else {
                try writer.print(" K{d} R{d}", .{ kidx, rsrc });
            }
        },
        .JMP_IF_NULLISH, .JMP_IF_NOT_NULLISH => {
            const rcond = code[new_pc];
            new_pc += 1;
            const lo = code[new_pc];
            new_pc += 1;
            const hi = code[new_pc];
            new_pc += 1;
            const offset: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
            const target: i64 = @intCast(new_pc);
            try writer.print(" R{d} -> {d}", .{ rcond, target + offset });
        },
    }
    try writer.print("\n", .{});
    return new_pc;
}

pub fn disassemble(chunk: *const Chunk, writer: anytype) !void {
    try writer.print("=== {s} ({d} bytes, {d} consts, {d} locals) ===\n", .{
        chunk.source_name,
        chunk.code.len,
        chunk.constants.len,
        chunk.num_locals,
    });
    var pc: usize = 0;
    while (pc < chunk.code.len) {
        pc = try disasmOne(chunk, pc, writer);
    }
}

test "ChunkBuilder basic emit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = ChunkBuilder.init(arena.allocator());
    try b.emitOp(.HALT, 1);
    const chunk = try b.finalize("<test>", 0);
    try std.testing.expectEqual(@as(usize, 1), chunk.code.len);
    try std.testing.expect(chunk.code[0] == @intFromEnum(Op.HALT));
}

test "ChunkBuilder addConstant dedup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var b = ChunkBuilder.init(alloc);
    const v1 = try val_mod.makeNumber(alloc, 42.0);
    const v2 = try val_mod.makeNumber(alloc, 42.0);
    const idx1 = try b.addConstant(v1);
    const idx2 = try b.addConstant(v2);
    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expectEqual(@as(usize, 1), b.constants.items.len);
}
