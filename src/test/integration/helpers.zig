// SPDX-License-Identifier: Apache-2.0
//! Shared helper functions for integration test sub-files.
//! Every sub-file in src/test/integration/ imports this module.
pub const std = @import("std");
pub const build_options = @import("build_options");
pub const root = @import("../../root.zig");
const val_mod = @import("../../value/value.zig");

const Isolate = root.Isolate;
const Value = root.Value;
const EvalResult = root.EvalResult;
pub const InterpMode = root.InterpMode;

pub fn evalToF64Mode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) !f64 {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| v.toF64(),
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

pub fn evalToStringMode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) ![]const u8 {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| try root.valueToDisplayString(allocator, v),
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

pub fn evalToBoolMode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) !bool {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| {
            const inner = val_mod.Value{ .bits = v.bits };
            if (inner.bits == 0) return false;
            return switch (inner.unbox()) {
                .boolean => |b| b,
                .number => |n| n != 0.0 and !std.math.isNan(n),
                else => false,
            };
        },
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

// The bytecode VM is the only engine; correctness validated against Node.js by differential.zig.
pub fn dualF64(allocator: std.mem.Allocator, source: []const u8) !f64 {
    return evalToF64Mode(allocator, source, .bc);
}

pub fn dualString(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return evalToStringMode(allocator, source, .bc);
}

pub fn dualBool(allocator: std.mem.Allocator, source: []const u8) !bool {
    return evalToBoolMode(allocator, source, .bc);
}

// Legacy single-mode helper names (used by many tests) — now bc-only.
pub fn evalToF64(allocator: std.mem.Allocator, source: []const u8) !f64 {
    return evalToF64Mode(allocator, source, .bc);
}

pub fn evalToString(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return evalToStringMode(allocator, source, .bc);
}

pub fn evalToBool(allocator: std.mem.Allocator, source: []const u8) !bool {
    return evalToBoolMode(allocator, source, .bc);
}

/// Run `source` in bc mode and report both the numeric result and the
/// call-frame depth high-water mark of that run.
pub fn evalBcWithFrames(allocator: std.mem.Allocator, source: []const u8) !struct { value: f64, frames: usize } {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| .{ .value = v.toF64(), .frames = ctx.lastFrameHighWater() },
        .exception => |e| {
            std.debug.print("exception (bc): {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error (bc): {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
}

// ---- Debugger helpers (used by es_features.zig) ----

pub var dbg_hits: u32 = 0;
pub var dbg_last_fn: []const u8 = "";

pub fn captureDebugHook(_: ?*anyopaque, stop: root.debug.DebugStop) void {
    dbg_hits += 1;
    dbg_last_fn = stop.function_name;
}

/// Must report a parse error (e.g. `??` mixed with `&&`/`||`).
pub fn expectDualParseError(source: []const u8) !void {
    inline for (.{.bc}) |mode| {
        var iso = try Isolate.init(std.testing.allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        ctx.setInterpMode(mode);
        switch (ctx.eval(source, "<test>")) {
            .parse_error => {},
            else => return error.ExpectedParseError,
        }
    }
}

/// Run in bc+experimental JIT mode; store compiled count in `out_compiled`.
pub fn evalExperimental(allocator: std.mem.Allocator, source: []const u8, out_compiled: *usize) !f64 {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    ctx.setJitMode(.experimental);
    const result = ctx.eval(source, "<test>");
    out_compiled.* = ctx.lastJitProfile().compiled;
    return switch (result) {
        .ok => |v| v.toF64(),
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
}
