# Building and Testing jsz

Reference for `build.zig`: build steps, options, and the test262 conformance
workflow. For the embedding API see [api.md](api.md); for the CLI see
[cli.md](cli.md); for engine internals see [architecture.md](architecture.md).

## Requirements

- Zig **0.15.2** or newer (`build.zig.zon` `minimum_zig_version`).
- Pure Zig stdlib, zero runtime dependencies for the default build.
- Optional: `cargo` (Rust toolchain) only if building with `-Djit=true`.
- Optional: `node` on PATH only for `zig build differential`.

---

## Build steps

Run any step with `zig build <step>`. List them all with `zig build --help`.

| Step | What it does |
|---|---|
| `run` | Build and run the `jsz` CLI (`zig build run -- [args]` forwards args after `--`). |
| `test` | Run all unit tests: the `jsz` module tests (`src/root.zig` and everything it imports), the CLI's own tests (`src/main.zig`, e.g. `parseArgs` cases), and the test262-runner's unit tests (`src/test/test262_runner.zig`). |
| `fuzz` | Run the fuzz harnesses (parser, VM, regex, JSON) as regular tests; add `--fuzz` to run them in actual fuzzing mode. |
| `conformance` | Run the Test262 conformance suite against the curated whitelist (`tests/test262_known_failing.txt` governs expected failures). |
| `conformance-summary` | Same as `conformance`, plus a per-category pass/fail summary. |
| `conformance-delta` | Same as `conformance-summary`, plus `--fail-on-flips`: fails the build if any test unexpectedly flips relative to the known-failing whitelist. |
| `conformance-dashboard` | Runs with `--summary --dashboard docs/CONFORMANCE_DASHBOARD.md` — regenerates that file from the current whitelist results. |
| `conformance-full` | Walks the **entire** `external/test262/test` corpus (not just the whitelist), loads real harness includes, and reports the true baseline. Runs with `--full --dashboard docs/CONFORMANCE_FULL.md --jobs 0` (`--jobs 0` autodetects CPU count and runs a parallel crash-resume wrapper). |
| `conformance-full-delta` | Full-corpus CI gate: `--full --fail-on-flips`, fails on any pass/fail flip vs `tests/test262_known_failing_full.txt`. |
| `conformance-full-seed` | Regenerates `tests/test262_known_failing_full.txt` from the current full-corpus results (`--full --write-known-failing <path>`). Run after intentionally fixing or accepting new failures. |
| `conformance-seed` | Same, but for the curated whitelist: regenerates `tests/test262_known_failing.txt`. |
| `differential` | Run the Node.js differential harness (`src/test/differential.zig`): evaluates the same source in jsz and in `node -e`, and diffs the results. **Requires `node` on PATH** — skips with a message if not found. |
| `example-hello` | Build and run `examples/hello.zig` (minimal embedding example). |
| `example-embed` | Build and run `examples/embed.zig` (fuller embedding API demo: host functions, GC, limits). |
| `docs` | Generate Zig autodoc HTML into `zig-out/docs/` from `src/root.zig`'s doc comments (via `-femit-docs` on the module's test artifact). |
| `bench` | Run the `fib(20)` and Phase 6 shape/IC benchmarks (`bench/fib20.zig`, `bench/phase6_ic.zig`), built `ReleaseFast` regardless of the outer optimize flag. |
| `bench-phase6` | Run only the Phase 6 shape/IC benchmark. |
| `gc-stress` | Run the GC stress test (`bench/gc_stress.zig`). |
| `gc-bench` | Run the M19 generational-vs-mark-sweep GC benchmark (`bench/gc_bench.zig`). |
| `jit` | Run the Phase 9 JIT module's own tests (`src/jit/mod.zig`) — a scaffold, not linked into the `jsz` CLI. |
| `jit-native` | Build the Cranelift native backend (`jit-native/`, via `cargo build --release`), link its import lib, and run its FFI tests. Not linked into the main CLI by this step alone — that requires `-Djit=true` on the relevant step. |

`zig build` alone (no step) runs the default step, which builds and installs
the `jsz` executable to `zig-out/bin/`.

---

## Build options

