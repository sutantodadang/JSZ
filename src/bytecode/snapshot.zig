// SPDX-License-Identifier: MIT
//! Phase 8: bytecode caching + code snapshot/restore.
//!
//! Serializes a compiled `BcFunction` tree to a flat, sourceless binary image
//! and reads it back into a runnable tree. This is the engine's *startup
//! snapshot*: it captures compiled code (bytecode, constant pool, source-line
//! table, nested function literals) so a program can be loaded without
//! re-lexing/parsing/compiling.
//!
//! Scope note: this is a *code* image, not a *heap* image. Live objects, the
//! global environment, and GC state are NOT captured — a fresh realm is built
//! at restore time and the restored code runs against it. A full heap snapshot
//! is angle-gated (PLAN §3.5 B/D) and remains out of scope.
//!
//! Format (little-endian):
//!   magic "JSZB" | u32 version | function
//! where `function` is, recursively:
//!   optStr name | str source_name | u16 arity | u16 num_regs | u16 num_locals
//!   | u8 is_strict | u16 nparams (str…) | u32 codeLen (bytes)
//!   | u32 nlines (u32…) | u16 nconsts (value…) | u16 nchildren (function…)
//! and a `value` is: u8 tag | payload (number=f64 bits; string=u32 len+bytes).
const std = @import("std");
const Chunk = @import("./chunk.zig").Chunk;
const BcFunction = @import("./function.zig").BcFunction;
const val_mod = @import("../value/value.zig");
const Value = val_mod.Value;
const ic_mod = @import("../vm/ic.zig");

pub const MAGIC = [4]u8{ 'J', 'S', 'Z', 'B' };
pub const VERSION: u32 = 1;

pub const SnapshotError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    UnsupportedConstant,
    OutOfMemory,
};

const ValueTag = enum(u8) {
    undefined_ = 0,
    null_ = 1,
    false_ = 2,
    true_ = 3,
    number = 4,
    string = 5,
};

// ----------------------------------------------------------------- writer ---

const Writer = struct {
    buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn u8v(self: *Writer, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }
    fn u16v(self: *Writer, v: u16) !void {
        try self.buf.appendSlice(self.alloc, &@as([2]u8, @bitCast(v)));
    }
    fn u32v(self: *Writer, v: u32) !void {
        try self.buf.appendSlice(self.alloc, &@as([4]u8, @bitCast(v)));
    }
    fn u64v(self: *Writer, v: u64) !void {
        try self.buf.appendSlice(self.alloc, &@as([8]u8, @bitCast(v)));
    }
    fn bytes(self: *Writer, b: []const u8) !void {
        try self.buf.appendSlice(self.alloc, b);
    }
    fn str(self: *Writer, s: []const u8) !void {
        try self.u32v(@intCast(s.len));
        try self.bytes(s);
    }
    fn optStr(self: *Writer, s: ?[]const u8) !void {
        if (s) |x| {
            try self.u8v(1);
            try self.str(x);
        } else {
            try self.u8v(0);
        }
    }
    fn value(self: *Writer, v: Value) !void {
        if (v.bits == 0) {
            try self.u8v(@intFromEnum(ValueTag.undefined_));
            return;
        }
        switch (v.toPtr().*) {
            .undefined_ => try self.u8v(@intFromEnum(ValueTag.undefined_)),
            .null_ => try self.u8v(@intFromEnum(ValueTag.null_)),
            .boolean => |b| try self.u8v(@intFromEnum(if (b) ValueTag.true_ else ValueTag.false_)),
            .number => |n| {
                try self.u8v(@intFromEnum(ValueTag.number));
                try self.u64v(@bitCast(n));
            },
            .string => |s| {
                try self.u8v(@intFromEnum(ValueTag.string));
                try self.str(s);
            },
            // Constant pools only ever hold primitives; anything else is a bug.
            else => return error.UnsupportedConstant,
        }
    }
};

