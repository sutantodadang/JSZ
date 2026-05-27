# Contributing to jsz

## Setup

Requires Zig 0.15.2 (pinned in `build.zig.zon`).

```sh
git clone https://github.com/your-handle/jsz
cd jsz
zig build
```

## Build

```sh
zig build             # compile CLI
zig build test        # run unit tests
zig build fuzz        # run fuzz harnesses (no coverage mode)
zig build fuzz --fuzz # run fuzz harnesses in fuzzing mode
zig build docs        # generate API docs to zig-out/docs/
```

## Conformance testing (Test262)

Test262 is not bundled. Add it manually once:

```sh
git submodule add https://github.com/tc39/test262 external/test262
git submodule update --init --recursive
```

Then run:

```sh
zig build conformance-summary
zig build conformance-delta
```

Whitelist lives in `tests/test262_whitelist.txt`.
Expected failures live in `tests/test262_known_failing.txt`.
`zig build conformance-delta` fails CI on unexpected pass/fail flips.

## Differential testing

Requires Node.js on PATH.

```sh
zig build differential
```

## Code style

- Zig fmt: `zig fmt src/` before committing.
- One `test` block per file minimum.
- New public API functions must have `///` doc comments.
- No external dependencies — pure Zig stdlib only.

## Adding a new builtin

See [docs/CONTRIBUTING/adding-a-builtin.md](docs/CONTRIBUTING/adding-a-builtin.md).

## Pull requests

- Fill out the PR template (conformance delta, CHANGELOG entry).
- All tests must pass: `zig build test`.
- No conformance flip regressions: `zig build conformance-delta`.

## Pre-commit checklist

- `zig fmt src/` — no format diffs
- `zig build test` — all green
- CHANGELOG entry in `[Unreleased]`

## License

By contributing, you agree your contributions are licensed under MIT.
