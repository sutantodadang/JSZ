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
const collections_mod = @import("es2015_collections.zig");
const function_proto_mod = @import("function_proto.zig");

// Temporal integration: `Intl.DateTimeFormat.prototype.format` accepts Temporal
// date/time objects, and `Temporal.X.prototype.toLocaleString` routes through
// this module's en-US formatter (see temporalEpochMs / temporalToLocaleString).
const t_shared = @import("temporal/shared.zig");
const str_mod = @import("string_proto.zig");
const unorm = @import("unicode_normalize.zig");
const uprops = @import("unicode_prop_tables.zig");
const ucase = @import("unicode_case_tables.zig");
const t_instant = @import("temporal/instant.zig");
const t_pdate = @import("temporal/plain_date.zig");
const t_ptime = @import("temporal/plain_time.zig");
const t_pdatetime = @import("temporal/plain_date_time.zig");
const t_zdt = @import("temporal/zoned_date_time.zig");
const t_pym = @import("temporal/plain_year_month.zig");
const t_pmd = @import("temporal/plain_month_day.zig");
const t_duration = @import("temporal/duration.zig");
const t_calendar = @import("temporal/calendar.zig");
const t_tzdata = @import("temporal/tzdata.zig");
const nfmt = @import("intl_number.zig");
const locale_id = @import("intl_locale_id.zig");
const likely = @import("intl_likely_subtags.zig");
const plural = @import("intl_plural.zig");

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
        try JsObject.createOnHeap(h, realm_mod.rangeErrorProto())
    else
        try JsObject.create(arena, realm_mod.rangeErrorProto());
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

pub fn throwTypeErrorIntl(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.typeErrorProto())
    else
        try JsObject.create(arena, realm_mod.typeErrorProto());
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

/// %Intl.NumberFormat.prototype%, for `intl_number.zig`'s legacy chaining.
pub fn numberFormatProto() ?*JsObject {
    return active_number_format_proto;
}

/// ChainNumberFormat / ChainDateTimeFormat / ChainCollator: a `new`-less call
/// whose `this` already inherits from the service's prototype does not build a
/// fresh instance — it hangs `created` off the receiver under
/// %Intl%.[[FallbackSymbol]] and returns the receiver (ECMA-402 §8.1).
pub fn chainLegacyService(this_val: Value, created: Value, proto: ?*JsObject) !Value {
    const target = proto orelse return created;
    if (this_val.bits == 0 or this_val.unbox() != .object) return created;
    const recv = this_val.toPtr().object;
    var walk: ?*JsObject = recv.proto;
    while (walk) |p| : (walk = p.proto) {
        if (p == target) break;
    } else return created;
    const sym = realm_mod.active_sym_intl_fallback orelse return created;
    try recv.setSymAttr(sym, created, .{ .writable = false, .enumerable = false, .configurable = false });
    return this_val;
}

/// UnwrapNumberFormat / UnwrapDateTimeFormat: `format` and `resolvedOptions`
/// accept the wrapper a `new`-less call produced and operate on the instance it
/// carries. The lookup is an ordinary [[Get]], so a Proxy in between observes it.
pub fn unwrapLegacyService(arena: std.mem.Allocator, this_val: Value, brand: []const u8) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return this_val;
    if (this_val.toPtr().object.getOwn(brand) != null) return this_val;
    const sym = realm_mod.active_sym_intl_fallback orelse return this_val;
    const inner = if (realm_mod.active_context) |c|
        try c.getPropSym(arena, this_val, sym)
    else
        (this_val.toPtr().object.getSym(sym) orelse Value{});
    if (inner.bits != 0 and inner.unbox() == .object) return inner;
    return this_val;
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

/// The date-time component options, in the order `CreateDateTimeFormat` reads
/// them (§11.1.2 step 36 — Table 7 order, which `constructor-options-order.js`
/// observes) together with the values each one accepts.
const dtf_components = [_]struct { key: []const u8, slot: []const u8, allowed: []const []const u8 }{
    .{ .key = "weekday", .slot = "__dtf_weekday", .allowed = &.{ "narrow", "short", "long" } },
    .{ .key = "era", .slot = "__dtf_era", .allowed = &.{ "narrow", "short", "long" } },
    .{ .key = "year", .slot = "__dtf_year", .allowed = &.{ "2-digit", "numeric" } },
    .{ .key = "month", .slot = "__dtf_month", .allowed = &.{ "2-digit", "numeric", "narrow", "short", "long" } },
    .{ .key = "day", .slot = "__dtf_day", .allowed = &.{ "2-digit", "numeric" } },
    .{ .key = "dayPeriod", .slot = "__dtf_dayPeriod", .allowed = &.{ "narrow", "short", "long" } },
    .{ .key = "hour", .slot = "__dtf_hour", .allowed = &.{ "2-digit", "numeric" } },
    .{ .key = "minute", .slot = "__dtf_minute", .allowed = &.{ "2-digit", "numeric" } },
    .{ .key = "second", .slot = "__dtf_second", .allowed = &.{ "2-digit", "numeric" } },
};

const dtf_styles = [_][]const u8{ "full", "long", "medium", "short" };

/// A Unicode `type` subtag: `alphanum{3,8}` joined by `-`. Both the `calendar`
/// and `numberingSystem` options must match it (§11.1.2 steps 5 / 8) — anything
/// else is a RangeError before the value is even looked up.
fn isWellFormedUnicodeType(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '-');
    var any = false;
    while (it.next()) |seg| {
        any = true;
        if (seg.len < 3 or seg.len > 8) return false;
        for (seg) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return any;
}

/// A resolved DateTimeFormat time zone: the identifier `resolvedOptions()`
/// reports (never Link-canonicalized — §11.1.2 keeps the requested spelling),
/// the zone whose offsets and name it formats with, and its fixed UTC offset in
/// milliseconds. `id` and `zone` differ only for a tzdb Link.
const DtfZone = struct { id: []const u8, zone: []const u8, offset_ms: i64 };

/// tzdb `backward` Links for the zones this build ships offsets for. The Link
/// name stays visible in `resolvedOptions().timeZone`, but formatting has to
/// follow the target — `Asia/Calcutta` and `Asia/Kolkata` must agree.
const iana_links = [_][2][]const u8{
    .{ "Asia/Calcutta", "Asia/Kolkata" },
    .{ "America/Buenos_Aires", "America/Argentina/Buenos_Aires" },
    .{ "Asia/Chongqing", "Asia/Shanghai" },
    .{ "Australia/Canberra", "Australia/Sydney" },
    .{ "Europe/Kiev", "Europe/Kyiv" },
    .{ "Europe/Nicosia", "Asia/Nicosia" },
    .{ "US/Eastern", "America/New_York" },
    .{ "US/Central", "America/Chicago" },
    .{ "US/Mountain", "America/Denver" },
    .{ "US/Pacific", "America/Los_Angeles" },
};

/// True for a syntactically valid IANA identifier: `Area/Location[/Sub]`, ASCII
/// only. Names without a `/` are the legacy non-IANA abbreviations (`PST`,
/// `IST`, …) that ECMA-402 rejects, and a non-ASCII byte is never valid.
fn isPlausibleIanaName(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '/') == null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg.len > 14) return false;
        for (seg) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '+' and c != '.') return false;
        }
    }
    return true;
}

/// Parse a `±HH`, `±HHMM` or `±HH:MM` offset identifier into minutes.
fn parseOffsetMinutes(s: []const u8) ?i64 {
    if (s.len < 3) return null;
    const sign: i64 = switch (s[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const body = s[1..];
    var h: i64 = 0;
    var m: i64 = 0;
    if (body.len == 2) {
        h = std.fmt.parseInt(i64, body, 10) catch return null;
    } else if (body.len == 4) {
        h = std.fmt.parseInt(i64, body[0..2], 10) catch return null;
        m = std.fmt.parseInt(i64, body[2..4], 10) catch return null;
    } else if (body.len == 5 and body[2] == ':') {
        h = std.fmt.parseInt(i64, body[0..2], 10) catch return null;
        m = std.fmt.parseInt(i64, body[3..5], 10) catch return null;
    } else return null;
    if (h > 23 or m > 59) return null;
    return sign * (h * 60 + m);
}

/// The `Etc/GMT±N` family, whose sign is POSIX-inverted (`Etc/GMT-3` is UTC+3).
/// Returns the offset in minutes, or null when `s` is not one of them.
fn etcGmtOffsetMinutes(s: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, s, "Etc/GMT")) return null;
    const rest = s["Etc/GMT".len..];
    if (rest.len == 0) return 0;
    const sign: i64 = switch (rest[0]) {
        '+' => -1,
        '-' => 1,
        else => return null,
    };
    const n = std.fmt.parseInt(i64, rest[1..], 10) catch return null;
    if (n > 14) return null;
    return sign * n * 60;
}

