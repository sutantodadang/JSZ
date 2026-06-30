// SPDX-License-Identifier: Apache-2.0
//! Phase 4b/4c/4d: String.prototype native functions.
//! All operate on the string `this` value (first arg = this_val).
//! No mutation — all return new strings or numbers.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const regexp_mod = @import("./regexp.zig");
const function_proto_mod = @import("./function_proto.zig");
const realm_mod = @import("../realm.zig");
const coercion_mod = @import("./coercion.zig");

/// Throw a TypeError with `msg` and return error.JsException.
/// Used by coerceThis for null/undefined/Symbol receivers.
fn throwTypeErrorStr(arena: std.mem.Allocator, msg: []const u8) anyerror![]const u8 {
    const JsObject = @import("../../object/object.zig").JsObject;
    const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    try obj.set("message", try val_mod.makeString(arena, msg));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// RequireObjectCoercible + ToString for the `this` receiver of String.prototype
/// methods (ES2024 22.1.3 preamble).
/// - null / undefined  → TypeError
/// - string            → the slice as-is
/// - number            → ES Number::toString (handles NaN, ±Infinity, -0 → "0")
/// - boolean           → "true" / "false"
/// - bigint            → decimal string
/// - symbol            → TypeError ("Cannot convert a Symbol value to a string")
/// - object            → ToPrimitive(hint: string) then re-stringify; falls back
///                       to "[object Object]" when toPrimitive returns null/object
fn coerceThis(arena: std.mem.Allocator, this_val: Value) anyerror![]const u8 {
    if (this_val.bits == 0) return throwTypeErrorStr(arena, "String.prototype method called on null or undefined");
    switch (this_val.unbox()) {
        .undefined_, .null_ => return throwTypeErrorStr(arena, "String.prototype method called on null or undefined"),
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .bigint => |bi| return try val_mod.bigIntToString(arena, bi),
        .symbol => return throwTypeErrorStr(arena, "Cannot convert a Symbol value to a string"),
        .object => {
            const prim_maybe = try coercion_mod.toPrimitive(arena, this_val, .string);
            if (prim_maybe) |prim| {
                if (coercion_mod.isPrimitive(prim)) {
                    return try coerceThis(arena, prim);
                }
            }
            return "[object Object]";
        },
        else => return "[object Object]",
    }
}

/// Normalize a (possibly negative) index for string of given length.
/// Returns clamped usize in [0, len].
fn normalizeIndex(idx: f64, len: usize) usize {
    if (std.math.isNan(idx)) return 0;
    const i: i64 = val_mod.f64ToI64Sat(idx);
    if (i < 0) {
        const pos: i64 = @intCast(len);
        const r = pos + i;
        return if (r < 0) 0 else @intCast(r);
    }
    if (i > @as(i64, @intCast(len))) return len;
    return @intCast(i);
}

pub fn nativeCharAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const i: usize = if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeString(arena, "") else @intCast(val_mod.f64ToI64Sat(idx));
    if (i >= s.len) return val_mod.makeString(arena, "");
    const ch = try arena.dupe(u8, s[i .. i + 1]);
    return val_mod.makeString(arena, ch);
}

pub fn nativeCharCodeAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const i: usize = if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeNumber(arena, std.math.nan(f64)) else @intCast(val_mod.f64ToI64Sat(idx));
    if (i >= s.len) return val_mod.makeNumber(arena, std.math.nan(f64));
    return val_mod.makeNumber(arena, @floatFromInt(s[i]));
}

/// Decode one WTF-8 code point starting at byte offset `i` in `s`.
/// WTF-8 admits lone surrogates (U+D800..U+DFFF) encoded as 3 bytes, matching
/// how this engine stores `\uD834`-style escapes. Returns the code point and the
/// number of bytes consumed. `i` must be < s.len.
pub fn decodeWtf8At(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 >= 0xF0 and i + 3 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x07) << 18) | (@as(u21, s[i + 1] & 0x3F) << 12) | (@as(u21, s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F);
        return .{ .cp = cp, .len = 4 };
    }
    if (b0 >= 0xE0 and i + 2 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F);
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 >= 0xC0 and i + 1 < s.len) {
        const cp: u21 = (@as(u21, b0 & 0x1F) << 6) | (s[i + 1] & 0x3F);
        return .{ .cp = cp, .len = 2 };
    }
    return .{ .cp = b0, .len = 1 };
}

/// String.prototype.codePointAt(pos): the code point whose WTF-8 encoding begins
/// at byte offset `pos` (this engine indexes strings by byte, consistent with
/// charCodeAt). Returns undefined when `pos` is out of range.
pub fn nativeCodePointAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const idx: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    if (idx < 0.0 or std.math.isNan(idx)) return val_mod.makeUndefined(arena);
    const i: usize = @intCast(val_mod.f64ToI64Sat(idx));
    if (i >= s.len) return val_mod.makeUndefined(arena);
    const dec = decodeWtf8At(s, i);
    return val_mod.makeNumber(arena, @floatFromInt(dec.cp));
}

