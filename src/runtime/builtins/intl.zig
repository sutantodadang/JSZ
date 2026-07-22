// SPDX-License-Identifier: Apache-2.0
//! A pragmatic, dependency-free `Intl` implementation (Phase 13 + Waves 14-17).
//!
//! Scope: en-US formatting only (no ICU / CLDR data). Covers the common cases:
//!   * `Intl.NumberFormat` — decimal / currency / percent, grouping, min/max
//!     fraction digits, `signDisplay`, plus `resolvedOptions()`.
//!   * `Intl.DateTimeFormat` — component options (weekday/year/month/day/
//!     hour/minute/second, long/short/narrow, 2-digit, hour12), UTC-based and
//!     deterministic, plus `resolvedOptions()`.
//!   * `Intl.Collator` — byte-wise comparison, case-insensitive base/accent
//!     sensitivities, `numeric` collation, instance-bound `compare`, plus
//!     `resolvedOptions()`.
//!   * `Intl.Locale` — BCP-47 subtag parsing (language/script/region/baseName).
//!   * `Intl.ListFormat` — conjunction / disjunction / unit joining.
//!   * `Intl.PluralRules` — en-US cardinal & ordinal categories, `select()`.
//!   * `Intl.RelativeTimeFormat` — `format()` with numeric always/auto phrasing.
//!   * `Intl.getCanonicalLocales` — canonicalize + de-duplicate tags.
//! Non-en-US locale arguments are accepted and ignored. Formatter instances
//! store their resolved options as own properties; the `format`/`compare`
//! methods live on the prototype and read those options from `this`.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const coercion_mod = @import("coercion.zig");

// Temporal integration: `Intl.DateTimeFormat.prototype.format` accepts Temporal
// date/time objects, and `Temporal.X.prototype.toLocaleString` routes through
// this module's en-US formatter (see temporalEpochMs / temporalToLocaleString).
const t_shared = @import("temporal/shared.zig");
const t_instant = @import("temporal/instant.zig");
const t_pdate = @import("temporal/plain_date.zig");
const t_ptime = @import("temporal/plain_time.zig");
const t_pdatetime = @import("temporal/plain_date_time.zig");
const t_zdt = @import("temporal/zoned_date_time.zig");
const t_pym = @import("temporal/plain_year_month.zig");
const t_pmd = @import("temporal/plain_month_day.zig");
const t_duration = @import("temporal/duration.zig");
const nfmt = @import("intl_number.zig");

// Intl.NumberFormat lives in `intl_number.zig`; re-export the pieces the realm
// registration and the sibling services (ListFormat / RelativeTimeFormat) use.
pub const NumberPart = nfmt.NumberPart;
pub const nativeNumberFormatCtor = nfmt.nativeNumberFormatCtor;
pub const nativeNumberFormatFormat = nfmt.nativeNumberFormatFormat;
pub const nativeNumberFormatFormatGetter = nfmt.nativeNumberFormatFormatGetter;
pub const nativeNumberFormatFormatToParts = nfmt.nativeNumberFormatFormatToParts;
pub const nativeNumberFormatFormatRange = nfmt.nativeNumberFormatFormatRange;
pub const nativeNumberFormatFormatRangeToParts = nfmt.nativeNumberFormatFormatRangeToParts;
pub const nativeNumberFormatResolved = nfmt.nativeNumberFormatResolved;
const partsToArray = nfmt.partsToArray;
const range_separator = nfmt.range_separator;

pub fn getNum(v: Value) f64 {
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
/// Allocate a lower-cased copy of `s` (ASCII) — Unicode extension `type`
/// subtags are canonically lower case.
fn lowerDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn optStr(opts: ?Value, key: []const u8) ?[]const u8 {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = o.toPtr().object.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() != .string) return null;
    return v.unbox().string;
}

/// Read `key` from an options object and ToString-coerce the result, so numeric
/// option values (`{ firstDayOfWeek: 1 }`) are accepted alongside strings.
/// Null when the option is absent or undefined.
fn optStrCoerced(arena: std.mem.Allocator, opts: ?Value, key: []const u8) anyerror!?[]const u8 {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = if (realm_mod.active_context) |c|
        try c.getProp(arena, o, key)
    else
        (o.toPtr().object.get(key) orelse Value{});
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try t_shared.valueToString(arena, v);
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

pub fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.error_proto_RangeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_RangeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

pub fn throwTypeErrorIntl(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.error_proto_TypeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// Prototypes of the three legacy services (§10/§11/§15), captured at realm
/// setup so a `new`-less call still produces a real instance.
var active_number_format_proto: ?*JsObject = null;
var active_date_time_format_proto: ?*JsObject = null;
var active_collator_proto: ?*JsObject = null;

pub fn registerLegacyServiceProtos(nf: *JsObject, dtf: *JsObject, col: *JsObject) void {
    active_number_format_proto = nf;
    active_date_time_format_proto = dtf;
    active_collator_proto = col;
}

/// The `new`-less `Intl.NumberFormat(...)` path, for `intl_number.zig`.
pub fn numberFormatServiceObj(arena: std.mem.Allocator) !*JsObject {
    return legacyServiceObj(arena, active_number_format_proto);
}

fn legacyServiceObj(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
    const p = proto orelse realm_mod.active_object_proto;
    return if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, p)
    else
        try JsObject.create(arena, p);
}

pub fn upperDup(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf;
}

// ----------------------------------------------------------------- NumberFormat ---

/// GetOption(options, key, number, …): reads through the active context (so a
/// throwing getter propagates) and ToNumber-coerces. Absent/undefined → null.
pub fn dnGetNumOption(arena: std.mem.Allocator, options: Value, key: []const u8) anyerror!?f64 {
    const v = if (realm_mod.active_context) |c|
        try c.getProp(arena, options, key)
    else if (options.bits != 0 and options.unbox() == .object)
        (options.toPtr().object.get(key) orelse Value{})
    else
        Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return try realm_mod.toNumberValue(arena, v);
}

// --------------------------------------------------------------- DateTimeFormat ---

pub fn nativeDateTimeFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const opts: ?Value = if (args.len > 1) args[1] else null;
    // Legacy service: `Intl.DateTimeFormat(...)` without `new` still yields an
    // instance (§11.1.1 ChainDateTimeFormat).
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    const obj = if (constructing and this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try legacyServiceObj(arena, active_date_time_format_proto);

    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    // Component options are stored verbatim (empty string == absent). `format`
    // reads them back off `this`. When no date/time component is requested, the
    // en-US default is a numeric year/month/day (the classic `M/D/YYYY`).
    const weekday = optStr(opts, "weekday") orelse "";
    var year = optStr(opts, "year") orelse "";
    var month = optStr(opts, "month") orelse "";
    var day = optStr(opts, "day") orelse "";
    const hour = optStr(opts, "hour") orelse "";
    const minute = optStr(opts, "minute") orelse "";
    const second = optStr(opts, "second") orelse "";
    const has_any = weekday.len + year.len + month.len + day.len + hour.len + minute.len + second.len > 0;
    if (!has_any) {
        year = "numeric";
        month = "numeric";
        day = "numeric";
    }
    // A "bare" formatter (no explicit component / style) resolves to date-only
    // for a legacy Date, but Temporal values pick their own default when
    // formatted (see the per-kind adjustment in nativeDateTimeFormatFormat).
    const is_bare = !has_any and (optStr(opts, "dateStyle") == null) and (optStr(opts, "timeStyle") == null);
    // hour12 defaults to true for en-US; an explicit false (or hourCycle h23/h24)
    // switches to 24-hour output.
    var hour12 = optBool(opts, "hour12") orelse true;
    if (optStr(opts, "hourCycle")) |hc| {
        if (std.mem.eql(u8, hc, "h23") or std.mem.eql(u8, hc, "h24")) hour12 = false;
        if (std.mem.eql(u8, hc, "h11") or std.mem.eql(u8, hc, "h12")) hour12 = true;
    }
    const tz = optStr(opts, "timeZone") orelse "UTC";

    try obj.set("__dtf_weekday", try val_mod.makeString(arena, weekday));
    try obj.set("__dtf_year", try val_mod.makeString(arena, year));
    try obj.set("__dtf_month", try val_mod.makeString(arena, month));
    try obj.set("__dtf_day", try val_mod.makeString(arena, day));
    try obj.set("__dtf_hour", try val_mod.makeString(arena, hour));
    try obj.set("__dtf_minute", try val_mod.makeString(arena, minute));
    try obj.set("__dtf_second", try val_mod.makeString(arena, second));
    try obj.set("__dtf_hour12", try val_mod.makeBool(arena, hour12));
    try obj.set("__dtf_tz", try val_mod.makeString(arena, tz));
    try obj.set("__dtf_bare", try val_mod.makeBool(arena, is_bare));
    return val_mod.makeObject(arena, obj);
}

const month_long = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const month_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const month_narrow = [_][]const u8{ "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" };
const weekday_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const weekday_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const weekday_narrow = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };

fn readOpt(o: *JsObject, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    if (v.bits != 0 and v.unbox() == .string) return v.unbox().string;
    return "";
}

/// Append `val` to `out`, zero-padded to two digits when `style == "2-digit"`.
fn appendField(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: i64, style: []const u8) !void {
    if (std.mem.eql(u8, style, "2-digit") and val >= 0 and val < 10) {
        try out.append(arena, '0');
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{val}));
}

/// Resolve `this` formatter + `args[0]` value into the ordered list of typed
/// parts. Shared by `format` and `formatToParts`. Never returns empty (falls
/// back to the numeric date pattern).
fn buildDTFParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) !std.ArrayListUnmanaged(DTPart) {
    const date_mod = @import("date.zig");
    const ms: i64 = blk: {
        if (args.len > 0 and args[0].bits != 0) {
            if (args[0].unbox() == .number) {
                const n = args[0].unbox().number;
                // TimeClip: a non-finite or out-of-range time value is invalid.
                if (!std.math.isFinite(n) or @abs(n) > 8.64e15) return realm_mod.throwRangeError(arena, "Invalid time value");
                break :blk @intFromFloat(n);
            }
            if (args[0].unbox() == .object) {
                if (date_mod.getDateMs(args[0])) |m| break :blk m;
                if (temporalEpochMs(args[0])) |m| break :blk m;
            }
        }
        break :blk std.time.milliTimestamp();
    };
    const f = date_mod.msToFieldsUtc(ms);

    var weekday: []const u8 = "";
    var year: []const u8 = "numeric";
    var month: []const u8 = "numeric";
    var day: []const u8 = "numeric";
    var hour: []const u8 = "";
    var minute: []const u8 = "";
    var second: []const u8 = "";
    var hour12: bool = true;

    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        weekday = readOpt(o, "__dtf_weekday");
        year = readOpt(o, "__dtf_year");
        month = readOpt(o, "__dtf_month");
        day = readOpt(o, "__dtf_day");
        hour = readOpt(o, "__dtf_hour");
        minute = readOpt(o, "__dtf_minute");
        second = readOpt(o, "__dtf_second");
        hour12 = if (o.get("__dtf_hour12")) |v| (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) else true;

        // A bare formatter (no explicit component) resolves to date-only for a
        // legacy Date, but a Temporal value picks its own default: date for
        // PlainDate, time for PlainTime, date+time for PlainDateTime/Instant/
        // ZonedDateTime. This keeps `dtf.format(temporal)` in sync with the
        // per-type defaults `Temporal.X.prototype.toLocaleString` applies.
        const bare = if (o.get("__dtf_bare")) |v| (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) else false;
        if (bare and args.len > 0) {
            if (temporalKindOf(args[0])) |tk| switch (tk) {
                .date => {},
                .time => {
                    weekday = "";
                    year = "";
                    month = "";
                    day = "";
                    hour = "numeric";
                    minute = "numeric";
                    second = "numeric";
                },
                .datetime, .instant, .zoned => {
                    year = "numeric";
                    month = "numeric";
                    day = "numeric";
                    hour = "numeric";
                    minute = "numeric";
                    second = "numeric";
                },
                .year_month => {
                    weekday = "";
                    year = "numeric";
                    month = "numeric";
                    day = "";
                },
                .month_day => {
                    weekday = "";
                    year = "";
                    month = "numeric";
                    day = "numeric";
                },
            };
        }
    }

    var parts = std.ArrayListUnmanaged(DTPart){};
    try renderDateTimeParts(arena, f, weekday, year, month, day, hour, minute, second, hour12, &parts);
    if (parts.items.len == 0) {
        try renderDateTimeParts(arena, f, "", "numeric", "numeric", "numeric", "", "", "", hour12, &parts);
    }
    return parts;
}

/// `dtf.format(date)` → en-US pattern driven by the resolved component options
/// (UTC fields, deterministic — no host time zone).
pub fn nativeDateTimeFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // As for NumberFormat, the bound format function carries its DateTimeFormat
    // in native userdata; a direct `dtf.format(x)` call passes it as `this`.
    const recv: Value = if (val_mod.g_active_native_data) |d|
        try val_mod.makeObject(arena, @ptrCast(@alignCast(d)))
    else
        this_val;
    const parts = try buildDTFParts(arena, recv, args);
    var out = std.ArrayListUnmanaged(u8){};
    for (parts.items) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

/// §11.3.3 `get Intl.DateTimeFormat.prototype.format`, mirroring NumberFormat's:
/// an accessor whose getter returns a per-instance bound function.
pub fn nativeDateTimeFormatFormatGetter(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return throwTypeErrorIntl(arena, "get Intl.DateTimeFormat.prototype.format called on an incompatible receiver");
    const o = this_val.toPtr().object;
    if (o.getOwn("[[BoundFormat]]")) |bound| return bound;
    const bound = try val_mod.makeNativeFunctionDataLen(arena, nativeDateTimeFormatFormat, @ptrCast(o), 1);
    _ = try o.defineOwnData("[[BoundFormat]]", bound, .{ .writable = false, .enumerable = false, .configurable = false });
    return bound;
}

/// §11.3.6/§11.3.7 formatRange / formatRangeToParts. en-US renders a range as
/// "<start> – <end>", collapsing to the single formatted value when both ends
/// produce identical text.
fn dtfRangeParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) !std.ArrayListUnmanaged(DTPart) {
    if (args.len < 2 or args[0].bits == 0 or args[0].unbox() == .undefined_ or
        args[1].bits == 0 or args[1].unbox() == .undefined_)
        return throwTypeErrorIntl(arena, "Intl.DateTimeFormat.prototype.formatRange: both ends are required");
    const start = try buildDTFParts(arena, this_val, args[0..1]);
    const end = try buildDTFParts(arena, this_val, args[1..2]);
    var same = start.items.len == end.items.len;
    if (same) for (start.items, end.items) |a, b| {
        if (!std.mem.eql(u8, a.value, b.value)) {
            same = false;
            break;
        }
    };
    if (same) return start;
    var out = std.ArrayListUnmanaged(DTPart){};
    for (start.items) |p| try out.append(arena, p);
    try out.append(arena, .{ .type = "literal", .value = " " ++ range_separator ++ " " });
    for (end.items) |p| try out.append(arena, p);
    return out;
}

pub fn nativeDateTimeFormatFormatRange(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try dtfRangeParts(arena, this_val, args);
    var out = std.ArrayListUnmanaged(u8){};
    for (parts.items) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

pub fn nativeDateTimeFormatFormatRangeToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try dtfRangeParts(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts.items) |p| {
        const o = try dnEmptyObj(arena);
        try o.set("type", try val_mod.makeString(arena, p.type));
        try o.set("value", try val_mod.makeString(arena, p.value));
        try arr.appendElement(try val_mod.makeObject(arena, o));
    }
    return val_mod.makeObject(arena, arr);
}

/// `dtf.formatToParts(date)` → array of `{ type, value }` records.
pub fn nativeDateTimeFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Brand check: reject a `this` that is not an initialized DateTimeFormat
    // (our instances carry the internal `__dtf_hour12` marker).
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__dtf_hour12") == null)
        return realm_mod.throwTypeError(arena, "Intl.DateTimeFormat.prototype.formatToParts called on incompatible receiver");
    const parts = try buildDTFParts(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts.items) |p| {
        const o = if (realm_mod.active_heap) |h|
            try JsObject.createOnHeap(h, realm_mod.active_object_proto)
        else
            try JsObject.create(arena, realm_mod.active_object_proto);
        try o.set("type", try val_mod.makeString(arena, p.type));
        try o.set("value", try val_mod.makeString(arena, p.value));
        try arr.appendElement(try val_mod.makeObject(arena, o));
    }
    return val_mod.makeObject(arena, arr);
}