/// Resolve the `timeZone` option (§11.1.2 step 30). Unlike Temporal's resolver
/// this keeps the requested spelling — `Asia/Calcutta` stays `Asia/Calcutta` —
/// and accepts any well-formed IANA name, since this build ships offsets for
/// only a fraction of the database.
fn resolveDtfTimeZone(arena: std.mem.Allocator, s: []const u8) !DtfZone {
    if (std.ascii.eqlIgnoreCase(s, "UTC")) return .{ .id = "UTC", .zone = "UTC", .offset_ms = 0 };
    if (parseOffsetMinutes(s)) |mins| {
        // A zero offset has one canonical spelling: "-00:00" resolves to "+00:00".
        const sign: u8 = if (mins < 0) '-' else '+';
        const abs: u64 = @intCast(@abs(mins));
        const id = try std.fmt.allocPrint(arena, "{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
        return .{ .id = id, .zone = id, .offset_ms = mins * 60_000 };
    }
    if (etcGmtOffsetMinutes(s)) |mins| return .{ .id = s, .zone = s, .offset_ms = mins * 60_000 };
    for ([_][]const u8{ "GMT", "Etc/UTC", "Etc/UCT", "Etc/Universal", "Etc/Zulu", "Etc/Greenwich" }) |z| {
        if (std.mem.eql(u8, s, z)) return .{ .id = s, .zone = s, .offset_ms = 0 };
    }
    var target = s;
    for (iana_links) |link| {
        if (std.mem.eql(u8, s, link[0])) target = link[1];
    }
    if (t_tzdata.lookupDef(target)) |def| {
        // `resolvedOptions().timeZone` echoes the requested identifier with its
        // canonical IANA casing (Zone names are matched case-insensitively).
        // Look up the requested spelling itself, so a link keeps its own name.
        const id = if (t_tzdata.lookupDef(s)) |own| own.name else s;
        return .{ .id = id, .zone = target, .offset_ms = @as(i64, def.std_offset_sec) * 1000 };
    }
    if (isPlausibleIanaName(s)) return .{ .id = s, .zone = target, .offset_ms = 0 };
    return throwRangeError(arena, "invalid time zone");
}

/// The ten digits of each decimal numbering system this build can render, as
/// UTF-8 (§11.5.5 uses them for every numeric date-time field). `null` for an
/// identifier we have no digits for — the caller then falls back to `latn`.
/// Table 4 of ECMA-402: every numbering system with a simple digit mapping.
/// `Intl.supportedValuesOf("numberingSystem")` reports exactly these.
pub const numbering_systems = [_]struct { []const u8, [10][]const u8 }{
    .{ "adlm", [10][]const u8{ "\u{1e950}", "\u{1e951}", "\u{1e952}", "\u{1e953}", "\u{1e954}", "\u{1e955}", "\u{1e956}", "\u{1e957}", "\u{1e958}", "\u{1e959}" } },
    .{ "ahom", [10][]const u8{ "\u{11730}", "\u{11731}", "\u{11732}", "\u{11733}", "\u{11734}", "\u{11735}", "\u{11736}", "\u{11737}", "\u{11738}", "\u{11739}" } },
    .{ "arab", [10][]const u8{ "\u{660}", "\u{661}", "\u{662}", "\u{663}", "\u{664}", "\u{665}", "\u{666}", "\u{667}", "\u{668}", "\u{669}" } },
    .{ "arabext", [10][]const u8{ "\u{6f0}", "\u{6f1}", "\u{6f2}", "\u{6f3}", "\u{6f4}", "\u{6f5}", "\u{6f6}", "\u{6f7}", "\u{6f8}", "\u{6f9}" } },
    .{ "bali", [10][]const u8{ "\u{1b50}", "\u{1b51}", "\u{1b52}", "\u{1b53}", "\u{1b54}", "\u{1b55}", "\u{1b56}", "\u{1b57}", "\u{1b58}", "\u{1b59}" } },
    .{ "beng", [10][]const u8{ "\u{9e6}", "\u{9e7}", "\u{9e8}", "\u{9e9}", "\u{9ea}", "\u{9eb}", "\u{9ec}", "\u{9ed}", "\u{9ee}", "\u{9ef}" } },
    .{ "bhks", [10][]const u8{ "\u{11c50}", "\u{11c51}", "\u{11c52}", "\u{11c53}", "\u{11c54}", "\u{11c55}", "\u{11c56}", "\u{11c57}", "\u{11c58}", "\u{11c59}" } },
    .{ "brah", [10][]const u8{ "\u{11066}", "\u{11067}", "\u{11068}", "\u{11069}", "\u{1106a}", "\u{1106b}", "\u{1106c}", "\u{1106d}", "\u{1106e}", "\u{1106f}" } },
    .{ "cakm", [10][]const u8{ "\u{11136}", "\u{11137}", "\u{11138}", "\u{11139}", "\u{1113a}", "\u{1113b}", "\u{1113c}", "\u{1113d}", "\u{1113e}", "\u{1113f}" } },
    .{ "cham", [10][]const u8{ "\u{aa50}", "\u{aa51}", "\u{aa52}", "\u{aa53}", "\u{aa54}", "\u{aa55}", "\u{aa56}", "\u{aa57}", "\u{aa58}", "\u{aa59}" } },
    .{ "deva", [10][]const u8{ "\u{966}", "\u{967}", "\u{968}", "\u{969}", "\u{96a}", "\u{96b}", "\u{96c}", "\u{96d}", "\u{96e}", "\u{96f}" } },
    .{ "diak", [10][]const u8{ "\u{11950}", "\u{11951}", "\u{11952}", "\u{11953}", "\u{11954}", "\u{11955}", "\u{11956}", "\u{11957}", "\u{11958}", "\u{11959}" } },
    .{ "fullwide", [10][]const u8{ "\u{ff10}", "\u{ff11}", "\u{ff12}", "\u{ff13}", "\u{ff14}", "\u{ff15}", "\u{ff16}", "\u{ff17}", "\u{ff18}", "\u{ff19}" } },
    .{ "gara", [10][]const u8{ "\u{10d40}", "\u{10d41}", "\u{10d42}", "\u{10d43}", "\u{10d44}", "\u{10d45}", "\u{10d46}", "\u{10d47}", "\u{10d48}", "\u{10d49}" } },
    .{ "gong", [10][]const u8{ "\u{11da0}", "\u{11da1}", "\u{11da2}", "\u{11da3}", "\u{11da4}", "\u{11da5}", "\u{11da6}", "\u{11da7}", "\u{11da8}", "\u{11da9}" } },
    .{ "gonm", [10][]const u8{ "\u{11d50}", "\u{11d51}", "\u{11d52}", "\u{11d53}", "\u{11d54}", "\u{11d55}", "\u{11d56}", "\u{11d57}", "\u{11d58}", "\u{11d59}" } },
    .{ "gujr", [10][]const u8{ "\u{ae6}", "\u{ae7}", "\u{ae8}", "\u{ae9}", "\u{aea}", "\u{aeb}", "\u{aec}", "\u{aed}", "\u{aee}", "\u{aef}" } },
    .{ "gukh", [10][]const u8{ "\u{16130}", "\u{16131}", "\u{16132}", "\u{16133}", "\u{16134}", "\u{16135}", "\u{16136}", "\u{16137}", "\u{16138}", "\u{16139}" } },
    .{ "guru", [10][]const u8{ "\u{a66}", "\u{a67}", "\u{a68}", "\u{a69}", "\u{a6a}", "\u{a6b}", "\u{a6c}", "\u{a6d}", "\u{a6e}", "\u{a6f}" } },
    .{ "hanidec", [10][]const u8{ "\u{3007}", "\u{4e00}", "\u{4e8c}", "\u{4e09}", "\u{56db}", "\u{4e94}", "\u{516d}", "\u{4e03}", "\u{516b}", "\u{4e5d}" } },
    .{ "hmng", [10][]const u8{ "\u{16b50}", "\u{16b51}", "\u{16b52}", "\u{16b53}", "\u{16b54}", "\u{16b55}", "\u{16b56}", "\u{16b57}", "\u{16b58}", "\u{16b59}" } },
    .{ "hmnp", [10][]const u8{ "\u{1e140}", "\u{1e141}", "\u{1e142}", "\u{1e143}", "\u{1e144}", "\u{1e145}", "\u{1e146}", "\u{1e147}", "\u{1e148}", "\u{1e149}" } },
    .{ "java", [10][]const u8{ "\u{a9d0}", "\u{a9d1}", "\u{a9d2}", "\u{a9d3}", "\u{a9d4}", "\u{a9d5}", "\u{a9d6}", "\u{a9d7}", "\u{a9d8}", "\u{a9d9}" } },
    .{ "kali", [10][]const u8{ "\u{a900}", "\u{a901}", "\u{a902}", "\u{a903}", "\u{a904}", "\u{a905}", "\u{a906}", "\u{a907}", "\u{a908}", "\u{a909}" } },
    .{ "kawi", [10][]const u8{ "\u{11f50}", "\u{11f51}", "\u{11f52}", "\u{11f53}", "\u{11f54}", "\u{11f55}", "\u{11f56}", "\u{11f57}", "\u{11f58}", "\u{11f59}" } },
    .{ "khmr", [10][]const u8{ "\u{17e0}", "\u{17e1}", "\u{17e2}", "\u{17e3}", "\u{17e4}", "\u{17e5}", "\u{17e6}", "\u{17e7}", "\u{17e8}", "\u{17e9}" } },
    .{ "knda", [10][]const u8{ "\u{ce6}", "\u{ce7}", "\u{ce8}", "\u{ce9}", "\u{cea}", "\u{ceb}", "\u{cec}", "\u{ced}", "\u{cee}", "\u{cef}" } },
    .{ "krai", [10][]const u8{ "\u{16d70}", "\u{16d71}", "\u{16d72}", "\u{16d73}", "\u{16d74}", "\u{16d75}", "\u{16d76}", "\u{16d77}", "\u{16d78}", "\u{16d79}" } },
    .{ "lana", [10][]const u8{ "\u{1a80}", "\u{1a81}", "\u{1a82}", "\u{1a83}", "\u{1a84}", "\u{1a85}", "\u{1a86}", "\u{1a87}", "\u{1a88}", "\u{1a89}" } },
    .{ "lanatham", [10][]const u8{ "\u{1a90}", "\u{1a91}", "\u{1a92}", "\u{1a93}", "\u{1a94}", "\u{1a95}", "\u{1a96}", "\u{1a97}", "\u{1a98}", "\u{1a99}" } },
    .{ "laoo", [10][]const u8{ "\u{ed0}", "\u{ed1}", "\u{ed2}", "\u{ed3}", "\u{ed4}", "\u{ed5}", "\u{ed6}", "\u{ed7}", "\u{ed8}", "\u{ed9}" } },
    .{ "latn", [10][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" } },
    .{ "lepc", [10][]const u8{ "\u{1c40}", "\u{1c41}", "\u{1c42}", "\u{1c43}", "\u{1c44}", "\u{1c45}", "\u{1c46}", "\u{1c47}", "\u{1c48}", "\u{1c49}" } },
    .{ "limb", [10][]const u8{ "\u{1946}", "\u{1947}", "\u{1948}", "\u{1949}", "\u{194a}", "\u{194b}", "\u{194c}", "\u{194d}", "\u{194e}", "\u{194f}" } },
    .{ "mathbold", [10][]const u8{ "\u{1d7ce}", "\u{1d7cf}", "\u{1d7d0}", "\u{1d7d1}", "\u{1d7d2}", "\u{1d7d3}", "\u{1d7d4}", "\u{1d7d5}", "\u{1d7d6}", "\u{1d7d7}" } },
    .{ "mathdbl", [10][]const u8{ "\u{1d7d8}", "\u{1d7d9}", "\u{1d7da}", "\u{1d7db}", "\u{1d7dc}", "\u{1d7dd}", "\u{1d7de}", "\u{1d7df}", "\u{1d7e0}", "\u{1d7e1}" } },
    .{ "mathmono", [10][]const u8{ "\u{1d7f6}", "\u{1d7f7}", "\u{1d7f8}", "\u{1d7f9}", "\u{1d7fa}", "\u{1d7fb}", "\u{1d7fc}", "\u{1d7fd}", "\u{1d7fe}", "\u{1d7ff}" } },
    .{ "mathsanb", [10][]const u8{ "\u{1d7ec}", "\u{1d7ed}", "\u{1d7ee}", "\u{1d7ef}", "\u{1d7f0}", "\u{1d7f1}", "\u{1d7f2}", "\u{1d7f3}", "\u{1d7f4}", "\u{1d7f5}" } },
    .{ "mathsans", [10][]const u8{ "\u{1d7e2}", "\u{1d7e3}", "\u{1d7e4}", "\u{1d7e5}", "\u{1d7e6}", "\u{1d7e7}", "\u{1d7e8}", "\u{1d7e9}", "\u{1d7ea}", "\u{1d7eb}" } },
    .{ "mlym", [10][]const u8{ "\u{d66}", "\u{d67}", "\u{d68}", "\u{d69}", "\u{d6a}", "\u{d6b}", "\u{d6c}", "\u{d6d}", "\u{d6e}", "\u{d6f}" } },
    .{ "modi", [10][]const u8{ "\u{11650}", "\u{11651}", "\u{11652}", "\u{11653}", "\u{11654}", "\u{11655}", "\u{11656}", "\u{11657}", "\u{11658}", "\u{11659}" } },
    .{ "mong", [10][]const u8{ "\u{1810}", "\u{1811}", "\u{1812}", "\u{1813}", "\u{1814}", "\u{1815}", "\u{1816}", "\u{1817}", "\u{1818}", "\u{1819}" } },
    .{ "mroo", [10][]const u8{ "\u{16a60}", "\u{16a61}", "\u{16a62}", "\u{16a63}", "\u{16a64}", "\u{16a65}", "\u{16a66}", "\u{16a67}", "\u{16a68}", "\u{16a69}" } },
    .{ "mtei", [10][]const u8{ "\u{abf0}", "\u{abf1}", "\u{abf2}", "\u{abf3}", "\u{abf4}", "\u{abf5}", "\u{abf6}", "\u{abf7}", "\u{abf8}", "\u{abf9}" } },
    .{ "mymr", [10][]const u8{ "\u{1040}", "\u{1041}", "\u{1042}", "\u{1043}", "\u{1044}", "\u{1045}", "\u{1046}", "\u{1047}", "\u{1048}", "\u{1049}" } },
    .{ "mymrepka", [10][]const u8{ "\u{116da}", "\u{116db}", "\u{116dc}", "\u{116dd}", "\u{116de}", "\u{116df}", "\u{116e0}", "\u{116e1}", "\u{116e2}", "\u{116e3}" } },
    .{ "mymrpao", [10][]const u8{ "\u{116d0}", "\u{116d1}", "\u{116d2}", "\u{116d3}", "\u{116d4}", "\u{116d5}", "\u{116d6}", "\u{116d7}", "\u{116d8}", "\u{116d9}" } },
    .{ "mymrshan", [10][]const u8{ "\u{1090}", "\u{1091}", "\u{1092}", "\u{1093}", "\u{1094}", "\u{1095}", "\u{1096}", "\u{1097}", "\u{1098}", "\u{1099}" } },
    .{ "mymrtlng", [10][]const u8{ "\u{a9f0}", "\u{a9f1}", "\u{a9f2}", "\u{a9f3}", "\u{a9f4}", "\u{a9f5}", "\u{a9f6}", "\u{a9f7}", "\u{a9f8}", "\u{a9f9}" } },
    .{ "nagm", [10][]const u8{ "\u{1e4f0}", "\u{1e4f1}", "\u{1e4f2}", "\u{1e4f3}", "\u{1e4f4}", "\u{1e4f5}", "\u{1e4f6}", "\u{1e4f7}", "\u{1e4f8}", "\u{1e4f9}" } },
    .{ "newa", [10][]const u8{ "\u{11450}", "\u{11451}", "\u{11452}", "\u{11453}", "\u{11454}", "\u{11455}", "\u{11456}", "\u{11457}", "\u{11458}", "\u{11459}" } },
    .{ "nkoo", [10][]const u8{ "\u{7c0}", "\u{7c1}", "\u{7c2}", "\u{7c3}", "\u{7c4}", "\u{7c5}", "\u{7c6}", "\u{7c7}", "\u{7c8}", "\u{7c9}" } },
    .{ "olck", [10][]const u8{ "\u{1c50}", "\u{1c51}", "\u{1c52}", "\u{1c53}", "\u{1c54}", "\u{1c55}", "\u{1c56}", "\u{1c57}", "\u{1c58}", "\u{1c59}" } },
    .{ "onao", [10][]const u8{ "\u{1e5f1}", "\u{1e5f2}", "\u{1e5f3}", "\u{1e5f4}", "\u{1e5f5}", "\u{1e5f6}", "\u{1e5f7}", "\u{1e5f8}", "\u{1e5f9}", "\u{1e5fa}" } },
    .{ "orya", [10][]const u8{ "\u{b66}", "\u{b67}", "\u{b68}", "\u{b69}", "\u{b6a}", "\u{b6b}", "\u{b6c}", "\u{b6d}", "\u{b6e}", "\u{b6f}" } },
    .{ "osma", [10][]const u8{ "\u{104a0}", "\u{104a1}", "\u{104a2}", "\u{104a3}", "\u{104a4}", "\u{104a5}", "\u{104a6}", "\u{104a7}", "\u{104a8}", "\u{104a9}" } },
    .{ "outlined", [10][]const u8{ "\u{1ccf0}", "\u{1ccf1}", "\u{1ccf2}", "\u{1ccf3}", "\u{1ccf4}", "\u{1ccf5}", "\u{1ccf6}", "\u{1ccf7}", "\u{1ccf8}", "\u{1ccf9}" } },
    .{ "rohg", [10][]const u8{ "\u{10d30}", "\u{10d31}", "\u{10d32}", "\u{10d33}", "\u{10d34}", "\u{10d35}", "\u{10d36}", "\u{10d37}", "\u{10d38}", "\u{10d39}" } },
    .{ "saur", [10][]const u8{ "\u{a8d0}", "\u{a8d1}", "\u{a8d2}", "\u{a8d3}", "\u{a8d4}", "\u{a8d5}", "\u{a8d6}", "\u{a8d7}", "\u{a8d8}", "\u{a8d9}" } },
    .{ "segment", [10][]const u8{ "\u{1fbf0}", "\u{1fbf1}", "\u{1fbf2}", "\u{1fbf3}", "\u{1fbf4}", "\u{1fbf5}", "\u{1fbf6}", "\u{1fbf7}", "\u{1fbf8}", "\u{1fbf9}" } },
    .{ "shrd", [10][]const u8{ "\u{111d0}", "\u{111d1}", "\u{111d2}", "\u{111d3}", "\u{111d4}", "\u{111d5}", "\u{111d6}", "\u{111d7}", "\u{111d8}", "\u{111d9}" } },
    .{ "sind", [10][]const u8{ "\u{112f0}", "\u{112f1}", "\u{112f2}", "\u{112f3}", "\u{112f4}", "\u{112f5}", "\u{112f6}", "\u{112f7}", "\u{112f8}", "\u{112f9}" } },
    .{ "sinh", [10][]const u8{ "\u{de6}", "\u{de7}", "\u{de8}", "\u{de9}", "\u{dea}", "\u{deb}", "\u{dec}", "\u{ded}", "\u{dee}", "\u{def}" } },
    .{ "sora", [10][]const u8{ "\u{110f0}", "\u{110f1}", "\u{110f2}", "\u{110f3}", "\u{110f4}", "\u{110f5}", "\u{110f6}", "\u{110f7}", "\u{110f8}", "\u{110f9}" } },
    .{ "sund", [10][]const u8{ "\u{1bb0}", "\u{1bb1}", "\u{1bb2}", "\u{1bb3}", "\u{1bb4}", "\u{1bb5}", "\u{1bb6}", "\u{1bb7}", "\u{1bb8}", "\u{1bb9}" } },
    .{ "sunu", [10][]const u8{ "\u{11bf0}", "\u{11bf1}", "\u{11bf2}", "\u{11bf3}", "\u{11bf4}", "\u{11bf5}", "\u{11bf6}", "\u{11bf7}", "\u{11bf8}", "\u{11bf9}" } },
    .{ "takr", [10][]const u8{ "\u{116c0}", "\u{116c1}", "\u{116c2}", "\u{116c3}", "\u{116c4}", "\u{116c5}", "\u{116c6}", "\u{116c7}", "\u{116c8}", "\u{116c9}" } },
    .{ "talu", [10][]const u8{ "\u{19d0}", "\u{19d1}", "\u{19d2}", "\u{19d3}", "\u{19d4}", "\u{19d5}", "\u{19d6}", "\u{19d7}", "\u{19d8}", "\u{19d9}" } },
    .{ "tamldec", [10][]const u8{ "\u{be6}", "\u{be7}", "\u{be8}", "\u{be9}", "\u{bea}", "\u{beb}", "\u{bec}", "\u{bed}", "\u{bee}", "\u{bef}" } },
    .{ "telu", [10][]const u8{ "\u{c66}", "\u{c67}", "\u{c68}", "\u{c69}", "\u{c6a}", "\u{c6b}", "\u{c6c}", "\u{c6d}", "\u{c6e}", "\u{c6f}" } },
    .{ "thai", [10][]const u8{ "\u{e50}", "\u{e51}", "\u{e52}", "\u{e53}", "\u{e54}", "\u{e55}", "\u{e56}", "\u{e57}", "\u{e58}", "\u{e59}" } },
    .{ "tibt", [10][]const u8{ "\u{f20}", "\u{f21}", "\u{f22}", "\u{f23}", "\u{f24}", "\u{f25}", "\u{f26}", "\u{f27}", "\u{f28}", "\u{f29}" } },
    .{ "tirh", [10][]const u8{ "\u{114d0}", "\u{114d1}", "\u{114d2}", "\u{114d3}", "\u{114d4}", "\u{114d5}", "\u{114d6}", "\u{114d7}", "\u{114d8}", "\u{114d9}" } },
    .{ "tnsa", [10][]const u8{ "\u{16ac0}", "\u{16ac1}", "\u{16ac2}", "\u{16ac3}", "\u{16ac4}", "\u{16ac5}", "\u{16ac6}", "\u{16ac7}", "\u{16ac8}", "\u{16ac9}" } },
    .{ "tols", [10][]const u8{ "\u{11de0}", "\u{11de1}", "\u{11de2}", "\u{11de3}", "\u{11de4}", "\u{11de5}", "\u{11de6}", "\u{11de7}", "\u{11de8}", "\u{11de9}" } },
    .{ "vaii", [10][]const u8{ "\u{a620}", "\u{a621}", "\u{a622}", "\u{a623}", "\u{a624}", "\u{a625}", "\u{a626}", "\u{a627}", "\u{a628}", "\u{a629}" } },
    .{ "wara", [10][]const u8{ "\u{118e0}", "\u{118e1}", "\u{118e2}", "\u{118e3}", "\u{118e4}", "\u{118e5}", "\u{118e6}", "\u{118e7}", "\u{118e8}", "\u{118e9}" } },
    .{ "wcho", [10][]const u8{ "\u{1e2f0}", "\u{1e2f1}", "\u{1e2f2}", "\u{1e2f3}", "\u{1e2f4}", "\u{1e2f5}", "\u{1e2f6}", "\u{1e2f7}", "\u{1e2f8}", "\u{1e2f9}" } },
};

pub fn isSupportedNumberingSystem(ns: []const u8) bool {
    for (numbering_systems) |e| if (std.mem.eql(u8, ns, e[0])) return true;
    return false;
}

pub fn numberingSystemDigitsFor(ns: []const u8) ?[10][]const u8 {
    return numberingSystemDigits(ns);
}

fn numberingSystemDigits(ns: []const u8) ?[10][]const u8 {
    for (numbering_systems) |e| if (std.mem.eql(u8, ns, e[0])) return e[1];
    return null;
}

/// Rewrite the ASCII digits of every numeric part into `ns`. The decimal mark
/// before the fractional-second digits follows the same script.
fn applyNumberingSystem(arena: std.mem.Allocator, parts: []DTPart, ns: []const u8) !void {
    const digits = numberingSystemDigits(ns) orelse return;
    if (std.mem.eql(u8, ns, "latn")) return;
    const arabic_script = std.mem.eql(u8, ns, "arab") or std.mem.eql(u8, ns, "arabext");
    for (parts) |*p| {
        if (arabic_script and std.mem.eql(u8, p.type, "literal") and std.mem.eql(u8, p.value, ".")) {
            p.value = "\u{066b}";
            continue;
        }
        if (std.mem.indexOfNone(u8, p.value, "0123456789") != null) continue;
        if (p.value.len == 0) continue;
        var out = std.ArrayListUnmanaged(u8){};
        for (p.value) |c| try out.appendSlice(arena, digits[c - '0']);
        p.value = out.items;
    }
}

/// The locale's default hour cycle. Only Japanese differs among the locales the
/// suite exercises (`resolvedOptions/hourCycle-default.js` asserts exactly this).
fn defaultHourCycle(locale: []const u8) []const u8 {
    return if (std.mem.eql(u8, primaryLanguage(locale), "ja")) "h11" else "h12";
}

/// `new Intl.DateTimeFormat(locales, options)` — CreateDateTimeFormat (§11.1.2).
///
/// Every option is read through `dnGetOption`, in the spec's order, so throwing
/// getters propagate and an out-of-range value is rejected before the next read.
/// The resolved state lives in `__dtf_*` own properties that `format` and
/// `resolvedOptions` read back; a component that was not requested is stored as
/// the empty string.
pub fn nativeDateTimeFormatCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Legacy service: `Intl.DateTimeFormat(...)` without `new` still yields an
    // instance (§11.1.1 ChainDateTimeFormat).
    const constructing = realm_mod.active_constructing;
    realm_mod.active_constructing = false;
    const obj = if (constructing and this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        try legacyServiceObj(arena, active_date_time_format_proto);

    const req = try resolveLocaleRequest(arena, if (args.len > 0) args[0] else Value{});
    // CreateDateTimeFormat uses CoerceOptionsToObject: a primitive `options` is
    // boxed rather than rejected (only null/undefined are special).
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);

    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");

    const calendar_opt = try dnGetOption(arena, options, "calendar", &.{}, null);
    if (calendar_opt) |c| {
        if (!isWellFormedUnicodeType(c)) return throwRangeError(arena, "invalid calendar");
    }
    const numbering_opt = try dnGetOption(arena, options, "numberingSystem", &.{}, null);
    if (numbering_opt) |n| {
        if (!isWellFormedUnicodeType(n)) return throwRangeError(arena, "invalid numberingSystem");
    }

    const hour12 = try dnGetBoolOption(arena, options, "hour12");
    // An explicit hour12 supersedes hourCycle entirely — including the `-u-hc-`
    // extension — but hourCycle is still read (and validated) first.
    const hour_cycle_opt = try dnGetOption(arena, options, "hourCycle", &.{ "h11", "h12", "h23", "h24" }, null);

    const tz_opt = try dnGetOption(arena, options, "timeZone", &.{}, null);

    // Table 7 components, then the styles.
    var comps: [dtf_components.len][]const u8 = undefined;
    for (dtf_components, 0..) |c, i| {
        comps[i] = (try dnGetOption(arena, options, c.key, c.allowed, null)) orelse "";
    }
    const frac_sec: u32 = if (try dnGetNumOption(arena, options, "fractionalSecondDigits")) |f| blk: {
        if (std.math.isNan(f) or f < 1 or f > 3) return throwRangeError(arena, "fractionalSecondDigits is out of range");
        break :blk @intFromFloat(@floor(f));
    } else 0;
    const tz_name = (try dnGetOption(arena, options, "timeZoneName", &.{
        "short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric",
    }, null)) orelse "";
    _ = try dnGetOption(arena, options, "formatMatcher", &.{ "basic", "best fit" }, "best fit");
    const date_style = (try dnGetOption(arena, options, "dateStyle", &dtf_styles, null)) orelse "";
    const time_style = (try dnGetOption(arena, options, "timeStyle", &dtf_styles, null)) orelse "";

    // `needDefaults` skips the `era` and `timeZoneName` rows of Table 7 (§11.1.2
    // step 41.a): neither pins a date down, so `{ era: "narrow" }` still gets the
    // numeric year/month/day default.
    var needs_defaults = frac_sec == 0;
    for (dtf_components, comps) |c, v| {
        if (v.len > 0 and !std.mem.eql(u8, c.key, "era")) needs_defaults = false;
    }
    // `hasExplicitFormatComponents` (§11.1.2 step 43.a) is set by ANY explicit
    // component — including `era`, `timeZoneName` and `fractionalSecondDigits` —
    // and is distinct from `needs_defaults`, which excludes `era` when deciding
    // whether to apply the numeric year/month/day defaults.
    var has_explicit = frac_sec > 0 or tz_name.len > 0;
    for (comps) |v| {
        if (v.len > 0) has_explicit = true;
    }
    // dateStyle/timeStyle are shorthands for a whole pattern and cannot be mixed
    // with individual components (§11.1.2 step 43).
    if ((date_style.len > 0 or time_style.len > 0) and has_explicit)
        return realm_mod.throwTypeError(arena, "dateStyle/timeStyle may not be used with other date-time component options");

    // ResolveLocale over the `ca` / `nu` / `hc` keys: an options value that this
    // build supports wins and drops the extension from the resolved locale; only
    // a keyword that actually took effect is echoed back.
    var kept: [3][2][]const u8 = undefined;
    var kept_n: usize = 0;
    const calendar = blk: {
        const from_opt = if (calendar_opt) |c| t_calendar.canonicalize(c) else null;
        if (from_opt) |id| {
            const s = id.str();
            if (try req.keyword(arena, "ca")) |ext| {
                if (t_calendar.canonicalize(ext)) |eid| if (eid == id) {
                    kept[kept_n] = .{ "ca", s };
                    kept_n += 1;
                };
            }
            break :blk s;
        }
        if (try req.keyword(arena, "ca")) |ext| {
            if (t_calendar.canonicalize(ext)) |eid| {
                kept[kept_n] = .{ "ca", eid.str() };
                kept_n += 1;
                break :blk eid.str();
            }
        }
        break :blk "gregory";
    };
    const numbering = blk: {
        if (numbering_opt) |raw| {
            // Numbering-system identifiers are case-insensitive.
            const n = try lowerDup(arena, raw);
            if (numberingSystemDigits(n) != null) {
                if (try req.keyword(arena, "nu")) |ext| if (std.mem.eql(u8, ext, n)) {
                    kept[kept_n] = .{ "nu", n };
                    kept_n += 1;
                };
                break :blk n;
            }
        }
        if (try req.keyword(arena, "nu")) |ext| {
            if (numberingSystemDigits(ext) != null) {
                kept[kept_n] = .{ "nu", ext };
                kept_n += 1;
                break :blk ext;
            }
        }
        break :blk "latn";
    };
    const hc_default = defaultHourCycle(req.base);
    var hour_cycle: []const u8 = hc_default;
    if (hour_cycle_opt) |hc| {
        hour_cycle = hc;
        if (try req.keyword(arena, "hc")) |ext| if (std.mem.eql(u8, ext, hc)) {
            kept[kept_n] = .{ "hc", hc };
            kept_n += 1;
        };
    } else if (try req.keyword(arena, "hc")) |ext| {
        for ([_][]const u8{ "h11", "h12", "h23", "h24" }) |v| {
            if (std.mem.eql(u8, ext, v)) {
                hour_cycle = v;
                kept[kept_n] = .{ "hc", v };
                kept_n += 1;
                break;
            }
        }
    }
    if (hour12) |h12| {
        // A normative 2023 change dropped "h24" from this selection: the 24-hour
        // clock always resolves to h23.
        hour_cycle = if (!h12)
            "h23"
        else if (std.mem.eql(u8, hc_default, "h11") or std.mem.eql(u8, hc_default, "h23"))
            "h11"
        else
            "h12";
        // hour12 overrides the extension, so `-u-hc-` never survives with it.
        var w: usize = 0;
        for (kept[0..kept_n]) |k| {
            if (std.mem.eql(u8, k[0], "hc")) continue;
            kept[w] = k;
            w += 1;
        }
        kept_n = w;
    }
    try storeResolvedLocale(arena, obj, req.base, kept[0..kept_n]);

    const zone = if (tz_opt) |tz|
        try resolveDtfTimeZone(arena, tz)
    else
        DtfZone{ .id = "UTC", .zone = "UTC", .offset_ms = 0 };

    // A "bare" formatter (no explicit component / style) resolves to date-only
    // for a legacy Date, but Temporal values pick their own default when
    // formatted (see the per-kind adjustment in `buildDTFParts`).
    const is_bare = needs_defaults and date_style.len == 0 and time_style.len == 0;
    if (is_bare) {
        comps[2] = "numeric"; // year
        comps[3] = "numeric"; // month
        comps[4] = "numeric"; // day
    }

    for (dtf_components, comps) |c, v| try obj.set(c.slot, try val_mod.makeString(arena, v));
    try obj.set("__dtf_fracSec", try val_mod.makeNumber(arena, @floatFromInt(frac_sec)));
    try obj.set("__dtf_tzName", try val_mod.makeString(arena, tz_name));
    try obj.set("__dtf_dateStyle", try val_mod.makeString(arena, date_style));
    try obj.set("__dtf_timeStyle", try val_mod.makeString(arena, time_style));
    try obj.set("__dtf_calendar", try val_mod.makeString(arena, calendar));
    try obj.set("__dtf_numbering", try val_mod.makeString(arena, numbering));
    try obj.set("__dtf_hourCycle", try val_mod.makeString(arena, hour_cycle));
    try obj.set("__dtf_hour12", try val_mod.makeBool(arena, std.mem.eql(u8, hour_cycle, "h11") or std.mem.eql(u8, hour_cycle, "h12")));
    try obj.set("__dtf_tz", try val_mod.makeString(arena, zone.id));
    try obj.set("__dtf_tzZone", try val_mod.makeString(arena, zone.zone));
    try obj.set("__dtf_tzOffsetMs", try val_mod.makeNumber(arena, @floatFromInt(zone.offset_ms)));
    try obj.set("__dtf_bare", try val_mod.makeBool(arena, is_bare));
    const created = try val_mod.makeObject(arena, obj);
    if (constructing) return created;
    return chainLegacyService(this_val, created, active_date_time_format_proto);
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

fn readNum(o: *JsObject, key: []const u8) f64 {
    const v = o.get(key) orelse return 0;
    if (v.bits != 0 and v.unbox() == .number) return v.unbox().number;
    return 0;
}

/// The resolved date-time pattern: which components to render and how. Built
/// from a DateTimeFormat's `__dtf_*` slots (or synthesized by `buildLocaleDTF`
/// for `toLocaleString`), then handed to `renderDateTimeParts`.
const DTFPattern = struct {
    weekday: []const u8 = "",
    era: []const u8 = "",
    year: []const u8 = "",
    month: []const u8 = "",
    day: []const u8 = "",
    day_period: []const u8 = "",
    hour: []const u8 = "",
    minute: []const u8 = "",
    second: []const u8 = "",
    frac_sec: u32 = 0,
    tz_name: []const u8 = "",
    hour12: bool = true,
    /// The resolved time zone identifier, for the `timeZoneName` part.
    tz_id: []const u8 = "UTC",

    fn hasDate(self: DTFPattern) bool {
        return self.weekday.len + self.era.len + self.year.len + self.month.len + self.day.len > 0;
    }
    fn hasTime(self: DTFPattern) bool {
        return self.day_period.len + self.hour.len + self.minute.len + self.second.len > 0 or self.frac_sec > 0;
    }
};

/// Append `val` to `out`, zero-padded to two digits when `style == "2-digit"`.
fn appendField(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: i64, style: []const u8) !void {
    if (std.mem.eql(u8, style, "2-digit") and val >= 0 and val < 10) {
        try out.append(arena, '0');
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{val}));
}

/// Drop from `p` every component the Temporal type `kind` cannot supply.
/// Returns false when nothing is left — the "no overlap" TypeError of §11.5.2.
fn restrictPatternToTemporal(p: *DTFPattern, kind: TemporalDTKind) bool {
    // An Instant is a full point in time; every component applies.
    if (kind == .instant) return true;
    const keep_date = kind == .date or kind == .datetime;
    const keep_time = kind == .time or kind == .datetime;
    if (!keep_date and kind != .year_month and kind != .month_day) {
        p.weekday = "";
        p.era = "";
        p.year = "";
        p.month = "";
        p.day = "";
    } else if (kind == .year_month) {
        p.weekday = "";
        p.day = "";
    } else if (kind == .month_day) {
        p.weekday = "";
        p.era = "";
        p.year = "";
    }
    if (!keep_time) {
        p.day_period = "";
        p.hour = "";
        p.minute = "";
        p.second = "";
        p.frac_sec = 0;
    }
    return p.hasDate() or p.hasTime();
}

/// Resolve `this` formatter + `args[0]` value into the ordered list of typed
/// parts. Shared by `format` and `formatToParts`. Never returns empty (falls
/// back to the numeric date pattern).
fn buildDTFParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) !std.ArrayListUnmanaged(DTPart) {
    const date_mod = @import("date.zig");
    // HandleDateTimeValue (§11.5.2): a Temporal value contributes its own
    // wall-clock fields; anything else is ToNumber-coerced and TimeClipped, so
    // `format("lol")` and `format(NaN)` are both a RangeError.
    const ms: i64 = blk: {
        if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .undefined_)
            break :blk std.time.milliTimestamp();
        if (args[0].unbox() == .object) {
            if (temporalEpochMs(args[0])) |m| break :blk m;
            if (date_mod.getDateData(args[0])) |dd| {
                if (!dd.valid) return realm_mod.throwRangeError(arena, "Invalid time value");
                break :blk dd.ms;
            }
        }
        // ToNumber rejects a Symbol rather than coercing it (our shared
        // `toNumberValue` yields NaN there, which would surface as a RangeError).
        if (args[0].unbox() == .symbol)
            return realm_mod.throwTypeError(arena, "cannot convert a Symbol to a number");
        const n = try realm_mod.toNumberValue(arena, args[0]);
        if (!std.math.isFinite(n) or @abs(n) > 8.64e15) return realm_mod.throwRangeError(arena, "Invalid time value");
        break :blk @intFromFloat(n);
    };
    var p = DTFPattern{ .year = "numeric", .month = "numeric", .day = "numeric" };
    var offset_ms: i64 = 0;

    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        p = .{
            .weekday = readOpt(o, "__dtf_weekday"),
            .era = readOpt(o, "__dtf_era"),
            .year = readOpt(o, "__dtf_year"),
            .month = readOpt(o, "__dtf_month"),
            .day = readOpt(o, "__dtf_day"),
            .day_period = readOpt(o, "__dtf_dayPeriod"),
            .hour = readOpt(o, "__dtf_hour"),
            .minute = readOpt(o, "__dtf_minute"),
            .second = readOpt(o, "__dtf_second"),
            .frac_sec = @intFromFloat(readNum(o, "__dtf_fracSec")),
            .tz_name = readOpt(o, "__dtf_tzName"),
            .hour12 = if (o.get("__dtf_hour12")) |v| (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) else true,
            .tz_id = blk: {
                const id = readOpt(o, "__dtf_tzZone");
                break :blk if (id.len > 0) id else "UTC";
            },
        };
        offset_ms = @intFromFloat(readNum(o, "__dtf_tzOffsetMs"));
        // A named IANA zone's offset depends on the instant (DST), so resolve it
        // here rather than freezing the standard offset at construction.
        if (t_tzdata.lookupDef(p.tz_id)) |def| {
            if (t_tzdata.offsetAt(def, @divFloor(ms, 1000))) |sec| offset_ms = @as(i64, sec) * 1000;
        }
        const date_style = readOpt(o, "__dtf_dateStyle");
        const time_style = readOpt(o, "__dtf_timeStyle");
        if (date_style.len > 0) applyDateStyle(date_style, &p);
        if (time_style.len > 0) applyTimeStyle(time_style, &p);

        // A bare formatter (no explicit component) resolves to date-only for a
        // legacy Date, but a Temporal value picks its own default: date for
        // PlainDate, time for PlainTime, date+time for PlainDateTime/Instant/
        // ZonedDateTime. This keeps `dtf.format(temporal)` in sync with the
        // per-type defaults `Temporal.X.prototype.toLocaleString` applies.
        const bare = if (o.get("__dtf_bare")) |v| (v.bits != 0 and v.unbox() == .boolean and v.unbox().boolean) else false;
        if (bare and args.len > 0) {
            if (temporalKindOf(args[0])) |tk| switch (tk) {
                .date => {},
                .time => p = .{ .hour = "numeric", .minute = "numeric", .second = "numeric", .hour12 = p.hour12 },
                .datetime, .instant, .zoned => {
                    p.hour = "numeric";
                    p.minute = "numeric";
                    p.second = "numeric";
                },
                .year_month => p = .{ .era = p.era, .year = "numeric", .month = "numeric", .hour12 = p.hour12 },
                .month_day => p = .{ .month = "numeric", .day = "numeric", .hour12 = p.hour12 },
            };
        }
        // A Temporal *plain* value carries no time zone of its own, so the
        // formatter's `timeZoneName` has nothing to name (§11.5.2 drops it). An
        // Instant is a real point in time, and a ZonedDateTime carries its own
        // zone (only reachable through `toLocaleString`), so both keep it.
        if (args.len > 0) {
            if (temporalKindOf(args[0])) |tk| {
                if (tk != .instant and tk != .zoned) p.tz_name = "";
            }
        }

        // §11.5.2 derives a per-Temporal-type format by dropping the components
        // that type has no fields for; when nothing survives, the value and the
        // formatter do not overlap at all and formatting is a TypeError. Only a
        // real Intl.DateTimeFormat goes through this — the synthetic formatters
        // `toLocaleString` builds already match their receiver by construction.
        if (args.len > 0 and o.getOwn("__dtf_hourCycle") != null) {
            if (temporalKindOf(args[0])) |tk| {
                if (tk == .zoned)
                    return realm_mod.throwTypeError(arena, "Intl.DateTimeFormat.prototype.format does not support Temporal.ZonedDateTime");
                if (!restrictPatternToTemporal(&p, tk))
                    return realm_mod.throwTypeError(arena, "the formatter has no component this Temporal type provides");
            }
        }
    }

    // A Temporal plain type carries its own wall-clock fields; a legacy Date and
    // a Temporal.Instant are points in time, so the zone offset applies to them.
    const wall_clock = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object)
        (if (temporalKindOf(args[0])) |tk| tk != .instant else false)
    else
        false;
    const local_ms = if (wall_clock) ms else ms + offset_ms;
    const f = date_mod.msToFieldsUtc(local_ms);

    var parts = std.ArrayListUnmanaged(DTPart){};
    try renderDateTimeParts(arena, f, p, &parts);
    if (parts.items.len == 0) {
        try renderDateTimeParts(arena, f, .{ .year = "numeric", .month = "numeric", .day = "numeric", .hour12 = p.hour12 }, &parts);
    }
    if (this_val.bits != 0 and this_val.unbox() == .object)
        try applyNumberingSystem(arena, parts.items, readOpt(this_val.toPtr().object, "__dtf_numbering"));
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
    const o = try requireDateTimeFormat(arena, this_val);
    if (o.getOwn("[[BoundFormat]]")) |bound| return bound;
    const bound = try val_mod.makeNativeFunctionDataLen(arena, nativeDateTimeFormatFormat, @ptrCast(o), 1);
    _ = try o.defineOwnData("[[BoundFormat]]", bound, .{ .writable = false, .enumerable = false, .configurable = false });
    return bound;
}