pub fn nativeIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);
    const search: []const u8 = if (args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        return val_mod.makeNumber(arena, -1.0);

    const from: usize = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .number => |n| blk: {
                if (n < 0.0) break :blk 0;
                if (std.math.isNan(n)) break :blk 0;
                const u: usize = @intCast(val_mod.f64ToI64Sat(n));
                break :blk if (u > s.len) s.len else u;
            },
            else => 0,
        }
    else
        0;

    if (from >= s.len and search.len > 0) return val_mod.makeNumber(arena, -1.0);
    if (std.mem.indexOf(u8, s[from..], search)) |pos| {
        return val_mod.makeNumber(arena, @floatFromInt(pos + from));
    }
    return val_mod.makeNumber(arena, -1.0);
}

pub fn nativeSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = s.len;

    const start_raw: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const end_raw: f64 = if (args.len > 1 and args[1].bits != 0)
        switch (args[1].unbox()) {
            .number => |n| n,
            .undefined_ => @floatFromInt(len),
            else => @floatFromInt(len),
        }
    else
        @floatFromInt(len);

    const start = normalizeIndex(start_raw, len);
    const end_ = normalizeIndex(end_raw, len);

    if (start >= end_) return val_mod.makeString(arena, "");
    const slice = try arena.dupe(u8, s[start..end_]);
    return val_mod.makeString(arena, slice);
}

pub fn nativeToUpperCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return val_mod.makeString(arena, out);
}

pub fn nativeToLowerCase(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return val_mod.makeString(arena, out);
}

pub fn nativeSplit(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const JsObject = @import("../../object/object.zig").JsObject;

    const arr_proto: ?*JsObject = if (realm_mod.active_array_proto) |p| p else null;

    // Check if separator is a RegExp
    if (args.len > 0 and args[0].bits != 0) {
        if (regexp_mod.getCompiledRegex(args[0])) |cr| {
            return splitByRegex(arena, s, cr, arr_proto);
        }
    }

    // Separator
    const sep: ?[]const u8 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .string => |sep_s| sep_s,
            .undefined_ => null,
            else => null,
        }
    else
        null;

    const arr = try JsObject.createArray(arena, arr_proto);

    if (sep == null) {
        // No separator: return array with full string
        const sv = try val_mod.makeString(arena, s);
        try arr.set("0", sv);
        arr.array_length = 1;
        return val_mod.makeObject(arena, arr);
    }

    const sep_s = sep.?;
    if (sep_s.len == 0) {
        // Split into chars
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const ch = try arena.dupe(u8, s[i .. i + 1]);
            const cv = try val_mod.makeString(arena, ch);
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            try arr.set(key, cv);
        }
        arr.array_length = @intCast(s.len);
        return val_mod.makeObject(arena, arr);
    }

    // Split by separator
    var idx: u32 = 0;
    var rest = s;
    while (true) {
        if (std.mem.indexOf(u8, rest, sep_s)) |pos| {
            const part = try arena.dupe(u8, rest[0..pos]);
            const pv = try val_mod.makeString(arena, part);
            const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(key, pv);
            idx += 1;
            rest = rest[pos + sep_s.len ..];
        } else {
            const part = try arena.dupe(u8, rest);
            const pv = try val_mod.makeString(arena, part);
            const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try arr.set(key, pv);
            idx += 1;
            break;
        }
    }
    arr.array_length = idx;
    return val_mod.makeObject(arena, arr);
}

fn splitByRegex(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, arr_proto: anytype) !Value {
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr = try JsObject.createArray(arena, arr_proto);
    var idx: u32 = 0;
    var search_from: usize = 0;

    while (search_from <= s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, search_from) orelse break;
        const match_start = m.start;
        const match_end = m.state.pos;

        // Add segment from search_from to match_start
        const part = try arena.dupe(u8, s[search_from..match_start]);
        const pv = try val_mod.makeString(arena, part);
        const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
        try arr.set(key, pv);
        idx += 1;

        if (match_end == match_start) {
            // Zero-width match: advance by one to avoid infinite loop
            if (search_from < s.len) {
                search_from = match_start + 1;
            } else {
                break;
            }
        } else {
            search_from = match_end;
        }
    }
    // Remainder
    const rem = try arena.dupe(u8, s[search_from..]);
    const rv = try val_mod.makeString(arena, rem);
    const rk = try std.fmt.allocPrint(arena, "{d}", .{idx});
    try arr.set(rk, rv);
    idx += 1;

    arr.array_length = idx;
    return val_mod.makeObject(arena, arr);
}