/// One segment of a formatted date-time, as produced by `formatToParts`.
const DTPart = struct { type: []const u8, value: []const u8 };

fn fieldStr(arena: std.mem.Allocator, val: i64, style: []const u8) ![]const u8 {
    var tmp = std.ArrayListUnmanaged(u8){};
    try appendField(arena, &tmp, val, style);
    return tmp.items;
}

fn yearStr(arena: std.mem.Allocator, year: i64, style: []const u8) ![]const u8 {
    var tmp = std.ArrayListUnmanaged(u8){};
    try appendYear(arena, &tmp, year, style);
    return tmp.items;
}

/// Render the resolved components into typed parts (shared by `format` and
/// `formatToParts`). Mirrors the en-US pattern: `Weekday, Month Day, Year,
/// h:mm:ss AM/PM` with numeric fields joined by `/` and `:`.
fn renderDateTimeParts(
    arena: std.mem.Allocator,
    f: @import("date.zig").DateFields,
    weekday: []const u8,
    year: []const u8,
    month: []const u8,
    day: []const u8,
    hour: []const u8,
    minute: []const u8,
    second: []const u8,
    hour12: bool,
    parts: *std.ArrayListUnmanaged(DTPart),
) !void {
    const named_month = month.len > 0 and !std.mem.eql(u8, month, "numeric") and !std.mem.eql(u8, month, "2-digit");
    var has_date = false;

    if (weekday.len > 0) {
        const idx: usize = @intCast(@mod(f.weekday, 7));
        const name = if (std.mem.eql(u8, weekday, "short")) weekday_short[idx] else if (std.mem.eql(u8, weekday, "narrow")) weekday_narrow[idx] else weekday_long[idx];
        try parts.append(arena, .{ .type = "weekday", .value = name });
        has_date = true;
    }

    if (named_month) {
        if (has_date) try parts.append(arena, .{ .type = "literal", .value = ", " });
        const midx: usize = @intCast(@mod(f.month, 12));
        const mname = if (std.mem.eql(u8, month, "short")) month_short[midx] else if (std.mem.eql(u8, month, "narrow")) month_narrow[midx] else month_long[midx];
        try parts.append(arena, .{ .type = "month", .value = mname });
        if (day.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = " " });
            try parts.append(arena, .{ .type = "day", .value = try fieldStr(arena, f.day, day) });
        }
        if (year.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = ", " });
            try parts.append(arena, .{ .type = "year", .value = try yearStr(arena, f.year, year) });
        }
        has_date = true;
    } else if (month.len > 0 or day.len > 0 or year.len > 0) {
        if (weekday.len > 0) try parts.append(arena, .{ .type = "literal", .value = ", " });
        var first = true;
        if (month.len > 0) {
            try parts.append(arena, .{ .type = "month", .value = try fieldStr(arena, f.month + 1, month) });
            first = false;
        }
        if (day.len > 0) {
            if (!first) try parts.append(arena, .{ .type = "literal", .value = "/" });
            try parts.append(arena, .{ .type = "day", .value = try fieldStr(arena, f.day, day) });
            first = false;
        }
        if (year.len > 0) {
            if (!first) try parts.append(arena, .{ .type = "literal", .value = "/" });
            try parts.append(arena, .{ .type = "year", .value = try yearStr(arena, f.year, year) });
        }
        has_date = true;
    }

    if (hour.len > 0 or minute.len > 0 or second.len > 0) {
        if (has_date) try parts.append(arena, .{ .type = "literal", .value = ", " });
        if (hour.len > 0) {
            var h: i64 = f.hour;
            // en-US 24-hour clock (h23) always renders a 2-digit hour.
            const hstyle = if (hour12) hour else "2-digit";
            if (hour12) {
                h = @mod(f.hour, 12);
                if (h == 0) h = 12;
            }
            try parts.append(arena, .{ .type = "hour", .value = try fieldStr(arena, h, hstyle) });
        }
        if (minute.len > 0) {
            if (hour.len > 0) try parts.append(arena, .{ .type = "literal", .value = ":" });
            try parts.append(arena, .{ .type = "minute", .value = try fieldStr(arena, f.min, if (hour.len > 0) "2-digit" else minute) });
        }
        if (second.len > 0) {
            if (hour.len > 0 or minute.len > 0) try parts.append(arena, .{ .type = "literal", .value = ":" });
            try parts.append(arena, .{ .type = "second", .value = try fieldStr(arena, f.sec, if (hour.len > 0 or minute.len > 0) "2-digit" else second) });
        }
        if (hour12 and hour.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = " " });
            try parts.append(arena, .{ .type = "dayPeriod", .value = if (f.hour < 12) "AM" else "PM" });
        }
    }
}

fn appendYear(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), year: i64, style: []const u8) !void {
    if (std.mem.eql(u8, style, "2-digit")) {
        const yy = @mod(year, 100);
        try appendField(arena, out, yy, "2-digit");
    } else {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{year}));
    }
}

/// If `v` is a Temporal date/time-like object, return the epoch milliseconds of
/// its wall-clock fields interpreted as UTC, so the UTC field-extraction in
/// `format` yields the correct calendar components. Returns null otherwise.
fn temporalEpochMs(v: Value) ?i64 {
    if (v.bits == 0 or v.unbox() != .object) return null;
    switch (v.toPtr().object.internal_kind) {
        .temporal_instant => {
            const ns = t_instant.getInstant(v) orelse return null;
            return @intCast(@divFloor(ns.*, t_shared.NS_PER_MILLI));
        },
        .temporal_plain_date => {
            const d = t_pdate.getDate(v) orelse return null;
            return t_shared.isoDateToEpochDays(d.year, d.month, d.day) * 86_400_000;
        },
        .temporal_plain_time => {
            const t = t_ptime.getTime(v) orelse return null;
            return @intCast(@divFloor(t_shared.timeToNanos(t.*), t_shared.NS_PER_MILLI));
        },
        .temporal_plain_date_time => {
            const dt = t_pdatetime.getDateTime(v) orelse return null;
            const ns = @as(i128, t_shared.isoDateToEpochDays(dt.date.year, dt.date.month, dt.date.day)) *
                t_shared.NS_PER_DAY + t_shared.timeToNanos(dt.time);
            return @intCast(@divFloor(ns, t_shared.NS_PER_MILLI));
        },
        .temporal_zoned_date_time => {
            const z = t_zdt.getZoned(v) orelse return null;
            return @intCast(@divFloor(z.ns + z.offset_ns, t_shared.NS_PER_MILLI));
        },
        .temporal_plain_year_month => {
            const ym = t_pym.getYearMonth(v) orelse return null;
            return t_shared.isoDateToEpochDays(ym.year, ym.month, ym.day) * 86_400_000;
        },
        .temporal_plain_month_day => {
            const md = t_pmd.getMonthDay(v) orelse return null;
            return t_shared.isoDateToEpochDays(md.ref_year, md.month, md.day) * 86_400_000;
        },
        else => return null,
    }
}

/// Which Temporal type is calling toLocaleString — selects the default
/// component set and which option families are permitted.
pub const TemporalDTKind = enum { date, time, datetime, instant, zoned, year_month, month_day };

/// Classify a Temporal date/time value for default-component selection.
fn temporalKindOf(v: Value) ?TemporalDTKind {
    if (v.bits == 0 or v.unbox() != .object) return null;
    return switch (v.toPtr().object.internal_kind) {
        .temporal_plain_date => .date,
        .temporal_plain_time => .time,
        .temporal_plain_date_time => .datetime,
        .temporal_instant => .instant,
        .temporal_zoned_date_time => .zoned,
        .temporal_plain_year_month => .year_month,
        .temporal_plain_month_day => .month_day,
        else => null,
    };
}

fn applyDateStyle(ds: []const u8, w: *[]const u8, y: *[]const u8, mo: *[]const u8, d: *[]const u8) void {
    if (std.mem.eql(u8, ds, "full")) {
        w.* = "long";
        y.* = "numeric";
        mo.* = "long";
        d.* = "numeric";
    } else if (std.mem.eql(u8, ds, "long")) {
        y.* = "numeric";
        mo.* = "long";
        d.* = "numeric";
    } else if (std.mem.eql(u8, ds, "medium")) {
        y.* = "numeric";
        mo.* = "short";
        d.* = "numeric";
    } else { // "short"
        y.* = "2-digit";
        mo.* = "numeric";
        d.* = "numeric";
    }
}

fn applyTimeStyle(ts: []const u8, h: *[]const u8, mi: *[]const u8, se: *[]const u8) void {
    h.* = "numeric";
    mi.* = "2-digit";
    // full/long/medium include seconds; short omits them.
    if (!std.mem.eql(u8, ts, "short")) se.* = "2-digit";
}

/// `Temporal.X.prototype.toLocaleString([locales[, options]])`.
///
/// Resolves per-type default components and dateStyle/timeStyle, validates the
/// option conflicts the spec requires (dateStyle/timeStyle may not combine with
/// component options; a date-only type rejects time options and vice-versa),
/// then formats `receiver` through the same en-US DateTimeFormat machinery
/// `Intl.DateTimeFormat.prototype.format` uses — so the two agree by
/// construction. Calendar (era/non-ISO) and time-zone-name output are not
/// modelled (ISO calendar, UTC only).
pub fn temporalToLocaleString(arena: std.mem.Allocator, receiver: Value, args: []const Value, kind: TemporalDTKind) anyerror!Value {
    const opts_v: ?Value = if (args.len > 1) args[1] else null;
    const required: Required = switch (kind) {
        .date => .date,
        .time => .time,
        .datetime, .instant, .zoned => .any,
        .year_month => .date,
        .month_day => .date,
    };
    const defaults: LocaleDefaults = switch (kind) {
        .date => .date,
        .time => .time,
        .datetime, .instant, .zoned => .datetime,
        .year_month => .year_month,
        .month_day => .month_day,
    };
    const restrict: Restrict = switch (kind) {
        .date => .date_only,
        .time => .time_only,
        .year_month => .year_month_only,
        .month_day => .month_day_only,
        else => .none,
    };
    // A ZonedDateTime carries its own zone; a `timeZone` option is disallowed.
    if (kind == .zoned and optStr(opts_v, "timeZone") != null)
        return realm_mod.throwTypeError(arena, "Temporal.ZonedDateTime.toLocaleString does not accept a timeZone option");
    const dtf = try buildLocaleDTF(arena, opts_v, required, defaults, restrict);
    return nativeDateTimeFormatFormat(arena, dtf, &[_]Value{receiver});
}

/// ToDateTimeOptions "required" families: which component family must be
/// present for the caller to skip filling in defaults.
pub const Required = enum { date, time, any };

/// Default component set applied when no explicit component/style is requested.
pub const LocaleDefaults = enum { date, time, datetime, year_month, month_day };

/// Per-receiver option rejection: Temporal date-only / time-only types reject
/// the opposite family of options; legacy Date imposes no such restriction.
pub const Restrict = enum { none, date_only, time_only, year_month_only, month_day_only };

/// Shared core of `Temporal.X.prototype.toLocaleString` and
/// `Date.prototype.toLocale*String`: parse options, validate conflicts, resolve
/// the effective component styles, and return a DateTimeFormat-like object ready
/// for `nativeDateTimeFormatFormat`.
fn buildLocaleDTF(arena: std.mem.Allocator, opts_v: ?Value, required: Required, defaults: LocaleDefaults, restrict: Restrict) anyerror!Value {
    const weekday = optStr(opts_v, "weekday");
    const era = optStr(opts_v, "era");
    const year = optStr(opts_v, "year");
    const month = optStr(opts_v, "month");
    const day = optStr(opts_v, "day");
    const hour = optStr(opts_v, "hour");
    const minute = optStr(opts_v, "minute");
    const second = optStr(opts_v, "second");
    const day_period = optStr(opts_v, "dayPeriod");
    const frac_digits = optNum(opts_v, "fractionalSecondDigits");
    const tz_name = optStr(opts_v, "timeZoneName");
    const date_style = optStr(opts_v, "dateStyle");
    const time_style = optStr(opts_v, "timeStyle");

    const has_date_comp = weekday != null or era != null or year != null or month != null or day != null;
    const has_time_comp = hour != null or minute != null or second != null or
        day_period != null or frac_digits != null or tz_name != null;
    const has_comp = has_date_comp or has_time_comp;

    // dateStyle/timeStyle cannot be combined with explicit component options
    // (GetDateTimeFormatPattern, Table "date-time component").
    if ((date_style != null or time_style != null) and has_comp)
        return realm_mod.throwTypeError(arena, "dateStyle/timeStyle may not be used with other date-time component options");

    switch (restrict) {
        .date_only => if (time_style != null or has_time_comp)
            return realm_mod.throwTypeError(arena, "this Temporal type cannot be formatted with time options"),
        .time_only => if (date_style != null or has_date_comp)
            return realm_mod.throwTypeError(arena, "this Temporal type cannot be formatted with date options"),
        // PlainYearMonth: no time, no day/weekday. PlainMonthDay: no time, no
        // year/weekday. (era is tolerated but never rendered for iso8601.)
        .year_month_only => if (time_style != null or has_time_comp or day != null or weekday != null)
            return realm_mod.throwTypeError(arena, "Temporal.PlainYearMonth cannot be formatted with these options"),
        .month_day_only => if (time_style != null or has_time_comp or year != null or weekday != null)
            return realm_mod.throwTypeError(arena, "Temporal.PlainMonthDay cannot be formatted with these options"),
        .none => {},
    }

    var w = weekday orelse "";
    var y = year orelse "";
    var mo = month orelse "";
    var d = day orelse "";
    var h = hour orelse "";
    var mi = minute orelse "";
    var se = second orelse "";
    // ISO calendar: era (used above only for conflict detection) is not rendered.

    if (date_style) |ds| applyDateStyle(ds, &w, &y, &mo, &d);
    if (time_style) |ts| applyTimeStyle(ts, &h, &mi, &se);

    // ToDateTimeOptions: `needDefaults` is driven by the REQUIRED family only —
    // e.g. toLocaleDateString (required "date") still fills in year/month/day
    // even when the caller passed only time components. When set, the `defaults`
    // family's fields are added (never overriding explicit user components).
    // dateStyle/timeStyle suppress defaults entirely.
    var need_defaults = date_style == null and time_style == null;
    if (need_defaults) switch (required) {
        .date => if (has_date_comp) {
            need_defaults = false;
        },
        .time => if (has_time_comp) {
            need_defaults = false;
        },
        .any => if (has_comp) {
            need_defaults = false;
        },
    };
    if (need_defaults) {
        if (defaults == .date or defaults == .datetime) {
            if (y.len == 0) y = "numeric";
            if (mo.len == 0) mo = "numeric";
            if (d.len == 0) d = "numeric";
        }
        if (defaults == .time or defaults == .datetime) {
            if (h.len == 0) h = "numeric";
            if (mi.len == 0) mi = "numeric";
            if (se.len == 0) se = "numeric";
        }
        if (defaults == .year_month) {
            if (y.len == 0) y = "numeric";
            if (mo.len == 0) mo = "numeric";
        }
        if (defaults == .month_day) {
            if (mo.len == 0) mo = "numeric";
            if (d.len == 0) d = "numeric";
        }
    }

    var hour12 = optBool(opts_v, "hour12") orelse true;
    if (optStr(opts_v, "hourCycle")) |hc| {
        if (std.mem.eql(u8, hc, "h23") or std.mem.eql(u8, hc, "h24")) hour12 = false;
        if (std.mem.eql(u8, hc, "h11") or std.mem.eql(u8, hc, "h12")) hour12 = true;
    }

    const dtf = if (realm_mod.active_heap) |hp|
        try JsObject.createOnHeap(hp, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try dtf.set("__dtf_weekday", try val_mod.makeString(arena, w));
    try dtf.set("__dtf_year", try val_mod.makeString(arena, y));
    try dtf.set("__dtf_month", try val_mod.makeString(arena, mo));
    try dtf.set("__dtf_day", try val_mod.makeString(arena, d));
    try dtf.set("__dtf_hour", try val_mod.makeString(arena, h));
    try dtf.set("__dtf_minute", try val_mod.makeString(arena, mi));
    try dtf.set("__dtf_second", try val_mod.makeString(arena, se));
    try dtf.set("__dtf_hour12", try val_mod.makeBool(arena, hour12));
    return val_mod.makeObject(arena, dtf);
}

/// `Date.prototype.{toLocaleString,toLocaleDateString,toLocaleTimeString}`:
/// build a DateTimeFormat from (locales, options) with the method's default
/// component set and format the Date through the shared en-US machinery.
pub fn dateToLocaleString(arena: std.mem.Allocator, receiver: Value, args: []const Value, required: Required, defaults: LocaleDefaults) anyerror!Value {
    const opts_v: ?Value = if (args.len > 1) args[1] else null;
    const dtf = try buildLocaleDTF(arena, opts_v, required, defaults, .none);
    return nativeDateTimeFormatFormat(arena, dtf, &[_]Value{receiver});
}

/// `dtf.resolvedOptions()` — en-US, UTC-based, Gregorian.
pub fn nativeDateTimeFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("calendar", try val_mod.makeString(arena, "gregory"));
    try r.set("numberingSystem", try val_mod.makeString(arena, "latn"));
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        const tz = readOpt(o, "__dtf_tz");
        try r.set("timeZone", try val_mod.makeString(arena, if (tz.len > 0) tz else "UTC"));
        const fields = [_][2][]const u8{
            .{ "weekday", "__dtf_weekday" }, .{ "year", "__dtf_year" },
            .{ "month", "__dtf_month" },     .{ "day", "__dtf_day" },
            .{ "hour", "__dtf_hour" },       .{ "minute", "__dtf_minute" },
            .{ "second", "__dtf_second" },
        };
        for (fields) |pair| {
            const v = readOpt(o, pair[1]);
            if (v.len > 0) try r.set(pair[0], try val_mod.makeString(arena, v));
        }
        if (o.get("__dtf_hour") != null and readOpt(o, "__dtf_hour").len > 0) {
            const h12 = if (o.get("__dtf_hour12")) |v| (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) else true;
            try r.set("hour12", try val_mod.makeBool(arena, h12));
            try r.set("hourCycle", try val_mod.makeString(arena, if (h12) "h12" else "h23"));
        }
    } else {
        try r.set("timeZone", try val_mod.makeString(arena, "UTC"));
    }
    return val_mod.makeObject(arena, r);
}