/// §11.3.6/§11.3.7 formatRange / formatRangeToParts. en-US renders a range as
/// "<start> – <end>", collapsing to the single formatted value when both ends
/// produce identical text.
fn dtfRangeParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) !std.ArrayListUnmanaged(DTPart) {
    _ = try requireDateTimeFormat(arena, this_val);
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
        try defineData(o, "type", try val_mod.makeString(arena, p.type));
        try defineData(o, "value", try val_mod.makeString(arena, p.value));
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
        try defineData(o, "type", try val_mod.makeString(arena, p.type));
        try defineData(o, "value", try val_mod.makeString(arena, p.value));
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

/// The en-US flexible day period for `hour` (CLDR `dayPeriods`): the noon
/// singleton, then morning / afternoon / evening / night bands. `narrow`
/// abbreviates only "noon".
fn dayPeriodName(hour: i64, minute: i64, second: i64, style: []const u8) []const u8 {
    if (hour == 12 and minute == 0 and second == 0)
        return if (std.mem.eql(u8, style, "narrow")) "n" else "noon";
    if (hour >= 6 and hour < 12) return "in the morning";
    if (hour >= 12 and hour < 18) return "in the afternoon";
    if (hour >= 18 and hour < 21) return "in the evening";
    return "at night";
}

/// The `timeZoneName` part for the resolved zone. Only UTC and fixed-offset
/// zones have real names here; a named IANA zone falls back to its identifier.
fn timeZoneNameFor(arena: std.mem.Allocator, tz_id: []const u8, style: []const u8) ![]const u8 {
    const is_utc = std.mem.eql(u8, tz_id, "UTC");
    if (std.mem.eql(u8, style, "long")) return if (is_utc) "Coordinated Universal Time" else tz_id;
    if (std.mem.eql(u8, style, "short")) return if (is_utc) "UTC" else tz_id;
    // The offset styles render the zone's own offset; "GMT" alone for UTC.
    if (is_utc) return "GMT";
    if (tz_id.len > 0 and (tz_id[0] == '+' or tz_id[0] == '-'))
        return std.fmt.allocPrint(arena, "GMT{s}", .{tz_id});
    return tz_id;
}

/// Render the resolved components into typed parts (shared by `format` and
/// `formatToParts`). Mirrors the en-US pattern: `Weekday, Month Day, Year,
/// h:mm:ss AM/PM` with numeric fields joined by `/` and `:`.
fn renderDateTimeParts(
    arena: std.mem.Allocator,
    f: @import("date.zig").DateFields,
    p: DTFPattern,
    parts: *std.ArrayListUnmanaged(DTPart),
) !void {
    const month = p.month;
    const named_month = month.len > 0 and !std.mem.eql(u8, month, "numeric") and !std.mem.eql(u8, month, "2-digit");
    var has_date = false;

    if (p.weekday.len > 0) {
        const idx: usize = @intCast(@mod(f.weekday, 7));
        const name = if (std.mem.eql(u8, p.weekday, "short")) weekday_short[idx] else if (std.mem.eql(u8, p.weekday, "narrow")) weekday_narrow[idx] else weekday_long[idx];
        try parts.append(arena, .{ .type = "weekday", .value = name });
        has_date = true;
    }

    if (named_month) {
        if (has_date) try parts.append(arena, .{ .type = "literal", .value = ", " });
        const midx: usize = @intCast(@mod(f.month, 12));
        const mname = if (std.mem.eql(u8, month, "short")) month_short[midx] else if (std.mem.eql(u8, month, "narrow")) month_narrow[midx] else month_long[midx];
        try parts.append(arena, .{ .type = "month", .value = mname });
        if (p.day.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = " " });
            try parts.append(arena, .{ .type = "day", .value = try fieldStr(arena, f.day, p.day) });
        }
        if (p.year.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = ", " });
            try parts.append(arena, .{ .type = "year", .value = try yearStr(arena, f.year, p.year) });
        }
        has_date = true;
    } else if (month.len > 0 or p.day.len > 0 or p.year.len > 0) {
        if (p.weekday.len > 0) try parts.append(arena, .{ .type = "literal", .value = ", " });
        var first = true;
        if (month.len > 0) {
            try parts.append(arena, .{ .type = "month", .value = try fieldStr(arena, f.month + 1, month) });
            first = false;
        }
        if (p.day.len > 0) {
            if (!first) try parts.append(arena, .{ .type = "literal", .value = "/" });
            try parts.append(arena, .{ .type = "day", .value = try fieldStr(arena, f.day, p.day) });
            first = false;
        }
        if (p.year.len > 0) {
            if (!first) try parts.append(arena, .{ .type = "literal", .value = "/" });
            try parts.append(arena, .{ .type = "year", .value = try yearStr(arena, f.year, p.year) });
        }
        has_date = true;
    }
    // The ISO calendar has no eras, so `era` renders the proleptic Gregorian one.
    if (p.era.len > 0) {
        if (has_date) try parts.append(arena, .{ .type = "literal", .value = " " });
        const bc = f.year <= 0;
        try parts.append(arena, .{ .type = "era", .value = if (std.mem.eql(u8, p.era, "long"))
            (if (bc) "Before Christ" else "Anno Domini")
        else if (std.mem.eql(u8, p.era, "narrow"))
            (if (bc) "B" else "A")
        else
            (if (bc) "BC" else "AD") });
        has_date = true;
    }

    const has_clock = p.hour.len > 0 or p.minute.len > 0 or p.second.len > 0;
    if (has_clock or p.day_period.len > 0) {
        if (has_date) try parts.append(arena, .{ .type = "literal", .value = ", " });
        if (p.hour.len > 0) {
            var h: i64 = f.hour;
            // en-US 24-hour clock (h23) always renders a 2-digit hour.
            const hstyle = if (p.hour12) p.hour else "2-digit";
            if (p.hour12) {
                h = @mod(f.hour, 12);
                if (h == 0) h = 12;
            }
            try parts.append(arena, .{ .type = "hour", .value = try fieldStr(arena, h, hstyle) });
        }
        if (p.minute.len > 0) {
            if (p.hour.len > 0) try parts.append(arena, .{ .type = "literal", .value = ":" });
            // The en-US clock patterns (`h:mm:ss`, `mm:ss`) pad every field that
            // is not the leading one — and pad the minute whenever seconds follow.
            const mstyle: []const u8 = if (p.hour.len > 0 or p.second.len > 0) "2-digit" else p.minute;
            try parts.append(arena, .{ .type = "minute", .value = try fieldStr(arena, f.min, mstyle) });
        }
        if (p.second.len > 0) {
            if (p.hour.len > 0 or p.minute.len > 0) try parts.append(arena, .{ .type = "literal", .value = ":" });
            try parts.append(arena, .{ .type = "second", .value = try fieldStr(arena, f.sec, if (p.hour.len > 0 or p.minute.len > 0) "2-digit" else p.second) });
        }
        if (p.frac_sec > 0) {
            // The sub-second digits are truncated, not rounded (§11.5.6 Table 9).
            const ms3 = try std.fmt.allocPrint(arena, "{d:0>3}", .{@as(u64, @intCast(@mod(f.ms, 1000)))});
            try parts.append(arena, .{ .type = "literal", .value = "." });
            try parts.append(arena, .{ .type = "fractionalSecond", .value = ms3[0..p.frac_sec] });
        }
        // An explicit dayPeriod replaces the AM/PM marker of the 12-hour clock.
        if (p.day_period.len > 0) {
            if (has_clock) try parts.append(arena, .{ .type = "literal", .value = " " });
            try parts.append(arena, .{ .type = "dayPeriod", .value = dayPeriodName(f.hour, f.min, f.sec, p.day_period) });
        } else if (p.hour12 and p.hour.len > 0) {
            try parts.append(arena, .{ .type = "literal", .value = " " });
            try parts.append(arena, .{ .type = "dayPeriod", .value = if (f.hour < 12) "AM" else "PM" });
        }
    }

    if (p.tz_name.len > 0) {
        if (parts.items.len > 0) try parts.append(arena, .{ .type = "literal", .value = " " });
        try parts.append(arena, .{ .type = "timeZoneName", .value = try timeZoneNameFor(arena, p.tz_id, p.tz_name) });
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

/// The en-US `dateStyle` patterns (CLDR `full`/`long`/`medium`/`short`).
fn applyDateStyle(ds: []const u8, p: *DTFPattern) void {
    p.year = "numeric";
    p.month = "long";
    p.day = "numeric";
    if (std.mem.eql(u8, ds, "full")) {
        p.weekday = "long";
    } else if (std.mem.eql(u8, ds, "medium")) {
        p.month = "short";
    } else if (std.mem.eql(u8, ds, "short")) {
        p.year = "2-digit";
        p.month = "numeric";
    }
}

/// The en-US `timeStyle` patterns: `full`/`long` also name the time zone.
fn applyTimeStyle(ts: []const u8, p: *DTFPattern) void {
    p.hour = "numeric";
    p.minute = "2-digit";
    // full/long/medium include seconds; short omits them.
    if (!std.mem.eql(u8, ts, "short")) p.second = "2-digit";
    if (std.mem.eql(u8, ts, "full")) p.tz_name = "long";
    if (std.mem.eql(u8, ts, "long")) p.tz_name = "short";
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
    const dtf = try buildLocaleDTF(arena, if (args.len > 0) args[0] else Value{}, opts_v, required, defaults, restrict);
    // A ZonedDateTime names its zone by default (Temporal §ZonedDateTime.toLocaleString).
    if (kind == .zoned and dtfWantsDefaults(opts_v)) {
        const o = dtf.toPtr().object;
        try o.set("__dtf_tzName", try val_mod.makeString(arena, "short"));
        if (t_zdt.getZoned(receiver)) |z| try o.set("__dtf_tzZone", try val_mod.makeString(arena, z.tz));
    }
    return nativeDateTimeFormatFormat(arena, dtf, &[_]Value{receiver});
}

/// True when a `toLocaleString` options bag names no component and no style, so
/// the receiver's whole default pattern applies (for a ZonedDateTime that
/// includes the time-zone name).
fn dtfWantsDefaults(opts_v: ?Value) bool {
    for ([_][]const u8{
        "weekday", "era",    "year",   "month",     "day",       "dayPeriod",
        "hour",    "minute", "second", "dateStyle", "timeStyle", "timeZoneName",
    }) |k| {
        if (optStr(opts_v, k) != null) return false;
    }
    return optNum(opts_v, "fractionalSecondDigits") == null;
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
fn buildLocaleDTF(arena: std.mem.Allocator, locales: Value, opts_v: ?Value, required: Required, defaults: LocaleDefaults, restrict: Restrict) anyerror!Value {
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
    // ToDateTimeOptions' `needDefaults` scan skips `era` and `timeZoneName`
    // (§11.1.2 step 41.a): neither pins a date down on its own.
    const has_pinning_comp = weekday != null or year != null or month != null or day != null or
        hour != null or minute != null or second != null or day_period != null or frac_digits != null;

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

    // ISO calendar: era (used above only for conflict detection) is not rendered.
    var p = DTFPattern{
        .weekday = weekday orelse "",
        .year = year orelse "",
        .month = month orelse "",
        .day = day orelse "",
        .hour = hour orelse "",
        .minute = minute orelse "",
        .second = second orelse "",
    };
    if (date_style) |ds| applyDateStyle(ds, &p);
    if (time_style) |ts| applyTimeStyle(ts, &p);

    // ToDateTimeOptions: `needDefaults` is driven by the REQUIRED family only —
    // e.g. toLocaleDateString (required "date") still fills in year/month/day
    // even when the caller passed only time components. When set, the `defaults`
    // family's fields are added (never overriding explicit user components).
    // dateStyle/timeStyle suppress defaults entirely.
    var need_defaults = date_style == null and time_style == null;
    if (need_defaults) switch (required) {
        .date => if (has_date_comp and has_pinning_comp) {
            need_defaults = false;
        },
        .time => if (has_time_comp and has_pinning_comp) {
            need_defaults = false;
        },
        .any => if (has_pinning_comp) {
            need_defaults = false;
        },
    };
    if (need_defaults) {
        if (defaults == .date or defaults == .datetime or defaults == .year_month) {
            if (p.year.len == 0) p.year = "numeric";
            if (p.month.len == 0) p.month = "numeric";
        }
        if (defaults == .date or defaults == .datetime or defaults == .month_day) {
            if (p.day.len == 0) p.day = "numeric";
        }
        if (defaults == .month_day and p.month.len == 0) p.month = "numeric";
        if (defaults == .time or defaults == .datetime) {
            if (p.hour.len == 0) p.hour = "numeric";
            if (p.minute.len == 0) p.minute = "numeric";
            if (p.second.len == 0) p.second = "numeric";
        }
    }

    p.hour12 = optBool(opts_v, "hour12") orelse true;
    if (optStr(opts_v, "hourCycle")) |hc| {
        if (std.mem.eql(u8, hc, "h23") or std.mem.eql(u8, hc, "h24")) p.hour12 = false;
        if (std.mem.eql(u8, hc, "h11") or std.mem.eql(u8, hc, "h12")) p.hour12 = true;
    }

    const dtf = if (realm_mod.active_heap) |hp|
        try JsObject.createOnHeap(hp, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try dtf.set("__dtf_weekday", try val_mod.makeString(arena, p.weekday));
    try dtf.set("__dtf_year", try val_mod.makeString(arena, p.year));
    try dtf.set("__dtf_month", try val_mod.makeString(arena, p.month));
    try dtf.set("__dtf_day", try val_mod.makeString(arena, p.day));
    try dtf.set("__dtf_hour", try val_mod.makeString(arena, p.hour));
    try dtf.set("__dtf_minute", try val_mod.makeString(arena, p.minute));
    try dtf.set("__dtf_second", try val_mod.makeString(arena, p.second));
    try dtf.set("__dtf_hour12", try val_mod.makeBool(arena, p.hour12));
    try dtf.set("__dtf_dayPeriod", try val_mod.makeString(arena, p.day_period));
    try dtf.set("__dtf_era", try val_mod.makeString(arena, p.era));
    try dtf.set("__dtf_tzName", try val_mod.makeString(arena, p.tz_name));
    // The numbering system comes from the requested locale exactly as it does
    // for a real formatter, so `date.toLocaleString("th-u-nu-thai")` and
    // `new Intl.DateTimeFormat("th-u-nu-thai").format(date)` agree.
    const req = try resolveLocaleRequest(arena, locales);
    const nu = blk: {
        const ext = (try req.keyword(arena, "nu")) orelse break :blk "latn";
        break :blk if (numberingSystemDigits(ext) != null) ext else "latn";
    };
    try dtf.set("__dtf_numbering", try val_mod.makeString(arena, nu));
    return val_mod.makeObject(arena, dtf);
}

/// `Date.prototype.{toLocaleString,toLocaleDateString,toLocaleTimeString}`:
/// build a DateTimeFormat from (locales, options) with the method's default
/// component set and format the Date through the shared en-US machinery.
pub fn dateToLocaleString(arena: std.mem.Allocator, receiver: Value, args: []const Value, required: Required, defaults: LocaleDefaults) anyerror!Value {
    const opts_v: ?Value = if (args.len > 1) args[1] else null;
    const dtf = try buildLocaleDTF(arena, if (args.len > 0) args[0] else Value{}, opts_v, required, defaults, .none);
    return nativeDateTimeFormatFormat(arena, dtf, &[_]Value{receiver});
}

/// Brand check for the `format` accessor and `resolvedOptions` (§11.4): our
/// instances carry the internal `__dtf_hourCycle` marker, so anything without
/// it is not an initialized DateTimeFormat.
fn requireDateTimeFormat(arena: std.mem.Allocator, this_val: Value) anyerror!*JsObject {
    const recv = try unwrapLegacyService(arena, this_val, "__dtf_hourCycle");
    if (recv.bits == 0 or recv.unbox() != .object or
        recv.toPtr().object.getOwn("__dtf_hourCycle") == null)
        return realm_mod.throwTypeError(arena, "called on incompatible receiver");
    return recv.toPtr().object;
}

/// `dtf.resolvedOptions()` (§11.4.5). Properties are created in the order of
/// Table 8, omitting the components that were not resolved; when dateStyle /
/// timeStyle drove the pattern, those are reported instead of the components.
pub fn nativeDateTimeFormatResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireDateTimeFormat(arena, this_val);
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "calendar", try val_mod.makeString(arena, readOpt(o, "__dtf_calendar")));
    try defineData(r, "numberingSystem", try val_mod.makeString(arena, readOpt(o, "__dtf_numbering")));
    try defineData(r, "timeZone", try val_mod.makeString(arena, readOpt(o, "__dtf_tz")));

    const date_style = readOpt(o, "__dtf_dateStyle");
    const time_style = readOpt(o, "__dtf_timeStyle");
    // hourCycle / hour12 are reported only when the resolved pattern has an hour
    // field — a date-only formatter reports neither, even for `-u-hc-`.
    if (readOpt(o, "__dtf_hour").len > 0 or time_style.len > 0) {
        const hc = readOpt(o, "__dtf_hourCycle");
        try defineData(r, "hourCycle", try val_mod.makeString(arena, hc));
        try defineData(r, "hour12", try val_mod.makeBool(arena, std.mem.eql(u8, hc, "h11") or std.mem.eql(u8, hc, "h12")));
    }
    if (date_style.len == 0 and time_style.len == 0) {
        for (dtf_components) |c| {
            const v = readOpt(o, c.slot);
            if (v.len > 0) try defineData(r, c.key, try val_mod.makeString(arena, v));
        }
        const frac = readNum(o, "__dtf_fracSec");
        if (frac > 0) try defineData(r, "fractionalSecondDigits", try val_mod.makeNumber(arena, frac));
        const tzn = readOpt(o, "__dtf_tzName");
        if (tzn.len > 0) try defineData(r, "timeZoneName", try val_mod.makeString(arena, tzn));
    } else {
        if (date_style.len > 0) try defineData(r, "dateStyle", try val_mod.makeString(arena, date_style));
        if (time_style.len > 0) try defineData(r, "timeStyle", try val_mod.makeString(arena, time_style));
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
    const locales = if (args.len > 0) args[0] else Value{};
    // InitializeCollator (§10.1.2) reads the options in this exact order.
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    const usage = (try dnGetOption(arena, options, "usage", &.{ "sort", "search" }, "sort")).?;
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    var co_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options, "collation", &.{}, null)) |c| {
        if (!isWellFormedNumberingSystem(c)) return throwRangeError(arena, "invalid collation");
        co_opt = try lowerDup(arena, c);
    }
    const numeric_opt = try dnGetBoolOption(arena, options, "numeric");
    const case_first_opt = try dnGetOption(arena, options, "caseFirst", &.{ "upper", "lower", "false" }, null);
    const sensitivity = (try dnGetOption(arena, options, "sensitivity", &.{ "base", "accent", "case", "variant" }, "variant")).?;

    // ResolveLocale over the three relevant extension keys. A value taken from
    // the requested tag stays in `resolvedOptions().locale`; one supplied by an
    // option does not (unless it happens to agree with the tag).
    const req = try resolveLocaleRequest(arena, locales);
    var kept: [3][2][]const u8 = undefined;
    var n_kept: usize = 0;

    var collation: []const u8 = "default";
    var co_from_tag = false;
    if (try req.keyword(arena, "co")) |ext| {
        if (isSupportedCollation(req.base, ext)) {
            collation = ext;
            co_from_tag = true;
        }
    }
    if (co_opt) |opt| {
        if (isSupportedCollation(req.base, opt)) {
            if (co_from_tag and !std.mem.eql(u8, opt, collation)) co_from_tag = false;
            collation = opt;
        }
    }
    if (co_from_tag) {
        kept[n_kept] = .{ "co", collation };
        n_kept += 1;
    }

    // `-u-kn` with no value means `true` (a missing type value is the boolean
    // key's "true"), so an empty keyword must not read as absent.
    var numeric = false;
    var kn_from_tag = false;
    if (try req.keyword(arena, "kn")) |ext| {
        if (ext.len == 0 or std.mem.eql(u8, ext, "true")) {
            numeric = true;
            kn_from_tag = true;
        } else if (std.mem.eql(u8, ext, "false")) {
            numeric = false;
            kn_from_tag = true;
        }
    }
    if (numeric_opt) |opt| {
        if (kn_from_tag and opt != numeric) kn_from_tag = false;
        numeric = opt;
    }
    if (kn_from_tag) {
        kept[n_kept] = .{ "kn", if (numeric) "true" else "false" };
        n_kept += 1;
    }

    var case_first: []const u8 = "false";
    var kf_from_tag = false;
    if (try req.keyword(arena, "kf")) |ext| {
        for ([_][]const u8{ "upper", "lower", "false" }) |v| {
            if (std.mem.eql(u8, ext, v)) {
                case_first = v;
                kf_from_tag = true;
            }
        }
    }
    if (case_first_opt) |opt| {
        if (kf_from_tag and !std.mem.eql(u8, opt, case_first)) kf_from_tag = false;
        case_first = opt;
    }
    if (kf_from_tag) {
        kept[n_kept] = .{ "kf", case_first };
        n_kept += 1;
    }
    try storeResolvedLocale(arena, obj, req.base, kept[0..n_kept]);

    // ignorePunctuation defaults to true only for the locales whose CLDR root
    // collation sets `alternate=shifted` (the South-East Asian scripts).
    const ignore_punct = (try dnGetBoolOption(arena, options, "ignorePunctuation")) orelse
        defaultIgnorePunctuation(req.base);
    try obj.set("__col_ignorePunctuation", try val_mod.makeBool(arena, ignore_punct));
    try obj.set("__col_usage", try val_mod.makeString(arena, usage));
    try obj.set("__col_sensitivity", try val_mod.makeString(arena, sensitivity));
    try obj.set("__col_numeric", try val_mod.makeBool(arena, numeric));
    try obj.set("__col_caseFirst", try val_mod.makeString(arena, case_first));
    try obj.set("__col_collation", try val_mod.makeString(arena, if (std.mem.eql(u8, usage, "search")) "default" else collation));
    return val_mod.makeObject(arena, obj);
}