/// String.prototype.match(re|str)
pub fn nativeMatch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len == 0) return val_mod.makeNull(arena);

    const arg = args[0];
    // Coerce string to RegExp
    const cr_opt: ?*regexp_mod.CompiledRegex = regexp_mod.getCompiledRegex(arg);
    if (cr_opt == null) {
        // String argument: treat as pattern
        const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
        const cr_arena = try arena.create(regexp_mod.CompiledRegex);
        cr_arena.* = regexp_mod.compileRegex(arena, pat, "") catch return val_mod.makeNull(arena);
        return doExec(arena, s, cr_arena);
    }
    const cr = cr_opt.?;

    if (!cr.flags.global) {
        // Non-global: return exec result
        return doExec(arena, s, cr);
    }

    // Global: return array of all match strings
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);
    var idx: u32 = 0;
    var pos: usize = 0;
    while (pos <= s.len) {
        const result = regexp_mod.matchAnywhere(cr, s, pos) orelse break;
        const full = try arena.dupe(u8, s[result.start..result.state.pos]);
        const fv = try val_mod.makeString(arena, full);
        const key = try std.fmt.allocPrint(arena, "{d}", .{idx});
        try arr.set(key, fv);
        idx += 1;
        if (result.state.pos == result.start) {
            pos = result.start + 1; // prevent infinite loop on zero-width match
        } else {
            pos = result.state.pos;
        }
    }
    if (idx == 0) return val_mod.makeNull(arena);
    arr.array_length = idx;
    return val_mod.makeObject(arena, arr);
}

fn doExec(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex) !Value {
    const result = regexp_mod.matchAnywhere(cr, s, 0) orelse return val_mod.makeNull(arena);
    const JsObject = @import("../../object/object.zig").JsObject;
    const arr_proto = realm_mod.active_array_proto;
    const arr = try JsObject.createArray(arena, arr_proto);

    const full = try arena.dupe(u8, s[result.start..result.state.pos]);
    const fv = try val_mod.makeString(arena, full);
    try arr.set("0", fv);

    var i: u32 = 1;
    while (i <= cr.num_captures) : (i += 1) {
        const cap = result.state.captures[i];
        const cv: Value = if (cap.start == 0 and cap.end == 0)
            try val_mod.makeUndefined(arena)
        else
            try val_mod.makeString(arena, try arena.dupe(u8, s[cap.start..cap.end]));
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try arr.set(key, cv);
    }
    arr.array_length = cr.num_captures + 1;

    const idx_val = try val_mod.makeNumber(arena, @floatFromInt(result.start));
    try arr.set("index", idx_val);
    const input_val = try val_mod.makeString(arena, s);
    try arr.set("input", input_val);

    return val_mod.makeObject(arena, arr);
}

/// String.prototype.search(re|str) -> index or -1
pub fn nativeSearch(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len == 0) return val_mod.makeNumber(arena, 0.0);

    const arg = args[0];
    const cr: regexp_mod.CompiledRegex = blk: {
        if (regexp_mod.getCompiledRegex(arg)) |cr_ptr| {
            break :blk cr_ptr.*;
        }
        const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
        break :blk regexp_mod.compileRegex(arena, pat, "") catch return val_mod.makeNumber(arena, -1.0);
    };

    if (regexp_mod.matchAnywhere(&cr, s, 0)) |result| {
        return val_mod.makeNumber(arena, @floatFromInt(result.start));
    }
    return val_mod.makeNumber(arena, -1.0);
}

/// Return true if a Value is callable (function, bc_function, native_function, bound_function).
fn isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        .object => |obj| obj.internal_kind == .bound_function,
        else => false,
    };
}

/// String.prototype.replace(re|str, replStr|fn)
pub fn nativeReplace(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len < 2) return val_mod.makeString(arena, s);

    const repl_arg = args[1];
    const arg = args[0];

    // Phase 4d: if second arg is callable, use callback path.
    if (isCallable(repl_arg)) {
        if (regexp_mod.getCompiledRegex(arg)) |cr| {
            return doReplaceWithFn(arena, s, cr, repl_arg);
        }
        // String pattern with callback: replace first occurrence only.
        const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
        if (std.mem.indexOf(u8, s, pat)) |idx| {
            const match_str = s[idx .. idx + pat.len];
            const undefined_val = try val_mod.makeUndefined(arena);
            const match_val = try val_mod.makeString(arena, match_str);
            const offset_val = try val_mod.makeNumber(arena, @floatFromInt(idx));
            const source_val = try val_mod.makeString(arena, s);
            const cb_args = [_]Value{ match_val, offset_val, source_val };
            const repl_val = function_proto_mod.invokeCallback(arena, undefined_val, repl_arg, &cb_args) catch |e| {
                if (e == error.JsException) return error.JsException;
                return error.OutOfMemory;
            };
            const repl_s: []const u8 = if (repl_val.bits != 0 and repl_val.unbox() == .string)
                repl_val.toPtr().string
            else
                "undefined";
            const result = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ s[0..idx], repl_s, s[idx + pat.len ..] });
            return val_mod.makeString(arena, result);
        }
        return val_mod.makeString(arena, try arena.dupe(u8, s));
    }

    const repl_str: []const u8 = if (repl_arg.bits != 0 and repl_arg.unbox() == .string)
        repl_arg.toPtr().string
    else
        "undefined";

    // Check if it's a RegExp
    if (regexp_mod.getCompiledRegex(arg)) |cr| {
        return doReplace(arena, s, cr, repl_str);
    }

    // String pattern: replace first occurrence
    const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
    if (std.mem.indexOf(u8, s, pat)) |idx| {
        const before = s[0..idx];
        const after = s[idx + pat.len..];
        const expanded = try applyReplacement(arena, repl_str, s[idx..idx + pat.len], s, idx, &[_][]const u8{});
        const result = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ before, expanded, after });
        return val_mod.makeString(arena, result);
    }
    return val_mod.makeString(arena, try arena.dupe(u8, s));
}

