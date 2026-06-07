// Phase 13: the `u` (unicode) flag is accepted (ASCII/BMP matching).
[/\d+/u.test("123"), /abc/u.test("xabcx"), /a.c/u.test("abc")].join(",")
