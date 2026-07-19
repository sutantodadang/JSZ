# Wave 25 — Temporal Core (Instant, Duration, PlainDate, PlainTime, PlainDateTime)

## Objective

Temporal accounted for ~6,642 of the corpus's ~14,436 failures (46%). This wave
implements the five foundational Temporal *value types* — the ones that carry no
time-zone or `Temporal.Now` dependency — end to end:

- `Temporal.Instant` — absolute time, i128 epoch nanoseconds
- `Temporal.Duration` — signed 10-field calendar+time span
- `Temporal.PlainDate` — ISO calendar date
- `Temporal.PlainTime` — nanosecond wall-clock time
- `Temporal.PlainDateTime` — date + time (no zone)

ZonedDateTime, PlainYearMonth, PlainMonthDay, TimeZone, Calendar, and
`Temporal.Now` are deferred to Wave 26.

## Architecture

New directory `src/runtime/builtins/temporal/`:

| File | Contents |
|---|---|
| `shared.zig` | ISO calendar math (Hinnant days↔civil), ISO-8601 parsing (date/time/datetime/duration/instant), rounding (9 modes, f64 + i128), unit tables, option reading, `BigInt`↔`i128`, string builders |
| `instant.zig` | `Temporal.Instant` (i128 slot) |
| `duration.zig` | `Temporal.Duration` (`DurationFields` slot) |
| `plain_date.zig` | `Temporal.PlainDate` (`ISODate` slot) |
| `plain_time.zig` | `Temporal.PlainTime` (`ISOTime` slot) |
| `plain_date_time.zig` | `Temporal.PlainDateTime` (`ISODateTime` slot) |
| `temporal.zig` | assembles the `Temporal` namespace + `@@toStringTag` wiring |

Each type follows the existing builtin convention: a per-type `internal_kind`
(five new enum variants in `object/object.zig`), a heap-or-arena internal slot,
and `register(ctx)` / `registerToStringTag(arena, tag)` entry points called from
`realm.zig` (alongside `date_mod`).

### Design choices

- **Storage.** Instant stores raw `i128` nanoseconds; Duration stores ten `f64`
  fields (validated integral, same-sign, `|f| < 2^53`); Plain* store packed ISO
  records. All slot reads brand-check `internal_kind`.
- **Calendar.** ISO-8601 only. `calendarId` is always `"iso8601"`; a non-ISO
  calendar argument is a RangeError.
- **Arithmetic.** Date add/subtract balances y/m (constrain/reject overflow) then
  epoch-day offsets; DateTime carries the time part into days first. Difference
  (`until`/`since`) uses the standard "compute in the *until* direction, sign the
  result" approach; calendar `until` walks months then splits into years.
- **Rounding.** `roundI128ToIncrement` implements all nine rounding modes at
  nanosecond precision for time units. Calendar-unit rounding that needs a
  `relativeTo` reference point is intentionally left partial (Wave 26).
- **Overflow safety.** All add/round paths do their intermediate arithmetic in
  `i128` with explicit range gates, so out-of-range inputs surface as RangeError
  rather than an integer-cast panic.

## Method surface (implemented)

- **Instant:** `from`, `fromEpochSeconds/Milliseconds/Microseconds/Nanoseconds`,
  `compare`; `epochSeconds/Milliseconds/Microseconds/Nanoseconds`, `add`,
  `subtract`, `until`, `since`, `round`, `equals`, `toString`, `toJSON`,
  `toLocaleString`, `valueOf` (throws). `toZonedDateTimeISO` stubs to a
  TypeError (Wave 26).
- **Duration:** `from`, `compare`; `with`, `negated`, `abs`, `add`, `subtract`,
  `round`, `total`, `toString`, `toJSON`, `toLocaleString`, `valueOf` (throws),
  `sign`, `blank`, ten field getters.
- **PlainDate:** `from`, `compare`; `with`, `add`, `subtract`, `until`, `since`,
  `equals`, `toPlainDateTime`, `toString/toJSON/toLocaleString`, `valueOf`
  (throws), and the full accessor set (`year`…`inLeapYear`, `calendarId`).
- **PlainTime:** `from`, `compare`; `with`, `add`, `subtract`, `until`, `since`,
  `round`, `equals`, `toPlainDateTime`, `toString/toJSON/toLocaleString`,
  `valueOf` (throws), six accessors.
- **PlainDateTime:** `from`, `compare`; `with`, `withPlainTime`, `add`,
  `subtract`, `until`, `since`, `round`, `equals`, `toPlainDate`, `toPlainTime`,
  `toString/toJSON/toLocaleString`, `valueOf` (throws), full date+time accessors.

## Known gaps (→ Wave 26+)

- `relativeTo`-dependent Duration `round`/`total`/`add` with calendar units.
- Calendar-unit rounding in `until`/`since` (day/time rounding works).
- `toZonedDateTime`, `PlainYearMonth`/`PlainMonthDay` conversions.
- Non-ISO calendars; `Temporal.Now`.

## Verification

- `zig build test` — pass (0 failures)
- `zig build differential` — 167/167
- `zig build` (curated runner) — 1278/1278 (no regression)
- Temporal subtree (`--full --filter built-ins/Temporal`): see PR description.

Several overflow-panic bugs surfaced during the full-subtree run and were fixed:
combined sub-second seconds formatting in Duration; f64→i128 epoch gates in
Instant; i128 day/year gates in `addISODate`; i128-wide time balancing.