/// ES2021 String.prototype.replaceAll — all occurrences (string or global RegExp).
pub fn nativeReplaceAll(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len < 2) return val_mod.makeString(arena, s);

    const repl_arg = args[1];
    const arg = args[0];

    if (isCallable(repl_arg)) {
        if (regexp_mod.getCompiledRegex(arg)) |cr| {
            if (!cr.flags.global) {
                realm_mod.pending_exception = try val_mod.makeString(arena, "TypeError: replaceAll must be called with a global RegExp");
                return error.JsException;
            }
            return doReplaceWithFn(arena, s, cr, repl_arg);
        }
        const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
        return replaceAllStringWithFn(arena, s, pat, repl_arg);
    }

    const repl_str: []const u8 = if (repl_arg.bits != 0 and repl_arg.unbox() == .string)
        repl_arg.toPtr().string
    else
        "undefined";

    if (regexp_mod.getCompiledRegex(arg)) |cr| {
        if (!cr.flags.global) {
            realm_mod.pending_exception = try val_mod.makeString(arena, "TypeError: replaceAll must be called with a global RegExp");
            return error.JsException;
        }
        return doReplace(arena, s, cr, repl_str);
    }

    const pat: []const u8 = if (arg.bits != 0 and arg.unbox() == .string) arg.toPtr().string else "";
    return replaceAllString(arena, s, pat, repl_str);
}

fn replaceAllString(arena: std.mem.Allocator, s: []const u8, pat: []const u8, repl: []const u8) !Value {
    if (pat.len == 0) {
        var result = std.ArrayList(u8){};
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (i > 0) try result.appendSlice(arena, s[i - 1 .. i]);
            try result.appendSlice(arena, repl);
        }
        return val_mod.makeString(arena, try arena.dupe(u8, result.items));
    }
    var result = std.ArrayList(u8){};
    var pos: usize = 0;
    while (pos <= s.len) {
        const idx = std.mem.indexOf(u8, s[pos..], pat) orelse break;
        const abs = pos + idx;
        try result.appendSlice(arena, s[pos..abs]);
        try result.appendSlice(arena, repl);
        pos = abs + pat.len;
    }
    try result.appendSlice(arena, s[pos..]);
    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

