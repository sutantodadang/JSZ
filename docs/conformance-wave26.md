# Wave 26 — Temporal Part 2: ZonedDateTime, Temporal.Now, string time zones

## Objective

Wave 25 shipped the five zone-free Temporal value types. This wave adds the
time-zone-aware layer — the single largest remaining Temporal target — plus the
`Temporal.Now` clock namespace.

**Important spec-version correction.** The wave brief was written against an older
Temporal proposal in which `Temporal.TimeZone` and `Temporal.Calendar` were
exotic *objects*. The vendored test262 corpus targets the **current** proposal,
where those types were **removed** — time zones and calendars are plain **string
identifiers**. The staging suite even asserts `!("TimeZone" in Temporal)` and
`!("Calendar" in Temporal)`. Implementing them as globals would have *regressed*
the suite, so we deliberately did **not** create `Temporal.TimeZone` /
`Temporal.Calendar`. Instead, time-zone identifiers are parsed/normalized as
strings and the ISO-8601 calendar remains the only calendar (`calendarId` is
always `"iso8601"`), consistent with the Wave 25 value types.

## What shipped

- **`Temporal.ZonedDateTime`** — `(epochNanoseconds: BigInt, timeZone: string,
  calendar?: string)`. Storage: `internal_kind = .temporal_zoned_date_time`,
  slot → `ZonedDT { ns: i128, tz: []const u8, offset_ns: i128 }`.
  - All accessors: `year…nanosecond`, `monthCode`, `epochMilliseconds`,
    `epochNanoseconds`, `offset`, `offsetNanoseconds`, `timeZoneId`,
    `calendarId`, `dayOfWeek/dayOfYear/weekOfYear/yearOfWeek`,
    `daysInWeek/Month/Year`, `monthsInYear`, `inLeapYear`, `hoursInDay`.
  - Methods: `with`, `withPlainTime`, `withTimeZone`, `withCalendar`, `add`,
    `subtract`, `until`, `since`, `equals`, `round`, `startOfDay`,
    `getTimeZoneTransition`, `toInstant`, `toPlainDate/Time/DateTime`,
    `toString/toJSON/toLocaleString`, `valueOf` (throws), and static
    `from`/`compare`.
- **`Temporal.Now`** — `instant`, `timeZoneId`, `zonedDateTimeISO`,
  `plainDateISO`, `plainDateTimeISO`, `plainTimeISO`. Clock is
  `std.time.nanoTimestamp()`; the host zone is reported as `"UTC"` (single source
  of truth so `timeZoneId()` and the `*ISO` defaults agree).
- **`toZonedDateTime` builders on Wave 25 types** (they *produce* the new type, a
  natural Wave 26 extension rather than a change to existing behavior):
  `Instant.prototype.toZonedDateTimeISO` (was a Wave 26 stub),
  `PlainDateTime.prototype.toZonedDateTime`,
  `PlainDate.prototype.toZonedDateTime`.

New files: `timezone.zig` (identifier parsing/normalization + offset formatting),
`zoned_date_time.zig`, `now.zig`. `temporal.zig` registers `ZonedDateTime` and the
`Now` namespace; one new `object.zig` `internal_kind` variant (appended at the
tail).

### Time-zone model

Only **fixed-offset** zones are modeled: `"UTC"` (case-insensitive → canonical
`"UTC"`) and numeric offsets `±HH`, `±HHMM`, `±HH:MM` (normalized to `±HH:MM`).
This covers the corpus, which uses `"UTC"` (555×) and offset zones almost
exclusively; named IANA zones with DST are essentially absent from the built-in
tests (they live in `intl402`, deferred to Wave 27). Consequences of fixed
offsets: every day is 24h (`hoursInDay === 24`), there are no transitions
(`getTimeZoneTransition` → `null`), and `disambiguation` is a no-op (validated,
then ignored).

Identifier parsing follows `ParseTimeZoneIdentifier`: a bare `"UTC"`/offset, or a
datetime string whose id comes from its `[tz]` bracket, else its trailing
`Z`/offset. Sub-minute offsets are valid *offsets* but **not** valid time-zone
*identifiers*; the Unicode minus U+2212 is accepted in an ISO offset field but
**not** in an identifier/annotation; a second `[tz]` annotation, a non-ISO
`[u-ca=…]`, and a negative-zero extended year are all rejected even when a valid
bracket is present.

## Cross-cutting engine fixes (help all Temporal types, not just this wave)

1. **Template-literal `ToString` hint.** `` `${x}` `` was desugared to `"" + (x)`,
   which uses the `+` operator's *default-hint* `ToPrimitive` (valueOf first).
   The spec requires `ToString` (string hint: toString first, TypeError for
   Symbols). Every Temporal type defines a throwing `valueOf`, so `` `${zdt}` ``
   threw instead of formatting. Fixed in `isolate.zig` by desugaring each
   substitution to `"".concat((x))` — exactly `ToString` per argument (toString
   for objects, `TypeError` for Symbols). More spec-compliant in general
   (`` `${ {valueOf:()=>99, toString:()=>"TS"} }` `` is now `"TS"`, not `"99"`).
2. **`skipOffset` in `shared.zig`** now accepts compact `±HHMMSS` offsets and
   comma fractions, so valid ISO strings like `1970-01-01T00+000000,0[UTC]` parse
   (previously rejected).
3. **`getOptionsObject`** now accepts callables (functions are Objects per
   `GetOptionsObject`); a bare function resolves to empty options instead of
   throwing `TypeError`.
4. **Negative-zero normalization** in ZonedDateTime `until`/`since` duration
   fields (`SameValue(-0, 0)` is `false`).

## Results

Verification (all green):
- `zig build test` — 0 failures
- `zig build differential` — 167/167
- curated conformance — 1278/1278 (no regression)

Temporal conformance (test262, `--full`):
- `built-ins/Temporal/ZonedDateTime`: ~0 → **638/898 (71%)**
- `built-ins/Temporal/Now`: **61/66 (92%)**
- new builder dirs: `PlainDateTime…/toZonedDateTime` 22/35,
  `PlainDate…/toZonedDateTime` 26/48, `Instant…/toZonedDateTimeISO` 17/19
- all `built-ins/Temporal`: **~1,588/2,806 (57%)** and climbing (measured before
  fixes #3/#4 landed; ZonedDateTime alone moved +638)

## Known gaps / deferred to Wave 27

- **`intl402/Temporal` (~570 ZonedDateTime failures)** — Intl-backed
  `toLocaleString` and **named IANA zones with DST** (offset depends on the
  instant; needs a tz database + transition search). This is the dominant
  remaining bucket.
- **Nested-namespace prototype identity** — `Object.getPrototypeOf(Temporal.Now)`
  (and every `X.prototype`'s `[[Prototype]]`) is a bootstrap `Object.prototype`,
  not the realm's final global `Object.prototype`. This is a **pre-existing Wave
  25 infra gap** (already true for `Instant.prototype` etc.), affecting the
  `builtin.js`-style tests uniformly; not addressed here.
- **Options `order-of-operations`** — callable options resolve to empty rather
  than having their properties observably read.
- Sub-minute-offset toString formatting, some `argument-string-*` limit edges,
  and `era`/`eraYear` (non-ISO-calendar) accessors.
