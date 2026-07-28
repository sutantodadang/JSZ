# Contributing to jsz

## Setup

Requires Zig 0.15.2 (pinned in `build.zig.zon`).

```sh
$ git clone https://github.com/sutantodadang/JSZ jsz
$ cd jsz
$ zig build
```

## Build

```sh
zig build             # compile the CLI to zig-out/bin/jsz
zig build test        # run unit tests (module + CLI + test262-runner internals)
zig build fuzz        # run fuzz harnesses once (no coverage-guided fuzzing)
zig build fuzz --fuzz # run fuzz harnesses in real fuzzing mode
zig build differential # bc engine vs Node.js on tests/diff_corpus (requires Node.js on PATH)
zig build docs        # generate API docs into zig-out/docs/
zig build example-hello  # build + run examples/hello.zig
zig build example-embed  # build + run examples/embed.zig (host-function demo)
```

Optional experimental JIT tier (requires a Rust/cargo toolchain):

```sh
zig build -Djit=true
```

Default builds, `zig build test`, and CI need no Rust toolchain — `-Djit`
is opt-in and only affects the hot-loop JIT backend.

## Test matrix

| Command | What it covers |
|---|---|
| `zig build test` | Unit + integration tests across the module, the CLI, and the test262 runner itself |
| `zig build fuzz` / `zig build fuzz --fuzz` | Parser/VM/regex/JSON fuzz harnesses — no panics allowed on arbitrary input |
| `zig build conformance-delta` | test262 curated whitelist, fails on unexpected pass/fail flips (see [docs/conformance.md](docs/conformance.md)) |
| `zig build conformance-full-delta` | test262 full corpus, same flip gate — run manually before a change expected to shift the full-corpus baseline |
| `zig build differential` | Compares jsz's bytecode VM against Node.js on `tests/diff_corpus` |

CI (`.github/workflows/ci.yml`) runs `test`, `gc-stress`, `differential`
(ubuntu only), `example-embed`, and `conformance-delta`
(ubuntu + Debug only) across the `{ubuntu, macos, windows} x {Debug,
ReleaseSafe}` matrix, skipping OS/optimize combinations noted above for
time.

## Conformance testing (test262)

test262 is not bundled. Add it once, as a **plain shallow clone** —
`external/test262` is gitignored and is **not** a git submodule (the
`.gitmodules` entry in this repo is vestigial; ignore it):

```sh
$ git clone --depth 1 https://github.com/tc39/test262 external/test262
```

Then:

```sh
$ zig build conformance-summary   # curated whitelist, with category buckets
$ zig build conformance-delta     # same, fails CI on unexpected pass/fail flips
```

Whitelist: `tests/test262_whitelist.txt`. Expected failures:
`tests/test262_known_failing.txt` (curated) /
`tests/test262_known_failing_full.txt` (full corpus). If a change
intentionally fixes or regresses a known-failing test, reseed:

```sh
$ zig build conformance-seed        # curated
$ zig build conformance-full-seed   # full corpus
```

then include the updated `tests/test262_known_failing*.txt` in your PR
alongside an explanation of what moved and why. See
[docs/conformance.md](docs/conformance.md) for the full runner-flag
reference, gate details, and current pass-rate standing.

## Code style

- `zig fmt src/` — no formatting diffs before committing.
- At least one `test` block per file that has non-trivial logic.
- New public API functions get `///` doc comments.
- No external dependencies — pure Zig standard library only (the optional
  `-Djit` Cranelift backend is the one exception, and it is off by default).

## Adding a builtin

See [docs/CONTRIBUTING/adding-a-builtin.md](docs/CONTRIBUTING/adding-a-builtin.md).
That document is a scaffold — some steps are still marked TODO pending the
`tools/new-builtin.zig` codegen; until then, copy an existing builtin under
`src/runtime/builtins/` as a starting point.

## Pull requests

Checklist (also in `.github/PULL_REQUEST_TEMPLATE.md`):

- [ ] `zig build test` passes
- [ ] `zig fmt src/` — no formatting diffs
- [ ] CHANGELOG entry added to `[Unreleased]`
- [ ] New public API has `///` doc comments
- [ ] `zig build conformance-delta` is clean, or the PR explains and reseeds
      the expected flip
- [ ] No obvious algorithmic regression (e.g. an accidental O(n²) on a hot
      path), or it's justified in the PR description

## License

By contributing, you agree your contributions are licensed under the Apache
License, Version 2.0 (inbound = outbound). See [LICENSE](LICENSE).