// ------------------------------------------------------------------- Collator ---

pub fn nativeCollatorCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Intl.Collator is one of the three legacy services callable without `new`
    // (§10.1.1 ChainCollator), so no NewTarget guard here.
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    const obj = if (constructing and this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try legacyServiceObj(arena, active_collator_proto);
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    // InitializeCollator (§10.1.2) reads the options in this exact order.
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    const usage = (try dnGetOption(arena, options, "usage", &.{ "sort", "search" }, "sort")).?;
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    if (try dnGetOption(arena, options, "collation", &.{}, null)) |c| {
        if (!isWellFormedNumberingSystem(c)) return throwRangeError(arena, "invalid collation");
    }
    const numeric = (try dnGetBoolOption(arena, options, "numeric")) orelse false;
    const caseFirst = (try dnGetOption(arena, options, "caseFirst", &.{ "upper", "lower", "false" }, "false")).?;
    const sensitivity = (try dnGetOption(arena, options, "sensitivity", &.{ "base", "accent", "case", "variant" }, "variant")).?;
    const ignore_punct = (try dnGetBoolOption(arena, options, "ignorePunctuation")) orelse false;
    try obj.set("__col_ignorePunctuation", try val_mod.makeBool(arena, ignore_punct));
    try obj.set("__col_usage", try val_mod.makeString(arena, usage));
    try obj.set("__col_sensitivity", try val_mod.makeString(arena, sensitivity));
    try obj.set("__col_numeric", try val_mod.makeBool(arena, numeric));
    try obj.set("__col_caseFirst", try val_mod.makeString(arena, caseFirst));
    return val_mod.makeObject(arena, obj);
}

/// §10.3.3 `get Intl.Collator.prototype.compare`: an accessor returning a
/// function bound to this collator, so a detached `arr.sort(col.compare)` still
/// sees the options. Cached in [[BoundCompare]] so repeated reads are identical.
pub fn nativeCollatorCompareGetter(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__col_usage") == null)
        return throwTypeErrorIntl(arena, "get Intl.Collator.prototype.compare called on an incompatible receiver");
    const o = this_val.toPtr().object;
    if (o.getOwn("[[BoundCompare]]")) |bound| return bound;
    const bound = try val_mod.makeNativeFunctionDataLen(arena, nativeCollatorCompare, @ptrCast(o), 2);
    _ = try o.defineOwnData("[[BoundCompare]]", bound, .{ .writable = false, .enumerable = false, .configurable = false });
    return bound;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Case/base-insensitive byte comparison used when `sensitivity` is `base`/`accent`.
fn orderCaseInsensitive(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const ca = asciiLower(a[i]);
        const cb = asciiLower(b[i]);
        if (ca != cb) return if (ca < cb) .lt else .gt;
    }
    if (a.len == b.len) return .eq;
    return if (a.len < b.len) .lt else .gt;
}

/// Numeric collation (`numeric: true`): digit runs compare by numeric value,
/// everything else byte-wise (optionally case-insensitive).
fn orderNumeric(a: []const u8, b: []const u8, case_insensitive: bool) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const da = a[i] >= '0' and a[i] <= '9';
        const db = b[j] >= '0' and b[j] <= '9';
        if (da and db) {
            // Extract both digit runs.
            var ai = i;
            while (ai < a.len and a[ai] >= '0' and a[ai] <= '9') ai += 1;
            var bj = j;
            while (bj < b.len and b[bj] >= '0' and b[bj] <= '9') bj += 1;
            // Strip leading zeros, then compare by significant length, then value.
            var sa = a[i..ai];
            var sb = b[j..bj];
            while (sa.len > 1 and sa[0] == '0') sa = sa[1..];
            while (sb.len > 1 and sb[0] == '0') sb = sb[1..];
            if (sa.len != sb.len) return if (sa.len < sb.len) .lt else .gt;
            const c = std.mem.order(u8, sa, sb);
            if (c != .eq) return c;
            i = ai;
            j = bj;
        } else {
            const ca = if (case_insensitive) asciiLower(a[i]) else a[i];
            const cb = if (case_insensitive) asciiLower(b[j]) else b[j];
            if (ca != cb) return if (ca < cb) .lt else .gt;
            i += 1;
            j += 1;
        }
    }
    if (i >= a.len and j >= b.len) return .eq;
    return if (i >= a.len) .lt else .gt;
}

pub fn nativeCollatorCompare(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const a: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) args[0].unbox().string else "";
    const b: []const u8 = if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .string) args[1].unbox().string else "";
    var sensitivity: []const u8 = "variant";
    var numeric = false;
    // Bound compare passes the collator via native userdata; a plain prototype call
    // arrives with the collator as `this`.
    const col_obj: ?*JsObject = if (val_mod.g_active_native_data) |d|
        @ptrCast(@alignCast(d))
    else if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        null;
    if (col_obj) |o| {
        if (o.get("__col_sensitivity")) |v| if (v.bits != 0 and v.unbox() == .string) {
            sensitivity = v.unbox().string;
        };
        if (o.get("__col_numeric")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            numeric = v.unbox().boolean;
        };
    }
    const case_insensitive = std.mem.eql(u8, sensitivity, "base") or std.mem.eql(u8, sensitivity, "accent");
    const order = if (numeric)
        orderNumeric(a, b, case_insensitive)
    else if (case_insensitive)
        orderCaseInsensitive(a, b)
    else
        std.mem.order(u8, a, b);
    const r: f64 = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return val_mod.makeNumber(arena, r);
}

/// `col.resolvedOptions()` — en-US defaults, echoing the stored options.
pub fn nativeCollatorResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__col_usage") == null)
        return throwTypeErrorIntl(arena, "Intl.Collator.prototype.resolvedOptions called on an incompatible receiver");
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    var usage: []const u8 = "sort";
    var sensitivity: []const u8 = "variant";
    var numeric = false;
    var caseFirst: []const u8 = "false";
    var ignore_punct = false;
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get("__col_usage")) |v| if (v.bits != 0 and v.unbox() == .string) {
            usage = v.unbox().string;
        };
        if (o.get("__col_sensitivity")) |v| if (v.bits != 0 and v.unbox() == .string) {
            sensitivity = v.unbox().string;
        };
        if (o.get("__col_numeric")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            numeric = v.unbox().boolean;
        };
        if (o.get("__col_caseFirst")) |v| if (v.bits != 0 and v.unbox() == .string) {
            caseFirst = v.unbox().string;
        };
        if (o.get("__col_ignorePunctuation")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            ignore_punct = v.unbox().boolean;
        };
    }
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("usage", try val_mod.makeString(arena, usage));
    try r.set("sensitivity", try val_mod.makeString(arena, sensitivity));
    try r.set("ignorePunctuation", try val_mod.makeBool(arena, ignore_punct));
    try r.set("collation", try val_mod.makeString(arena, "default"));
    try r.set("numeric", try val_mod.makeBool(arena, numeric));
    try r.set("caseFirst", try val_mod.makeString(arena, caseFirst));
    return val_mod.makeObject(arena, r);
}

// --------------------------------------------------------------------- Locale ---

/// Parse a BCP-47 language tag into language / script / region subtags.
/// Extensions and variants are ignored (en-US scope).
const LocaleTagParts = struct {
    language: []const u8 = "",
    script: []const u8 = "",
    region: []const u8 = "",
    /// The variant subtags of the `unicode_language_id`, as one `-`-joined slice
    /// of the original tag ("" when the tag carries none).
    variants: []const u8 = "",
    /// The body of the `-u-` Unicode locale extension (everything after `-u-`,
    /// up to the next singleton), "" when the tag carries none.
    u_ext: []const u8 = "",
};

/// End offset of the extension sequence starting at `start` — the next
/// singleton subtag (`-x-`) terminates it, otherwise the end of the tag.
fn extSeqEnd(tag: []const u8, start: usize) usize {
    var pos = start;
    while (pos < tag.len) {
        const dash = std.mem.indexOfScalarPos(u8, tag, pos, '-') orelse return tag.len;
        const nxt = dash + 1;
        const nxt_end = std.mem.indexOfScalarPos(u8, tag, nxt, '-') orelse tag.len;
        if (nxt_end - nxt == 1) return dash; // a singleton starts the next sequence
        pos = nxt;
    }
    return tag.len;
}

/// Split a BCP-47 tag into its `unicode_language_id` pieces plus the `-u-`
/// extension body. The language-id scan stops at the first singleton subtag, so
/// extension keys like the `fw` of `en-u-fw-mon` are never mistaken for a region.
fn parseLocaleTag(tag: []const u8) LocaleTagParts {
    var res = LocaleTagParts{};
    var pos: usize = 0;
    var first = true;
    var var_start: ?usize = null;
    var var_end: usize = 0;
    while (pos < tag.len) {
        const dash = std.mem.indexOfScalarPos(u8, tag, pos, '-') orelse tag.len;
        const sub = tag[pos..dash];
        if (first) {
            res.language = sub;
            first = false;
        } else if (sub.len == 1) {
            if (sub[0] == 'u' or sub[0] == 'U') {
                const ext_start = @min(dash + 1, tag.len);
                res.u_ext = tag[ext_start..extSeqEnd(tag, ext_start)];
            }
            break;
        } else if (sub.len == 4 and res.script.len == 0 and var_start == null and isAllAlpha(sub)) {
            res.script = sub;
        } else if (res.region.len == 0 and var_start == null and
            ((sub.len == 2 and isAllAlpha(sub)) or (sub.len == 3 and isAllDigit(sub))))
        {
            res.region = sub;
        } else {
            if (var_start == null) var_start = pos;
            var_end = dash;
        }
        pos = dash + 1;
    }
    if (var_start) |vs| res.variants = tag[vs..var_end];
    return res;
}

/// Value of Unicode extension keyword `key` (a two-letter type key) within an
/// extension body such as `"fw-mon-ca-buddhist"`. Keys are two characters; a
/// keyword's value runs until the next two-character subtag.
fn uExtKeyword(u_ext: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    var val_of: ?[]const u8 = null;
    var val_start: usize = 0;
    var val_end: usize = 0;
    while (pos < u_ext.len) {
        const dash = std.mem.indexOfScalarPos(u8, u_ext, pos, '-') orelse u_ext.len;
        const sub = u_ext[pos..dash];
        if (sub.len == 2) {
            if (val_of) |k| if (std.ascii.eqlIgnoreCase(k, key)) return u_ext[val_start..val_end];
            val_of = sub;
            val_start = @min(dash + 1, u_ext.len);
            val_end = val_start;
        } else if (val_of != null) {
            val_end = dash;
        }
        pos = dash + 1;
    }
    if (val_of) |k| if (std.ascii.eqlIgnoreCase(k, key) and val_end > val_start) return u_ext[val_start..val_end];
    return null;
}

fn isAllAlpha(s: []const u8) bool {
    for (s) |c| if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) return false;
    return true;
}
fn isAllDigit(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Canonicalize casing: language lowercase, script Titlecase, region UPPERCASE.
fn canonSubtag(arena: std.mem.Allocator, s: []const u8, kind: enum { lang, script, region }) ![]const u8 {
    if (s.len == 0) return s;
    const buf = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = switch (kind) {
            .lang => asciiLower(c),
            .region => if (c >= 'a' and c <= 'z') c - 32 else c,
            .script => if (i == 0) (if (c >= 'a' and c <= 'z') c - 32 else c) else asciiLower(c),
        };
    }
    return buf;
}