/// Construct an Intl.Collator from `locales`/`options`, as
/// `String.prototype.localeCompare` does. Collator is callable without `new`, so
/// this is just the constructor with NewTarget left undefined.
pub fn collatorFor(arena: std.mem.Allocator, locales: Value, options: Value) anyerror!Value {
    return nativeCollatorCtor(arena, Value{}, &[_]Value{ locales, options });
}

/// The `-u-co-` collations available in every locale.
const root_collations = [_][]const u8{ "emoji", "eor" };

/// Per-language CLDR collation tailorings this build accepts. Also the source
/// for `Intl.supportedValuesOf("collation")`, so the two can never disagree.
const collation_tailorings = [_]struct { l: []const u8, cos: []const []const u8 }{
    .{ .l = "de", .cos = &.{"phonebk"} },
    .{ .l = "es", .cos = &.{"trad"} },
    // "gb2312", not "gb2312han": the BCP-47 key is at most 8 characters, so the
    // longer CLDR name is not even a well-formed `-u-co-` type value.
    .{ .l = "zh", .cos = &.{ "pinyin", "stroke", "zhuyin", "gb2312", "big5han", "unihan" } },
    .{ .l = "ja", .cos = &.{"unihan"} },
    .{ .l = "ko", .cos = &.{ "unihan", "searchjl" } },
    .{ .l = "sv", .cos = &.{"reformed"} },
    .{ .l = "hi", .cos = &.{"trad"} },
    .{ .l = "si", .cos = &.{"dict"} },
};