fn replaceAllStringWithFn(arena: std.mem.Allocator, s: []const u8, pat: []const u8, fn_val: Value) !Value {
    const undefined_val = try val_mod.makeUndefined(arena);
    if (pat.len == 0) {
        var result = std.ArrayList(u8){};
        var pos: usize = 0;
        while (pos <= s.len) {
            const match_str = if (pos < s.len) s[pos .. pos + 1] else "";
            const match_val = try val_mod.makeString(arena, match_str);
            const offset_val = try val_mod.makeNumber(arena, @floatFromInt(pos));
            const source_val = try val_mod.makeString(arena, s);
            const cb_args = [_]Value{ match_val, offset_val, source_val };
            const repl_val = function_proto_mod.invokeCallback(arena, undefined_val, fn_val, &cb_args) catch |e| {
                if (e == error.JsException) return error.JsException;
                return error.OutOfMemory;
            };
            const repl_s: []const u8 = if (repl_val.bits != 0 and repl_val.unbox() == .string)
                repl_val.toPtr().string
            else
                "undefined";
            try result.appendSlice(arena, repl_s);
            if (pos < s.len) pos += 1 else break;
        }
        return val_mod.makeString(arena, try arena.dupe(u8, result.items));
    }
    var result = std.ArrayList(u8){};
    var pos: usize = 0;
    while (pos <= s.len) {
        const idx = std.mem.indexOf(u8, s[pos..], pat) orelse break;
        const abs = pos + idx;
        try result.appendSlice(arena, s[pos..abs]);
        const match_str = s[abs .. abs + pat.len];
        const match_val = try val_mod.makeString(arena, match_str);
        const offset_val = try val_mod.makeNumber(arena, @floatFromInt(abs));
        const source_val = try val_mod.makeString(arena, s);
        const cb_args = [_]Value{ match_val, offset_val, source_val };
        const repl_val = function_proto_mod.invokeCallback(arena, undefined_val, fn_val, &cb_args) catch |e| {
            if (e == error.JsException) return error.JsException;
            return error.OutOfMemory;
        };
        const repl_s: []const u8 = if (repl_val.bits != 0 and repl_val.unbox() == .string)
            repl_val.toPtr().string
        else
            "undefined";
        try result.appendSlice(arena, repl_s);
        pos = abs + pat.len;
    }
    try result.appendSlice(arena, s[pos..]);
    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

/// Replace with function callback for regex pattern.
fn doReplaceWithFn(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, fn_val: Value) !Value {
    var result = std.ArrayList(u8){};
    var pos: usize = 0;
    const undefined_val = try val_mod.makeUndefined(arena);

    while (pos <= s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, pos) orelse break;
        // Append text before match.
        try result.appendSlice(arena, s[pos..m.start]);

        const full_match = s[m.start..m.state.pos];

        // Build args: (match, cap1..capN, offset, source)
        const n_caps = cr.num_captures;
        const total_args = 1 + n_caps + 2; // match + captures + offset + source
        const cb_args = try arena.alloc(Value, total_args);
        cb_args[0] = try val_mod.makeString(arena, full_match);
        var ci: u32 = 1;
        while (ci <= n_caps) : (ci += 1) {
            const cap = m.state.captures[ci];
            if (cap.start == 0 and cap.end == 0) {
                cb_args[ci] = try val_mod.makeUndefined(arena);
            } else {
                cb_args[ci] = try val_mod.makeString(arena, s[cap.start..cap.end]);
            }
        }
        cb_args[1 + n_caps] = try val_mod.makeNumber(arena, @floatFromInt(m.start));
        cb_args[1 + n_caps + 1] = try val_mod.makeString(arena, s);

        const repl_val = function_proto_mod.invokeCallback(arena, undefined_val, fn_val, cb_args) catch |e| {
            if (e == error.JsException) return error.JsException;
            return error.OutOfMemory;
        };
        const repl_s: []const u8 = if (repl_val.bits != 0 and repl_val.unbox() == .string)
            repl_val.toPtr().string
        else
            "undefined";
        try result.appendSlice(arena, repl_s);

        if (m.state.pos == m.start) {
            if (pos < s.len) {
                try result.append(arena, s[pos]);
            }
            pos += 1;
        } else {
            pos = m.state.pos;
        }

        if (!cr.flags.global) break;
    }

    // Append remainder.
    if (pos <= s.len) {
        try result.appendSlice(arena, s[pos..]);
    }

    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

fn doReplace(arena: std.mem.Allocator, s: []const u8, cr: *const regexp_mod.CompiledRegex, repl_str: []const u8) !Value {
    var result = std.ArrayList(u8){};
    var pos: usize = 0;

    while (pos <= s.len) {
        const m = regexp_mod.matchAnywhere(cr, s, pos) orelse break;
        // Append text before match
        try result.appendSlice(arena, s[pos..m.start]);
        // Build captures array for $N
        const full_match = s[m.start..m.state.pos];
        var caps: [regexp_mod.MAX_CAPTURES][]const u8 = undefined;
        var i: u32 = 0;
        while (i < regexp_mod.MAX_CAPTURES) : (i += 1) caps[i] = "";
        var ci: u32 = 1;
        while (ci <= cr.num_captures) : (ci += 1) {
            const cap = m.state.captures[ci];
            if (cap.start != 0 or cap.end != 0) {
                caps[ci] = s[cap.start..cap.end];
            }
        }
        // Apply replacement
        const expanded = try applyReplacement(arena, repl_str, full_match, s, m.start, caps[0..]);
        try result.appendSlice(arena, expanded);

        if (m.state.pos == m.start) {
            if (pos < s.len) {
                try result.append(arena, s[pos]);
            }
            pos += 1;
        } else {
            pos = m.state.pos;
        }

        if (!cr.flags.global) break;
    }

    // Append remainder
    if (pos <= s.len) {
        try result.appendSlice(arena, s[pos..]);
    }

    return val_mod.makeString(arena, try arena.dupe(u8, result.items));
}

/// Apply $& $$ $1..$9 substitution in replacement string.
fn applyReplacement(
    arena: std.mem.Allocator,
    repl: []const u8,
    full_match: []const u8,
    input: []const u8,
    match_start: usize,
    caps: []const []const u8,
) ![]const u8 {
    _ = input;
    _ = match_start;
    var out = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < repl.len) {
        if (repl[i] == '$' and i + 1 < repl.len) {
            const next = repl[i + 1];
            switch (next) {
                '&' => {
                    try out.appendSlice(arena, full_match);
                    i += 2;
                    continue;
                },
                '$' => {
                    try out.append(arena, '$');
                    i += 2;
                    continue;
                },
                '1'...'9' => {
                    const n: usize = next - '0';
                    // Check for two-digit $NN
                    if (i + 2 < repl.len and repl[i + 2] >= '0' and repl[i + 2] <= '9') {
                        const nn: usize = n * 10 + (repl[i + 2] - '0');
                        if (nn < caps.len and caps[nn].len > 0) {
                            try out.appendSlice(arena, caps[nn]);
                            i += 3;
                            continue;
                        }
                    }
                    if (n < caps.len and caps[n].len > 0) {
                        try out.appendSlice(arena, caps[n]);
                    }
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(arena, repl[i]);
        i += 1;
    }
    return try arena.dupe(u8, out.items);
}

pub fn nativeConcat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var buf = std.ArrayList(u8){};
    try buf.appendSlice(arena, s);
    for (args) |a| {
        if (a.bits != 0) {
            switch (a.unbox()) {
                .string => |ss| try buf.appendSlice(arena, ss),
                .number => |n| {
                    const ns = try formatNumber(arena, n);
                    try buf.appendSlice(arena, ns);
                },
                .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
                .null_ => try buf.appendSlice(arena, "null"),
                .undefined_ => try buf.appendSlice(arena, "undefined"),
                else => try buf.appendSlice(arena, "[object Object]"),
            }
        } else {
            try buf.appendSlice(arena, "undefined");
        }
    }
    return val_mod.makeString(arena, buf.items);
}

/// Coerce an argument to a string slice for search methods (string/number/bool/
/// null/undefined; objects → "[object Object]"). Mirrors nativeConcat's coercion.
fn argToStr(arena: std.mem.Allocator, a: Value) ![]const u8 {
    if (a.bits == 0) return "undefined";
    return switch (a.unbox()) {
        .string => |ss| ss,
        .number => |n| try formatNumber(arena, n),
        .boolean => |b| if (b) "true" else "false",
        .null_ => "null",
        .undefined_ => "undefined",
        else => "[object Object]",
    };
}

/// Throw a TypeError if `a` is a RegExp (per String.prototype.{startsWith,endsWith,
/// includes}: a RegExp searchString is not allowed).
fn rejectRegExp(arena: std.mem.Allocator, a: Value) !void {
    if (a.bits != 0 and a.unbox() == .object and a.toPtr().object.internal_kind == .regexp) {
        const JsObject = @import("../../object/object.zig").JsObject;
        const obj = try JsObject.create(arena, realm_mod.error_proto_TypeError);
        try obj.set("message", try val_mod.makeString(arena, "First argument to String.prototype.startsWith/endsWith/includes must not be a regular expression"));
        try obj.set("name", try val_mod.makeString(arena, "TypeError"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
        return error.JsException;
    }
}

/// ES2015 String.prototype.startsWith(searchString [, position]).
pub fn nativeStartsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    const pos: usize = if (args.len > 1) normalizeIndex(toNum(args[1]), s.len) else 0;
    if (pos + search.len > s.len) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[pos .. pos + search.len], search));
}

/// ES2015 String.prototype.endsWith(searchString [, endPosition]).
pub fn nativeEndsWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    const end_: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        normalizeIndex(toNum(args[1]), s.len)
    else
        s.len;
    if (search.len > end_) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.eql(u8, s[end_ - search.len .. end_], search));
}