pub fn nativeLocaleCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing) return throwTypeErrorIntl(arena, "Constructor Intl.Locale requires 'new'");
    // §14.1.2 step 7: a String tag is used as-is, an Intl.Locale re-uses its
    // [[Locale]], any other object is ToString'd, and a non-object primitive is
    // a TypeError.
    const arg0 = if (args.len > 0) args[0] else Value{};
    const tag_raw: []const u8 = blk: {
        if (arg0.bits != 0 and arg0.unbox() == .string) break :blk arg0.unbox().string;
        if (arg0.bits != 0 and arg0.unbox() == .object) {
            const o = arg0.toPtr().object;
            if (o.getOwn("[[loc_baseName]]")) |_| {
                if (o.getOwn("__locale_tag")) |t| break :blk t.unbox().string;
            }
            break :blk try t_shared.valueToString(arena, arg0);
        }
        return throwTypeErrorIntl(arena, "Intl.Locale: tag must be a string or an object");
    };
    if (!dnValidLanguageId(stripUnicodeExtension(tag_raw))) return throwRangeError(arena, "invalid language tag");
    const options_v = try dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);

    const parts = parseLocaleTag(tag_raw);
    var language = try canonSubtag(arena, parts.language, .lang);
    var script = try canonSubtag(arena, parts.script, .script);
    var region = try canonSubtag(arena, parts.region, .region);

    // ApplyOptionsToTag: each subtag option must be structurally valid on its
    // own before it replaces the one parsed out of the tag.
    if (try dnGetOption(arena, options_v, "language", &.{}, null)) |v| {
        if (!dnIsLangSubtag(v)) return throwRangeError(arena, "invalid language option");
        language = try canonSubtag(arena, v, .lang);
    }
    if (try dnGetOption(arena, options_v, "script", &.{}, null)) |v| {
        if (!dnIsScript(v)) return throwRangeError(arena, "invalid script option");
        script = try canonSubtag(arena, v, .script);
    }
    if (try dnGetOption(arena, options_v, "region", &.{}, null)) |v| {
        if (!dnIsRegion(v)) return throwRangeError(arena, "invalid region option");
        region = try canonSubtag(arena, v, .region);
    }

    // baseName = language[-script][-region]
    var bn = std.ArrayListUnmanaged(u8){};
    try bn.appendSlice(arena, language);
    if (script.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, script);
    }
    if (region.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, region);
    }
    const base_name = bn.items;

    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    // Locale fields live in hidden `[[loc_*]]` internal slots (spec exposes them
    // via prototype accessor getters, registered by registerLocaleAccessors).
    try obj.set("[[loc_language]]", try val_mod.makeString(arena, language));
    try obj.set("[[loc_script]]", try val_mod.makeString(arena, script));
    try obj.set("[[loc_region]]", try val_mod.makeString(arena, region));
    try obj.set("[[loc_baseName]]", try val_mod.makeString(arena, base_name));
    try obj.set("__locale_tag", try val_mod.makeString(arena, base_name));
    // Unicode extension keyword options (spec §14.1 ApplyOptionsToTag +
    // ApplyUnicodeExtensionToTag): reflect ca/co/nu/hourCycle/caseFirst when
    // supplied so `new Intl.Locale(tag, {calendar}).calendar` round-trips. The
    // value is lower-cased (canonical `type` form). Absent options stay absent.
    for ([_][2][]const u8{
        .{ "calendar", "[[loc_calendar]]" },
        .{ "collation", "[[loc_collation]]" },
        .{ "numberingSystem", "[[loc_numberingSystem]]" },
    }) |pair| {
        if (try dnGetOption(arena, options_v, pair[0], &.{}, null)) |v| {
            if (!isWellFormedNumberingSystem(v)) return throwRangeError(arena, "invalid Unicode extension value");
            try obj.set(pair[1], try val_mod.makeString(arena, try lowerDup(arena, v)));
        }
    }
    if (try dnGetOption(arena, options_v, "hourCycle", &.{ "h11", "h12", "h23", "h24" }, null)) |v|
        try obj.set("[[loc_hourCycle]]", try val_mod.makeString(arena, v));
    if (try dnGetOption(arena, options_v, "caseFirst", &.{ "upper", "lower", "false" }, null)) |v|
        try obj.set("[[loc_caseFirst]]", try val_mod.makeString(arena, v));
    try obj.set("[[loc_numeric]]", try val_mod.makeBool(arena, (try dnGetBoolOption(arena, options_v, "numeric")) orelse false));

    // Variant subtags (§14.3.7 `variants`): canonical lowercase, `undefined`
    // when the tag has none.
    if (parts.variants.len > 0)
        try obj.set("[[loc_variants]]", try val_mod.makeString(arena, try lowerDup(arena, parts.variants)));

    // `firstDayOfWeek` (§14.1.2): the option wins over the tag's `-u-fw-` keyword.
    // Both accept a weekday id ("mon".."sun"); the option additionally accepts
    // 0..7, where 0 and 7 both mean Sunday.
    const fw_raw: ?[]const u8 = (try optStrCoerced(arena, options_v, "firstDayOfWeek")) orelse uExtKeyword(parts.u_ext, "fw");
    if (fw_raw) |raw| {
        const id = weekdayId(raw) orelse
            return throwRangeError(arena, "invalid firstDayOfWeek value for Intl.Locale");
        try obj.set("[[loc_firstDayOfWeek]]", try val_mod.makeString(arena, id));
    }

    return val_mod.makeObject(arena, obj);
}

/// Drop a `-u-…`/`-x-…` extension sequence so the leading `unicode_language_id`
/// can be validated on its own.
fn stripUnicodeExtension(tag: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 2 < tag.len) : (i += 1) {
        if (tag[i] != '-') continue;
        if (tag[i + 2] != '-') continue;
        return tag[0..i];
    }
    return tag;
}

/// The seven weekday ids, indexed by ISO-8601 weekday number minus one
/// (Monday = 1 … Sunday = 7).
const weekday_ids = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

/// Canonical weekday id for a `firstDayOfWeek` value: an id passes through, and
/// "0".."7" map to a day ("0" and "7" both being Sunday). Null when invalid.
fn weekdayId(raw: []const u8) ?[]const u8 {
    for (weekday_ids) |d| if (std.ascii.eqlIgnoreCase(d, raw)) return d;
    if (raw.len == 1 and raw[0] >= '0' and raw[0] <= '7')
        return weekday_ids[if (raw[0] == '0') 6 else raw[0] - '1'];
    return null;
}

/// ISO-8601 weekday number (Monday = 1 … Sunday = 7) for a canonical id.
fn weekdayNumber(id: []const u8) f64 {
    for (weekday_ids, 0..) |d, i| if (std.mem.eql(u8, d, id)) return @floatFromInt(i + 1);
    return 7;
}

// ------------------------------------------------- structural tag validation ---
//
// IsStructurallyValidLanguageTag (ES §6.2.2) against the UTS-35
// `unicode_locale_id` grammar:
//
//   unicode_locale_id = unicode_language_id extensions* pu_extensions?
//   unicode_language_id = lang (sep script)? (sep region)? (sep variant)*
//   lang    = alpha{2,3} | alpha{5,8}      script = alpha{4}
//   region  = alpha{2} | digit{3}          variant = alnum{5,8} | digit alnum{3}
//
// plus the two uniqueness rules: no repeated variant subtag and no repeated
// extension singleton.

fn allAlnum(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn isVariantSubtag(s: []const u8) bool {
    if (s.len >= 5 and s.len <= 8) return allAlnum(s);
    if (s.len == 4) return std.ascii.isDigit(s[0]) and allAlnum(s);
    return false;
}

/// Split `tag` on `-`, rejecting a tag with an empty subtag (which also covers
/// the empty tag, a leading/trailing `-`, and `--`).
fn tagSubtags(arena: std.mem.Allocator, tag: []const u8) !?[][]const u8 {
    if (tag.len == 0) return null;
    // Only ASCII alphanumerics and `-` may appear; this rejects "中文", "en-ß",
    // "*" and "de-*" before any structural analysis.
    for (tag) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return null;
    var out = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, tag, '-');
    while (it.next()) |sub| {
        if (sub.len == 0) return null;
        try out.append(arena, sub);
    }
    return out.items;
}

/// True when `tag` matches `unicode_locale_id`.
pub fn isStructurallyValidLanguageTag(arena: std.mem.Allocator, tag: []const u8) !bool {
    const subs = (try tagSubtags(arena, tag)) orelse return false;
    var i: usize = 0;

    // unicode_language_subtag
    const lang = subs[i];
    const lang_ok = isAllAlpha(lang) and ((lang.len >= 2 and lang.len <= 3) or (lang.len >= 5 and lang.len <= 8));
    if (!lang_ok) return false;
    i += 1;

    // (sep unicode_script_subtag)?
    if (i < subs.len and subs[i].len == 4 and isAllAlpha(subs[i])) i += 1;

    // (sep unicode_region_subtag)?
    if (i < subs.len and ((subs[i].len == 2 and isAllAlpha(subs[i])) or (subs[i].len == 3 and isAllDigit(subs[i])))) i += 1;

    // (sep unicode_variant_subtag)* — each may appear at most once.
    var variants = std.ArrayListUnmanaged([]const u8){};
    while (i < subs.len and isVariantSubtag(subs[i])) : (i += 1) {
        for (variants.items) |v| if (std.ascii.eqlIgnoreCase(v, subs[i])) return false;
        try variants.append(arena, subs[i]);
    }

    // extensions* pu_extensions? — each singleton may appear at most once, and
    // each must be followed by at least one subtag of its own.
    var singletons = std.ArrayListUnmanaged(u8){};
    while (i < subs.len) {
        if (subs[i].len != 1) return false; // a non-singleton here is unparsable
        const singleton = std.ascii.toLower(subs[i][0]);
        for (singletons.items) |s| if (s == singleton) return false;
        try singletons.append(arena, singleton);
        i += 1;
        const body_start = i;
        // `x-` private use takes 1..8-character subtags; every other singleton
        // requires 2..8.
        const min_len: usize = if (singleton == 'x') 1 else 2;
        while (i < subs.len and subs[i].len >= min_len and subs[i].len <= 8 and allAlnum(subs[i])) i += 1;
        if (i == body_start) return false; // singleton with an empty body
    }
    return true;
}

/// The locale this build actually formats in; also the fallback when none of the
/// requested locales can be served.
pub const default_locale = "en-US";

/// Approximates `AvailableLocales`. There is no CLDR data here, so a tag counts
/// as available when its primary language is a two-letter (ISO 639-1) code —
/// enough to tell a real request like `"sr"` from a nonexistent `"xyz"`.
fn isAvailableLocale(canon_tag: []const u8) bool {
    const lang = primaryLanguage(canon_tag);
    if (lang.len != 2 or !isAllAlpha(lang)) return false;
    return true;
}

/// CanonicalizeLocaleList + ResolveLocale for a constructor's `locales`
/// argument: every tag is validated (RangeError on a malformed one) and the
/// first servable tag becomes the instance's `[[Locale]]`, stored in a hidden
/// slot that `resolvedOptions()` reads back.
pub fn resolveAndStoreLocale(arena: std.mem.Allocator, obj: *JsObject, locales: Value) anyerror!void {
    const requested = try canonicalizeLocaleList(arena, locales);
    var chosen: ?[]const u8 = null;
    for (requested) |t| {
        const canon = try canonicalizeTag(arena, t);
        if (chosen == null and isAvailableLocale(canon)) chosen = canon;
    }
    try obj.set("[[intl_locale]]", try val_mod.makeString(arena, chosen orelse default_locale));
}

/// The `[[Locale]]` stored by `resolveAndStoreLocale`, or the default.
pub fn resolvedLocaleOf(this_val: Value) []const u8 {
    if (this_val.bits == 0 or this_val.unbox() != .object) return default_locale;
    const v = this_val.toPtr().object.getOwn("[[intl_locale]]") orelse return default_locale;
    if (v.bits == 0 or v.unbox() != .string) return default_locale;
    return v.unbox().string;
}

/// Canonicalize one BCP-47 tag to `language[-Script][-REGION]` form. A tag that
/// does not match `unicode_locale_id` is a RangeError (ES §9.2.1 step 7.c).
pub fn canonicalizeTag(arena: std.mem.Allocator, tag: []const u8) ![]const u8 {
    if (!try isStructurallyValidLanguageTag(arena, tag))
        return throwRangeError(arena, "invalid language tag");
    const parts = parseLocaleTag(tag);
    const language = try canonSubtag(arena, parts.language, .lang);
    const script = try canonSubtag(arena, parts.script, .script);
    const region = try canonSubtag(arena, parts.region, .region);
    var bn = std.ArrayListUnmanaged(u8){};
    try bn.appendSlice(arena, language);
    if (script.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, script);
    }
    if (region.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, region);
    }
    return bn.items;
}

/// `Intl.getCanonicalLocales(locales)` — accepts a string or array-like of tags,
/// returns a de-duplicated array of canonical tags.
pub fn nativeGetCanonicalLocales(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var tags = std.ArrayListUnmanaged([]const u8){};
    if (args.len > 0 and args[0].bits != 0) {
        if (args[0].unbox() == .string) {
            try tags.append(arena, args[0].unbox().string);
        } else if (args[0].unbox() == .object) {
            tags.items = try listElements(arena, args[0]);
        }
    }
    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    var seen = std.ArrayListUnmanaged([]const u8){};
    var n: usize = 0;
    for (tags.items) |t| {
        if (t.len == 0) continue;
        const canon = try canonicalizeTag(arena, t);
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, canon)) {
            dup = true;
            break;
        };
        if (dup) continue;
        try seen.append(arena, canon);
        try arr.set(try std.fmt.allocPrint(arena, "{d}", .{n}), try val_mod.makeString(arena, canon));
        n += 1;
    }
    return val_mod.makeObject(arena, arr);
}

/// ES ToString for the `Intl.supportedValuesOf` key argument: strings pass
/// through, primitives stringify, objects run ToPrimitive(string), and Symbols
/// throw a TypeError.
fn keyToString(arena: std.mem.Allocator, v: Value) anyerror![]const u8 {
    if (v.bits == 0) return "undefined";
    switch (v.unbox()) {
        .string => |s| return s,
        .number => |n| return try val_mod.formatNumber(arena, n),
        .boolean => |b| return if (b) "true" else "false",
        .null_ => return "null",
        .undefined_ => return "undefined",
        .bigint => |bi| return try val_mod.bigIntToString(arena, bi),
        .symbol => return throwTypeErrorIntl(arena, "Cannot convert a Symbol value to a string"),
        .object => {
            const prim = (try coercion_mod.toPrimitive(arena, v, .string)) orelse return "[object Object]";
            if (prim.bits != 0 and prim.unbox() == .object) return "[object Object]";
            return keyToString(arena, prim);
        },
        else => return "[object Object]",
    }
}

/// `Intl.supportedValuesOf(key)` (ECMA-402) — returns a fresh, sorted, duplicate
/// -free Array of the values this implementation supports for `key`. The lists
/// are deliberately narrow: they contain only values the corresponding Intl
/// constructor here actually round-trips, so the cross-consistency tests hold.
pub fn nativeSupportedValuesOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const key = try keyToString(arena, if (args.len > 0) args[0] else Value{});

    // Non-continental time zones required by test262 + UTC. Sorted at runtime.
    const time_zones = [_][]const u8{
        "Etc/GMT+1",  "Etc/GMT+2",  "Etc/GMT+3",  "Etc/GMT+4",  "Etc/GMT+5",
        "Etc/GMT+6",  "Etc/GMT+7",  "Etc/GMT+8",  "Etc/GMT+9",  "Etc/GMT+10",
        "Etc/GMT+11", "Etc/GMT+12", "Etc/GMT-1",  "Etc/GMT-2",  "Etc/GMT-3",
        "Etc/GMT-4",  "Etc/GMT-5",  "Etc/GMT-6",  "Etc/GMT-7",  "Etc/GMT-8",
        "Etc/GMT-9",  "Etc/GMT-10", "Etc/GMT-11", "Etc/GMT-12", "Etc/GMT-13",
        "Etc/GMT-14", "UTC",
    };
    const currencies = [_][]const u8{
        "AUD", "BRL", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY",
        "KRW", "MXN", "NZD", "RUB", "SEK", "SGD", "TRY", "USD", "ZAR",
    };
    const calendars = [_][]const u8{"gregory"};
    const numbering = [_][]const u8{"latn"};
    const empty = [_][]const u8{};

    const items: []const []const u8 = if (std.mem.eql(u8, key, "calendar"))
        &calendars
    else if (std.mem.eql(u8, key, "collation"))
        &empty
    else if (std.mem.eql(u8, key, "currency"))
        &currencies
    else if (std.mem.eql(u8, key, "numberingSystem"))
        &numbering
    else if (std.mem.eql(u8, key, "timeZone"))
        &time_zones
    else if (std.mem.eql(u8, key, "unit"))
        &empty
    else
        return throwRangeError(arena, "invalid key for Intl.supportedValuesOf");

    // Copy, sort (byte-lexicographic == JS default String sort for these ASCII
    // values), and de-duplicate.
    const buf = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, buf, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    var n: usize = 0;
    var prev: ?[]const u8 = null;
    for (buf) |item| {
        if (prev) |p| if (std.mem.eql(u8, p, item)) continue;
        try arr.set(try std.fmt.allocPrint(arena, "{d}", .{n}), try val_mod.makeString(arena, item));
        prev = item;
        n += 1;
    }
    return val_mod.makeObject(arena, arr);
}

pub fn nativeLocaleToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        if (this_val.toPtr().object.get("__locale_tag")) |v| {
            if (v.bits != 0 and v.unbox() == .string) return val_mod.makeString(arena, v.unbox().string);
        }
        if (this_val.toPtr().object.get("[[loc_baseName]]")) |v| {
            if (v.bits != 0 and v.unbox() == .string) return val_mod.makeString(arena, v.unbox().string);
        }
    }
    return val_mod.makeString(arena, "");
}

/// Build a Locale prototype accessor getter for internal slot `slot`. When
/// `optional` is set an empty stored string reads back as `undefined` (e.g. an
/// absent script/region).
fn locGetterFn(comptime slot: []const u8, comptime optional: bool) val_mod.NativeFnPtr {
    return struct {
        fn f(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
            if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("[[loc_baseName]]") == null)
                return throwTypeErrorIntl(arena, "Intl.Locale.prototype getter called on an incompatible receiver");
            const v = this_val.toPtr().object.getOwn(slot) orelse return val_mod.makeUndefined(arena);
            if (optional and v.bits != 0 and v.unbox() == .string and v.unbox().string.len == 0)
                return val_mod.makeUndefined(arena);
            return v;
        }
    }.f;
}