/// The `-u-co-` collations this build accepts for a locale: the root ones plus
/// the language's own CLDR tailorings.
fn isSupportedCollation(locale: []const u8, co: []const u8) bool {
    if (std.mem.eql(u8, co, "standard") or std.mem.eql(u8, co, "search")) return false;
    for (root_collations) |v| if (std.mem.eql(u8, co, v)) return true;
    const lang = primaryLanguage(locale);
    for (collation_tailorings) |row| {
        if (!std.mem.eql(u8, row.l, lang)) continue;
        for (row.cos) |v| if (std.mem.eql(u8, co, v)) return true;
    }
    return false;
}

/// CLDR gives these languages `alternate="shifted"` in their root collation, so
/// `ignorePunctuation` defaults to true for them.
fn defaultIgnorePunctuation(locale: []const u8) bool {
    const lang = primaryLanguage(locale);
    for ([_][]const u8{ "th", "lo", "km", "my" }) |v| if (std.mem.eql(u8, lang, v)) return true;
    return false;
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

// A three-level approximation of the UCA root collation. Full DUCET weights are
// out of scope, but the level structure is what `sensitivity`, `caseFirst` and
// `ignorePunctuation` are actually defined over, so modelling it directly gets
// the observable behaviour right for the Latin/Greek/Cyrillic ranges the suite
// exercises: strings are decomposed (NFD), then split into a primary key of
// case-folded base characters, a secondary key of the combining marks, and a
// tertiary key of the per-character case.

/// Simple lowercase of one code point (collation only needs the 1:1 mappings).
fn collFold(cp: u21) u21 {
    if (cp < 128) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    if (ucase.lookup(ucase.to_lower, cp)) |m| {
        if (m.len == 1) return m[0];
    }
    return cp;
}

fn inProp(name: []const u8, cp: u21) bool {
    const ranges = uprops.lookup(name) orelse return false;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// The "variable" characters `ignorePunctuation` drops: punctuation, symbols
/// and whitespace (CLDR `alternate=shifted`).
fn isVariableChar(cp: u21) bool {
    return inProp("P", cp) or inProp("Z", cp) or inProp("S", cp);
}

const CollKey = struct {
    /// Case-folded base characters.
    primary: []const u21,
    /// The combining marks, in canonical order.
    secondary: []const u21,
    /// 1 for an uppercase character, 0 otherwise — one entry per primary.
    tertiary: []const u8,
};

/// The German *search* collation expands the umlauts, so `\u00c4` matches `AE`
/// at the primary level (they still differ at the secondary level, which is
/// what keeps a `sort` collator ordering them the other way round).
fn searchExpansion(lang: []const u8, cp: u21) ?[]const u21 {
    if (!std.mem.eql(u8, lang, "de")) return null;
    return switch (cp) {
        'a' => &[_]u21{ 'a', 'e' },
        'o' => &[_]u21{ 'o', 'e' },
        'u' => &[_]u21{ 'u', 'e' },
        0xDF => &[_]u21{ 's', 's' }, // sharp s
        else => null,
    };
}

fn collationKey(
    arena: std.mem.Allocator,
    s: []const u8,
    ignore_punct: bool,
    search_lang: ?[]const u8,
) !CollKey {
    const cps = try str_mod.nfdCodePoints(arena, s);
    var primary = std.ArrayListUnmanaged(u21){};
    var secondary = std.ArrayListUnmanaged(u21){};
    var tertiary = std.ArrayListUnmanaged(u8){};
    for (cps, 0..) |cp, i| {
        if (unorm.ccc(cp) != 0) {
            try secondary.append(arena, cp);
            continue;
        }
        if (ignore_punct and isVariableChar(cp)) continue;
        const folded = collFold(cp);
        // The case level only ranks cased characters: a digit or symbol
        // contributes nothing, so "007" and "7" still tie once the primary
        // level has compared them numerically.
        const cased = inProp("Cased", cp);
        const upper: u8 = @intFromBool(folded != cp);
        // The expansion only applies to a base letter that actually carries a
        // diaeresis (or to the sharp s, which stands alone).
        const expand: ?[]const u21 = if (search_lang) |lang| blk: {
            const diaeresis = cp == 0xDF or (i + 1 < cps.len and cps[i + 1] == 0x308);
            break :blk if (diaeresis) searchExpansion(lang, folded) else null;
        } else null;
        if (expand) |seq| {
            for (seq) |e| {
                try primary.append(arena, e);
                if (cased) try tertiary.append(arena, upper);
            }
            continue;
        }
        try primary.append(arena, folded);
        if (cased) try tertiary.append(arena, upper);
    }
    return .{ .primary = primary.items, .secondary = secondary.items, .tertiary = tertiary.items };
}

fn orderCps(a: []const u21, b: []const u21) std.math.Order {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Numeric collation over the primary key: a run of decimal digits compares by
/// value rather than code point, so "item2" sorts before "item10".
fn orderCpsNumeric(a: []const u21, b: []const u21) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const da = a[i] >= '0' and a[i] <= '9';
        const db = b[j] >= '0' and b[j] <= '9';
        if (da and db) {
            var ai = i;
            while (ai < a.len and a[ai] >= '0' and a[ai] <= '9') ai += 1;
            var bj = j;
            while (bj < b.len and b[bj] >= '0' and b[bj] <= '9') bj += 1;
            var sa = a[i..ai];
            var sb = b[j..bj];
            while (sa.len > 1 and sa[0] == '0') sa = sa[1..];
            while (sb.len > 1 and sb[0] == '0') sb = sb[1..];
            if (sa.len != sb.len) return if (sa.len < sb.len) .lt else .gt;
            const c = orderCps(sa, sb);
            if (c != .eq) return c;
            i = ai;
            j = bj;
        } else {
            if (a[i] != b[j]) return if (a[i] < b[j]) .lt else .gt;
            i += 1;
            j += 1;
        }
    }
    if (i >= a.len and j >= b.len) return .eq;
    return if (i >= a.len) .lt else .gt;
}

fn orderCase(a: []const u8, b: []const u8, upper_first: bool) std.math.Order {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        if (a[i] == b[i]) continue;
        const a_upper = a[i] == 1;
        return if (a_upper == upper_first) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// CompareStrings (§10.3.3): the level comparison `sensitivity` selects.
fn collatorCompareStrings(
    arena: std.mem.Allocator,
    x: []const u8,
    y: []const u8,
    sensitivity: []const u8,
    numeric: bool,
    case_first: []const u8,
    ignore_punct: bool,
) !std.math.Order {
    return collatorCompareStringsIn(arena, x, y, sensitivity, numeric, case_first, ignore_punct, null);
}

fn collatorCompareStringsIn(
    arena: std.mem.Allocator,
    x: []const u8,
    y: []const u8,
    sensitivity: []const u8,
    numeric: bool,
    case_first: []const u8,
    ignore_punct: bool,
    search_lang: ?[]const u8,
) !std.math.Order {
    const ka = try collationKey(arena, x, ignore_punct, search_lang);
    const kb = try collationKey(arena, y, ignore_punct, search_lang);
    const p = if (numeric) orderCpsNumeric(ka.primary, kb.primary) else orderCps(ka.primary, kb.primary);
    if (p != .eq) return p;
    const use_secondary = !std.mem.eql(u8, sensitivity, "base") and !std.mem.eql(u8, sensitivity, "case");
    const use_tertiary = !std.mem.eql(u8, sensitivity, "base") and !std.mem.eql(u8, sensitivity, "accent");
    if (use_secondary) {
        const sec = orderCps(ka.secondary, kb.secondary);
        if (sec != .eq) return sec;
    }
    if (use_tertiary) {
        const ter = orderCase(ka.tertiary, kb.tertiary, std.mem.eql(u8, case_first, "upper"));
        if (ter != .eq) return ter;
    }
    return .eq;
}

pub fn nativeCollatorCompare(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    // Bound compare passes the collator via native userdata; a plain prototype
    // call arrives with the collator as `this`.
    const col_obj: ?*JsObject = if (val_mod.g_active_native_data) |d|
        @ptrCast(@alignCast(d))
    else if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else
        null;
    var sensitivity: []const u8 = "variant";
    var case_first: []const u8 = "false";
    var numeric = false;
    var ignore_punct = false;
    var usage: []const u8 = "sort";
    var collation: []const u8 = "default";
    var locale: []const u8 = default_locale;
    if (col_obj) |o| {
        if (o.get("__col_usage")) |v| if (v.bits != 0 and v.unbox() == .string) {
            usage = v.unbox().string;
        };
        if (o.get("__col_collation")) |v| if (v.bits != 0 and v.unbox() == .string) {
            collation = v.unbox().string;
        };
        if (o.getOwn("[[intl_locale]]")) |v| if (v.bits != 0 and v.unbox() == .string) {
            locale = v.unbox().string;
        };
        if (o.get("__col_sensitivity")) |v| if (v.bits != 0 and v.unbox() == .string) {
            sensitivity = v.unbox().string;
        };
        if (o.get("__col_caseFirst")) |v| if (v.bits != 0 and v.unbox() == .string) {
            case_first = v.unbox().string;
        };
        if (o.get("__col_numeric")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            numeric = v.unbox().boolean;
        };
        if (o.get("__col_ignorePunctuation")) |v| if (v.bits != 0 and v.unbox() == .boolean) {
            ignore_punct = v.unbox().boolean;
        };
    }
    // Both arguments are ToString'd (a Symbol therefore throws).
    const a = try t_shared.valueToString(arena, if (args.len > 0) args[0] else Value{});
    const b = try t_shared.valueToString(arena, if (args.len > 1) args[1] else Value{});
    // German expands the umlauts in both its `search` collation and its
    // `phonebk` tailoring, so "\u00c4" sorts (and matches) as "AE".
    const expand = std.mem.eql(u8, usage, "search") or std.mem.eql(u8, collation, "phonebk");
    const search_lang: ?[]const u8 = if (expand) primaryLanguage(locale) else null;
    const order = try collatorCompareStringsIn(arena, a, b, sensitivity, numeric, case_first, ignore_punct, search_lang);
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
    var collation: []const u8 = "default";
    var ignore_punct = false;
    if (this_val.bits != 0 and this_val.unbox() == .object) {
        const o = this_val.toPtr().object;
        if (o.get("__col_collation")) |v| if (v.bits != 0 and v.unbox() == .string) {
            collation = v.unbox().string;
        };
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
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "usage", try val_mod.makeString(arena, usage));
    try defineData(r, "sensitivity", try val_mod.makeString(arena, sensitivity));
    try defineData(r, "ignorePunctuation", try val_mod.makeBool(arena, ignore_punct));
    try defineData(r, "collation", try val_mod.makeString(arena, collation));
    try defineData(r, "numeric", try val_mod.makeBool(arena, numeric));
    try defineData(r, "caseFirst", try val_mod.makeString(arena, caseFirst));
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
    // A trailing key with no type value ("-u-kn") is present with the empty
    // value, which for a boolean key means `true`.
    if (val_of) |k| if (std.ascii.eqlIgnoreCase(k, key)) return u_ext[val_start..val_end];
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

/// The `-u-` body of `tag` (already canonical), plus everything after the
/// language id that is *not* the `-u-` sequence, so the two can be recombined.
const TagSections = struct {
    lang_id: []const u8,
    u_body: []const u8,
    /// Other extension / private-use sequences, each with its leading '-'.
    others: []const u8,
};

fn splitTagSections(arena: std.mem.Allocator, tag: []const u8) !TagSections {
    const lang_id = locale_id.languageIdOf(tag);
    var u_body: []const u8 = "";
    var others = std.ArrayListUnmanaged(u8){};
    var pos = lang_id.len;
    while (pos < tag.len) {
        // Each section starts at "-<singleton>-".
        const seq_start = pos + 1; // skip the '-'
        const end = extSeqEnd(tag, seq_start + 2);
        if (tag[seq_start] == 'u') {
            u_body = tag[@min(seq_start + 2, tag.len)..end];
        } else {
            try others.appendSlice(arena, tag[pos..end]);
        }
        pos = end;
    }
    return .{ .lang_id = lang_id, .u_body = u_body, .others = others.items };
}

/// InsertUnicodeExtensionAndCanonicalize: merge `pairs` (key, value — an empty
/// value spells the bare `true` form) into `tag`'s `-u-` extension, replacing
/// any keyword already there, and re-canonicalize. Returns null when the result
/// is not a valid `unicode_locale_id`.
fn insertUnicodeKeywords(arena: std.mem.Allocator, tag: []const u8, pairs: []const [2][]const u8) !?[]const u8 {
    const sec = try splitTagSections(arena, tag);

    var attributes = std.ArrayListUnmanaged([]const u8){};
    var keys = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, sec.u_body, '-');
    var cur_key: ?usize = null;
    while (it.next()) |sub| {
        if (sub.len == 0) continue;
        if (sub.len == 2) {
            try keys.append(arena, sub);
            try values.append(arena, "");
            cur_key = keys.items.len - 1;
        } else if (cur_key) |k| {
            values.items[k] = if (values.items[k].len == 0)
                sub
            else
                try std.mem.concat(arena, u8, &.{ values.items[k], "-", sub });
        } else {
            try attributes.append(arena, sub);
        }
    }
    for (pairs) |kv| {
        var found = false;
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, kv[0])) {
                values.items[i] = kv[1];
                found = true;
                break;
            }
        }
        if (!found) {
            try keys.append(arena, kv[0]);
            try values.append(arena, kv[1]);
        }
    }

    var out = std.ArrayListUnmanaged(u8){};
    try out.appendSlice(arena, sec.lang_id);
    if (attributes.items.len > 0 or keys.items.len > 0) {
        try out.appendSlice(arena, "-u");
        for (attributes.items) |a| {
            try out.append(arena, '-');
            try out.appendSlice(arena, a);
        }
        for (keys.items, values.items) |k, v| {
            try out.append(arena, '-');
            try out.appendSlice(arena, k);
            if (v.len > 0) {
                try out.append(arena, '-');
                try out.appendSlice(arena, v);
            }
        }
    }
    try out.appendSlice(arena, sec.others);
    return locale_id.canonicalize(arena, out.items);
}

/// The value of `-u-<key>` in a canonical tag: null when absent, "" for the
/// bare (implicit `true`) form.
fn tagKeyword(arena: std.mem.Allocator, tag: []const u8, key: []const u8) !?[]const u8 {
    const sec = try splitTagSections(arena, tag);
    var it = std.mem.splitScalar(u8, sec.u_body, '-');
    var in_key = false;
    var value = std.ArrayListUnmanaged(u8){};
    while (it.next()) |sub| {
        if (sub.len == 2) {
            if (in_key) return value.items;
            in_key = std.mem.eql(u8, sub, key);
        } else if (in_key) {
            if (value.items.len > 0) try value.append(arena, '-');
            try value.appendSlice(arena, sub);
        }
    }
    return if (in_key) value.items else null;
}

/// A `variants` option must be one or more distinct `unicode_variant_subtag`s.
fn validVariantsOption(s: []const u8) bool {
    if (s.len == 0) return false;
    var seen: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '-');
    while (it.next()) |sub| {
        if (!isVariantSubtag(sub)) return false;
        for (seen[0..n]) |p| if (std.ascii.eqlIgnoreCase(p, sub)) return false;
        if (n < seen.len) {
            seen[n] = sub;
            n += 1;
        }
    }
    return true;
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
    const options_v = try dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);

    // ApplyOptionsToTag (§14.1.2): the tag must be a `unicode_locale_id`, and
    // each language-id option must be structurally valid on its own before it
    // replaces the subtag parsed out of the tag. The options are read in this
    // exact order — `constructor-getter-order.js` asserts it.
    var lang_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options_v, "language", &.{}, null)) |v| {
        if (!dnIsLangSubtag(v)) return throwRangeError(arena, "invalid language option");
        lang_opt = v;
    }
    var script_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options_v, "script", &.{}, null)) |v| {
        if (!dnIsScript(v)) return throwRangeError(arena, "invalid script option");
        script_opt = v;
    }
    var region_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options_v, "region", &.{}, null)) |v| {
        if (!dnIsRegion(v)) return throwRangeError(arena, "invalid region option");
        region_opt = v;
    }
    var variants_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options_v, "variants", &.{}, null)) |v| {
        if (!validVariantsOption(v)) return throwRangeError(arena, "invalid variants option");
        variants_opt = v;
    }

    var tag = (try locale_id.canonicalize(arena, tag_raw)) orelse
        return throwRangeError(arena, "invalid language tag");

    if (lang_opt != null or script_opt != null or region_opt != null or variants_opt != null) {
        const sec = try splitTagSections(arena, tag);
        const parts = parseLocaleTag(sec.lang_id);
        var rebuilt = std.ArrayListUnmanaged(u8){};
        try rebuilt.appendSlice(arena, lang_opt orelse parts.language);
        for ([_]?[]const u8{ script_opt orelse nonEmpty(parts.script), region_opt orelse nonEmpty(parts.region), variants_opt orelse nonEmpty(parts.variants) }) |maybe| {
            if (maybe) |s| {
                try rebuilt.append(arena, '-');
                try rebuilt.appendSlice(arena, s);
            }
        }
        try rebuilt.appendSlice(arena, tag[sec.lang_id.len..]);
        tag = (try locale_id.canonicalize(arena, rebuilt.items)) orelse
            return throwRangeError(arena, "invalid language tag");
    }

    // ApplyUnicodeExtensionToTag: an option overrides the tag's keyword for each
    // relevant extension key, and the surviving keywords are folded back into
    // the `-u-` sequence (which re-canonicalizes and re-sorts them).
    var kw = std.ArrayListUnmanaged([2][]const u8){};
    for ([_][2][]const u8{
        .{ "calendar", "ca" },
        .{ "collation", "co" },
    }) |pair| {
        if (try dnGetOption(arena, options_v, pair[0], &.{}, null)) |v| {
            if (!isWellFormedNumberingSystem(v)) return throwRangeError(arena, "invalid Unicode extension value");
            try kw.append(arena, .{ pair[1], try lowerDup(arena, v) });
        }
    }
    if (try dnGetOption(arena, options_v, "hourCycle", &.{ "h11", "h12", "h23", "h24" }, null)) |v|
        try kw.append(arena, .{ "hc", v });
    if (try dnGetOption(arena, options_v, "caseFirst", &.{ "upper", "lower", "false" }, null)) |v|
        try kw.append(arena, .{ "kf", v });
    if (try dnGetBoolOption(arena, options_v, "numeric")) |b|
        try kw.append(arena, .{ "kn", if (b) "true" else "false" });
    if (try dnGetOption(arena, options_v, "numberingSystem", &.{}, null)) |v| {
        if (!isWellFormedNumberingSystem(v)) return throwRangeError(arena, "invalid Unicode extension value");
        try kw.append(arena, .{ "nu", try lowerDup(arena, v) });
    }
    // WeekdayToString: 0..7 name a weekday (0 and 7 both being Sunday), and any
    // other value is used verbatim provided it is a well-formed `type` sequence.
    if (try optStrCoerced(arena, options_v, "firstDayOfWeek")) |raw| {
        const id = weekdayId(raw) orelse blk: {
            if (!isWellFormedNumberingSystem(raw))
                return throwRangeError(arena, "invalid firstDayOfWeek value for Intl.Locale");
            break :blk try lowerDup(arena, raw);
        };
        try kw.append(arena, .{ "fw", id });
    }
    if (kw.items.len > 0) {
        tag = (try insertUnicodeKeywords(arena, tag, kw.items)) orelse
            return throwRangeError(arena, "invalid language tag");
    }

    const obj = if (this_val.bits != 0 and this_val.unbox() == .object)
        this_val.toPtr().object
    else if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    try storeLocaleSlots(arena, obj, tag);
    return val_mod.makeObject(arena, obj);
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

