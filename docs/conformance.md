# Conformance

How jsz measures ECMAScript conformance, current standing, and how to
reproduce or extend the numbers locally.

## How we measure

jsz conformance is measured against
[test262](https://github.com/tc39/test262), the official ECMAScript
conformance suite, using the runner at `src/test/test262_runner.zig`
(`zig-out/bin/test262-runner` once built). There are two modes:

- **Curated** (default): a hand-maintained whitelist
  (`tests/test262_whitelist.txt`) of tests known to be relevant and
  ES5/ES2015+-eligible. Fast — used for day-to-day development.
- **Full** (`--full`): every test under `external/test262/test`, with real
  harness includes loaded from `external/test262/harness`. This is the
  number that maps onto public trackers like test262.fyi.

Every test runs under its own fresh `Isolate`/`Context` with a **500 ms
wall-clock deadline** and a 256 MB memory cap (`src/test/test262_runner.zig`,
`runOneTest`). A breach surfaces as a resource-limit exception and is
counted as a skip, not a fail — this keeps one pathological test from
hanging the whole run, but it also means **pass/fail counts can vary by
about ±2-4 tests between runs** on machines under load, entirely from tests
that sit close to the 500 ms boundary. Treat single-digit deltas between two
full-corpus runs as noise, not a regression, unless they reproduce with
`--filter`.

### Whitelist / known-failing files

| File | Purpose |
|---|---|
| `tests/test262_whitelist.txt` | Curated set of tests to run (supports directory globs ending in `/`) |
| `tests/test262_known_failing.txt` | Expected-fail list for the curated whitelist |
| `tests/test262_known_failing_full.txt` | Expected-fail list for the full corpus |

A test flips from pass→fail or fail→pass relative to its known-failing
entry and that flip is what CI gates on — not the raw pass count. This lets
the suite carry a stable baseline of known gaps (unimplemented staged
proposals, edge cases) without those gaps blocking every unrelated PR.

### Runner flags

```
test262-runner [--list] [--summary] [--full] [--fail-on-flips] [--strict-failures]
                [--debug-fail] [--dashboard[=path]] [--write-known-failing[=path]]
                [--filter <substr>] [--shard <i>/<n>] [--jobs <n>]
                [--progress-file <path>] [--results-file <path>] [--start-after <path>]
```

| Flag | Effect |
|---|---|
| `--full` | Run the entire corpus instead of the curated whitelist |
| `--summary` | Print per-category pass/fail buckets |
| `--fail-on-flips` | Exit 1 on any unexpected pass/fail flip vs the known-failing list (the CI gate) |
| `--strict-failures` | Exit 1 if any test fails, full stop (ignores the known-failing list) |
| `--debug-fail` | Print the failing test's source + engine output on first failure |
| `--filter <substr>` | Only run tests whose relative path contains `<substr>` — isolate one feature area |
| `--dashboard[=path]` / `--dashboard <path>` | Write a Markdown status table to `path` |
| `--write-known-failing[=path]` | Regenerate a known-failing file from the current run (reseed after intentional fixes) |
| `--shard <i>/<n>` | Run shard `i` of `n` (0-indexed) — used by the crash-resilient parallel orchestrator |
| `--jobs <n>` | Run `n` shards in parallel worker threads (`--jobs 0` picks a shard count automatically) |
| `--progress-file` / `--results-file` / `--start-after` | Crash-resume support for long full-corpus runs: the in-flight test is recorded so a hard crash names its own crasher, and a resumed run skips everything already recorded |

### Curated vs. full gates

`build.zig` wires the runner into named steps:

| Step | Runner args | Use |
|---|---|---|
| `zig build conformance` | (none) | Run the curated whitelist |
| `zig build conformance-summary` | `--summary` | Curated, with category buckets |
| `zig build conformance-delta` | `--summary --fail-on-flips` | **CI gate**: curated whitelist, fail on flips |
| `zig build conformance-dashboard` | `--summary --dashboard docs/CONFORMANCE_DASHBOARD.md` | Regenerate the curated dashboard |
| `zig build conformance-full` | `--full --dashboard docs/CONFORMANCE_FULL.md --jobs 0` | Full corpus, report the true baseline |
| `zig build conformance-full-delta` | `--full --fail-on-flips` | Full-corpus flip gate vs `tests/test262_known_failing_full.txt` |
| `zig build conformance-seed` / `conformance-full-seed` | `--write-known-failing tests/test262_known_failing*.txt` | Reseed a known-failing file after an intentional fix or a tracked regression |

## Current standing (2026-07-28)

Full-corpus run, `zig build conformance-full`:

| Metric | Value |
|---|---|
| Whitelisted (runnable) tests | 53,447 |
| Tests run | ~52,651 |
| Pass | ~52,110 |
| Pass rate of run | ~99.0% |
| Known-failing entries | 540 |

Public cross-engine comparison, [test262.fyi](https://test262.fyi) snapshot
2026-07-28:

| Engine | Score |
|---|---|
| SpiderMonkey (Firefox) | 98.28% |
| LibJS (Ladybird) | 97.89% |
| JavaScriptCore (Safari) | 97.80% |
| jsz | ~97.5% strict / ~99.0% of run |
| V8 (Chrome/Node) | parity reference |

jsz is in the same band as the four other independent engines on that
tracker. "Strict" and "of run" differ because test262.fyi's methodology
counts a wider denominator (including tests jsz's runner currently treats
as skips — see the 500 ms/256 MB note above); both numbers come from the
same underlying pass count.

Exact per-category numbers are regenerated artifacts, not hand-maintained —
see [CONFORMANCE_DASHBOARD.md](CONFORMANCE_DASHBOARD.md) (curated whitelist)
and [CONFORMANCE_FULL.md](CONFORMANCE_FULL.md) (full corpus). Regenerate
either with the `conformance-dashboard` / `conformance-full` build steps
above rather than editing them by hand.

## Reproduce locally

```sh
$ git clone --depth 1 https://github.com/tc39/test262 external/test262
$ zig build conformance-summary          # curated, ~seconds
$ zig build conformance-full             # full corpus, several minutes
```

`external/test262` is a plain shallow clone, gitignored — **not** a git
submodule, despite the vestigial `.gitmodules` entry in this repo. Don't run
`git submodule update`; a plain `git clone` into that path is sufficient and
is what CI and `build.zig`'s conformance steps expect.

To investigate one failing area:

```sh
$ zig build conformance-full -- --filter "built-ins/Array" --debug-fail
```

(`zig build <step> -- <args>` forwards `<args>` to the runner only where the
step doesn't already hardcode its own args — `conformance-full` already
passes `--full`/`--dashboard`/`--jobs`, so extra `--filter`/`--debug-fail`
flags are appended after those.)

## How the CI gates work

`.github/workflows/ci.yml` runs `zig build conformance-delta` (the curated
whitelist, flip-gated) on `ubuntu-latest` + `Debug` only — one job in the
matrix, not every OS/optimize combination, to keep CI time bounded.

`conformance-full-delta` (the full-corpus flip gate) is **not** currently
wired into the CI workflow — it's a local/manual step for before landing a
change expected to move the full-corpus baseline (a new builtin, a spec-
compliance fix touching a widely-shared code path). Run it yourself before
opening a PR that you expect to shift full-corpus numbers, and reseed with
`conformance-full-seed` if the shift is intentional.

## See also

- [CONFORMANCE_DASHBOARD.md](CONFORMANCE_DASHBOARD.md) — generated, curated whitelist
- [CONFORMANCE_FULL.md](CONFORMANCE_FULL.md) — generated, full corpus
- [CONTRIBUTING.md](../CONTRIBUTING.md) — conformance workflow as part of the PR checklist
