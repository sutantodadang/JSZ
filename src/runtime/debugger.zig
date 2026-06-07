// SPDX-License-Identifier: Apache-2.0
//! Phase 8: source maps + debugger protocol stubs.
//!
//! Two things live here:
//!
//!   1. A *source map* emitter that maps bytecode offsets back to positions in
//!      the original source. Each opcode carries the byte offset of the AST node
//!      that produced it (`Chunk.lines[pc]`); we convert that to line/column and
//!      emit a compact JSON document (one entry per source-position change, per
//!      function, recursing into nested function literals).
//!
//!   2. A *debugger protocol* surface. This is intentionally a stub (per the
//!      plan: "source maps, full debugger protocol — stubs only"). Breakpoint
//!      bookkeeping and the `debugger;` hook are real; execution control
//!      (stepping, pause, live stack inspection) returns `error.NotImplemented`.
//!
//! The `debugger;` statement compiles to a `DEBUGGER` opcode. When the VM hits
//! it, it fires `active_hook` (if installed) with a `DebugStop`. This mirrors
//! the global-`active_context` pattern already used by realm.zig so no per-VM
//! plumbing is required.
const std = @import("std");
const BcFunction = @import("../bytecode/function.zig").BcFunction;
const Op = @import("../bytecode/opcodes.zig").Op;
const instrSize = @import("../bytecode/opcodes.zig").instrSize;

// --------------------------------------------------------------- positions ---

pub const SourcePosition = struct {
    /// Byte offset into the original source.
    offset: u32,
    /// 1-based line number.
    line: u32,
    /// 0-based column (UTF-8 byte column), source-map convention.
    column: u32,
};

/// Convert a byte offset into a (1-based line, 0-based column) position.
pub fn offsetToLineCol(source: []const u8, offset: u32) SourcePosition {
    var line: u32 = 1;
    var col: u32 = 0;
    const end = @min(offset, @as(u32, @intCast(source.len)));
    var i: u32 = 0;
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .offset = offset, .line = line, .column = col };
}

// -------------------------------------------------------------- source map ---

/// Write a JSON source map for `func` (and its nested function literals) to
/// `writer`. The map is jsz-native (not Source Map v3 VLQ): there is no
/// generated text stream, only a bytecode→source position table, which is what
/// a bytecode debugger actually needs.
pub fn writeSourceMap(writer: anytype, source: []const u8, source_name: []const u8, func: *const BcFunction) !void {
    try writer.writeAll("{\"version\":3,\"engine\":\"jsz-bytecode\",\"source\":\"");
    try writeJsonString(writer, source_name);
    try writer.writeAll("\",\"functions\":[");
    var first = true;
    try writeFunctionMap(writer, source, func, &first);
    try writer.writeAll("]}");
}