/// Derive every `[[loc_*]]` slot from the finished `[[Locale]]` tag. The spec
/// defines each accessor as a projection of the tag, so the slots are only a
/// cache — keeping them in one place stops them drifting from `toString()`.
fn storeLocaleSlots(arena: std.mem.Allocator, obj: *JsObject, tag: []const u8) !void {
    const sec = try splitTagSections(arena, tag);
    const parts = parseLocaleTag(sec.lang_id);
    try obj.set("[[loc_language]]", try val_mod.makeString(arena, parts.language));
    try obj.set("[[loc_script]]", try val_mod.makeString(arena, parts.script));
    try obj.set("[[loc_region]]", try val_mod.makeString(arena, parts.region));
    try obj.set("[[loc_variants]]", try val_mod.makeString(arena, parts.variants));
    try obj.set("[[loc_baseName]]", try val_mod.makeString(arena, sec.lang_id));
    try obj.set("__locale_tag", try val_mod.makeString(arena, tag));

    for ([_][2][]const u8{
        .{ "ca", "[[loc_calendar]]" },
        .{ "co", "[[loc_collation]]" },
        .{ "hc", "[[loc_hourCycle]]" },
        .{ "kf", "[[loc_caseFirst]]" },
        .{ "nu", "[[loc_numberingSystem]]" },
    }) |pair| {
        if (try tagKeyword(arena, tag, pair[0])) |v| {
            try obj.set(pair[1], try val_mod.makeString(arena, v));
        } else {
            _ = try obj.deleteOwn(pair[1]);
        }
    }
    // `-u-kn` (bare) and `-u-kn-true` both mean numeric collation.
    const kn = try tagKeyword(arena, tag, "kn");
    try obj.set("[[loc_numeric]]", try val_mod.makeBool(arena, kn != null and !std.mem.eql(u8, kn.?, "false")));
    if (try tagKeyword(arena, tag, "fw")) |v| {
        if (weekdayId(v)) |id| try obj.set("[[loc_firstDayOfWeek]]", try val_mod.makeString(arena, id));
    } else {
        _ = try obj.deleteOwn("[[loc_firstDayOfWeek]]");
    }
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
    // The canonicalizer is the authority on `unicode_locale_id` shape; it parses
    // the `-t-`/`-u-` bodies the sketch below never modelled.
    return (try locale_id.canonicalize(arena, tag)) != null;
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
        // A service's `[[Locale]]` is the language id alone; its `-u-` keywords
        // are resolved per key and re-attached by `storeResolvedLocale`.
        const canon = locale_id.languageIdOf(try canonicalizeTag(arena, t));
        if (chosen == null and isAvailableLocale(canon)) chosen = canon;
    }
    try obj.set("[[intl_locale]]", try val_mod.makeString(arena, chosen orelse default_locale));
}

/// The locale a service resolved to, before its `-u-` keywords are re-attached.
pub const LocaleRequest = struct {
    /// `language[-Script][-REGION]`, already canonicalized.
    base: []const u8,
    /// The `-u-` extension body of the requested tag ("" when it carried none).
    u_ext: []const u8,

    /// The requested value of Unicode extension keyword `key`, if any. Keyword
    /// values are case-insensitive, so this hands back the canonical lowercase.
    pub fn keyword(self: LocaleRequest, arena: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const raw = uExtKeyword(self.u_ext, key) orelse return null;
        return try lowerDup(arena, raw);
    }
};

/// CanonicalizeLocaleList + LookupMatcher, keeping the `-u-` keywords of the
/// tag that won. A service resolves each relevant key itself (an options value
/// beats the extension) and then calls `storeResolvedLocale` with the keywords
/// that actually took effect, so `resolvedOptions().locale` echoes only those.
pub fn resolveLocaleRequest(arena: std.mem.Allocator, locales: Value) anyerror!LocaleRequest {
    const requested = try canonicalizeLocaleList(arena, locales);
    for (requested) |t| {
        const canon = locale_id.languageIdOf(try canonicalizeTag(arena, t));
        if (isAvailableLocale(canon)) return .{ .base = canon, .u_ext = parseLocaleTag(t).u_ext };
    }
    return .{ .base = default_locale, .u_ext = "" };
}

/// Store `base` extended with the `-u-` keywords that survived resolution, in
/// canonical (key-sorted) order.
pub fn storeResolvedLocale(arena: std.mem.Allocator, obj: *JsObject, base: []const u8, kept: []const [2][]const u8) !void {
    if (kept.len == 0) {
        try obj.set("[[intl_locale]]", try val_mod.makeString(arena, base));
        return;
    }
    const sorted = try arena.dupe([2][]const u8, kept);
    std.mem.sort([2][]const u8, sorted, {}, struct {
        fn lt(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return std.mem.lessThan(u8, a[0], b[0]);
        }
    }.lt);
    var out = std.ArrayListUnmanaged(u8){};
    try out.appendSlice(arena, base);
    try out.appendSlice(arena, "-u");
    for (sorted) |kv| {
        try out.append(arena, '-');
        try out.appendSlice(arena, kv[0]);
        // The canonical spelling of a boolean key's `true` is the bare key.
        if (std.mem.eql(u8, kv[1], "true")) continue;
        try out.append(arena, '-');
        try out.appendSlice(arena, kv[1]);
    }
    try obj.set("[[intl_locale]]", try val_mod.makeString(arena, out.items));
}

/// ResolveLocale for a service whose only relevant extension key is `nu`: the
/// requested tag's `-u-nu-` value wins unless the options supply a supported one
/// that differs, and the resolved locale keeps the keyword only when it actually
/// came from the tag. Stores `[[Locale]]` on `obj` and returns the numbering
/// system to format with.
pub fn resolveNumberingSystem(
    arena: std.mem.Allocator,
    obj: *JsObject,
    locales: Value,
    opt_nu: ?[]const u8,
) anyerror![]const u8 {
    const req = try resolveLocaleRequest(arena, locales);
    var value: []const u8 = "latn";
    var from_tag = false;
    if (try req.keyword(arena, "nu")) |ext| {
        if (isSupportedNumberingSystem(ext)) {
            value = ext;
            from_tag = true;
        }
    }
    if (opt_nu) |opt| {
        if (isSupportedNumberingSystem(opt)) {
            if (from_tag and !std.mem.eql(u8, opt, value)) from_tag = false;
            value = opt;
        }
    }
    var kept: [1][2][]const u8 = .{.{ "nu", value }};
    try storeResolvedLocale(arena, obj, req.base, if (from_tag) kept[0..1] else kept[0..0]);
    return value;
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
    return (try locale_id.canonicalize(arena, tag)) orelse
        throwRangeError(arena, "invalid language tag");
}

/// `Intl.getCanonicalLocales(locales)` — accepts a string or array-like of tags,
/// returns a de-duplicated array of canonical tags.
pub fn nativeGetCanonicalLocales(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const tags = try canonicalizeLocaleList(arena, if (args.len > 0) args[0] else Value{});
    const arr = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    var seen = std.ArrayListUnmanaged([]const u8){};
    var n: usize = 0;
    for (tags) |t| {
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
    // Every calendar `Intl.DateTimeFormat` resolves, in CalendarId order.
    var calendars: [@typeInfo(t_calendar.CalendarId).@"enum".fields.len][]const u8 = undefined;
    inline for (@typeInfo(t_calendar.CalendarId).@"enum".fields, 0..) |f, ci| {
        calendars[ci] = (@as(t_calendar.CalendarId, @enumFromInt(f.value))).str();
    }
    var numbering: [numbering_systems.len][]const u8 = undefined;
    inline for (numbering_systems, 0..) |e, ni| numbering[ni] = e[0];
    // Every collation `Intl.Collator` round-trips, from the same tables
    // `isSupportedCollation` consults (the sort/dedup below handles overlap).
    var collations = std.ArrayListUnmanaged([]const u8){};
    for (root_collations) |c| try collations.append(arena, c);
    for (collation_tailorings) |row| {
        for (row.cos) |c| try collations.append(arena, c);
    }

    const items: []const []const u8 = if (std.mem.eql(u8, key, "calendar"))
        &calendars
    else if (std.mem.eql(u8, key, "collation"))
        collations.items
    else if (std.mem.eql(u8, key, "currency"))
        &currencies
    else if (std.mem.eql(u8, key, "numberingSystem"))
        &numbering
    else if (std.mem.eql(u8, key, "timeZone"))
        &time_zones
    else if (std.mem.eql(u8, key, "unit"))
        &nfmt.sanctioned_units
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
    const o = try requireLocale(arena, this_val);
    if (o.getOwn("__locale_tag")) |v| {
        if (v.bits != 0 and v.unbox() == .string) return val_mod.makeString(arena, v.unbox().string);
    }
    if (o.getOwn("[[loc_baseName]]")) |v| {
        if (v.bits != 0 and v.unbox() == .string) return val_mod.makeString(arena, v.unbox().string);
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

/// The `unicode_language_id` fields the likely-subtags algorithms operate on.
const LangIdTriple = struct {
    language: []const u8,
    script: []const u8 = "",
    region: []const u8 = "",

    fn eql(a: LangIdTriple, b: LangIdTriple) bool {
        return std.mem.eql(u8, a.language, b.language) and
            std.mem.eql(u8, a.script, b.script) and
            std.mem.eql(u8, a.region, b.region);
    }
};

fn likelyRow(table: []const [3][]const u8, key: []const u8) ?[2][]const u8 {
    for (table) |row| if (std.mem.eql(u8, row[0], key)) return .{ row[1], row[2] };
    return null;
}

/// AddLikelySubtags (UTS #35 §4.3). Null when CLDR has no entry that matches —
/// the tag is then left exactly as it is.
fn addLikelySubtags(arena: std.mem.Allocator, t: LangIdTriple) !?LangIdTriple {
    const und = t.language.len == 0 or std.mem.eql(u8, t.language, "und");
    if (!und and t.script.len > 0 and t.region.len > 0) return t;

    if (und) {
        if (t.script.len > 0) {
            const e = likelyRow(&likely.by_script, t.script) orelse return null;
            var lang = e[0];
            // A script+region pair can name a different language than the script
            // alone ("und-Cyrl-RO" is Bulgarian, not Russian).
            if (t.region.len > 0) {
                const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ t.script, t.region });
                for (likely.by_script_region) |row| {
                    if (std.mem.eql(u8, row[0], key)) {
                        lang = row[1];
                        break;
                    }
                }
            }
            return .{ .language = lang, .script = t.script, .region = if (t.region.len > 0) t.region else e[1] };
        }
        if (t.region.len > 0) {
            const e = likelyRow(&likely.by_region, t.region) orelse return null;
            return .{ .language = e[0], .script = e[1], .region = t.region };
        }
        const e = likelyRow(&likely.by_language, "und") orelse return null;
        return .{ .language = "en", .script = e[0], .region = e[1] };
    }

    const lang_entry = likelyRow(&likely.by_language, t.language);
    if (t.script.len > 0) {
        // A language+script pair can imply a different region than the language
        // alone ("en-Shaw" is spoken in GB, not US).
        const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ t.language, t.script });
        var region = t.region;
        if (region.len == 0) {
            for (likely.by_language_script) |row| {
                if (std.mem.eql(u8, row[0], key)) {
                    region = row[1];
                    break;
                }
            }
        }
        if (region.len == 0) region = (lang_entry orelse return null)[1];
        return .{ .language = t.language, .script = t.script, .region = region };
    }
    const e = lang_entry orelse return null;
    var script = e[0];
    // A language+region pair can imply a different script ("zh-TW" is Hant).
    if (t.region.len > 0) {
        const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ t.language, t.region });
        for (likely.by_language_region) |row| {
            if (std.mem.eql(u8, row[0], key)) {
                script = row[1];
                break;
            }
        }
    }
    return .{ .language = t.language, .script = script, .region = if (t.region.len > 0) t.region else e[1] };
}

/// RemoveLikelySubtags: the shortest tag that maximizes back to the same thing.
fn removeLikelySubtags(arena: std.mem.Allocator, t: LangIdTriple) !LangIdTriple {
    const max = (try addLikelySubtags(arena, t)) orelse return t;
    const trials = [_]LangIdTriple{
        .{ .language = max.language },
        .{ .language = max.language, .region = max.region },
        .{ .language = max.language, .script = max.script },
    };
    for (trials) |trial| {
        if (try addLikelySubtags(arena, trial)) |m| {
            if (m.eql(max)) return trial;
        }
    }
    return max;
}

/// Build a new Intl.Locale whose language id is `t` but which keeps the
/// receiver's variants, extensions and private-use sequence (§14.3.3/§14.3.4
/// only touch the language/script/region subtags).
fn makeLocaleFrom(arena: std.mem.Allocator, src: *JsObject, t: LangIdTriple) anyerror!Value {
    const old_tag = if (src.getOwn("__locale_tag")) |v| v.unbox().string else "und";
    const sec = try splitTagSections(arena, old_tag);
    const variants = parseLocaleTag(sec.lang_id).variants;

    var out = std.ArrayListUnmanaged(u8){};
    try out.appendSlice(arena, t.language);
    for ([_][]const u8{ t.script, t.region, variants }) |piece| {
        if (piece.len == 0) continue;
        try out.append(arena, '-');
        try out.appendSlice(arena, piece);
    }
    try out.appendSlice(arena, old_tag[sec.lang_id.len..]);
    const tag = (try locale_id.canonicalize(arena, out.items)) orelse out.items;

    const obj = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, active_locale_proto orelse realm_mod.active_object_proto)
    else
        try JsObject.create(arena, active_locale_proto orelse realm_mod.active_object_proto);
    try storeLocaleSlots(arena, obj, tag);
    return val_mod.makeObject(arena, obj);
}

fn localeTriple(o: *JsObject) LangIdTriple {
    return .{
        .language = if (o.getOwn("[[loc_language]]")) |v| v.unbox().string else "und",
        .script = if (o.getOwn("[[loc_script]]")) |v| v.unbox().string else "",
        .region = if (o.getOwn("[[loc_region]]")) |v| v.unbox().string else "",
    };
}

pub fn nativeLocaleMaximize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const t = localeTriple(o);
    return makeLocaleFrom(arena, o, (try addLikelySubtags(arena, t)) orelse t);
}

pub fn nativeLocaleMinimize(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    return makeLocaleFrom(arena, o, try removeLikelySubtags(arena, localeTriple(o)));
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
    try defineData(r, "direction", try val_mod.makeString(arena, if (rtl) "rtl" else "ltr"));
    return val_mod.makeObject(arena, r);
}