/// ES2015 String.prototype.includes(searchString [, position]).
pub fn nativeStringIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len > 0) try rejectRegExp(arena, args[0]);
    const search = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    const pos: usize = if (args.len > 1) normalizeIndex(toNum(args[1]), s.len) else 0;
    if (pos > s.len) return val_mod.makeBool(arena, false);
    return val_mod.makeBool(arena, std.mem.indexOf(u8, s[pos..], search) != null);
}

/// ToNumber for a position arg (number → itself; absent/other → 0). NaN handled by normalizeIndex.
fn toNum(a: Value) f64 {
    if (a.bits == 0) return 0;
    return switch (a.unbox()) {
        .number => |n| n,
        else => 0,
    };
}

pub fn nativeTrim(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    return val_mod.makeString(arena, try arena.dupe(u8, trimmed));
}

/// ES2019 String.prototype.trimStart.
pub fn nativeTrimStart(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const trimmed = std.mem.trimLeft(u8, s, " \t\n\r");
    return val_mod.makeString(arena, try arena.dupe(u8, trimmed));
}

/// ES2019 String.prototype.trimEnd.
pub fn nativeTrimEnd(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    return val_mod.makeString(arena, try arena.dupe(u8, trimmed));
}

fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    return val_mod.formatNumber(arena, n);
}

/// Build a pad filler of `count` bytes by repeating `pad`.
fn buildFiller(arena: std.mem.Allocator, pad: []const u8, count: usize) ![]const u8 {
    var buf = std.ArrayList(u8){};
    while (buf.items.len < count) {
        const remaining = count - buf.items.len;
        try buf.appendSlice(arena, if (pad.len <= remaining) pad else pad[0..remaining]);
    }
    return buf.items;
}

