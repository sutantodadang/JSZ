// SPDX-License-Identifier: Apache-2.0
//! console global: log / error / warn / info / debug
//! Display logic mirrors root.zig:valueToDisplayString (kept local to avoid
//! circular imports: root imports the runtime).
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;

/// Convert a Value to a console display string.
/// Mirrors root.zig:valueToDisplayString without importing it.
fn displayString(arena: std.mem.Allocator, v: Value) ![]const u8 {
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| try val_mod.formatNumber(arena, n),
        .string => |s| try arena.dupe(u8, s),
        .function => |f| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{f.name orelse ""}),
        .bc_function => |c| try std.fmt.allocPrint(arena, "function {s}() {{ [native code] }}", .{c.func.name orelse ""}),
        .native_function => try arena.dupe(u8, "function () { [native code] }"),
        .symbol => |sd| try std.fmt.allocPrint(arena, "Symbol({s})", .{sd.description orelse ""}),
        .object => |obj| blk: {
            if (obj.is_array) {
                var buf = std.ArrayList(u8){};
                const len = obj.getArrayLength();
                for (0..len) |i| {
                    const key = try std.fmt.allocPrint(arena, "{d}", .{i});
                    if (i > 0) try buf.append(arena, ',');
                    if (obj.get(key)) |elem| {
                        const elem_inner = val_mod.Value{ .bits = elem.bits };
                        if (elem_inner.bits != 0) {
                            switch (elem_inner.unbox()) {
                                .number => |n| {
                                    const s2 = try val_mod.formatNumber(arena, n);
                                    try buf.appendSlice(arena, s2);
                                },
                                .string => |s2| try buf.appendSlice(arena, s2),
                                .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
                                .null_ => {},
                                .undefined_ => {},
                                else => try buf.appendSlice(arena, "[object Object]"),
                            }
                        }
                    }
                }
                break :blk try arena.dupe(u8, buf.items);
            }
            break :blk try arena.dupe(u8, "[object Object]");
        },
    };
}

/// Shared log implementation: join args with space, write to `writer`, append \n.
fn logImpl(arena: std.mem.Allocator, args: []const Value, writer: anytype) !void {
    for (args, 0..) |arg, i| {
        if (i > 0) try writer.print(" ", .{});
        const s = try displayString(arena, arg);
        try writer.print("{s}", .{s});
    }
    try writer.print("\n", .{});
    try writer.flush();
}

// stdout targets: log / info / debug
pub fn nativeConsoleLog(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try logImpl(arena, args, out);
    return val_mod.makeUndefined(arena);
}

pub fn nativeConsoleInfo(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try logImpl(arena, args, out);
    return val_mod.makeUndefined(arena);
}

pub fn nativeConsoleDebug(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try logImpl(arena, args, out);
    return val_mod.makeUndefined(arena);
}

// stderr targets: error / warn
pub fn nativeConsoleError(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const out = &w.interface;
    try logImpl(arena, args, out);
    return val_mod.makeUndefined(arena);
}

pub fn nativeConsoleWarn(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const out = &w.interface;
    try logImpl(arena, args, out);
    return val_mod.makeUndefined(arena);
}