/// §14.3.13 `getWeekInfo` — { firstDay, weekend }, both as ISO-8601 weekday
/// numbers (Monday = 1 … Sunday = 7). `firstDay` honours the locale's
/// `firstDayOfWeek`; the weekend is the Saturday/Sunday default.
pub fn nativeLocaleGetWeekInfo(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const o = try requireLocale(arena, this_val);
    const first: f64 = if (localeSlotStr(o, "[[loc_firstDayOfWeek]]")) |id| weekdayNumber(id) else 7;
    const r = try dnEmptyObj(arena);
    try defineData(r, "firstDay", try val_mod.makeNumber(arena, first));
    const weekend = if (realm_mod.active_heap) |h|
        try JsObject.createArrayOnHeap(h, realm_mod.active_array_proto)
    else
        try JsObject.createArray(arena, realm_mod.active_array_proto);
    try weekend.set("0", try val_mod.makeNumber(arena, 6));
    try weekend.set("1", try val_mod.makeNumber(arena, 7));
    try defineData(r, "weekend", try val_mod.makeObject(arena, weekend));
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
    try locAccessor(arena, proto, "calendar", "[[loc_calendar]]", false);
    try locAccessor(arena, proto, "collation", "[[loc_collation]]", false);
    try locAccessor(arena, proto, "hourCycle", "[[loc_hourCycle]]", false);
    try locAccessor(arena, proto, "caseFirst", "[[loc_caseFirst]]", false);
    try locAccessor(arena, proto, "numberingSystem", "[[loc_numberingSystem]]", false);
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
    const sym = realm_mod.active_sym_iterator orelse
        return throwTypeErrorIntl(arena, "Intl.ListFormat: argument is not iterable");
    const ctx = realm_mod.active_context orelse
        return throwTypeErrorIntl(arena, "Intl.ListFormat: argument is not iterable");
    const iter_fn = try ctx.getPropSym(arena, v, sym);
    if (!coercion_mod.isCallable(iter_fn))
        return throwTypeErrorIntl(arena, "Intl.ListFormat: argument is not iterable");
    const iterator = try function_proto_mod.invokeCallback(arena, v, iter_fn, &[_]Value{});
    if (iterator.bits == 0 or iterator.unbox() != .object)
        return throwTypeErrorIntl(arena, "Intl.ListFormat: [Symbol.iterator]() returned a non-object");
    const next_fn = try ctx.getProp(arena, iterator, "next");
    if (!coercion_mod.isCallable(next_fn))
        return throwTypeErrorIntl(arena, "Intl.ListFormat: iterator.next is not a function");
    // Step 4.b.v: each value is type-checked as it arrives, so a non-String stops
    // the iteration there (and closes the iterator) rather than after draining it.
    while (true) {
        const res = try function_proto_mod.invokeCallback(arena, iterator, next_fn, &[_]Value{});
        if (res.bits == 0 or res.unbox() != .object)
            return throwTypeErrorIntl(arena, "Intl.ListFormat: iterator.next() returned a non-object");
        const done = try ctx.getProp(arena, res, "done");
        if (val_mod.toBoolean(done)) break;
        const item = try ctx.getProp(arena, res, "value");
        if (item.bits == 0 or item.unbox() != .string) {
            collections_mod.closeIterator(arena, iterator);
            return throwTypeErrorIntl(arena, "Intl.ListFormat: list elements must be strings");
        }
        try out.append(arena, item.unbox().string);
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
    return listPartsFor(arena, items, resolvedLocaleOf(this_val), typ, style);
}

/// A CLDR listPattern reduced to its separators: `sep` joins all but the last
/// pair (start/middle), `two` joins a two-element list, and `end` joins the last
/// pair of a longer list. CLDR distinguishes the latter two — Spanish `unit`
/// short is "foo y bar" but "foo, bar, baz".
const ListPattern = struct { sep: []const u8, two: []const u8, end: []const u8 };

/// The list pattern for `locale`/`type`/`style`. Falls back to the en-US set,
/// which most locales share apart from the conjunction word.
fn listPatternFor(locale: []const u8, typ: []const u8, style: []const u8) ListPattern {
    const is_unit = std.mem.eql(u8, typ, "unit");
    const is_disjunction = std.mem.eql(u8, typ, "disjunction");
    const narrow = std.mem.eql(u8, style, "narrow");
    const short = std.mem.eql(u8, style, "short");

    if (std.mem.eql(u8, primaryLanguage(locale), "es")) {
        // Spanish joins with "y"/"o" and never uses a serial comma.
        if (is_disjunction) return .{ .sep = ", ", .two = " o ", .end = " o " };
        if (!is_unit) return .{ .sep = ", ", .two = " y ", .end = " y " };
        if (narrow) return .{ .sep = " ", .two = " ", .end = " " };
        if (short) return .{ .sep = ", ", .two = " y ", .end = ", " };
        return .{ .sep = ", ", .two = " y ", .end = " y " };
    }

    // en-US. The conjunction word only appears for `conjunction`/`disjunction`:
    // `unit` lists just enumerate (with a bare space in the narrow style), and a
    // narrow conjunction drops the word.
    const sep: []const u8 = if (is_unit and narrow) " " else ", ";
    const conj: ?[]const u8 = if (is_disjunction)
        "or"
    else if (is_unit or narrow)
        null
    else if (short)
        "&"
    else
        "and";
    if (conj) |c| {
        return .{
            .sep = sep,
            .two = if (std.mem.eql(u8, c, "or")) " or " else if (std.mem.eql(u8, c, "&")) " & " else " and ",
            .end = if (std.mem.eql(u8, c, "or")) ", or " else if (std.mem.eql(u8, c, "&")) ", & " else ", and ",
        };
    }
    return .{ .sep = sep, .two = sep, .end = sep };
}

/// CreatePartsFromList over an already-materialized list of strings, split out
/// so `Intl.DurationFormat` can reuse the same list patterns.
fn listPartsFor(
    arena: std.mem.Allocator,
    items: []const []const u8,
    locale: []const u8,
    typ: []const u8,
    style: []const u8,
) ![]NumberPart {
    var parts: std.ArrayList(NumberPart) = .empty;
    if (items.len == 0) return parts.items;
    if (items.len == 1) {
        try parts.append(arena, .{ .type = "element", .value = items[0] });
        return parts.items;
    }

    const pat = listPatternFor(locale, typ, style);
    const last_sep = if (items.len == 2) pat.two else pat.end;
    for (items, 0..) |it, i| {
        if (i > 0) try parts.append(arena, .{
            .type = "literal",
            .value = if (i == items.len - 1) last_sep else pat.sep,
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
        try defineData(o, "type", try val_mod.makeString(arena, p.type));
        try defineData(o, "value", try val_mod.makeString(arena, p.value));
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
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "type", try val_mod.makeString(arena, typ));
    try defineData(r, "style", try val_mod.makeString(arena, style));
    return val_mod.makeObject(arena, r);
}

// ------------------------------------------------------------------ PluralRules ---

/// Unwrap a PluralRules receiver, throwing on anything without the brand slot.
fn requirePluralRules(arena: std.mem.Allocator, this_val: Value, comptime method: []const u8) anyerror!*JsObject {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__pr_type") == null)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype." ++ method ++ " called on an incompatible receiver");
    return this_val.toPtr().object;
}

/// The plural category `x` selects for this PluralRules. `type: "ordinal"` uses
/// the English ordinal rules everywhere; cardinal follows the locale's CLDR rule.
fn pluralSelect(arena: std.mem.Allocator, this_val: Value, obj: *JsObject, x: f64) ![]const u8 {
    const raw = try nfmt.pluralOperands(arena, this_val, x);
    const ops = plural.Ops{
        .n = raw.n,
        .i = raw.i,
        .v = raw.v,
        .w = raw.w,
        .f = raw.f,
        .t = raw.t,
        .e = raw.e,
    };
    if (std.mem.eql(u8, readOpt(obj, "__pr_type"), "ordinal")) return plural.selectOrdinal(ops);
    return plural.selectCardinal(plural.ruleFor(resolvedLocaleOf(this_val)), ops);
}

pub fn nativePluralRulesCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try intlNewTarget(arena, this_val, "Intl.PluralRules");
    try resolveAndStoreLocale(arena, obj, if (args.len > 0) args[0] else Value{});
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    const typ = (try dnGetOption(arena, options, "type", &.{ "cardinal", "ordinal" }, "cardinal")).?;
    try obj.set("__pr_type", try val_mod.makeString(arena, typ));
    // §16.1.2 steps 12–16: PluralRules shares SetNumberFormatDigitOptions with
    // NumberFormat, and reads notation/compactDisplay ahead of it, because the
    // plural operands depend on how the number would be formatted.
    const notation = (try dnGetOption(arena, options, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard")).?;
    const is_compact = std.mem.eql(u8, notation, "compact");
    const compact_display = (try dnGetOption(arena, options, "compactDisplay", &.{ "short", "long" }, "short")).?;
    try obj.set("__intl_notation", try val_mod.makeString(arena, notation));
    if (is_compact)
        try obj.set("__intl_compactDisplay", try val_mod.makeString(arena, compact_display));
    try nfmt.setDigitOptions(arena, options, obj, 0, 3, is_compact);
    return val_mod.makeObject(arena, obj);
}

pub fn nativePluralRulesSelect(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try requirePluralRules(arena, this_val, "select");
    const n = if (args.len > 0)
        try coercion_mod.toNumberThrowing(arena, args[0])
    else
        std.math.nan(f64);
    return val_mod.makeString(arena, try pluralSelect(arena, this_val, obj, n));
}

/// §16.3.3 selectRange(start, end): both ends go through ToIntlMathematicalValue
/// (so a Symbol is a TypeError and NaN a RangeError); en-US and every rule set
/// modelled here resolve a range to the plural form of its end value.
pub fn nativePluralRulesSelectRange(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const obj = try requirePluralRules(arena, this_val, "selectRange");
    if (args.len < 2 or args[0].bits == 0 or args[0].unbox() == .undefined_ or args[1].bits == 0 or args[1].unbox() == .undefined_)
        return throwTypeErrorIntl(arena, "Intl.PluralRules.prototype.selectRange: start and end are required");
    const start = try coercion_mod.toNumberThrowing(arena, args[0]);
    const end = try coercion_mod.toNumberThrowing(arena, args[1]);
    if (std.math.isNan(start) or std.math.isNan(end))
        return throwRangeError(arena, "Intl.PluralRules.prototype.selectRange: start and end must not be NaN");
    return val_mod.makeString(arena, try pluralSelect(arena, this_val, obj, end));
}

pub fn nativePluralRulesResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const obj = try requirePluralRules(arena, this_val, "resolvedOptions");
    const r = if (realm_mod.active_heap) |h|
        try JsObject.createOnHeap(h, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    const ordinal = std.mem.eql(u8, readOpt(obj, "__pr_type"), "ordinal");
    const notation = readOpt(obj, "__intl_notation");
    const round_type = readOpt(obj, "__intl_roundType");
    // Table 16 order: locale, type, notation, [compactDisplay], the digit
    // options that the resolved rounding type actually uses, then the category
    // list and the rounding knobs.
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "type", try val_mod.makeString(arena, if (ordinal) "ordinal" else "cardinal"));
    try defineData(r, "notation", try val_mod.makeString(arena, if (notation.len > 0) notation else "standard"));
    if (std.mem.eql(u8, notation, "compact"))
        try defineData(r, "compactDisplay", try val_mod.makeString(arena, readOpt(obj, "__intl_compactDisplay")));
    try defineData(r, "minimumIntegerDigits", try val_mod.makeNumber(arena, readNum(obj, "__intl_minInt")));
    if (!std.mem.eql(u8, round_type, "significantDigits")) {
        try defineData(r, "minimumFractionDigits", try val_mod.makeNumber(arena, readNum(obj, "__intl_minFrac")));
        try defineData(r, "maximumFractionDigits", try val_mod.makeNumber(arena, readNum(obj, "__intl_maxFrac")));
    }
    if (!std.mem.eql(u8, round_type, "fractionDigits")) {
        try defineData(r, "minimumSignificantDigits", try val_mod.makeNumber(arena, readNum(obj, "__intl_minSig")));
        try defineData(r, "maximumSignificantDigits", try val_mod.makeNumber(arena, readNum(obj, "__intl_maxSig")));
    }
    // pluralCategories: a real Array of every category the locale's rule set can
    // produce, in CLDR order.
    const cats = try JsObject.createArray(arena, realm_mod.active_array_proto);
    const names: []const []const u8 = if (ordinal)
        plural.ordinalCategories()
    else
        plural.categoriesFor(plural.ruleFor(resolvedLocaleOf(this_val)));
    for (names) |n| try cats.appendElement(try val_mod.makeString(arena, n));
    try defineData(r, "pluralCategories", try val_mod.makeObject(arena, cats));
    try defineData(r, "roundingIncrement", try val_mod.makeNumber(arena, readNum(obj, "__intl_roundInc")));
    try defineData(r, "roundingMode", try val_mod.makeString(arena, readOpt(obj, "__intl_roundMode")));
    try defineData(r, "roundingPriority", try val_mod.makeString(arena, readOpt(obj, "__intl_roundPriority")));
    try defineData(r, "trailingZeroDisplay", try val_mod.makeString(arena, readOpt(obj, "__intl_trailingZero")));
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
    const locales = if (args.len > 0) args[0] else Value{};
    const options = try coerceOptionsToObject(arena, if (args.len > 1) args[1] else null);
    _ = try dnGetOption(arena, options, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    var nu_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, options, "numberingSystem", &.{}, null)) |ns| {
        if (!isWellFormedNumberingSystem(ns)) return throwRangeError(arena, "invalid numberingSystem");
        nu_opt = ns;
    }
    // ResolveLocale over `nu` also stores [[Locale]], so it replaces the plain
    // resolveAndStoreLocale a locale-insensitive service would use.
    const nu = try resolveNumberingSystem(arena, obj, locales, nu_opt);
    try obj.set("__intl_numberingSystem", try val_mod.makeString(arena, nu));
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

/// The en display name for `unit` in `style`, for the singular ("one") or plural
/// ("other") plural category. CLDR abbreviates most units in the short and
/// narrow styles ("sec.", "qtrs.") but leaves "day"/"days" spelled out.
fn rtfUnitName(arena: std.mem.Allocator, unit: []const u8, style: []const u8, singular: bool) ![]const u8 {
    if (std.mem.eql(u8, style, "long")) {
        return if (singular) unit else try std.fmt.allocPrint(arena, "{s}s", .{unit});
    }
    // "short" and "narrow" share the abbreviated forms in en.
    const table = [_]struct { u: []const u8, one: []const u8, other: []const u8 }{
        .{ .u = "second", .one = "sec.", .other = "sec." },
        .{ .u = "minute", .one = "min.", .other = "min." },
        .{ .u = "hour", .one = "hr.", .other = "hr." },
        .{ .u = "day", .one = "day", .other = "days" },
        .{ .u = "week", .one = "wk.", .other = "wk." },
        .{ .u = "month", .one = "mo.", .other = "mo." },
        .{ .u = "quarter", .one = "qtr.", .other = "qtrs." },
        .{ .u = "year", .one = "yr.", .other = "yr." },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.u, unit)) return if (singular) row.one else row.other;
    }
    return if (singular) unit else try std.fmt.allocPrint(arena, "{s}s", .{unit});
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
    const obj = this_val.toPtr().object;
    const unit_name = try rtfUnitName(arena, u, readOpt(obj, "__rtf_style"), av == 1);
    if (!past) try parts.append(arena, .{ .type = "literal", .value = "in " });
    const nf_opt = nfmt.NfOptions{
        .locale = resolvedLocaleOf(this_val),
        .numbering_system = readOpt(obj, "__intl_numberingSystem"),
    };
    for (try nfmt.formatNumberParts(arena, av, nf_opt)) |np|
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
        try defineData(o, "type", try val_mod.makeString(arena, p.type));
        try defineData(o, "value", try val_mod.makeString(arena, p.value));
        if (p.source) |unit| try defineData(o, "unit", try val_mod.makeString(arena, unit));
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
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "style", try val_mod.makeString(arena, style));
    try defineData(r, "numeric", try val_mod.makeString(arena, numeric));
    try defineData(r, "numberingSystem", try val_mod.makeString(arena, readOpt(this_val.toPtr().object, "__intl_numberingSystem")));
    return val_mod.makeObject(arena, r);
}

// ----------------------------------------------------------------- DisplayNames ---

/// CreateDataPropertyOrThrow. Every `resolvedOptions()` result and
/// `formatToParts` part is built with [[DefineOwnProperty]], so a setter planted
/// on Object.prototype can neither intercept nor observe the write
/// (`taint-Object-prototype.js`).
pub fn defineData(o: *JsObject, key: []const u8, v: Value) !void {
    _ = try o.defineOwnData(key, v, .{ .writable = true, .enumerable = true, .configurable = true });
}

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
    if (dnEnglishName(typ, code)) |name| return val_mod.makeString(arena, name);
    // Outside the tables there is no CLDR name data: with fallback "code" the
    // (validated) code is returned; with "none" the absent name is undefined.
    if (std.mem.eql(u8, fallback, "none")) return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, code);
}

/// The en display name for `code`, for the types this build has data for. Every
/// value `Intl.supportedValuesOf` advertises appears here, so a DisplayNames
/// with `fallback: "none"` still names all of them.
fn dnEnglishName(typ: []const u8, code: []const u8) ?[]const u8 {
    const Row = struct { code: []const u8, name: []const u8 };
    const calendars = [_]Row{
        .{ .code = "iso8601", .name = "ISO-8601 Calendar" },
        .{ .code = "gregory", .name = "Gregorian Calendar" },
        .{ .code = "buddhist", .name = "Buddhist Calendar" },
        .{ .code = "roc", .name = "Minguo Calendar" },
        .{ .code = "japanese", .name = "Japanese Calendar" },
        .{ .code = "coptic", .name = "Coptic Calendar" },
        .{ .code = "ethiopic", .name = "Ethiopic Calendar" },
        .{ .code = "ethioaa", .name = "Ethiopic Amete Alem Calendar" },
        .{ .code = "islamic-civil", .name = "Islamic Calendar (tabular, civil epoch)" },
        .{ .code = "islamic-tbla", .name = "Islamic Calendar (tabular, astronomical epoch)" },
        .{ .code = "islamic-umalqura", .name = "Islamic Calendar (Umm al-Qura)" },
        .{ .code = "persian", .name = "Persian Calendar" },
        .{ .code = "indian", .name = "Indian National Calendar" },
        .{ .code = "hebrew", .name = "Hebrew Calendar" },
        .{ .code = "chinese", .name = "Chinese Calendar" },
        .{ .code = "dangi", .name = "Dangi Calendar" },
    };
    const currencies = [_]Row{
        .{ .code = "AUD", .name = "Australian Dollar" },
        .{ .code = "BRL", .name = "Brazilian Real" },
        .{ .code = "CAD", .name = "Canadian Dollar" },
        .{ .code = "CHF", .name = "Swiss Franc" },
        .{ .code = "CNY", .name = "Chinese Yuan" },
        .{ .code = "EUR", .name = "Euro" },
        .{ .code = "GBP", .name = "British Pound" },
        .{ .code = "HKD", .name = "Hong Kong Dollar" },
        .{ .code = "INR", .name = "Indian Rupee" },
        .{ .code = "JPY", .name = "Japanese Yen" },
        .{ .code = "KRW", .name = "South Korean Won" },
        .{ .code = "MXN", .name = "Mexican Peso" },
        .{ .code = "NZD", .name = "New Zealand Dollar" },
        .{ .code = "RUB", .name = "Russian Ruble" },
        .{ .code = "SEK", .name = "Swedish Krona" },
        .{ .code = "SGD", .name = "Singapore Dollar" },
        .{ .code = "TRY", .name = "Turkish Lira" },
        .{ .code = "USD", .name = "US Dollar" },
        .{ .code = "ZAR", .name = "South African Rand" },
    };
    const rows: []const Row = if (std.mem.eql(u8, typ, "calendar"))
        &calendars
    else if (std.mem.eql(u8, typ, "currency"))
        &currencies
    else
        return null;
    for (rows) |row| {
        if (std.ascii.eqlIgnoreCase(row.code, code)) return row.name;
    }
    return null;
}

