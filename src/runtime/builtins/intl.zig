// SPDX-License-Identifier: Apache-2.0
//! Phase 13: a pragmatic, dependency-free `Intl` implementation.
//!
//! Scope: en-US formatting only (no ICU / CLDR data). Covers the common cases:
//!   * `Intl.NumberFormat` — decimal / currency / percent, grouping, min/max
//!     fraction digits.
//!   * `Intl.DateTimeFormat` — `M/D/YYYY` (UTC-based, deterministic).
//!   * `Intl.Collator` — byte-wise comparison returning -1/0/1.
//! Locale arguments are accepted and ignored. Formatter instances store their
//! resolved options as own properties; the `format`/`compare` methods live on
//! the prototype and read those options from `this`.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");

fn getNum(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .number => |n| n,
        .boolean => |b| if (b) 1.0 else 0.0,
        .null_ => 0.0,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\n\r")) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

/// Read an option from the options object (`args[1]`). Returns null if absent.
fn optStr(opts: ?Value, key: []const u8) ?[]const u8 {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = o.toPtr().object.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() != .string) return null;
    return v.unbox().string;
}

fn optNum(opts: ?Value, key: []const u8) ?f64 {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = o.toPtr().object.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() != .number) return null;
    return v.unbox().number;
}

fn optBool(opts: ?Value, key: []const u8) ?bool {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = o.toPtr().object.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() != .boolean) return null;
    return v.unbox().boolean;
}

fn pow10(n: u32) u64 {
    var r: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}

/// Format `int_part` (a non-negative integer) with ASCII thousands separators.
fn groupInteger(arena: std.mem.Allocator, int_part: u64, group: bool) ![]const u8 {
    const digits = try std.fmt.allocPrint(arena, "{d}", .{int_part});
    if (!group or digits.len <= 3) return digits;
    var out = std.ArrayListUnmanaged(u8){};
    const first = digits.len % 3;
    var idx: usize = 0;
    if (first != 0) {
        try out.appendSlice(arena, digits[0..first]);
        idx = first;
    }
    while (idx < digits.len) : (idx += 3) {
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, digits[idx .. idx + 3]);
    }
    return out.items;
}

/// Core en-US number formatting.
fn formatNumber(
    arena: std.mem.Allocator,
    value: f64,
    style: []const u8,
    currency: []const u8,
    min_frac_in: u32,
    max_frac_in: u32,
    group: bool,
) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";

    var n = value;
    const negative = std.math.signbit(n) and n != 0;
    n = @abs(n);

    const is_percent = std.mem.eql(u8, style, "percent");
    const is_currency = std.mem.eql(u8, style, "currency");
    if (is_percent) n *= 100;

    const min_frac = min_frac_in;
    var max_frac = max_frac_in;
    if (max_frac < min_frac) max_frac = min_frac;
    // `pow10(max_frac)` must fit u64 (10^18 < 2^63) and f64 carries only ~17
    // significant digits, so a larger fraction-digit count cannot be represented;
    // clamp the scale exponent to avoid integer overflow in pow10.
    if (max_frac > 18) max_frac = 18;

    const sign_prefix: []const u8 = if (negative) "-" else "";
    var cur_prefix: []const u8 = "";
    var suffix: []const u8 = "";
    if (is_currency) {
        cur_prefix = currencySymbol(currency);
    }
    if (is_percent) suffix = "%";

    if (std.math.isInf(value)) {
        return std.fmt.allocPrint(arena, "{s}{s}\u{221e}{s}", .{ sign_prefix, cur_prefix, suffix });
    }

    const scale = pow10(max_frac);
    const scale_f: f64 = @floatFromInt(scale);
    const scaled: f64 = @round(n * scale_f);
    // Guard the float→int conversion: a value large enough to overflow u64 (or NaN)
    // would panic @intFromFloat. Saturate instead of crashing.
    const scaled_u: u64 = if (std.math.isNan(scaled) or scaled < 0 or scaled >= 1.8446744073709552e19)
        std.math.maxInt(u64)
    else
        @intFromFloat(scaled);
    const int_part = scaled_u / scale;
    const frac_part = scaled_u % scale;

    const int_str = try groupInteger(arena, int_part, group);

    // Fraction: zero-pad to max_frac, then trim trailing zeros down to min_frac.
    var frac_str: []const u8 = "";
    if (max_frac > 0) {
        const buf = try std.fmt.allocPrint(arena, "{d:0>[1]}", .{ frac_part, max_frac });
        var keep = buf.len;
        while (keep > min_frac and buf[keep - 1] == '0') keep -= 1;
        frac_str = buf[0..keep];
    }

    if (frac_str.len > 0) {
        return std.fmt.allocPrint(arena, "{s}{s}{s}.{s}{s}", .{ sign_prefix, cur_prefix, int_str, frac_str, suffix });
    }
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ sign_prefix, cur_prefix, int_str, suffix });
}