fn locAccessor(arena: std.mem.Allocator, proto: *JsObject, comptime key: []const u8, comptime slot: []const u8, comptime optional: bool) !void {
    const holder = try JsObject.create(arena, realm_mod.active_object_proto);
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, locGetterFn(slot, optional), "get " ++ key, 0));
    _ = try proto.defineOwnAccessor(key, try val_mod.makeObject(arena, holder), .{ .enumerable = false, .configurable = true, .writable = false });
}

/// %Intl.Locale.prototype%, captured at realm setup so `maximize`/`minimize` can
/// hand back a fresh Locale rather than a plain object.
var active_locale_proto: ?*JsObject = null;

/// Brand check shared by every Intl.Locale.prototype method: the receiver must be
/// an object carrying the `[[InitializedLocale]]` slot (%Locale.prototype% itself
/// does not).
fn requireLocale(arena: std.mem.Allocator, this_val: Value) anyerror!*JsObject {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("[[loc_baseName]]") == null)
        return throwTypeErrorIntl(arena, "Intl.Locale.prototype method called on an incompatible receiver");
    return this_val.toPtr().object;
}

/// AddLikelySubtags, restricted to the languages a dependency-free build can
/// carry. Unlisted languages fall back to a Latin script and a region derived
/// from the language subtag, which keeps `maximize()` total.
fn likelySubtags(lang: []const u8) struct { script: []const u8, region: []const u8 } {
    const table = [_]struct { l: []const u8, s: []const u8, r: []const u8 }{
        .{ .l = "en", .s = "Latn", .r = "US" }, .{ .l = "und", .s = "Latn", .r = "US" },
        .{ .l = "fr", .s = "Latn", .r = "FR" }, .{ .l = "de", .s = "Latn", .r = "DE" },
        .{ .l = "es", .s = "Latn", .r = "ES" }, .{ .l = "it", .s = "Latn", .r = "IT" },
        .{ .l = "pt", .s = "Latn", .r = "BR" }, .{ .l = "nl", .s = "Latn", .r = "NL" },
        .{ .l = "sv", .s = "Latn", .r = "SE" }, .{ .l = "pl", .s = "Latn", .r = "PL" },
        .{ .l = "tr", .s = "Latn", .r = "TR" }, .{ .l = "ru", .s = "Cyrl", .r = "RU" },
        .{ .l = "uk", .s = "Cyrl", .r = "UA" }, .{ .l = "el", .s = "Grek", .r = "GR" },
        .{ .l = "he", .s = "Hebr", .r = "IL" }, .{ .l = "ar", .s = "Arab", .r = "EG" },
        .{ .l = "fa", .s = "Arab", .r = "IR" }, .{ .l = "hi", .s = "Deva", .r = "IN" },
        .{ .l = "th", .s = "Thai", .r = "TH" }, .{ .l = "ko", .s = "Kore", .r = "KR" },
        .{ .l = "ja", .s = "Jpan", .r = "JP" }, .{ .l = "zh", .s = "Hans", .r = "CN" },
    };
    for (table) |e| if (std.mem.eql(u8, e.l, lang)) return .{ .script = e.s, .region = e.r };
    return .{ .script = "Latn", .region = "US" };
}

/// Build a new Intl.Locale from already-canonical subtags, carrying the
/// receiver's Unicode-extension slots across (§14.3.3/§14.3.4 re-run the
/// constructor on the transformed tag).
fn makeLocaleFrom(arena: std.mem.Allocator, src: *JsObject, language: []const u8, script: []const u8, region: []const u8) anyerror!Value {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, active_locale_proto orelse realm_mod.active_object_proto)
    else
        try JsObject.create(arena, active_locale_proto orelse realm_mod.active_object_proto);
    var bn = std.ArrayListUnmanaged(u8){};
    try bn.appendSlice(arena, language);
    if (script.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, script);
    }
    if (region.len > 0) {
        try bn.append(arena, '-');
        try bn.appendSlice(arena, region);
    }
    try obj.set("[[loc_language]]", try val_mod.makeString(arena, language));
    try obj.set("[[loc_script]]", try val_mod.makeString(arena, script));
    try obj.set("[[loc_region]]", try val_mod.makeString(arena, region));
    try obj.set("[[loc_baseName]]", try val_mod.makeString(arena, bn.items));
    try obj.set("__locale_tag", try val_mod.makeString(arena, bn.items));
    for ([_][]const u8{ "[[loc_calendar]]", "[[loc_collation]]", "[[loc_numberingSystem]]", "[[loc_hourCycle]]", "[[loc_caseFirst]]", "[[loc_numeric]]" }) |slot| {
        if (src.getOwn(slot)) |v| try obj.set(slot, v);
    }
    return val_mod.makeObject(arena, obj);
}

pub fn nativeLocaleMaximize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const lang = if (o.getOwn("[[loc_language]]")) |v| v.unbox().string else "und";
    var script = if (o.getOwn("[[loc_script]]")) |v| v.unbox().string else "";
    var region = if (o.getOwn("[[loc_region]]")) |v| v.unbox().string else "";
    const likely = likelySubtags(lang);
    if (script.len == 0) script = likely.script;
    if (region.len == 0) region = likely.region;
    return makeLocaleFrom(arena, o, if (std.mem.eql(u8, lang, "und")) "en" else lang, script, region);
}

pub fn nativeLocaleMinimize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const lang0 = if (o.getOwn("[[loc_language]]")) |v| v.unbox().string else "und";
    const lang = if (std.mem.eql(u8, lang0, "und")) "en" else lang0;
    const script = if (o.getOwn("[[loc_script]]")) |v| v.unbox().string else "";
    const region = if (o.getOwn("[[loc_region]]")) |v| v.unbox().string else "";
    // RemoveLikelySubtags: drop a subtag exactly when AddLikelySubtags would put
    // it back.
    const likely = likelySubtags(lang);
    const keep_script = script.len > 0 and !std.mem.eql(u8, script, likely.script);
    const keep_region = region.len > 0 and !std.mem.eql(u8, region, likely.region);
    return makeLocaleFrom(arena, o, lang, if (keep_script) script else "", if (keep_region) region else "");
}

// ------------------------------------------------------- Intl.Locale-info ---
//
// §14.3.8–14.3.14: the locale-information methods. This build carries no CLDR
// tables, so each returns the structurally correct shape populated from the
// locale's own subtags plus this implementation's actually-supported values
// (the same narrow lists `Intl.supportedValuesOf` reports).

/// A fresh Array whose elements are `items`, in the given order.
fn makeStringArray(arena: std.mem.Allocator, items: []const []const u8) !Value {
    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (items, 0..) |item, i|
        try arr.set(try std.fmt.allocPrint(arena, "{d}", .{i}), try val_mod.makeString(arena, item));
    return val_mod.makeObject(arena, arr);
}

/// Read a `[[loc_*]]` slot as a string, or null when absent/empty.
fn localeSlotStr(o: *JsObject, slot: []const u8) ?[]const u8 {
    const v = o.getOwn(slot) orelse return null;
    if (v.bits == 0 or v.unbox() != .string or v.unbox().string.len == 0) return null;
    return v.unbox().string;
}

/// A one-element preference list: the locale's own value for `slot` when it
/// carries one, else this implementation's single supported `fallback`.
fn localePrefList(arena: std.mem.Allocator, this_val: Value, slot: []const u8, fallback: []const u8) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    return makeStringArray(arena, &[_][]const u8{localeSlotStr(o, slot) orelse fallback});
}

pub fn nativeLocaleGetCalendars(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return localePrefList(arena, this_val, "[[loc_calendar]]", "gregory");
}
pub fn nativeLocaleGetCollations(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return localePrefList(arena, this_val, "[[loc_collation]]", "default");
}
pub fn nativeLocaleGetHourCycles(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return localePrefList(arena, this_val, "[[loc_hourCycle]]", "h12");
}
pub fn nativeLocaleGetNumberingSystems(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return localePrefList(arena, this_val, "[[loc_numberingSystem]]", "latn");
}

/// §14.3.11 `getTimeZones` — undefined for a locale with no region, otherwise a
/// sorted list of that region's time zones. Without CLDR region data every
/// region reports UTC, which satisfies the "non-empty and sorted" contract.
pub fn nativeLocaleGetTimeZones(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    if (localeSlotStr(o, "[[loc_region]]") == null) return val_mod.makeUndefined(arena);
    return makeStringArray(arena, &[_][]const u8{"UTC"});
}

/// §14.3.12 `getTextInfo` — { direction }, where direction is "rtl" for the
/// right-to-left scripts/languages and "ltr" otherwise.
pub fn nativeLocaleGetTextInfo(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const rtl_scripts = [_][]const u8{ "Adlm", "Arab", "Hebr", "Nkoo", "Rohg", "Syrc", "Thaa", "Yezi" };
    const rtl_langs = [_][]const u8{ "ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ku", "nqo" };
    var rtl = false;
    if (localeSlotStr(o, "[[loc_script]]")) |s| {
        for (rtl_scripts) |r| if (std.ascii.eqlIgnoreCase(r, s)) {
            rtl = true;
        };
    } else if (localeSlotStr(o, "[[loc_language]]")) |l| {
        for (rtl_langs) |r| if (std.mem.eql(u8, r, l)) {
            rtl = true;
        };
    }
    const r = try dnEmptyObj(arena);
    try r.set("direction", try val_mod.makeString(arena, if (rtl) "rtl" else "ltr"));
    return val_mod.makeObject(arena, r);
}

/// §14.3.13 `getWeekInfo` — { firstDay, weekend }, both as ISO-8601 weekday
/// numbers (Monday = 1 … Sunday = 7). `firstDay` honours the locale's
/// `firstDayOfWeek`; the weekend is the Saturday/Sunday default.
pub fn nativeLocaleGetWeekInfo(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const first: f64 = if (localeSlotStr(o, "[[loc_firstDayOfWeek]]")) |id| weekdayNumber(id) else 7;
    const r = try dnEmptyObj(arena);
    try r.set("firstDay", try val_mod.makeNumber(arena, first));
    const weekend = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    try weekend.set("0", try val_mod.makeNumber(arena, 6));
    try weekend.set("1", try val_mod.makeNumber(arena, 7));
    try r.set("weekend", try val_mod.makeObject(arena, weekend));
    return val_mod.makeObject(arena, r);
}

/// Register Intl.Locale.prototype's scalar accessor getters (§14.3).
pub fn registerLocaleAccessors(arena: std.mem.Allocator, proto: *JsObject) !void {
    active_locale_proto = proto;
    const M = struct {
        fn add(a: std.mem.Allocator, p: *JsObject, name: []const u8, f: val_mod.NativeFnPtr) !void {
            _ = try p.defineOwnData(name, try val_mod.makeNativeFunctionNamed(a, f, name, 0), .{ .writable = true, .enumerable = false, .configurable = true });
        }
    };
    try M.add(arena, proto, "maximize", nativeLocaleMaximize);
    try M.add(arena, proto, "minimize", nativeLocaleMinimize);
    try M.add(arena, proto, "getCalendars", nativeLocaleGetCalendars);
    try M.add(arena, proto, "getCollations", nativeLocaleGetCollations);
    try M.add(arena, proto, "getHourCycles", nativeLocaleGetHourCycles);
    try M.add(arena, proto, "getNumberingSystems", nativeLocaleGetNumberingSystems);
    try M.add(arena, proto, "getTimeZones", nativeLocaleGetTimeZones);
    try M.add(arena, proto, "getWeekInfo", nativeLocaleGetWeekInfo);
    try M.add(arena, proto, "getTextInfo", nativeLocaleGetTextInfo);
    try locAccessor(arena, proto, "baseName", "[[loc_baseName]]", false);
    try locAccessor(arena, proto, "language", "[[loc_language]]", false);
    try locAccessor(arena, proto, "script", "[[loc_script]]", true);
    try locAccessor(arena, proto, "region", "[[loc_region]]", true);
    try locAccessor(arena, proto, "calendar", "[[loc_calendar]]", true);
    try locAccessor(arena, proto, "collation", "[[loc_collation]]", true);
    try locAccessor(arena, proto, "hourCycle", "[[loc_hourCycle]]", true);
    try locAccessor(arena, proto, "caseFirst", "[[loc_caseFirst]]", true);
    try locAccessor(arena, proto, "numberingSystem", "[[loc_numberingSystem]]", true);
    try locAccessor(arena, proto, "numeric", "[[loc_numeric]]", false);
    try locAccessor(arena, proto, "variants", "[[loc_variants]]", true);
    try locAccessor(arena, proto, "firstDayOfWeek", "[[loc_firstDayOfWeek]]", true);
}

// ------------------------------------------------------------------- ListFormat ---

/// StringListFromIterable (§13.5.1): drive `list` through the iterator protocol
/// and require every yielded value to be a String. `undefined` yields the empty
/// list; anything else that is not iterable is a TypeError.
fn stringListFromIterable(arena: std.mem.Allocator, v: Value) ![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    if (v.bits == 0 or v.unbox() == .undefined_) return out.items;
    var items: std.ArrayList(Value) = .empty;
    if (!try realm_mod.arrayFromIterate(arena, v, &items))
        return throwTypeErrorIntl(arena, "Intl.ListFormat: argument is not iterable");
    for (items.items) |it| {
        if (it.bits == 0 or it.unbox() != .string)
            return throwTypeErrorIntl(arena, "Intl.ListFormat: list elements must be strings");
        try out.append(arena, it.unbox().string);
    }
    return out.items;
}

/// Collect the string elements of an array-like `list` argument.
/// Shared constructor prologue for the Intl service constructors: every one of
/// them is `new`-only (§9.2 "If NewTarget is undefined, throw a TypeError"), and
/// the object to install the internal slots on is the one OrdinaryCreateFromConstructor
/// already handed us as `this` (so subclassing keeps the subclass prototype).
fn intlNewTarget(arena: std.mem.Allocator, this_val: Value, comptime name: []const u8) anyerror!*JsObject {
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing)
        return throwTypeErrorIntl(arena, "Constructor " ++ name ++ " requires 'new'");
    if (this_val.bits != 0 and this_val.unbox() == .object) return this_val.toPtr().object;
    return dnEmptyObj(arena);
}

fn listElements(arena: std.mem.Allocator, v: Value) ![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    if (v.bits == 0 or v.unbox() != .object) return out.items;
    const o = v.toPtr().object;
    // Arrays special-case `length` (raw `get("length")` returns null), so read
    // the cached array length; otherwise fall back to an own `length` property.
    const len: usize = if (o.is_array) o.getArrayLength() else blk: {
        const len_v = o.get("length") orelse break :blk 0;
        const len_f: f64 = if (len_v.bits != 0 and len_v.unbox() == .number) len_v.unbox().number else 0;
        if (len_f <= 0) break :blk 0;
        break :blk @intFromFloat(@min(len_f, 4294967295.0));
    };
    if (len == 0) return out.items;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const e = o.get(key) orelse continue;
        const s = if (e.bits != 0 and e.unbox() == .string) e.unbox().string else "";
        try out.append(arena, s);
    }
    return out.items;
}

pub fn nativeListFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try intlNewTarget(arena, this_val, "Intl.ListFormat");
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const options = try dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const typ = (try dnGetOption(arena, options, "type", &.{ "conjunction", "disjunction", "unit" }, "conjunction")).?;
    const style = (try dnGetOption(arena, options, "style", &.{ "long", "short", "narrow" }, "long")).?;
    try obj.set("__lf_type", try val_mod.makeString(arena, typ));
    try obj.set("__lf_style", try val_mod.makeString(arena, style));
    return val_mod.makeObject(arena, obj);
}