fn writeFunctionMap(writer: anytype, source: []const u8, func: *const BcFunction, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;

    try writer.writeAll("{\"name\":\"");
    try writeJsonString(writer, func.name orelse "<anonymous>");
    try writer.print("\",\"codeSize\":{d},\"mappings\":[", .{func.chunk.code.len});

    const code = func.chunk.code;
    const lines = func.chunk.lines;
    var pc: usize = 0;
    var emitted = false;
    var last_line: u32 = 0;
    var last_col: u32 = 0;
    var any = false;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const off: u32 = if (pc < lines.len) lines[pc] else 0;
        const pos = offsetToLineCol(source, off);
        if (!any or pos.line != last_line or pos.column != last_col) {
            if (emitted) try writer.writeAll(",");
            try writer.print("{{\"pc\":{d},\"line\":{d},\"column\":{d}}}", .{ pc, pos.line, pos.column });
            emitted = true;
            last_line = pos.line;
            last_col = pos.column;
            any = true;
        }
        pc += instrSize(op);
    }
    try writer.writeAll("]}");

    // Recurse into nested function literals.
    for (func.child_functions) |child| {
        try writeFunctionMap(writer, source, child, first);
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

// ------------------------------------------------------- debugger protocol ---

pub const DebugError = error{NotImplemented};

/// Why execution stopped. Only `.debugger_statement` is wired up today.
pub const StopReason = enum {
    entry,
    debugger_statement,
    breakpoint,
    step,
    pause,
};

/// Minimal info handed to a debug hook when a `DEBUGGER` opcode executes.
pub const DebugStop = struct {
    reason: StopReason,
    source_name: []const u8,
    /// Byte offset of the source position responsible for the current opcode.
    source_offset: u32,
    function_name: []const u8,
    /// Bytecode program counter of the DEBUGGER opcode.
    pc: usize,
};

pub const Breakpoint = struct {
    id: u32,
    source: []const u8,
    line: u32,
    enabled: bool = true,
};

pub const StackFrameInfo = struct {
    function_name: []const u8,
    source_name: []const u8,
    position: SourcePosition,
};

/// A debug-adapter-style session. Breakpoint bookkeeping is real; execution
/// control is a stub (returns error.NotImplemented) — see module doc comment.
pub const DebugSession = struct {
    allocator: std.mem.Allocator,
    breakpoints: std.ArrayListUnmanaged(Breakpoint) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) DebugSession {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DebugSession) void {
        self.breakpoints.deinit(self.allocator);
    }

    /// Register a line breakpoint. Returns its id. (Bookkeeping is functional;
    /// the VM does not yet honor breakpoints during execution.)
    pub fn setBreakpoint(self: *DebugSession, source: []const u8, line: u32) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.breakpoints.append(self.allocator, .{ .id = id, .source = source, .line = line });
        return id;
    }

    /// Remove a breakpoint by id. Returns true if one was removed.
    pub fn removeBreakpoint(self: *DebugSession, id: u32) bool {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == id) {
                _ = self.breakpoints.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn listBreakpoints(self: *const DebugSession) []const Breakpoint {
        return self.breakpoints.items;
    }

    // --- execution control: stubs (Phase 8 surface only) ---
    pub fn cont(_: *DebugSession) DebugError!void {
        return error.NotImplemented;
    }
    pub fn stepOver(_: *DebugSession) DebugError!void {
        return error.NotImplemented;
    }
    pub fn stepInto(_: *DebugSession) DebugError!void {
        return error.NotImplemented;
    }
    pub fn stepOut(_: *DebugSession) DebugError!void {
        return error.NotImplemented;
    }
    pub fn pause(_: *DebugSession) DebugError!void {
        return error.NotImplemented;
    }
    pub fn stackTrace(_: *DebugSession) DebugError![]StackFrameInfo {
        return error.NotImplemented;
    }
};

// ------------------------------------------------------------- global hook ---

pub const DebugHook = *const fn (ctx: ?*anyopaque, stop: DebugStop) void;

/// Installed debug hook, fired by the VM on a DEBUGGER opcode. Null = no-op.
pub var active_hook: ?DebugHook = null;
/// Opaque context passed back to the hook.
pub var active_hook_ctx: ?*anyopaque = null;

pub fn installHook(hook: DebugHook, ctx: ?*anyopaque) void {
    active_hook = hook;
    active_hook_ctx = ctx;
}

pub fn clearHook() void {
    active_hook = null;
    active_hook_ctx = null;
}

// ------------------------------------------------------------------ tests ---

test "offsetToLineCol: multi-line" {
    const src = "a\nbc\ndef";
    try std.testing.expectEqual(@as(u32, 1), offsetToLineCol(src, 0).line);
    try std.testing.expectEqual(@as(u32, 0), offsetToLineCol(src, 0).column);
    // offset 2 = 'b' on line 2, col 0
    try std.testing.expectEqual(@as(u32, 2), offsetToLineCol(src, 2).line);
    try std.testing.expectEqual(@as(u32, 0), offsetToLineCol(src, 2).column);
    // offset 6 = 'e' on line 3, col 1
    try std.testing.expectEqual(@as(u32, 3), offsetToLineCol(src, 6).line);
    try std.testing.expectEqual(@as(u32, 1), offsetToLineCol(src, 6).column);
}

test "DebugSession: breakpoint bookkeeping" {
    var s = DebugSession.init(std.testing.allocator);
    defer s.deinit();
    const a = try s.setBreakpoint("x.js", 10);
    const b = try s.setBreakpoint("x.js", 20);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 2), s.listBreakpoints().len);
    try std.testing.expect(s.removeBreakpoint(a));
    try std.testing.expect(!s.removeBreakpoint(a));
    try std.testing.expectEqual(@as(usize, 1), s.listBreakpoints().len);
}

test "DebugSession: execution control is stubbed" {
    var s = DebugSession.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectError(error.NotImplemented, s.cont());
    try std.testing.expectError(error.NotImplemented, s.stepOver());
    try std.testing.expectError(error.NotImplemented, s.stackTrace());
}