// ----------------------------------------------------------------- reader ---

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn need(self: *Reader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.Truncated;
    }
    fn u8v(self: *Reader) !u8 {
        try self.need(1);
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn u16v(self: *Reader) !u16 {
        try self.need(2);
        const v: u16 = @bitCast(self.data[self.pos..][0..2].*);
        self.pos += 2;
        return v;
    }
    fn u32v(self: *Reader) !u32 {
        try self.need(4);
        const v: u32 = @bitCast(self.data[self.pos..][0..4].*);
        self.pos += 4;
        return v;
    }
    fn u64v(self: *Reader) !u64 {
        try self.need(8);
        const v: u64 = @bitCast(self.data[self.pos..][0..8].*);
        self.pos += 8;
        return v;
    }
    fn bytesDup(self: *Reader, alloc: std.mem.Allocator, n: usize) ![]u8 {
        try self.need(n);
        const out = try alloc.dupe(u8, self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return out;
    }
    fn str(self: *Reader, alloc: std.mem.Allocator) ![]const u8 {
        const n = try self.u32v();
        return self.bytesDup(alloc, n);
    }
    fn optStr(self: *Reader, alloc: std.mem.Allocator) !?[]const u8 {
        const present = try self.u8v();
        if (present == 0) return null;
        return try self.str(alloc);
    }
    fn value(self: *Reader, alloc: std.mem.Allocator) !Value {
        const tag: ValueTag = @enumFromInt(try self.u8v());
        return switch (tag) {
            .undefined_ => try val_mod.makeUndefined(alloc),
            .null_ => try val_mod.makeNull(alloc),
            .false_ => try val_mod.makeBool(alloc, false),
            .true_ => try val_mod.makeBool(alloc, true),
            .number => try val_mod.makeNumber(alloc, @bitCast(try self.u64v())),
            .string => try val_mod.makeString(alloc, try self.str(alloc)),
        };
    }
};

// --------------------------------------------------------------- public API ---

/// Serialize a compiled function tree into a sourceless bytecode image.
/// Caller owns the returned bytes.
pub fn serialize(allocator: std.mem.Allocator, func: *const BcFunction) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    var w = Writer{ .buf = &buf, .alloc = allocator };
    try w.bytes(&MAGIC);
    try w.u32v(VERSION);
    try writeFunction(&w, func);
    return buf.toOwnedSlice(allocator);
}

fn writeFunction(w: *Writer, f: *const BcFunction) !void {
    try w.optStr(f.name);
    try w.str(f.chunk.source_name);
    try w.u16v(f.arity);
    try w.u16v(f.num_regs);
    try w.u16v(f.chunk.num_locals);
    try w.u8v(if (f.is_strict) 1 else 0);

    try w.u16v(@intCast(f.param_names.len));
    for (f.param_names) |p| try w.str(p);

    try w.u32v(@intCast(f.chunk.code.len));
    try w.bytes(f.chunk.code);

    try w.u32v(@intCast(f.chunk.lines.len));
    for (f.chunk.lines) |ln| try w.u32v(ln);

    try w.u16v(@intCast(f.chunk.constants.len));
    for (f.chunk.constants) |c| try w.value(c);

    try w.u16v(@intCast(f.child_functions.len));
    for (f.child_functions) |child| try writeFunction(w, child);
}

/// Restore a function tree from a bytecode image. Everything is allocated in
/// `arena`. IC feedback tables are reset (empty) — they re-warm at runtime.
pub fn deserialize(arena: std.mem.Allocator, data: []const u8) !*BcFunction {
    var r = Reader{ .data = data };
    try r.need(4);
    if (!std.mem.eql(u8, r.data[0..4], &MAGIC)) return error.BadMagic;
    r.pos = 4;
    const ver = try r.u32v();
    if (ver != VERSION) return error.UnsupportedVersion;
    return readFunction(&r, arena);
}