fn currencySymbol(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "USD")) return "$";
    if (std.mem.eql(u8, code, "EUR")) return "\u{20ac}";
    if (std.mem.eql(u8, code, "GBP")) return "\u{a3}";
    if (std.mem.eql(u8, code, "JPY")) return "\u{a5}";
    return "$";
}

fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.error_proto_RangeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_RangeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// Coerce an Intl fraction-digits option to u32. Per ECMA-402 these must be
/// integers in a bounded range; a NaN / negative / huge value would panic
/// `@intFromFloat`, so validate and throw RangeError (the spec error) instead.
fn toFracDigits(arena: std.mem.Allocator, m: f64) anyerror!u32 {
    if (std.math.isNan(m) or m < 0 or m > 100) return throwRangeError(arena, "fraction digits value is out of range");
    return @intFromFloat(@floor(m));
}

// ----------------------------------------------------------------- NumberFormat ---

/// `new Intl.NumberFormat(locales, options)` — store resolved options on `this`.
pub fn nativeNumberFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const opts: ?Value = if (args.len > 1) args[1] else null;
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);

    const style = optStr(opts, "style") orelse "decimal";
    const currency = optStr(opts, "currency") orelse "USD";
    const is_currency = std.mem.eql(u8, style, "currency");
    const is_jpy = std.mem.eql(u8, currency, "JPY");

    // Default fraction digits per style (en-US).
    const default_min: u32 = if (is_currency) (if (is_jpy) 0 else 2) else 0;
    const default_max: u32 = if (is_currency) (if (is_jpy) 0 else 2) else if (std.mem.eql(u8, style, "percent")) 0 else 3;

    const min_frac: u32 = if (optNum(opts, "minimumFractionDigits")) |m| try toFracDigits(arena, m) else default_min;
    const max_frac: u32 = if (optNum(opts, "maximumFractionDigits")) |m| try toFracDigits(arena, m) else @max(default_max, min_frac);
    const group: bool = optBool(opts, "useGrouping") orelse true;

    try obj.set("__intl_style", try val_mod.makeString(arena, style));
    try obj.set("__intl_currency", try val_mod.makeString(arena, currency));
    try obj.set("__intl_minFrac", try val_mod.makeNumber(arena, @floatFromInt(min_frac)));
    try obj.set("__intl_maxFrac", try val_mod.makeNumber(arena, @floatFromInt(max_frac)));
    try obj.set("__intl_group", try val_mod.makeBool(arena, group));
    return val_mod.makeObject(arena, obj);
}

pub fn nativeNumberFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return val_mod.makeString(arena, "");
    const o = this_val.toPtr().object;
    const style = if (o.get("__intl_style")) |v| (if (v.bits != 0 and v.unbox() == .string) v.unbox().string else "decimal") else "decimal";
    const currency = if (o.get("__intl_currency")) |v| (if (v.bits != 0 and v.unbox() == .string) v.unbox().string else "USD") else "USD";
    const min_frac: u32 = if (o.get("__intl_minFrac")) |v| (if (v.bits != 0 and v.unbox() == .number) @intFromFloat(v.unbox().number) else 0) else 0;
    const max_frac: u32 = if (o.get("__intl_maxFrac")) |v| (if (v.bits != 0 and v.unbox() == .number) @intFromFloat(v.unbox().number) else 3) else 3;
    const group: bool = if (o.get("__intl_group")) |v| (if (v.bits != 0 and v.unbox() == .boolean) v.unbox().boolean else true) else true;
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    const s = try formatNumber(arena, n, style, currency, min_frac, max_frac, group);
    return val_mod.makeString(arena, s);
}

// --------------------------------------------------------------- DateTimeFormat ---

pub fn nativeDateTimeFormatCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    return val_mod.makeObject(arena, obj);
}

/// `dtf.format(date)` → `M/D/YYYY` (UTC fields, deterministic — no local TZ).
pub fn nativeDateTimeFormatFormat(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const date_mod = @import("date.zig");
    const ms: i64 = blk: {
        if (args.len > 0 and args[0].bits != 0) {
            if (args[0].unbox() == .number) break :blk @intFromFloat(args[0].unbox().number);
            if (args[0].unbox() == .object) {
                if (date_mod.getDateMs(args[0])) |m| break :blk m;
            }
        }
        break :blk std.time.milliTimestamp();
    };
    const f = date_mod.msToFieldsUtc(ms);
    const s = try std.fmt.allocPrint(arena, "{d}/{d}/{d}", .{ f.month + 1, f.day, f.year });
    return val_mod.makeString(arena, s);
}

// ------------------------------------------------------------------- Collator ---

pub fn nativeCollatorCtor(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    return val_mod.makeObject(arena, obj);
}

pub fn nativeCollatorCompare(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const a: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) args[0].unbox().string else "";
    const b: []const u8 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .string) args[1].unbox().string else "";
    const order = std.mem.order(u8, a, b);
    const r: f64 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return val_mod.makeNumber(arena, r);
}