fn padImpl(arena: std.mem.Allocator, this_val: Value, args: []const Value, at_start: bool) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const target: usize = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| if (n <= 0 or std.math.isNan(n)) 0 else @intCast(val_mod.f64ToI64Sat(n)),
            else => 0,
        }
    else
        0;
    if (target <= s.len) return val_mod.makeString(arena, s);
    const pad: []const u8 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .string)
        args[1].toPtr().string
    else
        " ";
    if (pad.len == 0) return val_mod.makeString(arena, s);
    const filler = try buildFiller(arena, pad, target - s.len);
    var buf = std.ArrayList(u8){};
    if (at_start) {
        try buf.appendSlice(arena, filler);
        try buf.appendSlice(arena, s);
    } else {
        try buf.appendSlice(arena, s);
        try buf.appendSlice(arena, filler);
    }
    return val_mod.makeString(arena, buf.items);
}

/// ES2017 String.prototype.padStart.
pub fn nativePadStart(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return padImpl(arena, this_val, args, true);
}

/// ES2017 String.prototype.padEnd.
pub fn nativePadEnd(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return padImpl(arena, this_val, args, false);
}

// ---------------------------------------------------------------------------
// HTML wrapper methods (Annex B B.2.3)
// ---------------------------------------------------------------------------

/// Wrap receiver S in an HTML tag. When attrName is non-null, escapes `"` in
/// attrVal to `&quot;` and produces `<tag attrName="attrVal">S</tag>`.
fn htmlWrap(
    arena: std.mem.Allocator,
    s: []const u8,
    tag: []const u8,
    attr_name: ?[]const u8,
    attr_val: ?[]const u8,
) !Value {
    if (attr_name) |aname| {
        const av = attr_val orelse "undefined";
        var esc = std.ArrayList(u8){};
        for (av) |c| {
            if (c == '"') {
                try esc.appendSlice(arena, "&quot;");
            } else {
                try esc.append(arena, c);
            }
        }
        const result = try std.fmt.allocPrint(arena, "<{s} {s}=\"{s}\">{s}</{s}>", .{ tag, aname, esc.items, s, tag });
        return val_mod.makeString(arena, result);
    } else {
        const result = try std.fmt.allocPrint(arena, "<{s}>{s}</{s}>", .{ tag, s, tag });
        return val_mod.makeString(arena, result);
    }
}

pub fn nativeAnchor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const name = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "a", "name", name);
}

pub fn nativeLink(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const url = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "a", "href", url);
}

pub fn nativeFontcolor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const c = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "font", "color", c);
}

pub fn nativeFontsize(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const sz = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    return htmlWrap(arena, s, "font", "size", sz);
}

pub fn nativeBig(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "big", null, null);
}

pub fn nativeBlink(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "blink", null, null);
}

pub fn nativeBold(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "b", null, null);
}

pub fn nativeFixed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "tt", null, null);
}

pub fn nativeItalics(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "i", null, null);
}

pub fn nativeSmall(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "small", null, null);
}

pub fn nativeStrike(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "strike", null, null);
}

pub fn nativeSub(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "sub", null, null);
}

pub fn nativeSup(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return htmlWrap(arena, try coerceThis(arena, this_val), "sup", null, null);
}

// ---------------------------------------------------------------------------
// Core string methods
// ---------------------------------------------------------------------------

/// String.prototype.substring(start, end) — ES5.
/// NaN/negatives → 0; clamped to [0, len]; min(a,b)..max(a,b).
pub fn nativeSubstring(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = s.len;

    const clampIdx = struct {
        fn f(n: f64, l: usize) usize {
            if (std.math.isNan(n) or n < 0.0) return 0;
            const i: i64 = val_mod.f64ToI64Sat(n);
            if (i > @as(i64, @intCast(l))) return l;
            return @intCast(i);
        }
    }.f;

    const a0: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const a = clampIdx(a0, len);

    const b: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        clampIdx(switch (args[1].unbox()) {
            .number => |n| n,
            else => 0.0,
        }, len)
    else
        len;

    const from = if (a < b) a else b;
    const to = if (a < b) b else a;
    return val_mod.makeString(arena, try arena.dupe(u8, s[from..to]));
}

/// String.prototype.substr(start, length) — legacy (Annex B).
pub fn nativeSubstr(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const len = s.len;

    const start_f: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    const int_start: i64 = if (std.math.isNan(start_f)) 0 else val_mod.f64ToI64Sat(start_f);

    const start: usize = if (int_start < 0) blk: {
        const r = @as(i64, @intCast(len)) + int_start;
        break :blk if (r < 0) 0 else @intCast(r);
    } else blk: {
        const u: usize = @intCast(int_start);
        break :blk if (u > len) len else u;
    };

    const size: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        blk: {
            const n: f64 = switch (args[1].unbox()) {
                .number => |nn| nn,
                else => 0.0,
            };
            if (n <= 0.0 or std.math.isNan(n)) break :blk 0;
            const u: usize = @intCast(val_mod.f64ToI64Sat(n));
            const max = len - start;
            break :blk if (u > max) max else u;
        }
    else
        len - start;

    return val_mod.makeString(arena, try arena.dupe(u8, s[start .. start + size]));
}