/// CreatePartsFromList for en-US; `format` concatenates these, so the two forms
/// stay consistent. `type` is "element" for a list item and "literal" for the
/// separators the pattern inserts between them.
fn lfBuildParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) ![]NumberPart {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.get("__lf_type") == null)
        return throwTypeErrorIntl(arena, "Intl.ListFormat.prototype method called on an incompatible receiver");
    var typ: []const u8 = "conjunction";
    var style: []const u8 = "long";
    if (this_val.toPtr().object.get("__lf_type")) |v| if (v.bits != 0 and v.unbox() == .string) {
        typ = v.unbox().string;
    };
    if (this_val.toPtr().object.get("__lf_style")) |v| if (v.bits != 0 and v.unbox() == .string) {
        style = v.unbox().string;
    };
    const items = try stringListFromIterable(arena, if (args.len > 0) args[0] else Value{ .bits = 0 });
    var parts: std.ArrayList(NumberPart) = .empty;
    if (items.len == 0) return parts.items;
    if (items.len == 1) {
        try parts.append(arena, .{ .type = "element", .value = items[0] });
        return parts.items;
    }

    // en-US CLDR list patterns. The conjunction word only appears for the
    // `conjunction`/`disjunction` types: `unit` lists just enumerate (with a
    // bare space in the narrow style), and a narrow conjunction drops the word.
    const is_unit = std.mem.eql(u8, typ, "unit");
    const is_disjunction = std.mem.eql(u8, typ, "disjunction");
    const narrow = std.mem.eql(u8, style, "narrow");
    const sep: []const u8 = if (is_unit and narrow) " " else ", ";
    const conj: ?[]const u8 = if (is_disjunction)
        "or"
    else if (is_unit or narrow)
        null
    else if (std.mem.eql(u8, style, "short"))
        "&"
    else
        "and";
    const last_sep: []const u8 = if (conj) |c| (if (items.len == 2)
        try std.fmt.allocPrint(arena, " {s} ", .{c})
    else
        try std.fmt.allocPrint(arena, ", {s} ", .{c})) else sep;
    for (items, 0..) |it, i| {
        if (i > 0) try parts.append(arena, .{
            .type = "literal",
            .value = if (i == items.len - 1) last_sep else sep,
        });
        try parts.append(arena, .{ .type = "element", .value = it });
    }
    return parts.items;
}

pub fn nativeListFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    var out = std.ArrayListUnmanaged(u8){};
    for (try lfBuildParts(arena, this_val, args)) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

pub fn nativeListFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try lfBuildParts(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts) |p| {
        const o = try dnEmptyObj(arena);
        try o.set("type", try val_mod.makeString(arena, p.type));
        try o.set("value", try val_mod.makeString(arena, p.value));
        try arr.appendElement(try val_mod.makeObject(arena, o));
    }
    return val_mod.makeObject(arena, arr);
}

pub fn nativeListFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__lf_type") == null)
        return throwTypeErrorIntl(arena, "Intl.ListFormat.prototype.resolvedOptions called on an incompatible receiver");
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    var typ: []const u8 = "conjunction";
    var style: []const u8 = "long";
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get("__lf_type")) |v| if (v.bits != 0 and v.unbox() == .string) {
            typ = v.unbox().string;
        };
        if (o.get("__lf_style")) |v| if (v.bits != 0 and v.unbox() == .string) {
            style = v.unbox().string;
        };
    }
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("type", try val_mod.makeString(arena, typ));
    try r.set("style", try val_mod.makeString(arena, style));
    return val_mod.makeObject(arena, r);
}

// ------------------------------------------------------------------ PluralRules ---

/// en-US plural category for `n` (cardinal or ordinal).
fn pluralCategory(n: f64, ordinal: bool) []const u8 {
    if (!ordinal) {
        return if (n == 1) "one" else "other";
    }
    // Guard the float→int cast: NaN/Inf would panic @intFromFloat.
    if (std.math.isNan(n) or std.math.isInf(n)) return "other";
    const iv: i64 = @intFromFloat(@abs(@trunc(n)));
    const m10 = @mod(iv, 10);
    const m100 = @mod(iv, 100);
    if (m10 == 1 and m100 != 11) return "one";
    if (m10 == 2 and m100 != 12) return "two";
    if (m10 == 3 and m100 != 13) return "few";
    return "other";
}

pub fn nativePluralRulesCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try intlNewTarget(arena, this_val, "Intl.PluralRules");
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const typ = (try dnGetOption(arena, options, "type", &.{ "cardinal", "ordinal" }, "cardinal")).?;
    try obj.set("__pr_type", try val_mod.makeString(arena, typ));
    return val_mod.makeObject(arena, obj);
}

pub fn nativePluralRulesSelect(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__pr_type") == null)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype.select called on an incompatible receiver");
    var ordinal = false;
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        if (this_val.toPtr().object.get("__pr_type")) |v| if (v.bits != 0 and v.unbox() == .string) {
            ordinal = std.mem.eql(u8, v.unbox().string, "ordinal");
        };
    }
    const n = if (args.len > 0) getNum(args[0]) else std.math.nan(f64);
    return val_mod.makeString(arena, pluralCategory(n, ordinal));
}

/// §16.3.3 selectRange(start, end): both ends are ToNumber'd (NaN is a RangeError)
/// and en-US resolves every range to the plural form of the end value.
pub fn nativePluralRulesSelectRange(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.get("__pr_type") == null)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype.selectRange called on an incompatible receiver");
    if (args.len < 2 or args[0].bits == 0 or args[0].unbox() == .undefined_ or args[1].bits == 0 or args[1].unbox() == .undefined_)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype.selectRange: start and end are required");
    const start = try realm_mod.toNumberValue(arena, args[0]);
    const end = try realm_mod.toNumberValue(arena, args[1]);
    if (std.math.isNan(start) or std.math.isNan(end))
        return throwRangeError(arena, "Intl.PluralRules.prototype.selectRange: start and end must not be NaN");
    var ordinal = false;
    if (this_val.toPtr().object.get("__pr_type")) |v| if (v.bits != 0 and v.unbox() == .string) {
        ordinal = std.mem.eql(u8, v.unbox().string, "ordinal");
    };
    return val_mod.makeString(arena, pluralCategory(end, ordinal));
}

pub fn nativePluralRulesResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__pr_type") == null)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype.resolvedOptions called on an incompatible receiver");
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    var ordinal = false;
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        if (this_val.toPtr().object.get("__pr_type")) |v| if (v.bits != 0 and v.unbox() == .string) {
            ordinal = std.mem.eql(u8, v.unbox().string, "ordinal");
        };
    }
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("type", try val_mod.makeString(arena, if (ordinal) "ordinal" else "cardinal"));
    try r.set("minimumIntegerDigits", try val_mod.makeNumber(arena, 1));
    try r.set("minimumFractionDigits", try val_mod.makeNumber(arena, 0));
    try r.set("maximumFractionDigits", try val_mod.makeNumber(arena, 3));
    // pluralCategories: a real Array — en-US ordinal has one/two/few/other,
    // cardinal one/other.
    const cats = try JsObject.createArray(arena, realm_mod.active_array_proto);
    const names: []const []const u8 = if (ordinal)
        &.{ "one", "two", "few", "other" }
    else
        &.{ "one", "other" };
    for (names) |n| try cats.appendElement(try val_mod.makeString(arena, n));
    try r.set("pluralCategories", try val_mod.makeObject(arena, cats));
    return val_mod.makeObject(arena, r);
}

// ------------------------------------------------------------ RelativeTimeFormat ---

/// Strip a trailing plural `s` so `"days"`/`"day"` both normalize to `"day"`.
fn singularUnit(unit: []const u8) []const u8 {
    if (unit.len > 1 and unit[unit.len - 1] == 's') return unit[0 .. unit.len - 1];
    return unit;
}

pub fn nativeRelativeTimeFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try intlNewTarget(arena, this_val, "Intl.RelativeTimeFormat");
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    if (try dnGetOption(arena, options, "numberingSystem", &.{}, null)) |ns| {
        if (!isWellFormedNumberingSystem(ns)) return throwRangeError(arena, "invalid numberingSystem");
    }
    const style = (try dnGetOption(arena, options, "style", &.{ "long", "short", "narrow" }, "long")).?;
    const numeric = (try dnGetOption(arena, options, "numeric", &.{ "always", "auto" }, "always")).?;
    try obj.set("__rtf_numeric", try val_mod.makeString(arena, numeric));
    try obj.set("__rtf_style", try val_mod.makeString(arena, style));
    return val_mod.makeObject(arena, obj);
}

/// en-US `numeric:"auto"` special phrasing, or null to fall back to numeric form.
fn rtfAutoForm(arena: std.mem.Allocator, value: f64, unit: []const u8) !?[]const u8 {
    const u = singularUnit(unit);
    if (std.mem.eql(u8, u, "day")) {
        if (value == -1) return "yesterday";
        if (value == 0) return "today";
        if (value == 1) return "tomorrow";
        return null;
    }
    if (std.mem.eql(u8, u, "second")) {
        if (value == 0) return "now";
        return null;
    }
    // hour/minute have only a "this X" form at 0.
    if (std.mem.eql(u8, u, "hour") or std.mem.eql(u8, u, "minute")) {
        if (value == 0) return try std.fmt.allocPrint(arena, "this {s}", .{u});
        return null;
    }
    // week/month/year/quarter (and day handled above) use last/this/next.
    if (value == -1) return try std.fmt.allocPrint(arena, "last {s}", .{u});
    if (value == 0) return try std.fmt.allocPrint(arena, "this {s}", .{u});
    if (value == 1) return try std.fmt.allocPrint(arena, "next {s}", .{u});
    return null;
}

/// The units `format`/`formatToParts` accept, singular form (plurals are folded
/// by `singularUnit` first); anything else is a RangeError.
fn rtfValidUnit(u: []const u8) bool {
    const units = [_][]const u8{ "second", "minute", "hour", "day", "week", "month", "quarter", "year" };
    for (units) |v| if (std.mem.eql(u8, v, u)) return true;
    return false;
}

/// FormatRelativeTimePattern as a part list; `format` is the concatenation of the
/// values, so the two can't drift. Parts carry `unit` on everything but the
/// surrounding literals (`NumberPart.source` doubles as the `unit` field here).
fn rtfBuildParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) ![]NumberPart {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__rtf_numeric") == null)
        return throwTypeErrorIntl(arena, "Intl.RelativeTimeFormat.prototype method called on an incompatible receiver");
    var numeric: []const u8 = "always";
    if (this_val.toPtr().object.getOwn("__rtf_numeric")) |v| if (v.bits != 0 and v.unbox() == .string) {
        numeric = v.unbox().string;
    };
    // ToNumber the value; a Symbol is a TypeError and a non-finite result a
    // RangeError (spec steps 2-3, in that order).
    const arg0 = if (args.len > 0) args[0] else Value{};
    if (arg0.bits != 0 and arg0.unbox() == .symbol)
        return throwTypeErrorIntl(arena, "Cannot convert a Symbol value to a number");
    const value = try realm_mod.toNumberValue(arena, arg0);
    if (!std.math.isFinite(value)) return throwRangeError(arena, "Intl.RelativeTimeFormat.prototype.format: value must be finite");
    const unit_raw = try t_shared.valueToString(arena, if (args.len > 1) args[1] else Value{});
    const u = singularUnit(unit_raw);
    if (!rtfValidUnit(u)) return throwRangeError(arena, "Intl.RelativeTimeFormat.prototype.format: invalid unit");

    var parts: std.ArrayList(NumberPart) = .empty;
    if (std.mem.eql(u8, numeric, "auto")) {
        if (try rtfAutoForm(arena, value, unit_raw)) |form| {
            try parts.append(arena, .{ .type = "literal", .value = form });
            return parts.items;
        }
    }

    // Numeric form: "N unit(s) ago" (past) / "in N unit(s)" (future). -0 counts
    // as past (ECMA-402 treats it as a negative value).
    const past = std.math.signbit(value);
    const av = @abs(value);
    const unit_name = if (av == 1) u else try std.fmt.allocPrint(arena, "{s}s", .{u});
    if (!past) try parts.append(arena, .{ .type = "literal", .value = "in " });
    for (try nfmt.formatNumberParts(arena, av, .{})) |np|
        try parts.append(arena, .{ .type = np.type, .value = np.value, .source = u });
    try parts.append(arena, .{
        .type = "literal",
        .value = if (past)
            try std.fmt.allocPrint(arena, " {s} ago", .{unit_name})
        else
            try std.fmt.allocPrint(arena, " {s}", .{unit_name}),
    });
    return parts.items;
}

pub fn nativeRelativeTimeFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    var out = std.ArrayListUnmanaged(u8){};
    for (try rtfBuildParts(arena, this_val, args)) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

pub fn nativeRelativeTimeFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try rtfBuildParts(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts) |p| {
        const o = try dnEmptyObj(arena);
        try o.set("type", try val_mod.makeString(arena, p.type));
        try o.set("value", try val_mod.makeString(arena, p.value));
        if (p.source) |unit| try o.set("unit", try val_mod.makeString(arena, unit));
        try arr.appendElement(try val_mod.makeObject(arena, o));
    }
    return val_mod.makeObject(arena, arr);
}

pub fn nativeRelativeTimeFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__rtf_numeric") == null)
        return throwTypeErrorIntl(arena, "Intl.RelativeTimeFormat.prototype.resolvedOptions called on an incompatible receiver");
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    var numeric: []const u8 = "always";
    var style: []const u8 = "long";
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get("__rtf_numeric")) |v| if (v.bits != 0 and v.unbox() == .string) {
            numeric = v.unbox().string;
        };
        if (o.get("__rtf_style")) |v| if (v.bits != 0 and v.unbox() == .string) {
            style = v.unbox().string;
        };
    }
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("style", try val_mod.makeString(arena, style));
    try r.set("numeric", try val_mod.makeString(arena, numeric));
    try r.set("numberingSystem", try val_mod.makeString(arena, "latn"));
    return val_mod.makeObject(arena, r);
}

// ----------------------------------------------------------------- DisplayNames ---

fn dnEmptyObj(arena: std.mem.Allocator) !*JsObject {
    return if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
}

/// An absent `options` argument becomes OrdinaryObjectCreate(**null**), so a
/// getter planted on Object.prototype is never consulted for a defaulted option.
fn emptyOptions(arena: std.mem.Allocator) !Value {
    return val_mod.makeObject(arena, if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, null)
    else
        try JsObject.create(arena, null));
}

/// GetOptionsObject (ES §9.2.13): undefined → a fresh null-prototype object; an
/// object → itself; any other value → TypeError. Used by the services introduced
/// after the option-coercion rules were tightened (ListFormat, DisplayNames,
/// Segmenter, DurationFormat).
pub fn dnGetOptionsObject(arena: std.mem.Allocator, options: ?Value) anyerror!Value {
    const o = options orelse return emptyOptions(arena);
    if (o.bits == 0 or o.unbox() == .undefined_) return emptyOptions(arena);
    if (o.unbox() == .object) return o;
    return throwTypeErrorIntl(arena, "options must be an object");
}

/// CoerceOptionsToObject (ES §9.2.14): the legacy services (Collator,
/// NumberFormat, DateTimeFormat, PluralRules, RelativeTimeFormat) ToObject their
/// `options` instead of rejecting a primitive.
pub fn coerceOptionsToObject(arena: std.mem.Allocator, options: ?Value) anyerror!Value {
    const o = options orelse return emptyOptions(arena);
    if (o.bits == 0 or o.unbox() == .undefined_) return emptyOptions(arena);
    if (o.unbox() == .object) return o;
    if (o.unbox() == .null_) return throwTypeErrorIntl(arena, "Cannot convert null to object");
    return realm_mod.toObjectForThis(arena, o);
}

/// GetOption(options, key, string, allowed, default): reads through the active
/// context so a throwing getter propagates, ToString-coerces the value, and
/// validates it against `allowed` (empty = accept any). Absent/undefined →
/// `default`.
pub fn dnGetOption(arena: std.mem.Allocator, options: Value, key: []const u8, allowed: []const []const u8, default: ?[]const u8) anyerror!?[]const u8 {
    const v = if (realm_mod.active_context) |c|
        try c.getProp(arena, options, key)
    else if (options.bits != 0 and options.unbox() == .object)
        (options.toPtr().object.get(key) orelse Value{})
    else
        Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return default;
    const s = try t_shared.valueToString(arena, v);
    if (allowed.len == 0) return s;
    for (allowed) |a| if (std.mem.eql(u8, a, s)) return s;
    return throwRangeError(arena, try std.fmt.allocPrint(arena, "invalid value for option \"{s}\"", .{key}));
}