fn readFunction(r: *Reader, arena: std.mem.Allocator) (SnapshotError)!*BcFunction {
    const name = try r.optStr(arena);
    const source_name = try r.str(arena);
    const arity = try r.u16v();
    const num_regs = try r.u16v();
    const num_locals = try r.u16v();
    const is_strict = (try r.u8v()) != 0;

    const nparams = try r.u16v();
    const param_names = try arena.alloc([]const u8, nparams);
    for (param_names) |*p| p.* = try r.str(arena);

    const code_len = try r.u32v();
    const code = try r.bytesDup(arena, code_len);

    const nlines = try r.u32v();
    const lines = try arena.alloc(u32, nlines);
    for (lines) |*ln| ln.* = try r.u32v();

    const nconsts = try r.u16v();
    const constants = try arena.alloc(Value, nconsts);
    for (constants) |*c| c.* = try r.value(arena);

    const nchildren = try r.u16v();
    const children = try arena.alloc(*BcFunction, nchildren);
    for (children) |*ch| ch.* = try readFunction(r, arena);

    // Fresh IC tables, sized to the code length (as the compiler does).
    const ic_table = try arena.alloc(ic_mod.InlineCache, code.len);
    for (ic_table) |*e| e.* = ic_mod.InlineCache{};
    const arith_ic_table = try arena.alloc(ic_mod.ArithCache, code.len);
    for (arith_ic_table) |*e| e.* = ic_mod.ArithCache{};
    const typeof_ic_table = try arena.alloc(ic_mod.TypeofCache, code.len);
    for (typeof_ic_table) |*e| e.* = ic_mod.TypeofCache{};
    const instanceof_ic_table = try arena.alloc(ic_mod.InstanceofCache, code.len);
    for (instanceof_ic_table) |*e| e.* = ic_mod.InstanceofCache{};

    const f = try arena.create(BcFunction);
    f.* = BcFunction{
        .name = name,
        .arity = arity,
        .chunk = Chunk{
            .code = code,
            .constants = constants,
            .lines = lines,
            .source_name = source_name,
            .num_locals = num_locals,
        },
        .num_regs = num_regs,
        .child_functions = children,
        .param_names = param_names,
        .is_strict = is_strict,
        .ic_table = ic_table,
        .arith_ic_table = arith_ic_table,
        .typeof_ic_table = typeof_ic_table,
        .instanceof_ic_table = instanceof_ic_table,
    };
    return f;
}

// ------------------------------------------------------------------ tests ---

const compiler_mod = @import("./compiler.zig");
const parser_mod = @import("../parser/parser.zig");
const ast = @import("../parser/ast.zig");

fn compile(arena: std.mem.Allocator, src: []const u8) !*BcFunction {
    var p = parser_mod.Parser.init(src, arena);
    const stmts = switch (p.parseScript()) {
        .ok => |s| s,
        .err => return error.ParseFailed,
    };
    const prog = ast.Program{ .body = stmts };
    return compiler_mod.compileProgram(arena, &prog, "<snap>");
}

test "snapshot: round-trip preserves code, constants, children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f = try compile(a, "function add(x,y){ return x+y; } var s = 'hi'; add(40,2)");
    const blob = try serialize(a, f);
    const g = try deserialize(a, blob);

    try std.testing.expectEqualSlices(u8, f.chunk.code, g.chunk.code);
    try std.testing.expectEqual(f.chunk.constants.len, g.chunk.constants.len);
    try std.testing.expectEqual(f.child_functions.len, g.child_functions.len);
    try std.testing.expectEqual(f.num_regs, g.num_regs);
    try std.testing.expectEqualStrings(f.child_functions[0].name.?, g.child_functions[0].name.?);
    // String constant survives.
    var found_hi = false;
    for (g.chunk.constants) |c| {
        if (c.bits != 0 and c.toPtr().* == .string and std.mem.eql(u8, c.toPtr().string, "hi")) found_hi = true;
    }
    try std.testing.expect(found_hi);
}

test "snapshot: bad magic rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadMagic, deserialize(arena.allocator(), "XXXXnope"));
}

test "snapshot: truncated rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try compile(a, "1+2");
    const blob = try serialize(a, f);
    try std.testing.expectError(error.Truncated, deserialize(a, blob[0 .. blob.len - 3]));
}
