// SPDX-License-Identifier: Apache-2.0
//! Wave 45c: Temporal non-ISO calendar integration tests.
//!
//! These pin the behaviour that the pure-Zig unit tests in
//! runtime/builtins/temporal/calendar.zig cannot reach: the JS-visible
//! projection (field getters, from/with/add) once a calendar is threaded
//! through a Temporal object. Expected values were cross-checked against ICU
//! via Node's Intl.DateTimeFormat.
const helpers = @import("helpers.zig");
const std = helpers.std;
const dualString = helpers.dualString;

fn expectEval(source: []const u8, expected: []const u8) !void {
    const s = try dualString(std.testing.allocator, source);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "temporal calendar: gregorian-family fields and eras" {
    try expectEval(
        \\var d = Temporal.PlainDate.from({year: 2564, monthCode: "M07", day: 16, calendar: "buddhist"});
        \\[d.year, d.month, d.monthCode, d.day, d.era, d.eraYear, d.toString()].join("|")
    , "2564|7|M07|16|be|2564|2021-07-16[u-ca=buddhist]");
}

test "temporal calendar: japanese era boundary re-derives the containing era" {
    // Reiwa began 2019-05-01, so Reiwa 1 on 30 April is really Heisei 31.
    try expectEval(
        \\var d = Temporal.PlainDate.from({era: "reiwa", eraYear: 1, monthCode: "M04", day: 30,
        \\  calendar: "japanese"}, {overflow: "reject"});
        \\[d.year, d.era, d.eraYear].join("|")
    , "2019|heisei|31");
}

test "temporal calendar: arithmetic calendars agree with ICU" {
    try expectEval(
        \\var iso = Temporal.PlainDate.from("2021-07-16");
        \\["coptic", "ethiopic", "islamic-civil", "islamic-tbla", "persian", "indian", "hebrew"]
        \\  .map(function (c) { var d = iso.withCalendar(c); return d.year + "/" + d.month + "/" + d.day; })
        \\  .join(" ")
    , "1737/11/9 2013/11/9 1442/12/6 1442/12/7 1400/4/25 1943/4/25 5781/11/7");
}

test "temporal calendar: hebrew leap month gets the M05L code" {
    // 5784 is a leap year: Adar I sits at ordinal 6 and pushes Adar II to 7.
    try expectEval(
        \\var d = Temporal.PlainDate.from({year: 5784, monthCode: "M05L", day: 1, calendar: "hebrew"});
        \\[d.month, d.monthCode, d.monthsInYear, d.inLeapYear, d.toString()].join("|")
    , "6|M05L|13|true|2024-02-10[u-ca=hebrew]");
}

test "temporal calendar: adding a month lands on the calendar month, not the ISO one" {
    // Regression: the month-addition anchor took the ISO *month's* day 1 rather
    // than the anchor's own ISO day, so every non-Gregorian calendar landed up
    // to 30 days early. Adar I 1 + 1 month is Adar II 1 = 2024-03-11.
    try expectEval(
        \\var d = Temporal.PlainDate.from({year: 5784, monthCode: "M05L", day: 1, calendar: "hebrew"});
        \\var n = d.add({months: 1});
        \\[n.toString(), n.monthCode].join("|")
    , "2024-03-11[u-ca=hebrew]|M06");
}

test "temporal calendar: add/subtract round-trips in a non-Gregorian calendar" {
    try expectEval(
        \\var d = Temporal.PlainDate.from({year: 1400, month: 4, day: 25, calendar: "persian"});
        \\d.add({months: 5}).subtract({months: 5}).toString()
    , "2021-07-16[u-ca=persian]");
}

test "temporal calendar: month-day reference date walks back to a year that has it" {
    // An Islamic month 12 with 30 days needs a leap year; 1971-02-26 is
    // islamic-civil 1390-12-30 (confirmed against ICU).
    try expectEval(
        \\var md = Temporal.PlainMonthDay.from({monthCode: "M12", day: 30, calendar: "islamic-civil"});
        \\[md.monthCode, md.day, md.toString()].join("|")
    , "M12|30|1971-02-26[u-ca=islamic-civil]");
}

test "temporal calendar: the ISO calendar is unchanged" {
    // era/eraYear are undefined for iso8601, which `join` renders as empty.
    try expectEval(
        \\var d = Temporal.PlainDate.from("2021-07-16");
        \\[d.year, d.month, d.monthCode, d.day, d.era, d.eraYear, d.calendarId, d.toString()].join("|")
    , "2021|7|M07|16|||iso8601|2021-07-16");
}

test "temporal calendar: calendar survives conversions between Temporal types" {
    try expectEval(
        \\var z = Temporal.ZonedDateTime.from({year: 2564, monthCode: "M07", day: 16,
        \\  timeZone: "UTC", calendar: "buddhist"});
        \\[z.calendarId, z.toPlainDate().calendarId, z.toPlainDateTime().calendarId,
        \\ z.startOfDay().calendarId, z.toPlainDate().year].join("|")
    , "buddhist|buddhist|buddhist|buddhist|2564");
}
