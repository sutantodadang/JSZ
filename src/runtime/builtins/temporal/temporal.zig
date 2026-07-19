// SPDX-License-Identifier: Apache-2.0
//! Wave 25: the `Temporal` namespace object. Registers the value-type
//! constructors (Instant, Duration, PlainDate, PlainTime, PlainDateTime) and
//! installs `Temporal` as a global. ZonedDateTime, PlainYearMonth,
//! PlainMonthDay, TimeZone, Calendar, and Temporal.Now arrive in Wave 26.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../../object/object.zig").JsObject;
const realm_mod = @import("../../realm.zig");
const intrinsics = @import("../intrinsics.zig");

const instant = @import("instant.zig");
const duration = @import("duration.zig");
const plain_date = @import("plain_date.zig");
const plain_time = @import("plain_time.zig");
const plain_date_time = @import("plain_date_time.zig");
const zoned_date_time = @import("zoned_date_time.zig");
const plain_year_month = @import("plain_year_month.zig");
const plain_month_day = @import("plain_month_day.zig");
const now = @import("now.zig");

var temporal_obj: ?*JsObject = null;

pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;

    try instant.register(ctx);
    try duration.register(ctx);
    try plain_date.register(ctx);
    try plain_time.register(ctx);
    try plain_date_time.register(ctx);
    try zoned_date_time.register(ctx);
    try plain_year_month.register(ctx);
    try plain_month_day.register(ctx);

    const temporal = try JsObject.create(arena, ctx.object_proto);
    temporal_obj = temporal;

    try installCtor(arena, temporal, "Instant", instant.ctor_obj);
    try installCtor(arena, temporal, "Duration", duration.ctor_obj);
    try installCtor(arena, temporal, "PlainDate", plain_date.ctor_obj);
    try installCtor(arena, temporal, "PlainTime", plain_time.ctor_obj);
    try installCtor(arena, temporal, "PlainDateTime", plain_date_time.ctor_obj);
    try installCtor(arena, temporal, "ZonedDateTime", zoned_date_time.ctor_obj);
    try installCtor(arena, temporal, "PlainYearMonth", plain_year_month.ctor_obj);
    try installCtor(arena, temporal, "PlainMonthDay", plain_month_day.ctor_obj);

    // Temporal.Now namespace (not a constructor).
    const now_ns = try now.create(ctx);
    _ = try temporal.defineOwnData("Now", try val_mod.makeObject(arena, now_ns), .{ .writable = true, .enumerable = false, .configurable = true });

    try ctx.defineGlobal("Temporal", temporal);
}

fn installCtor(arena: std.mem.Allocator, ns: *JsObject, name: []const u8, ctor: ?*JsObject) !void {
    const c = ctor orelse return;
    _ = try ns.defineOwnData(name, try val_mod.makeObject(arena, c), .{ .writable = true, .enumerable = false, .configurable = true });
}

/// After the GC migrates %Object.prototype% from the arena to the heap
/// (Realm.activateHeap), the generic reparenting pass only walks *global*
/// bindings. The Temporal per-type prototypes (Instant.prototype, …) and the
/// nested `Temporal.Now` namespace are reachable only as properties, so they are
/// missed and keep pointing at the stale arena %Object.prototype%. Reparent them
/// here so identity checks like `Object.getPrototypeOf(Temporal.Now) ===
/// Object.prototype` hold.
pub fn reparentObjectProto(old_proto: *JsObject, new_proto: *JsObject) void {
    const protos = [_]?*JsObject{
        instant.proto_obj,
        duration.proto_obj,
        plain_date.proto_obj,
        plain_time.proto_obj,
        plain_date_time.proto_obj,
        zoned_date_time.proto_obj,
        plain_year_month.proto_obj,
        plain_month_day.proto_obj,
    };
    for (protos) |maybe| {
        if (maybe) |o| {
            if (o.proto == old_proto) o.proto = new_proto;
        }
    }
    now.reparentObjectProto(old_proto, new_proto);
}

/// Wire @@toStringTag on the namespace and each prototype (run once the
/// well-known symbols exist).
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    const tag = realm_mod.active_sym_to_string_tag orelse return;
    if (temporal_obj) |t| {
        try t.setSymAttr(tag, try val_mod.makeString(arena, "Temporal"), .{ .writable = false, .enumerable = false, .configurable = true });
    }
    try instant.registerToStringTag(arena, tag);
    try duration.registerToStringTag(arena, tag);
    try plain_date.registerToStringTag(arena, tag);
    try plain_time.registerToStringTag(arena, tag);
    try plain_date_time.registerToStringTag(arena, tag);
    try zoned_date_time.registerToStringTag(arena, tag);
    try plain_year_month.registerToStringTag(arena, tag);
    try plain_month_day.registerToStringTag(arena, tag);
    try now.registerToStringTag(arena, tag);
}
