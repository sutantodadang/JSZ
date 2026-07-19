// SPDX-License-Identifier: Apache-2.0
//! Wave 28: Intl-backed `toLocaleString` for Temporal types.
//!
//! Provides a native helper that formats a date/time as en-US locale strings,
//! matching the default Intl.DateTimeFormat output. Since JSZ only supports
//! en-US (no ICU/CLDR), this covers the common test262 intl402 Temporal cases.
const std = @import("std");
const val_mod = @import("../../../value/value.zig");
const Value = val_mod.Value;
const js_obj = @import("../../../object/object.zig");
const realm_mod = @import("../../realm.zig");
const shared = @import("shared.zig");
const ISODate = shared.ISODate;
const ISOTime = shared.ISOTime;

/// Format a wall-clock (local) datetime as an en-US locale string using the
/// default Intl.DateTimeFormat options.
///
/// en-US defaults: `M/D/YYYY, h:mm:ss AM/PM`
/// When date-only (time fields all zero): `M/D/YYYY`
pub fn dateTimeToLocaleString(arena: std.mem.Allocator, date: ISODate, time: ISOTime) ![]const u8 {
    const is_date_only = time.hour == 0 and time.minute == 0 and time.second == 0 and time.millisecond == 0 and time.microsecond == 0 and time.nanosecond == 0;    var buf = shared.Buf{};

    if (is_date_only) {
        try std.fmt.format(buf.writer(arena), "{d}/{d}/{d}", .{ date.month, date.day, date.year });
        return buf.items;
    }

    const hour12: u8 = if (time.hour == 0 or time.hour == 12) 12 else @mod(time.hour, 12);
    const ampm = if (time.hour < 12) "AM" else "PM";
    try std.fmt.format(buf.writer(arena), "{d}/{d}/{d}, {d}:{d:0>2}:{d:0>2} {s}", .{
        date.month, date.day, date.year,
        hour12, time.minute, time.second, ampm,
    });
    return buf.items;
}