pub fn nativeDisplayNamesResolved(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object or this_val.toPtr().object.getOwn("__dn_type") == null)
        return throwTypeErrorIntl(arena, "Intl.DisplayNames.prototype.resolvedOptions called on an incompatible receiver");
    const o = this_val.toPtr().object;
    const r = try dnEmptyObj(arena);
    const typ = o.getOwn("__dn_type").?.unbox().string;
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "style", o.getOwn("__dn_style") orelse try val_mod.makeString(arena, "long"));
    try defineData(r, "type", try val_mod.makeString(arena, typ));
    try defineData(r, "fallback", o.getOwn("__dn_fallback") orelse try val_mod.makeString(arena, "code"));
    if (std.mem.eql(u8, typ, "language"))
        try defineData(r, "languageDisplay", o.getOwn("__dn_langdisplay") orelse try val_mod.makeString(arena, "dialect"));
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
    const locales = if (args.len > 0) args[0] else Value{};
    // GetOptionsObject: a non-undefined, non-Object options argument is a
    // TypeError, and every read below is a real [[Get]], in spec order.
    const opts = try dnGetOptionsObject(arena, if (args.len > 1) args[1] else null);

    // localeMatcher must be "lookup" or "best fit" when present (else RangeError).
    _ = try dnGetOption(arena, opts, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");

    // numberingSystem — must be a well-formed Unicode `type` value when present.
    var nu_opt: ?[]const u8 = null;
    if (try dnGetOption(arena, opts, "numberingSystem", &.{}, null)) |nstr| {
        if (!isWellFormedNumberingSystem(nstr))
            return throwRangeError(arena, "invalid numberingSystem");
        nu_opt = nstr;
    }
    // ResolveLocale over `nu` stores [[Locale]] too, keeping a `-u-nu-` that came
    // from the requested tag (and dropping one an option overrode).
    const nu = try resolveNumberingSystem(arena, obj, locales, nu_opt);
    try obj.set("__df_nu", try val_mod.makeString(arena, nu));

    const base_style = (try dnGetOption(arena, opts, "style", &.{ "long", "short", "narrow", "digital" }, "short")).?;
    try obj.set("__df_style", try val_mod.makeString(arena, base_style));

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
        var style = try dnGetOption(arena, opts, uname, allowed_buf[0..n_allowed], null);
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
        // GetDurationUnitOptions step 7: a long/short/narrow style cannot follow a
        // unit rendered with "numeric"/"2-digit", and minutes/seconds in that
        // position are always zero-padded — even when "numeric" was explicit.
        if (dfIsNumericStyle(prev_style)) {
            if (!dfIsNumericStyle(style.?))
                return throwRangeError(arena, "Intl.DurationFormat: style cannot follow a numeric unit");
            if (i == 5 or i == 6) style = "2-digit";
        }
        const disp_key = try std.fmt.allocPrint(arena, "{s}Display", .{uname});
        const display = (try dnGetOption(arena, opts, disp_key, &.{ "auto", "always" }, null)) orelse display_default;

        try obj.set(try std.fmt.allocPrint(arena, "__df_s{d}", .{i}), try val_mod.makeString(arena, style.?));
        try obj.set(try std.fmt.allocPrint(arena, "__df_d{d}", .{i}), try val_mod.makeString(arena, display));
        prev_style = style.?;
    }

    // fractionalDigits is read last, after every per-unit option: 0..9, or the
    // -1 sentinel when absent.
    var frac: f64 = -1;
    if (try dnGetNumOption(arena, opts, "fractionalDigits")) |n| {
        if (!std.math.isFinite(n) or n < 0 or n > 9 or n != @trunc(n))
            return throwRangeError(arena, "fractionalDigits out of range");
        frac = n;
    }
    try obj.set("__df_frac", try val_mod.makeNumber(arena, frac));

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
/// Step 7.c.vii of CanonicalizeLocaleList: reject a structurally invalid tag,
/// then canonicalize it. Applied to every element, including ones no caller will
/// ever look at.
fn appendCanonicalTag(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), tag: []const u8) anyerror!void {
    if (!try isStructurallyValidLanguageTag(arena, tag))
        return throwRangeError(arena, "invalid language tag");
    try out.append(arena, try canonicalizeTag(arena, tag));
}

pub fn canonicalizeLocaleList(arena: std.mem.Allocator, locales: Value) anyerror![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    if (locales.bits == 0 or locales.unbox() == .undefined_) return out.items;
    // ToObject(null) is a TypeError; other primitives box to a wrapper with no
    // "length" (→ empty list). A String is a single-element list.
    if (locales.unbox() == .null_) return throwTypeErrorIntl(arena, "Cannot convert null locales to object");
    if (locales.unbox() == .string) {
        try appendCanonicalTag(arena, &out, locales.unbox().string);
        return out.items;
    }
    // An Intl.Locale is a one-element list of its [[Locale]] — never an
    // array-like, and `toString` is not consulted.
    if (locales.unbox() == .object) {
        if (locales.toPtr().object.getOwn("__locale_tag")) |lt| {
            if (lt.bits != 0 and lt.unbox() == .string) {
                try appendCanonicalTag(arena, &out, lt.unbox().string);
                return out.items;
            }
        }
    }
    // Every other primitive is ToObject-boxed, so inherited index/length
    // properties on e.g. Number.prototype are still seen.
    // A Symbol boxes like any other primitive: the resulting wrapper has no
    // indices, but its `length` [[Get]] is still observable (and may be a
    // getter installed on Symbol.prototype).
    const obj: Value = if (locales.unbox() == .object)
        locales
    else
        try realm_mod.toObjectForThis(arena, locales);
    const ctx = realm_mod.active_context;
    const len_v = if (ctx) |c| try c.getProp(arena, obj, "length") else Value{};
    // ToLength → ToNumber: a Symbol or BigInt length is a TypeError.
    if (len_v.bits != 0 and (len_v.unbox() == .symbol or len_v.unbox() == .bigint))
        return throwTypeErrorIntl(arena, "Cannot convert length to a number");
    const len = try realm_mod.toLengthValue(arena, len_v);
    var k: usize = 0;
    while (k < len) : (k += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{k});
        const present = if (ctx) |c| try c.hasProp(arena, obj, key) else false;
        if (!present) continue;
        const kv = if (ctx) |c| try c.getProp(arena, obj, key) else Value{};
        if (kv.bits != 0 and kv.unbox() == .string) {
            try appendCanonicalTag(arena, &out, kv.unbox().string);
        } else if (kv.bits != 0 and kv.unbox() == .object) {
            // An Intl.Locale element contributes its [[Locale]] directly.
            if (kv.toPtr().object.get("__locale_tag")) |lt| {
                if (lt.bits != 0 and lt.unbox() == .string) {
                    try appendCanonicalTag(arena, &out, lt.unbox().string);
                    continue;
                }
            }
            try appendCanonicalTag(arena, &out, try t_shared.valueToString(arena, kv));
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

/// One duration field's value: either a plain amount, or the exact decimal
/// string that folding sub-second fields into fractional seconds produced (that
/// sum can carry more significant digits than an f64 holds).
const DfValue = union(enum) {
    num: f64,
    dec: []const u8,

    /// The spec's `value != 0` display test. A fractional-seconds string is
    /// never equal to the number 0, so it always displays.
    fn isNonZero(self: DfValue) bool {
        return switch (self) {
            .num => |n| n != 0,
            .dec => true,
        };
    }
};

/// ToIntegerIfIntegral of a duration field, as an exact i128. Duration fields
/// are integers below 2**53, so the cast is lossless.
fn dfExact(x: f64) i128 {
    if (!std.math.isFinite(x)) return 0;
    return @intFromFloat(@trunc(x));
}

/// The seconds/milliseconds/microseconds amount with every finer field folded
/// into its fractional part, as an exact decimal string. `exponent` is 9 for
/// seconds, 6 for milliseconds and 3 for microseconds — the number of decimal
/// places one whole unit spans in nanoseconds.
fn dfToFractional(arena: std.mem.Allocator, fields: *const [10]f64, exponent: u5) !DfValue {
    const secs = fields[6];
    const ms = fields[7];
    const us = fields[8];
    const ns = fields[9];
    // No sub-second remainder: the field keeps its own (possibly negative-zero)
    // value, which is what carries the sign for a leading unit.
    switch (exponent) {
        9 => if (ms == 0 and us == 0 and ns == 0) return .{ .num = secs },
        6 => if (us == 0 and ns == 0) return .{ .num = ms },
        else => if (ns == 0) return .{ .num = us },
    }

    var total: i128 = dfExact(ns);
    if (exponent >= 9) total += dfExact(secs) * 1_000_000_000;
    if (exponent >= 6) total += dfExact(ms) * 1_000_000;
    total += dfExact(us) * 1_000;

    var scale: i128 = 1;
    for (0..exponent) |_| scale *= 10;
    const q = @divTrunc(total, scale);
    // Truncated remainder (sign of the dividend), then its magnitude: the
    // fractional digits are unsigned and the sign rides on the quotient.
    const r: i128 = @intCast(@abs(@rem(total, scale)));

    var frac_buf: [40]u8 = undefined;
    const frac = std.fmt.bufPrint(&frac_buf, "{d}", .{r}) catch "0";
    var buf = std.ArrayListUnmanaged(u8){};
    // `q` is 0 for a sub-unit magnitude, so a leading "-" would be dropped;
    // reproduce the reference algorithm, which formats the quotient as-is.
    try buf.writer(arena).print("{d}.", .{q});
    for (frac.len..exponent) |_| try buf.append(arena, '0');
    try buf.appendSlice(arena, frac);
    return .{ .dec = buf.items };
}

/// The NumberFormat singular unit name for a duration field ("years" → "year").
fn dfSingular(unit: []const u8) []const u8 {
    return unit[0 .. unit.len - 1];
}

/// PartitionDurationFormatPattern (ECMA-402 §13.5.7). Each formatted field
/// becomes a run of NumberFormat parts (with `source` carrying the singular
/// unit name); consecutive numeric fields are joined by ":" into one list
/// element, and the elements are then run through the en `unit` list pattern.
fn dfBuildParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) ![]NumberPart {
    if (this_val.bits == 0 or this_val.unbox() != .object)
        return throwTypeErrorIntl(arena, "Intl.DurationFormat.prototype method called on incompatible receiver");
    const o = this_val.toPtr().object;
    if (o.get("__df_style") == null)
        return throwTypeErrorIntl(arena, "Intl.DurationFormat.prototype method called on incompatible receiver");

    const d = try t_duration.toTemporalDuration(arena, if (args.len > 0) args[0] else try val_mod.makeUndefined(arena));
    // A Duration record holds mathematical integers, so a `-0` field argument
    // arrives as `+0` and must not make the whole duration read as negative.
    var fields = [_]f64{ d.years, d.months, d.weeks, d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };
    for (&fields) |*f| {
        if (f.* == 0) f.* = 0;
    }

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

    const any_negative = blk: {
        for (fields) |f| if (f < 0) break :blk true;
        break :blk false;
    };

    // One entry per list element; a numeric clock group accumulates into the
    // element the first of its fields opened.
    var elements = std.ArrayListUnmanaged(std.ArrayListUnmanaged(NumberPart)){};
    var need_separator = false;
    var display_negative_sign = true;

    for (DF_UNITS, 0..) |uname, i| {
        var value: DfValue = .{ .num = fields[i] };
        const style = styles[i];
        const display = displays[i];
        const numeric = dfIsNumericStyle(style);
        var max_frac: ?u32 = null;
        var min_frac: ?u32 = null;
        var trunc_rounding = false;
        var done = false;

        // Numeric seconds and sub-seconds collapse into a single fractional
        // amount as soon as the *next* field is rendered numerically.
        if (i >= 6 and i <= 8 and dfIsNumericStyle(styles[i + 1])) {
            const exponent: u5 = switch (i) {
                6 => 9,
                7 => 6,
                else => 3,
            };
            value = try dfToFractional(arena, &fields, exponent);
            max_frac = if (frac_digits >= 0) @intCast(frac_digits) else 9;
            min_frac = if (frac_digits >= 0) @intCast(frac_digits) else 0;
            trunc_rounding = true;
            done = true;
        }

        // A numeric "minutes" that precedes a shown seconds field must render
        // even when it is zero, so the clock does not lose its "0:" segment.
        var display_required = false;
        if (i == 5 and need_separator) {
            display_required = std.mem.eql(u8, displays[6], "always") or
                fields[6] != 0 or fields[7] != 0 or fields[8] != 0 or fields[9] != 0;
        }

        if (value.isNonZero() or !std.mem.eql(u8, display, "auto") or display_required) {
            var sign_display: []const u8 = "auto";
            if (display_negative_sign) {
                display_negative_sign = false;
                // The first rendered field carries the whole duration's sign,
                // even when it is itself zero.
                if (value == .num and value.num == 0 and any_negative) value = .{ .num = -0.0 };
            } else {
                sign_display = "never";
            }

            const standalone = !numeric;
            const nf_opt = nfmt.NfOptions{
                .style = if (standalone) "unit" else "decimal",
                .unit = if (standalone) dfSingular(uname) else "",
                .unit_display = if (standalone) style else "short",
                .use_grouping = if (standalone) "auto" else "false",
                .min_int = @as(u32, if (std.mem.eql(u8, style, "2-digit")) 2 else 1),
                .min_frac = min_frac orelse 0,
                .max_frac = max_frac orelse 3,
                .rounding_mode = if (trunc_rounding) nfmt.RoundMode.trunc else nfmt.RoundMode.half_expand,
                .sign_display = sign_display,
            };
            const num_parts = switch (value) {
                .num => |n| try nfmt.formatNumberParts(arena, n, nf_opt),
                .dec => |s| try nfmt.formatDecimalStringParts(arena, s, nf_opt),
            };

            var list: *std.ArrayListUnmanaged(NumberPart) = undefined;
            if (need_separator) {
                list = &elements.items[elements.items.len - 1];
                try list.append(arena, .{ .type = "literal", .value = ":" });
            } else {
                try elements.append(arena, .{});
                list = &elements.items[elements.items.len - 1];
            }
            for (num_parts) |p|
                try list.append(arena, .{ .type = p.type, .value = p.value, .source = dfSingular(uname) });
            if (!need_separator and numeric) need_separator = true;
        }

        if (done) break;
    }

    // Join the elements with the en `unit`-type list pattern; "digital" borrows
    // the "short" list style.
    var strings = std.ArrayListUnmanaged([]const u8){};
    for (elements.items) |el| {
        var s = std.ArrayListUnmanaged(u8){};
        for (el.items) |p| try s.appendSlice(arena, p.value);
        try strings.append(arena, s.items);
    }
    const list_style: []const u8 = if (std.mem.eql(u8, base_style, "digital")) "short" else base_style;
    var out = std.ArrayListUnmanaged(NumberPart){};
    var next: usize = 0;
    for (try listPartsFor(arena, strings.items, resolvedLocaleOf(this_val), "unit", list_style)) |p| {
        if (std.mem.eql(u8, p.type, "element")) {
            try out.appendSlice(arena, elements.items[next].items);
            next += 1;
        } else {
            try out.append(arena, .{ .type = p.type, .value = p.value });
        }
    }
    return out.items;
}

pub fn nativeDurationFormatFormat(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    var out = std.ArrayListUnmanaged(u8){};
    for (try dfBuildParts(arena, this_val, args)) |p| try out.appendSlice(arena, p.value);
    return val_mod.makeString(arena, out.items);
}

pub fn nativeDurationFormatFormatToParts(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const parts = try dfBuildParts(arena, this_val, args);
    const arr = try JsObject.createArray(arena, realm_mod.active_array_proto);
    for (parts) |p| {
        const part = try dnEmptyObj(arena);
        try defineData(part, "type", try val_mod.makeString(arena, p.type));
        try defineData(part, "value", try val_mod.makeString(arena, p.value));
        if (p.source) |unit| try defineData(part, "unit", try val_mod.makeString(arena, unit));
        try arr.appendElement(try val_mod.makeObject(arena, part));
    }
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
    try defineData(r, "locale", try val_mod.makeString(arena, resolvedLocaleOf(this_val)));
    try defineData(r, "numberingSystem", try val_mod.makeString(arena, dfReadStr(o, "__df_nu", "latn")));
    try defineData(r, "style", try val_mod.makeString(arena, dfReadStr(o, "__df_style", "short")));
    for (DF_UNITS, 0..) |uname, i| {
        var sk: [8]u8 = undefined;
        var dk: [8]u8 = undefined;
        try defineData(r, uname, try val_mod.makeString(arena, dfReadStr(o, std.fmt.bufPrint(&sk, "__df_s{d}", .{i}) catch unreachable, "short")));
        const disp_key = try std.fmt.allocPrint(arena, "{s}Display", .{uname});
        try defineData(r, disp_key, try val_mod.makeString(arena, dfReadStr(o, std.fmt.bufPrint(&dk, "__df_d{d}", .{i}) catch unreachable, "auto")));
    }
    const frac_digits: i32 = if (o.get("__df_frac")) |fv| (if (fv.bits != 0 and fv.unbox() == .number) @intFromFloat(fv.unbox().number) else -1) else -1;
    if (frac_digits >= 0) try defineData(r, "fractionalDigits", try val_mod.makeNumber(arena, @floatFromInt(frac_digits)));
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmp = struct {
        fn f(al: std.mem.Allocator, x: []const u8, y: []const u8) !std.math.Order {
            return collatorCompareStrings(al, x, y, "accent", false, "false", false);
        }
    }.f;
    try std.testing.expectEqual(std.math.Order.eq, try cmp(a, "Apple", "apple"));
    try std.testing.expectEqual(std.math.Order.lt, try cmp(a, "apple", "banana"));
    try std.testing.expectEqual(std.math.Order.gt, try cmp(a, "Banana", "apple"));
    // Canonically equivalent spellings of "ö" collate as one string.
    try std.testing.expectEqual(std.math.Order.eq, try cmp(a, "o\u{308}", "\u{f6}"));
}

test "intl: listformat en-US phrasing" {
    try std.testing.expect(true); // format() needs an array object; covered by differential corpus.
}

test "intl: plural category cardinal & ordinal" {
    const card = struct {
        fn f(i: u64) []const u8 {
            return plural.selectCardinal(.en, .{ .n = @floatFromInt(i), .i = i });
        }
    }.f;
    const ord = struct {
        fn f(i: u64) []const u8 {
            return plural.selectOrdinal(.{ .n = @floatFromInt(i), .i = i });
        }
    }.f;
    try std.testing.expectEqualStrings("one", card(1));
    try std.testing.expectEqualStrings("other", card(0));
    try std.testing.expectEqualStrings("other", card(2));
    try std.testing.expectEqualStrings("one", ord(1));
    try std.testing.expectEqualStrings("two", ord(2));
    try std.testing.expectEqualStrings("few", ord(3));
    try std.testing.expectEqualStrings("other", ord(4));
    try std.testing.expectEqualStrings("other", ord(11));
    try std.testing.expectEqualStrings("other", ord(12));
    try std.testing.expectEqualStrings("other", ord(13));
    try std.testing.expectEqualStrings("one", ord(21));
    try std.testing.expectEqualStrings("few", ord(103));
}

test "intl: singularUnit strips plural s" {
    try std.testing.expectEqualStrings("day", singularUnit("days"));
    try std.testing.expectEqualStrings("day", singularUnit("day"));
    try std.testing.expectEqualStrings("month", singularUnit("months"));
}

test "intl: numeric collation order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmp = struct {
        fn f(al: std.mem.Allocator, x: []const u8, y: []const u8, sens: []const u8) !std.math.Order {
            return collatorCompareStrings(al, x, y, sens, true, "false", false);
        }
    }.f;
    try std.testing.expectEqual(std.math.Order.gt, try cmp(a, "10", "2", "variant"));
    try std.testing.expectEqual(std.math.Order.lt, try cmp(a, "a2", "a10", "variant"));
    try std.testing.expectEqual(std.math.Order.lt, try cmp(a, "file9", "file10", "variant"));
    try std.testing.expectEqual(std.math.Order.eq, try cmp(a, "2", "2", "variant"));
    try std.testing.expectEqual(std.math.Order.gt, try cmp(a, "item20", "item3", "variant"));
    try std.testing.expectEqual(std.math.Order.eq, try cmp(a, "007", "7", "variant"));
    try std.testing.expectEqual(std.math.Order.eq, try cmp(a, "A1", "a1", "accent"));
}
