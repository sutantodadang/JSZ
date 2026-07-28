# Security Policy

## Supported versions

jsz is pre-1.0 (`0.x`). Only the `main` branch is supported — there are no
maintained release branches or backports yet. Fixes land on `main`; there
is no LTS line to target.

## Reporting a vulnerability

Report security issues privately through
[GitHub Security Advisories](https://github.com/sutantodadang/JSZ/security/advisories/new)
on this repository. Do not open a public issue for a suspected
vulnerability — use the advisory form so the report stays private until a
fix is ready.

Include, where applicable:

- A minimal JS reproducer (or Zig snippet, for embedding-API issues).
- What you expected vs. what happened (crash, memory corruption, resource
  exhaustion, incorrect sandboxing behavior).
- jsz version/commit and platform (OS/arch).

## Response expectations

This is a pre-1.0, small-maintainer project. Response is best-effort — there
is no SLA. Crashes and memory-safety issues (segfaults, use-after-free, OOB
reads/writes) are treated as the highest priority, in line with the
project's standing rule that **the engine must never segfault on any
input**, trusted or not. Non-memory-safety correctness bugs (wrong result,
conformance gap) are important but not security issues — file those as
regular bug reports (`.github/ISSUE_TEMPLATE/bug_report.md`), not
advisories.

## Scope

jsz enforces resource limits — `gas` (bytecode instruction count),
`time_ms` (wall-clock deadline), and `mem_bytes` (live heap cap) — via
`Context.setLimits` (see [docs/embedding.md](docs/embedding.md#enforce-resource-limits)).
These bound a runaway script's CPU, wall-clock time, and memory use, and a
breach is designed to surface as a catchable exception rather than a crash
or hang.

That said: **pre-1.0, jsz should not be treated as a hardened sandbox for
running fully untrusted, adversarial JavaScript.** Resource limits reduce
denial-of-service risk from buggy or greedy scripts; they are not a
substitute for OS-level sandboxing (containers, seccomp, a separate process
per untrusted script) when the input is actively hostile. Contexts sharing
one `Isolate` also share the underlying GC heap and, currently, top-level
`var` global bindings (see
[docs/embedding.md](docs/embedding.md#multiple-contexts-per-isolate)) — they
are not an isolation boundary between mutually distrusting scripts. If your
threat model includes adversarial JS, isolate at the process level in
addition to using `setLimits`.

This framing will be revisited as jsz approaches 1.0 and the embedding API
stabilizes further.
