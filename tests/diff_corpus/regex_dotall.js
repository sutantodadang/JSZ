// Phase 13: the `s` (dotAll) flag — `.` matches line terminators.
[/a.b/.test("a\nb"), /a.b/s.test("a\nb"), /a.b/s.test("axb")].join(",")