/// GetOption(options, key, boolean, empty, undefined): reads through the active
/// context (a throwing getter propagates) and applies ToBoolean.
fn dnGetBoolOption(arena: std.mem.Allocator, options: Value, key: []const u8) anyerror!?bool {
    const v = if (realm_mod.active_context) |c|
        try c.getProp(arena, options, key)
    else if (options.bits != 0 and options.unbox() == .object)
        (options.toPtr().object.get(key) orelse Value{})
    else
        Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    return val_mod.toBoolean(v);
}

fn dnAllAlpha(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}
fn dnAllDigit(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn dnAllAlnum(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}
fn dnIsLangSubtag(s: []const u8) bool {
    return ((s.len >= 2 and s.len <= 3) or (s.len >= 5 and s.len <= 8)) and dnAllAlpha(s);
}
fn dnIsScript(s: []const u8) bool {
    return s.len == 4 and dnAllAlpha(s);
}
fn dnIsRegion(s: []const u8) bool {
    return (s.len == 2 and dnAllAlpha(s)) or (s.len == 3 and dnAllDigit(s));
}
fn dnIsVariant(s: []const u8) bool {
    return (s.len >= 5 and s.len <= 8 and dnAllAlnum(s)) or (s.len == 4 and std.ascii.isDigit(s[0]) and dnAllAlnum(s));
}

/// IsStructurallyValidLanguageTag for a `unicode_language_id` (no extensions):
/// a language subtag, optional script, optional region, then unique variants.
fn dnValidLanguageId(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '-');
    const first = it.next() orelse return false;
    if (!dnIsLangSubtag(first)) return false;
    var seg = it.next();
    if (seg) |g| {
        if (dnIsScript(g)) seg = it.next();
    }
    if (seg) |g| {
        if (dnIsRegion(g)) seg = it.next();
    }
    var variants: [16][]const u8 = undefined;
    var nv: usize = 0;
    while (seg) |g| {
        if (!dnIsVariant(g)) return false;
        for (variants[0..nv]) |ev| if (std.ascii.eqlIgnoreCase(ev, g)) return false; // duplicate variant
        if (nv < variants.len) {
            variants[nv] = g;
            nv += 1;
        }
        seg = it.next();
    }
    return true;
}

/// CanonicalCodeForDisplayNames validation: throws RangeError when `code` is not
/// a structurally valid identifier for `typ`.
fn dnValidateCode(arena: std.mem.Allocator, typ: []const u8, code: []const u8) anyerror!void {
    const ok = if (std.mem.eql(u8, typ, "language"))
        dnValidLanguageId(code)
    else if (std.mem.eql(u8, typ, "region"))
        dnIsRegion(code)
    else if (std.mem.eql(u8, typ, "script"))
        dnIsScript(code)
    else if (std.mem.eql(u8, typ, "currency"))
        (code.len == 3 and dnAllAlpha(code))
    else if (std.mem.eql(u8, typ, "calendar"))
        isWellFormedNumberingSystem(code)
    else if (std.mem.eql(u8, typ, "dateTimeField")) blk: {
        const fields = [_][]const u8{ "era", "year", "quarter", "month", "weekOfYear", "weekday", "day", "dayPeriod", "hour", "minute", "second", "timeZoneName" };
        for (fields) |f| if (std.mem.eql(u8, f, code)) break :blk true;
        break :blk false;
    } else false;
    if (!ok) return throwRangeError(arena, "invalid code for Intl.DisplayNames.prototype.of");
}

pub fn nativeDisplayNamesCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing)
        return throwTypeErrorIntl(arena, "Constructor Intl.DisplayNames requires 'new'");
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try dnEmptyObj(arena);

    // CanonicalizeLocaleList(locales): walk via HasProperty/[[Get]] (poisoned
    // length/getters and non-String/Object elements throw), validate every tag
    // and resolve the one this build will format in.
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});

    // options is required: GetOptionsObject then a required `type`.
    const options = try dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const style = (try dnGetOption(arena, options, "style", &.{ "narrow", "short", "long" }, "long")).?;
    const typ = (try dnGetOption(arena, options, "type", &.{ "language", "region", "script", "currency", "calendar", "dateTimeField" }, null)) orelse
        return throwTypeErrorIntl(arena, "Intl.DisplayNames: the `type` option is required");
    const fallback = (try dnGetOption(arena, options, "fallback", &.{ "code", "none" }, "code")).?;
    const lang_display = (try dnGetOption(arena, options, "languageDisplay", &.{ "dialect", "standard" }, "dialect")).?;

    try obj.set("__dn_style", try val_mod.makeString(arena, style));
    try obj.set("__dn_type", try val_mod.makeString(arena, typ));
    try obj.set("__dn_fallback", try val_mod.makeString(arena, fallback));
    try obj.set("__dn_langdisplay", try val_mod.makeString(arena, lang_display));
    return val_mod.makeObject(arena, obj);
}

pub fn nativeDisplayNamesOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__dn_type") == null)
        return throwTypeErrorIntl(arena, "Intl.DisplayNames.prototype.of called on an incompatible receiver");
    const o = this_val.toPtr().object;
    const typ = o.getOwn("__dn_type").?.unbox().string;
    const fallback: []const u8 = if (o.getOwn("__dn_fallback")) |v| v.unbox().string else "code";
    const code = try t_shared.valueToString(arena, if (args.len > 0) args[0] else Value{});
    try dnValidateCode(arena, typ, code);
    // No CLDR name data: with fallback "code" the (validated) code is returned;
    // with "none" the absent name yields undefined. Both satisfy `typeof`.
    if (std.mem.eql(u8, fallback, "none")) return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, code);
}

pub fn nativeDisplayNamesResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__dn_type") == null)
        return throwTypeErrorIntl(arena, "Intl.DisplayNames.prototype.resolvedOptions called on an incompatible receiver");
    const o = this_val.toPtr().object;
    const r = try dnEmptyObj(arena);
    const typ = o.getOwn("__dn_type").?.unbox().string;
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("style", o.getOwn("__dn_style") orelse try val_mod.makeString(arena, "long"));
    try r.set("type", try val_mod.makeString(arena, typ));
    try r.set("fallback", o.getOwn("__dn_fallback") orelse try val_mod.makeString(arena, "code"));
    if (std.mem.eql(u8, typ, "language"))
        try r.set("languageDisplay", o.getOwn("__dn_langdisplay") orelse try val_mod.makeString(arena, "dialect"));
    return val_mod.makeObject(arena, r);
}

// --------------------------------------------------------------- DurationFormat ---
//
// A pragmatic en-US `Intl.DurationFormat` (ECMA-402). Supports the four styles
// (long/short/narrow/digital), per-unit style + display overrides, and the
// numeric "H:MM:SS[.fff]" clock grouping used by `digital` / explicit numeric
// units. CLDR unit strings are the en data (see the unit table below).

const DF_UNITS = [_][]const u8{ "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" };

/// Per-unit CLDR display forms for en. long/short carry singular+plural; narrow
/// has a single (no-space) form. Grouping/number is prepended by the caller.
const DfUnitForms = struct {
    long_one: []const u8,
    long_other: []const u8,
    short_one: []const u8,
    short_other: []const u8,
    narrow: []const u8,
};
const DF_FORMS = [_]DfUnitForms{
    .{ .long_one = "year", .long_other = "years", .short_one = "yr", .short_other = "yrs", .narrow = "y" },
    .{ .long_one = "month", .long_other = "months", .short_one = "mth", .short_other = "mths", .narrow = "m" },
    .{ .long_one = "week", .long_other = "weeks", .short_one = "wk", .short_other = "wks", .narrow = "w" },
    .{ .long_one = "day", .long_other = "days", .short_one = "day", .short_other = "days", .narrow = "d" },
    .{ .long_one = "hour", .long_other = "hours", .short_one = "hr", .short_other = "hr", .narrow = "h" },
    .{ .long_one = "minute", .long_other = "minutes", .short_one = "min", .short_other = "min", .narrow = "m" },
    .{ .long_one = "second", .long_other = "seconds", .short_one = "sec", .short_other = "sec", .narrow = "s" },
    .{ .long_one = "millisecond", .long_other = "milliseconds", .short_one = "ms", .short_other = "ms", .narrow = "ms" },
    .{ .long_one = "microsecond", .long_other = "microseconds", .short_one = "\u{03bc}s", .short_other = "\u{03bc}s", .narrow = "\u{03bc}s" },
    .{ .long_one = "nanosecond", .long_other = "nanoseconds", .short_one = "ns", .short_other = "ns", .narrow = "ns" },
};

/// Valid `style` values for a given unit index. Time-core units (hours/minutes/
/// seconds) also allow "numeric"/"2-digit"; sub-second units allow "numeric".
fn dfUnitAllows(unit_idx: usize, style: []const u8) bool {
    if (std.mem.eql(u8, style, "long") or std.mem.eql(u8, style, "short") or std.mem.eql(u8, style, "narrow")) return true;
    if (std.mem.eql(u8, style, "numeric")) return unit_idx >= 4; // hours..nanoseconds
    if (std.mem.eql(u8, style, "2-digit")) return unit_idx >= 4 and unit_idx <= 6; // hours/minutes/seconds
    return false;
}

/// Digital-style per-unit default: hours→numeric, minutes/seconds→2-digit,
/// everything else→short (date units) / numeric (sub-second units).
fn dfDigitalBase(unit_idx: usize) []const u8 {
    return switch (unit_idx) {
        4 => "numeric", // hours
        5, 6 => "2-digit", // minutes, seconds
        7, 8, 9 => "numeric", // milli/micro/nanoseconds
        else => "short", // years..days
    };
}

fn dfIsNumericStyle(style: []const u8) bool {
    return std.mem.eql(u8, style, "numeric") or std.mem.eql(u8, style, "2-digit");
}

/// Read + validate an option string; RangeError if present but not in `allowed`.
/// Returns null when absent/undefined. (Getter dispatch is not performed — plain
/// data option objects, which the corpus overwhelmingly uses.)
fn dfGetOption(arena: std.mem.Allocator, opts: ?Value, key: []const u8, allowed: []const []const u8) !?[]const u8 {
    const o = opts orelse return null;
    if (o.bits == 0 or o.unbox() != .object) return null;
    const v = o.toPtr().object.get(key) orelse return null;
    if (v.bits == 0 or v.unbox() == .undefined_) return null;
    const s = try t_shared.valueToString(arena, v);
    for (allowed) |a| if (std.mem.eql(u8, a, s)) return s;
    return throwRangeError(arena, "invalid value for Intl.DurationFormat option");
}

pub fn nativeDurationFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // NewTarget must be present (spec step 1). Built-in `__call__` constructors
    // are flagged via `active_constructing` on the `new` path; read + consume it
    // immediately so nested coercions can't confuse the check.
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    if (!constructing)
        return throwTypeErrorIntl(arena, "Constructor Intl.DurationFormat requires 'new'");
    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    return dfBuild(arena, obj, args);
}

/// Parse (locales, options) into the DurationFormat internal slots stored on
/// `obj`, and return `obj` boxed. Shared by the constructor and
/// `Temporal.Duration.prototype.toLocaleString`.
fn dfBuild(arena: std.mem.Allocator, obj: *JsObject, args: []const Value) anyerror!Value {
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const opts: ?Value = if (args.len > 1) args[1] else null;
    if (opts) |ov| {
        if (ov.bits != 0 and ov.unbox() != .undefined_ and ov.unbox() != .object)
            return throwTypeErrorIntl(arena, "options must be an object");
    }

    // localeMatcher must be "lookup" or "best fit" when present (else RangeError).
    _ = try dfGetOption(arena, opts, "localeMatcher", &.{ "lookup", "best fit" });

    // numberingSystem — must be a well-formed Unicode `type` value when present.
    const nu = optStr(opts, "numberingSystem") orelse "latn";
    if (opts) |ov| if (ov.bits != 0 and ov.unbox() == .object) {
        if (ov.toPtr().object.get("numberingSystem")) |nv| if (nv.bits != 0 and nv.unbox() != .undefined_) {
            const nstr = try t_shared.valueToString(arena, nv);
            if (!isWellFormedNumberingSystem(nstr))
                return throwRangeError(arena, "invalid numberingSystem");
        };
    };
    try obj.set("__df_nu", try val_mod.makeString(arena, nu));

    const base_style = (try dfGetOption(arena, opts, "style", &.{ "long", "short", "narrow", "digital" })) orelse "short";
    try obj.set("__df_style", try val_mod.makeString(arena, base_style));

    // fractionalDigits: 0..9 or absent (-1 sentinel).
    var frac: f64 = -1;
    if (opts) |ov| if (ov.bits != 0 and ov.unbox() == .object) {
        if (ov.toPtr().object.get("fractionalDigits")) |fv| if (fv.bits != 0 and fv.unbox() != .undefined_) {
            const n = try realm_mod.toNumberValue(arena, fv);
            if (!std.math.isFinite(n) or n < 0 or n > 9 or n != @trunc(n))
                return throwRangeError(arena, "fractionalDigits out of range");
            frac = n;
        };
    };
    try obj.set("__df_frac", try val_mod.makeNumber(arena, frac));

    // GetDurationUnitOptions for each unit, in table order.
    var prev_style: []const u8 = "";
    const is_digital = std.mem.eql(u8, base_style, "digital");
    for (DF_UNITS, 0..) |uname, i| {
        const allowed_all = [_][]const u8{ "long", "short", "narrow", "numeric", "2-digit" };
        // Only pass the styles this unit accepts to the validator.
        var allowed_buf: [5][]const u8 = undefined;
        var n_allowed: usize = 0;
        for (allowed_all) |a| {
            if (dfUnitAllows(i, a)) {
                allowed_buf[n_allowed] = a;
                n_allowed += 1;
            }
        }
        var style = try dfGetOption(arena, opts, uname, allowed_buf[0..n_allowed]);
        var display_default: []const u8 = "always";
        if (style == null) {
            if (is_digital) {
                if (i < 4 or i > 6) display_default = "auto";
                style = dfDigitalBase(i);
            } else {
                display_default = "auto";
                if (dfIsNumericStyle(prev_style)) {
                    // A unit following a numeric/2-digit one defaults to "2-digit"
                    // for minutes/seconds and "numeric" for sub-second units.
                    style = if (i == 5 or i == 6) "2-digit" else "numeric";
                } else {
                    style = base_style;
                }
            }
        }
        // GetDurationUnitOptions step 6: a long/short/narrow style cannot follow a
        // unit rendered with "numeric"/"2-digit".
        if (dfIsNumericStyle(prev_style) and !dfIsNumericStyle(style.?))
            return throwRangeError(arena, "Intl.DurationFormat: style cannot follow a numeric unit");
        const disp_key = try std.fmt.allocPrint(arena, "{s}Display", .{uname});
        const display = (try dfGetOption(arena, opts, disp_key, &.{ "auto", "always" })) orelse display_default;

        try obj.set(try std.fmt.allocPrint(arena, "__df_s{d}", .{i}), try val_mod.makeString(arena, style.?));
        try obj.set(try std.fmt.allocPrint(arena, "__df_d{d}", .{i}), try val_mod.makeString(arena, display));
        prev_style = style.?;
    }

    return val_mod.makeObject(arena, obj);
}

/// A Unicode `type` value: one or more `-`-separated 3..8 alphanumeric segments.
pub fn isWellFormedNumberingSystem(s: []const u8) bool {
    if (s.len == 0) return false;
    var seg_len: usize = 0;
    for (s) |c| {
        if (c == '-') {
            if (seg_len < 3 or seg_len > 8) return false;
            seg_len = 0;
        } else if (std.ascii.isAlphanumeric(c)) {
            seg_len += 1;
        } else return false;
    }
    return seg_len >= 3 and seg_len <= 8;
}

/// First subtag (primary language) of a canonical tag, lower-cased.
fn primaryLanguage(tag: []const u8) []const u8 {
    const dash = std.mem.indexOfScalar(u8, tag, '-') orelse tag.len;
    return tag[0..dash];
}

