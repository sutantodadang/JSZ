// SPDX-License-Identifier: Apache-2.0
//! Wave 26: the `Temporal.Now` namespace — clock readings anchored to the host
//! system clock. Time zone/calendar are string identifiers (current proposal).
//! The host time zone is reported as "UTC" (we do not model a local zone db), so
//! the *ISO methods interpret "now" in UTC by default.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");
const shared = @import("shared.zig");
const timezone = @import("timezone.zig");
const instant = @import("instant.zig");
const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const plain_date_time = @import("plain_date_time.zig");
const zoned = @import("zoned_date_time.zig");

var now_obj: ?*JsObject = null;

/// System UTC time-zone identifier. Kept as a single source of truth so
/// `timeZoneId()` and the default zone used by the *ISO methods agree.
const SYSTEM_TZ = "UTC";

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn resolveZone(arena: std.mem.Allocator, args: []const Value) !timezone.Zone {
    const v = if (args.len > 0) args[0] else Value{};
    if (v.bits == 0 or v.unbox() == .undefined_) return .{ .id = SYSTEM_TZ, .offset_ns = 0 };
    if (v.unbox() != .string) return realm_mod.throwTypeError(arena, "time zone must be a string");
    return timezone.toZone(arena, v.unbox().string);
}

fn localDT(ns: i128, offset_ns: i128) shared.ISODateTime {
    const total = ns + offset_ns;
    const days: i64 = @intCast(@divFloor(total, shared.NS_PER_DAY));
    const tod = total - @as(i128, days) * shared.NS_PER_DAY;
    const tr = shared.nanosToTime(tod);
    const date = shared.epochDaysToISODate(days + tr.days);
    return .{ .date = date, .time = tr.time };
}

pub fn nativeInstant(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return instant.makeInstant(arena, nowNs());
}

pub fn nativeTimeZoneId(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return val_mod.makeString(arena, SYSTEM_TZ);
}

pub fn nativeZonedDateTimeISO(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const zone = try resolveZone(arena, args);
    return zoned.makeZoned(arena, .{ .ns = nowNs(), .tz = zone.id, .offset_ns = zone.offset_ns });
}

pub fn nativePlainDateISO(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const zone = try resolveZone(arena, args);
    return plain_date.makeDate(arena, localDT(nowNs(), zone.offset_ns).date);
}

pub fn nativePlainDateTimeISO(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const zone = try resolveZone(arena, args);
    return plain_date_time.makeDateTime(arena, localDT(nowNs(), zone.offset_ns));
}

pub fn nativePlainTimeISO(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const zone = try resolveZone(arena, args);
    return plain_time.makeTime(arena, localDT(nowNs(), zone.offset_ns).time);
}

pub fn create(ctx: *const intrinsics.Ctx) !*JsObject {
    const arena = ctx.arena;
    const now = try JsObject.create(arena, ctx.object_proto);
    now_obj = now;
    try intrinsics.setMethod(arena, now, "instant", nativeInstant);
    try intrinsics.setMethod(arena, now, "timeZoneId", nativeTimeZoneId);
    try intrinsics.setMethod(arena, now, "zonedDateTimeISO", nativeZonedDateTimeISO);
    try intrinsics.setMethod(arena, now, "plainDateISO", nativePlainDateISO);
    try intrinsics.setMethod(arena, now, "plainDateTimeISO", nativePlainDateTimeISO);
    try intrinsics.setMethod(arena, now, "plainTimeISO", nativePlainTimeISO);
    return now;
}

pub fn registerToStringTag(arena: std.mem.Allocator, tag_sym: Value) !void {
    const now = now_obj orelse return;
    try now.setSymAttr(tag_sym, try val_mod.makeString(arena, "Temporal.Now"), .{ .writable = false, .enumerable = false, .configurable = true });
}