| Option | Type | Default | Effect |
|---|---|---|---|
| `-Djit` | `bool` | `false` | Link the Cranelift native JIT backend (`jit-native/`, a Rust cdylib) into the CLI and every artifact that embeds the `jsz` module, so the experimental hot-loop JIT (`--jit=experimental`, see [cli.md](cli.md#--jitoffcountexperimental)) compiles and runs native code instead of only profiling. Requires `cargo` on PATH — `zig build` runs `cargo build --release --manifest-path jit-native/Cargo.toml` as a dependency step. Default builds, tests, and CI need **no** Rust toolchain: the native JIT reference is a `comptime` gate (`build_options.jit_enabled`) that compiles out entirely when `false`. |

```
zig build -Djit=true
zig build test -Djit=true
zig build conformance-full -Djit=true
```

Standard Zig options also apply: `-Dtarget=<triple>` for cross-compilation
and `-Doptimize=<mode>` (`Debug` / `ReleaseSafe` / `ReleaseFast` /
`ReleaseSmall`; some steps like `bench` and `gc-bench` hardcode
`ReleaseFast`/inherit the outer optimize mode respectively — see the table
above).

### Cross-compilation

Standard Zig cross-compilation works out of the box, e.g.:

```
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-linux-gnu
```

Note: `-Djit=true` links a platform-specific prebuilt Rust cdylib
(`jit-native/target/release/`) built for the **host** target by `cargo`; it
is not itself cross-compiled by this build graph. Cross-compiled builds
should omit `-Djit=true` unless you separately cross-build the Rust cdylib.

---

## Test262 corpus setup

`external/test262` is a **plain git clone**, not a git submodule, and it is
gitignored (`.gitignore`: `external/test262/`). Clone it yourself before
running any `conformance*` step:

```
git clone --depth 1 https://github.com/tc39/test262.git external/test262
```

If you have previously seen instructions referring to a git submodule for
`external/test262`, they are stale — there is no `.gitmodules` entry for it
in this repository; a shallow clone is sufficient and faster.

---

## Conformance workflow

jsz tracks two Test262 views:

1. **Curated whitelist** (`tests/test262_known_failing.txt`) — a fixed subset
   of tests, run by `conformance`/`conformance-summary`/`conformance-delta`.
   Used as a fast, deterministic CI gate.
2. **Full corpus** (`external/test262/test`, ~53k tests) — run by
   `conformance-full`/`conformance-full-delta`. Slower, but reports the true
   pass rate (jsz measures ~99.0% of run tests as of 2026-07-28, near V8
   parity per [test262.fyi](https://test262.fyi/)).

Typical loop:

```
# Fast local check against the curated whitelist:
zig build conformance-summary

# Fail the build on any regression vs the whitelist:
zig build conformance-delta

# After intentionally fixing (or accepting) failures, refresh the whitelist:
zig build conformance-seed

# Full-corpus baseline (slow; parallel via --jobs 0):
zig build conformance-full

# Full-corpus CI gate:
zig build conformance-full-delta

# Refresh the full-corpus known-failing list after intentional changes:
zig build conformance-full-seed
```

The underlying binary is `test262-runner` (installed to
`zig-out/bin/test262-runner` — a stable path, unlike the content-hashed cache
path, so a resume wrapper can re-invoke it after a crash). Useful flags when
invoking it directly (`zig-out/bin/test262-runner <flags>`):

| Flag | Effect |
|---|---|
| `--full` | Run the entire corpus instead of the curated whitelist. Implies `--summary`; defaults `--fail-on-flips` off. |
| `--summary` | Print a per-category pass/fail summary. |
| `--fail-on-flips` | Fail (non-zero exit) on any unexpected pass/fail flip vs the relevant known-failing list. |
| `--dashboard <path>` / `--dashboard=<path>` | Write a Markdown dashboard to `<path>`. |
| `--write-known-failing <path>` / `--write-known-failing=<path>` | Regenerate the known-failing list at `<path>` from the current run. |
| `--jobs <n>` | Parallel worker count for full-corpus runs. `0` autodetects CPU count. Default `1`. Only takes effect when `--full` is set and no `--shard` is given. |
| `--shard <i>/<n>` | Run only shard `i` of `n` (for splitting the full corpus across machines/CI jobs). |
| `--progress-file <path>` | Record the test about to run (truncated + flushed each iteration) — after a crash, names the crashing test. |
| `--results-file <path>` | Append one `PASS|FAIL|SKIP <path>` line per test (survives across resumed runs). |
| `--start-after <path>` | Skip every test up to and including `<path>` — used to resume past a crasher. |
| `--filter <substr>` | Full-mode only: restrict the run to tests whose relative path contains `<substr>` — isolates a single feature area. |
| `--strict-failures` | Stricter failure classification (see runner source for exact semantics). |
| `--list` | List selected tests without running them. |

---

## Differential testing

`zig build differential` evaluates the same source with jsz and with `node
-e <source>` and diffs the results. It checks for `node --version` first and
prints `differential testing requires Node.js (node not found on PATH).
Skipping.` if Node.js is not installed, rather than failing the build.
Install a recent Node.js and ensure `node` is on `PATH` to use this step.

---

## Examples

```
zig build                        # build zig-out/bin/jsz
zig build run -- -e "1+1"        # build and run, forwarding args
zig build test                   # all unit tests
zig build example-embed          # embedding API demo
zig build docs                   # zig-out/docs/ HTML API docs
zig build conformance-summary    # curated Test262 whitelist + summary
zig build conformance-full       # full ~53k Test262 corpus (parallel)
zig build -Djit=true test        # build + test with the Cranelift JIT linked
```

See also: [cli.md](cli.md) for the resulting CLI's flags, [api.md](api.md)
for the embedding surface every example/build step exercises, and
[architecture.md](architecture.md) for how the bytecode compiler, GC, and
JIT fit together.