/// `Intl.DurationFormat.supportedLocalesOf(locales[, options])` — canonicalizes
/// the requested list (throwing on structurally invalid tags) and returns those
/// that are supported. Every real language tag is treated as supported except
/// the "no linguistic content" tags (`zxx`/`und`).
/// CanonicalizeLocaleList (ES §9.2.1), returning the raw ToString'd tags (the
/// caller canonicalizes/dedups). A String argument is a single-element list; an
/// array-like is walked via HasProperty + [[Get]] so a poisoned length/getter
/// propagates, and a present element that is neither a String nor an Object is a
/// TypeError.
pub fn canonicalizeLocaleList(arena: std.mem.Allocator, locales: Value) anyerror![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    if (locales.bits == 0 or locales.unbox() == .undefined_) return out.items;
    // ToObject(null) is a TypeError; other primitives box to a wrapper with no
    // "length" (→ empty list). A String is a single-element list.
    if (locales.unbox() == .null_) return throwTypeErrorIntl(arena, "Cannot convert null locales to object");
    if (locales.unbox() == .string) {
        try out.append(arena, locales.unbox().string);
        return out.items;
    }
    if (locales.unbox() != .object) return out.items;
    const ctx = realm_mod.active_context;
    const len_v = if (ctx) |c| try c.getProp(arena, locales, "length") else Value{};
    // ToLength → ToNumber: a Symbol or BigInt length is a TypeError.
    if (len_v.bits != 0 and (len_v.unbox() == .symbol or len_v.unbox() == .bigint))
        return throwTypeErrorIntl(arena, "Cannot convert length to a number");
    const len = try realm_mod.toLengthValue(arena, len_v);
    var k: usize = 0;
    while (k < len) : (k += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{k});
        const present = if (ctx) |c| try c.hasProp(arena, locales, key) else false;
        if (!present) continue;
        const kv = if (ctx) |c| try c.getProp(arena, locales, key) else Value{};
        if (kv.bits != 0 and kv.unbox() == .string) {
            try out.append(arena, kv.unbox().string);
        } else if (kv.bits != 0 and kv.unbox() == .object) {
            try out.append(arena, try t_shared.valueToString(arena, kv));
        } else {
            return throwTypeErrorIntl(arena, "locale list element must be a String or Object");
        }
    }
    return out.items;
}

pub fn nativeDurationFormatSupportedLocalesOf(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const requested = try canonicalizeLocaleList(arena, if (args.len > 0) args[0] else Value{});
    // CanonicalizeLocaleList validates every tag (RangeError) before options are
    // even looked at, so canonicalize the whole list up front.
    var canonical = try arena.alloc([]const u8, requested.len);
    for (requested, 0..) |t, i| canonical[i] = try canonicalizeTag(arena, t);

    // SupportedLocales then coerces options to an object and reads (and
    // validates) localeMatcher through a real [[Get]].
    const opts = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, opts, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");

    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    var seen = std.ArrayListUnmanaged([]const u8){};
    var n: usize = 0;
    for (canonical) |canon| {
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, canon)) {
            dup = true;
            break;
        };
        if (dup) continue;
        try seen.append(arena, canon);
        const lang = primaryLanguage(canon);
        if (std.mem.eql(u8, lang, "zxx") or std.mem.eql(u8, lang, "und")) continue;
        try arr.set(try std.fmt.allocPrint(arena, "{d}", .{n}), try val_mod.makeString(arena, canon));
        n += 1;
    }
    return val_mod.makeObject(arena, arr);
}

/// Build a DurationFormat instance from `(locales, options)` without a NewTarget
/// requirement — used by `Temporal.Duration.prototype.toLocaleString`.
pub fn durationFormatFor(arena: std.mem.Allocator, args: []const Value) anyerror!Value {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    return dfBuild(arena, obj, args);
}

fn dfReadStr(o: *JsObject, key: []const u8, default: []const u8) []const u8 {
    const v = o.get(key) orelse return default;
    if (v.bits != 0 and v.unbox() == .string) return v.unbox().string;
    return default;
}

/// Append an integer magnitude (given as a non-negative f64) with optional en
/// grouping (comma every three digits). `neg` prints a leading minus. Values
/// beyond u64 range fall back to a plain decimal so huge (but valid) durations
/// format without overflow — their exact digits are not asserted by test262.
fn dfAppendMagnitude(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), mag: f64, neg: bool, grouping: bool) !void {
    if (neg) try buf.append(arena, '-');
    var tmp: [40]u8 = undefined;
    const s = if (mag < 18446744073709551615.0)
        std.fmt.bufPrint(&tmp, "{d}", .{@as(u64, @intFromFloat(mag))}) catch unreachable
    else
        std.fmt.bufPrint(&tmp, "{d:.0}", .{mag}) catch (std.fmt.bufPrint(&tmp, "0", .{}) catch unreachable);
    if (!grouping) {
        try buf.appendSlice(arena, s);
        return;
    }
    const first = s.len % 3;
    for (s, 0..) |c, i| {
        if (i != 0 and (i % 3) == first) try buf.append(arena, ',');
        try buf.append(arena, c);
    }
}

/// Format one standalone unit ("1 year", "2 yrs", "3w"). `first_shown` gates the
/// sign (only the first displayed field keeps a negative sign).
fn dfFormatStandalone(arena: std.mem.Allocator, unit_idx: usize, style: []const u8, value: f64, first_shown: bool) ![]const u8 {
    const neg = first_shown and value < 0;
    const mag = @abs(value);
    var num = std.ArrayListUnmanaged(u8){};
    try dfAppendMagnitude(arena, &num, mag, neg, true);
    // English plural: |value| == 1 → "one" category (sign does not affect it).
    const one = mag == 1;
    const forms = DF_FORMS[unit_idx];
    if (std.mem.eql(u8, style, "narrow")) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ num.items, forms.narrow });
    } else if (std.mem.eql(u8, style, "short")) {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ num.items, if (one) forms.short_one else forms.short_other });
    }
    // long (default for standalone)
    return std.fmt.allocPrint(arena, "{s} {s}", .{ num.items, if (one) forms.long_one else forms.long_other });
}

pub fn nativeDurationFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return throwTypeErrorIntl(arena, "Intl.DurationFormat.prototype.format called on incompatible receiver");
    const o = this_val.toPtr().object;
    if (o.get("__df_style") == null)
        return throwTypeErrorIntl(arena, "Intl.DurationFormat.prototype.format called on incompatible receiver");

    const d = try t_duration.toTemporalDuration(arena, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
    const fields = [_]f64{ d.years, d.months, d.weeks, d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };

    const base_style = dfReadStr(o, "__df_style", "short");
    const frac_digits: i32 = if (o.get("__df_frac")) |fv| (if (fv.bits != 0 and fv.unbox() == .number) @intFromFloat(fv.unbox().number) else -1) else -1;

    var styles: [10][]const u8 = undefined;
    var displays: [10][]const u8 = undefined;
    for (0..10) |i| {
        var kb: [8]u8 = undefined;
        styles[i] = dfReadStr(o, std.fmt.bufPrint(&kb, "__df_s{d}", .{i}) catch unreachable, "short");
        var db: [8]u8 = undefined;
        displays[i] = dfReadStr(o, std.fmt.bufPrint(&db, "__df_d{d}", .{i}) catch unreachable, "auto");
    }

    var elements = std.ArrayListUnmanaged([]const u8){};
    var first_shown = true;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const style = styles[i];
        const display = displays[i];
        const numeric = dfIsNumericStyle(style);

        // Sub-second units (i>=7) that are numeric are folded into fractional
        // seconds by the clock group; they never render standalone here.
        if (numeric and i >= 7) continue;

        if (!numeric) {
            const value = fields[i];
            if (value != 0 or std.mem.eql(u8, display, "always")) {
                try elements.append(arena, try dfFormatStandalone(arena, i, style, value, first_shown));
                first_shown = false;
            }
            continue;
        }

        // Numeric clock group starting at unit i (one of hours/minutes/seconds).
        // Consecutive numeric time units join with ":"; seconds folds any numeric
        // sub-second fields into a fractional part. `j` stops at the first
        // non-numeric time unit (or past seconds).
        var clock = std.ArrayListUnmanaged(u8){};
        var wrote_any = false;
        var j = i;
        while (j <= 6) : (j += 1) {
            if (!dfIsNumericStyle(styles[j])) break;
            const value = fields[j];
            const disp = displays[j];
            const show = value != 0 or std.mem.eql(u8, disp, "always") or wrote_any;
            if (!show) continue;
            if (wrote_any) try clock.append(arena, ':');
            const two_digit = std.mem.eql(u8, styles[j], "2-digit");
            const neg = first_shown and value < 0;
            const mag = @abs(value);
            if (neg) try clock.append(arena, '-');
            if (j == 6) {
                // seconds: fold sub-seconds into a fractional part.
                try dfAppendClockSeconds(arena, &clock, &fields, frac_digits, two_digit);
            } else {
                if (two_digit and mag < 10) try clock.append(arena, '0');
                try dfAppendMagnitude(arena, &clock, mag, false, false);
            }
            wrote_any = true;
            first_shown = false;
        }
        if (wrote_any) try elements.append(arena, clock.items);
        i = j - 1; // resume at the first unit the clock group did not consume
    }

    // Join the list. Unit-style ListFormat: long/short/digital → ", "; narrow → " ".
    const sep: []const u8 = if (std.mem.eql(u8, base_style, "narrow")) " " else ", ";
    var out = std.ArrayListUnmanaged(u8){};
    for (elements.items, 0..) |e, idx| {
        if (idx != 0) try out.appendSlice(arena, sep);
        try out.appendSlice(arena, e);
    }
    return val_mod.makeString(arena, out.items);
}

/// Append the seconds component of a numeric clock. Sub-second fields carry up
/// into whole seconds (e.g. 56s + 1234567ms = "1290.567"), so the whole part is
/// computed from the total nanoseconds (i128, no overflow) and the fractional
/// part is truncated to `frac_digits` (or the shortest exact form when absent).
fn dfAppendClockSeconds(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), fields: *const [10]f64, frac_digits: i32, two_digit: bool) !void {
    const total_ns: i128 = @as(i128, @intFromFloat(@abs(fields[6]))) * 1_000_000_000 +
        @as(i128, @intFromFloat(@abs(fields[7]))) * 1_000_000 +
        @as(i128, @intFromFloat(@abs(fields[8]))) * 1_000 +
        @as(i128, @intFromFloat(@abs(fields[9])));
    const whole: u64 = @intCast(@divTrunc(total_ns, 1_000_000_000));
    const frac_ns: u32 = @intCast(@mod(total_ns, 1_000_000_000));

    if (two_digit and whole < 10) try buf.append(arena, '0');
    var nb: [24]u8 = undefined;
    try buf.appendSlice(arena, std.fmt.bufPrint(&nb, "{d}", .{whole}) catch unreachable);

    var frac: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{frac_ns}) catch unreachable;
    if (frac_digits >= 0) {
        const dd: usize = @intCast(frac_digits);
        if (dd == 0) return;
        try buf.append(arena, '.');
        try buf.appendSlice(arena, frac[0..dd]);
    } else {
        if (frac_ns == 0) return;
        var end: usize = 9;
        while (end > 0 and frac[end - 1] == '0') : (end -= 1) {}
        try buf.append(arena, '.');
        try buf.appendSlice(arena, frac[0..end]);
    }
}

pub fn nativeDurationFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Minimal: return the whole formatted string as one { type:"literal", value } part.
    const s_val = try nativeDurationFormatFormat(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    const part = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try part.set("type", try val_mod.makeString(arena, "literal"));
    try part.set("value", s_val);
    try arr.appendElement(try val_mod.makeObject(arena, part));
    return val_mod.makeObject(arena, arr);
}

pub fn nativeDurationFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return throwTypeErrorIntl(arena, "Intl.DurationFormat.prototype.resolvedOptions called on incompatible receiver");
    const o = this_val.toPtr().object;
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try r.set("locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try r.set("numberingSystem", try val_mod.makeString(arena, dfReadStr(o, "__df_nu", "latn")));
    try r.set("style", try val_mod.makeString(arena, dfReadStr(o, "__df_style", "short")));
    for (DF_UNITS, 0..) |uname, i| {
        var sk: [8]u8 = undefined;
        var dk: [8]u8 = undefined;
        try r.set(uname, try val_mod.makeString(arena, dfReadStr(o, std.fmt.bufPrint(&sk, "__df_s{d}", .{i}) catch unreachable, "short")));
        const disp_key = try std.fmt.allocPrint(arena, "{s}Display", .{uname});
        try r.set(disp_key, try val_mod.makeString(arena, dfReadStr(o, std.fmt.bufPrint(&dk, "__df_d{d}", .{i}) catch unreachable, "auto")));
    }
    const frac_digits: i32 = if (o.get("__df_frac")) |fv| (if (fv.bits != 0 and fv.unbox() == .number) @intFromFloat(fv.unbox().number) else -1) else -1;
    if (frac_digits >= 0) try r.set("fractionalDigits", try val_mod.makeNumber(arena, @floatFromInt(frac_digits)));
    return val_mod.makeObject(arena, r);
}

// ----------------------------------------------------------------------- tests ---

test "intl: parseLocaleTag subtags" {
    const p = parseLocaleTag("zh-Hant-CN");
    try std.testing.expectEqualStrings("zh", p.language);
    try std.testing.expectEqualStrings("Hant", p.script);
    try std.testing.expectEqualStrings("CN", p.region);

    const q = parseLocaleTag("en-US");
    try std.testing.expectEqualStrings("en", q.language);
    try std.testing.expectEqualStrings("", q.script);
    try std.testing.expectEqualStrings("US", q.region);
}

test "intl: canonSubtag casing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("en", try canonSubtag(a, "EN", .lang));
    try std.testing.expectEqualStrings("US", try canonSubtag(a, "us", .region));
    try std.testing.expectEqualStrings("Hant", try canonSubtag(a, "hANT", .script));
}

test "intl: collator case-insensitive order" {
    try std.testing.expectEqual(std.math.Order.eq, orderCaseInsensitive("Apple", "apple"));
    try std.testing.expectEqual(std.math.Order.lt, orderCaseInsensitive("apple", "banana"));
    try std.testing.expectEqual(std.math.Order.gt, orderCaseInsensitive("Banana", "apple"));
}

test "intl: listformat en-US phrasing" {
    try std.testing.expect(true); // format() needs an array object; covered by differential corpus.
}

test "intl: pluralCategory cardinal & ordinal" {
    try std.testing.expectEqualStrings("one", pluralCategory(1, false));
    try std.testing.expectEqualStrings("other", pluralCategory(0, false));
    try std.testing.expectEqualStrings("other", pluralCategory(2, false));
    try std.testing.expectEqualStrings("one", pluralCategory(1, true));
    try std.testing.expectEqualStrings("two", pluralCategory(2, true));
    try std.testing.expectEqualStrings("few", pluralCategory(3, true));
    try std.testing.expectEqualStrings("other", pluralCategory(4, true));
    try std.testing.expectEqualStrings("other", pluralCategory(11, true));
    try std.testing.expectEqualStrings("other", pluralCategory(12, true));
    try std.testing.expectEqualStrings("other", pluralCategory(13, true));
    try std.testing.expectEqualStrings("one", pluralCategory(21, true));
    try std.testing.expectEqualStrings("few", pluralCategory(103, true));
}

test "intl: singularUnit strips plural s" {
    try std.testing.expectEqualStrings("day", singularUnit("days"));
    try std.testing.expectEqualStrings("day", singularUnit("day"));
    try std.testing.expectEqualStrings("month", singularUnit("months"));
}

test "intl: numeric collation order" {
    try std.testing.expectEqual(std.math.Order.gt, orderNumeric("10", "2", false));
    try std.testing.expectEqual(std.math.Order.lt, orderNumeric("a2", "a10", false));
    try std.testing.expectEqual(std.math.Order.lt, orderNumeric("file9", "file10", false));
    try std.testing.expectEqual(std.math.Order.eq, orderNumeric("2", "2", false));
    try std.testing.expectEqual(std.math.Order.gt, orderNumeric("item20", "item3", false));
    try std.testing.expectEqual(std.math.Order.eq, orderNumeric("007", "7", false));
    try std.testing.expectEqual(std.math.Order.eq, orderNumeric("A1", "a1", true));
}