/// String.prototype.at(index) — ES2022.
pub fn nativeStringAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const raw: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;
    var k: i64 = if (std.math.isNan(raw)) 0 else val_mod.f64ToI64Sat(raw);
    if (k < 0) k = @as(i64, @intCast(s.len)) + k;
    if (k < 0 or k >= @as(i64, @intCast(s.len))) return val_mod.makeUndefined(arena);
    const idx: usize = @intCast(k);
    return val_mod.makeString(arena, try arena.dupe(u8, s[idx .. idx + 1]));
}

/// String.prototype.repeat(count) — ES2015.
pub fn nativeRepeat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const n_raw: f64 = if (args.len > 0 and args[0].bits != 0)
        switch (args[0].unbox()) {
            .number => |n| n,
            else => 0.0,
        }
    else
        0.0;

    if (n_raw < 0.0 or std.math.isInf(n_raw)) {
        const JsObject = @import("../../object/object.zig").JsObject;
        const eo = try JsObject.create(arena, realm_mod.error_proto_RangeError);
        try eo.set("message", try val_mod.makeString(arena, "Invalid count value"));
        try eo.set("name", try val_mod.makeString(arena, "RangeError"));
        realm_mod.pending_exception = try val_mod.makeObject(arena, eo);
        return error.JsException;
    }

    if (std.math.isNan(n_raw) or n_raw == 0.0 or s.len == 0) return val_mod.makeString(arena, "");
    const n: usize = @intCast(val_mod.f64ToI64Sat(n_raw));
    const buf = try arena.alloc(u8, s.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(buf[i * s.len .. (i + 1) * s.len], s);
    }
    return val_mod.makeString(arena, buf);
}

/// String.prototype.lastIndexOf(searchString, position).
pub fn nativeLastIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    if (args.len == 0) return val_mod.makeNumber(arena, -1.0);

    const search = try argToStr(arena, args[0]);

    const pos_limit: usize = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_)
        blk: {
            const n: f64 = switch (args[1].unbox()) {
                .number => |nn| nn,
                else => @as(f64, @floatFromInt(s.len)),
            };
            if (std.math.isNan(n)) break :blk s.len;
            if (n < 0.0) break :blk 0;
            const u: usize = @intCast(val_mod.f64ToI64Sat(n));
            break :blk if (u > s.len) s.len else u;
        }
    else
        s.len;

    if (search.len == 0) {
        return val_mod.makeNumber(arena, @floatFromInt(if (pos_limit > s.len) s.len else pos_limit));
    }
    if (s.len < search.len) return val_mod.makeNumber(arena, -1.0);

    const max_start: usize = if (pos_limit > s.len - search.len) s.len - search.len else pos_limit;

    var i: usize = max_start + 1;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, s[i .. i + search.len], search)) {
            return val_mod.makeNumber(arena, @floatFromInt(i));
        }
    }
    return val_mod.makeNumber(arena, -1.0);
}

// ---------------------------------------------------------------------------
// Locale aliases
// ---------------------------------------------------------------------------

pub fn nativeToLocaleLowerCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeToLowerCase(arena, this_val, args);
}

pub fn nativeToLocaleUpperCase(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeToUpperCase(arena, this_val, args);
}

// ---------------------------------------------------------------------------
// localeCompare
// ---------------------------------------------------------------------------

/// String.prototype.localeCompare(that) — byte-wise lexicographic order.
pub fn nativeLocaleCompare(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    const that = if (args.len > 0) try argToStr(arena, args[0]) else "undefined";
    const result: f64 = switch (std.mem.order(u8, s, that)) {
        .lt => -1.0,
        .eq => 0.0,
        .gt => 1.0,
    };
    return val_mod.makeNumber(arena, result);
}

// ---------------------------------------------------------------------------
// ES2024 well-formed
// ---------------------------------------------------------------------------

/// String.prototype.isWellFormed() — true iff no lone surrogates in WTF-8.
pub fn nativeIsWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDFFF) return val_mod.makeBool(arena, false);
        i += dec.len;
    }
    return val_mod.makeBool(arena, true);
}

/// String.prototype.toWellFormed() — replace lone surrogates with U+FFFD.
pub fn nativeToWellFormed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const s = try coerceThis(arena, this_val);
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < s.len) {
        const dec = decodeWtf8At(s, i);
        if (dec.cp >= 0xD800 and dec.cp <= 0xDFFF) {
            // U+FFFD encoded as EF BF BD in UTF-8/WTF-8
            try buf.appendSlice(arena, &[_]u8{ 0xEF, 0xBF, 0xBD });
        } else {
            try buf.appendSlice(arena, s[i .. i + dec.len]);
        }
        i += dec.len;
    }
    return val_mod.makeString(arena, try arena.dupe(u8, buf.items));
}
