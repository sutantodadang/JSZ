// SPDX-License-Identifier: Apache-2.0
//! Wave 56c: `timeZoneName` display names for `Intl.DateTimeFormat`.
//!
//! CLDR names time zones through *metazones* — "Central European Standard Time"
//! covers Vienna, Berlin, Paris and a dozen more — so this table maps the IANA
//! identifiers to their metazone rather than naming each zone separately. A zone
//! with no entry falls back to its GMT offset, which is what CLDR itself does.
const std = @import("std");

pub const Metazone = struct {
    /// `timeZoneName: "long"`, standard and daylight variants.
    long_std: []const u8,
    long_dst: []const u8,
    /// `timeZoneName: "short"`. Only the Americas have real abbreviations in
    /// `en`; elsewhere CLDR falls back to the GMT offset, spelled "" here.
    short_std: []const u8 = "",
    short_dst: []const u8 = "",
};

const Entry = struct { zones: []const []const u8, mz: Metazone };

const table = [_]Entry{
    .{
        .zones = &.{ "Europe/Vienna", "Europe/Berlin", "Europe/Paris", "Europe/Madrid", "Europe/Rome", "Europe/Amsterdam", "Europe/Brussels", "Europe/Prague", "Europe/Warsaw", "Europe/Stockholm", "Europe/Oslo", "Europe/Copenhagen", "Europe/Budapest", "Europe/Zurich", "Europe/Luxembourg", "Europe/Monaco", "Europe/Ljubljana", "Europe/Bratislava", "Europe/Zagreb", "Europe/Belgrade", "Europe/Sarajevo", "Europe/Skopje", "Europe/Podgorica", "Europe/Tirane", "Europe/Malta", "Europe/Gibraltar", "Europe/Andorra", "Europe/San_Marino", "Europe/Vatican", "Arctic/Longyearbyen", "Europe/Busingen", "Europe/Vaduz" },
        .mz = .{ .long_std = "Central European Standard Time", .long_dst = "Central European Summer Time" },
    },
    .{
        .zones = &.{ "Europe/Athens", "Europe/Helsinki", "Europe/Bucharest", "Europe/Sofia", "Europe/Riga", "Europe/Tallinn", "Europe/Vilnius", "Europe/Kiev", "Europe/Kyiv", "Europe/Chisinau", "Europe/Nicosia", "Asia/Nicosia", "Europe/Mariehamn", "Europe/Uzhgorod", "Europe/Zaporozhye" },
        .mz = .{ .long_std = "Eastern European Standard Time", .long_dst = "Eastern European Summer Time" },
    },
    .{
        .zones = &.{ "Europe/London", "Europe/Belfast", "Europe/Guernsey", "Europe/Isle_of_Man", "Europe/Jersey" },
        .mz = .{ .long_std = "Greenwich Mean Time", .long_dst = "British Summer Time", .short_std = "GMT", .short_dst = "GMT+1" },
    },
    .{
        .zones = &.{ "Europe/Dublin" },
        .mz = .{ .long_std = "Greenwich Mean Time", .long_dst = "Irish Standard Time", .short_std = "GMT", .short_dst = "GMT+1" },
    },
    .{
        .zones = &.{ "Europe/Lisbon", "Atlantic/Canary", "Atlantic/Faroe", "Atlantic/Madeira" },
        .mz = .{ .long_std = "Western European Standard Time", .long_dst = "Western European Summer Time" },
    },
    .{
        .zones = &.{ "America/New_York", "America/Detroit", "America/Toronto", "America/Montreal", "America/Kentucky/Louisville", "America/Kentucky/Monticello", "America/Indiana/Indianapolis", "America/Nassau", "America/Iqaluit", "America/Nipigon", "America/Thunder_Bay", "America/Pangnirtung" },
        .mz = .{ .long_std = "Eastern Standard Time", .long_dst = "Eastern Daylight Time", .short_std = "EST", .short_dst = "EDT" },
    },
    .{
        .zones = &.{ "America/Chicago", "America/Winnipeg", "America/Mexico_City", "America/Indiana/Knox", "America/Menominee", "America/North_Dakota/Center", "America/Rainy_River", "America/Matamoros", "America/Monterrey" },
        .mz = .{ .long_std = "Central Standard Time", .long_dst = "Central Daylight Time", .short_std = "CST", .short_dst = "CDT" },
    },
    .{
        .zones = &.{ "America/Denver", "America/Edmonton", "America/Boise", "America/Cambridge_Bay", "America/Inuvik", "America/Yellowknife", "America/Chihuahua", "America/Ojinaga" },
        .mz = .{ .long_std = "Mountain Standard Time", .long_dst = "Mountain Daylight Time", .short_std = "MST", .short_dst = "MDT" },
    },
    .{
        .zones = &.{ "America/Phoenix", "America/Creston", "America/Dawson_Creek", "America/Fort_Nelson", "America/Hermosillo" },
        .mz = .{ .long_std = "Mountain Standard Time", .long_dst = "Mountain Daylight Time", .short_std = "MST", .short_dst = "MDT" },
    },
    .{
        .zones = &.{ "America/Los_Angeles", "America/Vancouver", "America/Tijuana", "America/Dawson", "America/Whitehorse" },
        .mz = .{ .long_std = "Pacific Standard Time", .long_dst = "Pacific Daylight Time", .short_std = "PST", .short_dst = "PDT" },
    },
    .{
        .zones = &.{ "America/Anchorage", "America/Juneau", "America/Nome", "America/Sitka", "America/Yakutat", "America/Metlakatla" },
        .mz = .{ .long_std = "Alaska Standard Time", .long_dst = "Alaska Daylight Time", .short_std = "AKST", .short_dst = "AKDT" },
    },
    .{
        .zones = &.{ "Pacific/Honolulu" },
        .mz = .{ .long_std = "Hawaii-Aleutian Standard Time", .long_dst = "Hawaii-Aleutian Daylight Time", .short_std = "HST", .short_dst = "HDT" },
    },
    .{
        .zones = &.{ "America/Halifax", "America/Moncton", "America/Glace_Bay", "America/Goose_Bay", "Atlantic/Bermuda" },
        .mz = .{ .long_std = "Atlantic Standard Time", .long_dst = "Atlantic Daylight Time", .short_std = "AST", .short_dst = "ADT" },
    },
    .{
        .zones = &.{ "America/St_Johns" },
        .mz = .{ .long_std = "Newfoundland Standard Time", .long_dst = "Newfoundland Daylight Time", .short_std = "NST", .short_dst = "NDT" },
    },
    .{
        .zones = &.{ "Asia/Tokyo" },
        .mz = .{ .long_std = "Japan Standard Time", .long_dst = "Japan Daylight Time" },
    },
    .{
        .zones = &.{ "Asia/Seoul", "Asia/Pyongyang" },
        .mz = .{ .long_std = "Korean Standard Time", .long_dst = "Korean Daylight Time" },
    },
    .{
        .zones = &.{ "Asia/Shanghai", "Asia/Chongqing", "Asia/Harbin", "Asia/Macau", "Asia/Hong_Kong", "Asia/Taipei" },
        .mz = .{ .long_std = "China Standard Time", .long_dst = "China Daylight Time" },
    },
    .{
        .zones = &.{ "Asia/Kolkata", "Asia/Calcutta" },
        .mz = .{ .long_std = "India Standard Time", .long_dst = "India Standard Time" },
    },
    .{
        .zones = &.{ "Australia/Sydney", "Australia/Melbourne", "Australia/Canberra", "Australia/Hobart" },
        .mz = .{ .long_std = "Australian Eastern Standard Time", .long_dst = "Australian Eastern Daylight Time" },
    },
    .{
        .zones = &.{ "Europe/Moscow", "Europe/Simferopol", "Europe/Kirov" },
        .mz = .{ .long_std = "Moscow Standard Time", .long_dst = "Moscow Summer Time" },
    },
};

/// The metazone `tz_id` belongs to, or null when the zone has no CLDR name and
/// must fall back to its GMT offset.
pub fn lookup(tz_id: []const u8) ?Metazone {
    for (table) |e| {
        for (e.zones) |z| {
            if (std.mem.eql(u8, z, tz_id)) return e.mz;
        }
    }
    return null;
}

/// The GMT-offset fallback name: "GMT" at zero, else "GMT+5" / "GMT-3:30" —
/// hours unpadded, minutes present only when non-zero (CLDR's `gmtFormat` with
/// the short `hourFormat`).
pub fn gmtOffsetName(arena: std.mem.Allocator, offset_ms: i64) ![]const u8 {
    if (offset_ms == 0) return "GMT";
    const neg = offset_ms < 0;
    const total_min = @divTrunc(if (neg) -offset_ms else offset_ms, 60_000);
    const h = @divTrunc(total_min, 60);
    const m = @mod(total_min, 60);
    if (m == 0) return std.fmt.allocPrint(arena, "GMT{c}{d}", .{ @as(u8, if (neg) '-' else '+'), h });
    return std.fmt.allocPrint(arena, "GMT{c}{d}:{d:0>2}", .{ @as(u8, if (neg) '-' else '+'), h, m });
}
