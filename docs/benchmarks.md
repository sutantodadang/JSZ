# Benchmarks

Comparative benchmarks of jsz against QuickJS and Node.js, plus how to run
and read them. The suite exists to keep performance claims honest and to
catch large regressions — not to win microbenchmark bragging rights.

## How it works

Workloads live in `bench/js/`. Each file is plain, engine-portable JS that:

1. warms up,
2. self-times its hot section with `Date.now()` (so process startup and
   parse time are excluded),
3. prints one line: `name,milliseconds,checksum`.

`bench/run.sh` runs every workload N times per engine (default `RUNS=5`),
takes the median, **verifies the checksum agrees across engines** (so every
engine provably did the same work — a mismatch fails the run), and prints a
markdown table.

```bash
zig build -Doptimize=ReleaseSafe   # the shipped configuration
bash bench/run.sh                  # engines auto-detected: jsz, qjs, node
```

The `Bench` GitHub workflow (`workflow_dispatch`) runs the same script on
ubuntu with distro QuickJS and current Node, and publishes the table in the
job summary. CI numbers are the citable ones — same machine, same OS, all
engines.

## Workloads

| file | exercises |
|---|---|
| `fib.js` | recursive call overhead |
| `loops.js` | raw bytecode dispatch, integer arithmetic |
| `strings.js` | string building, `indexOf`, `split`, `replace` |
| `objects.js` | property access, shape transitions, method calls via prototype |
| `arrays.js` | `push` + `map`/`filter`/`reduce` pipeline |
| `sort.js` | comparator `Array.prototype.sort` (small on purpose — see below) |
| `json.js` | `JSON.stringify`/`parse` roundtrip of a nested tree |
| `regex.js` | `test`, global `match`, global `replace` |

## Reading the numbers

- **Node (V8)** JIT-compiles everything; a 10–250× gap on hot loops is the
  expected cost of running an interpreter and is not the comparison that
  matters day-to-day.
- **QuickJS** is the honest peer: also a small embeddable interpreter-first
  engine. Parity with qjs is the current performance bar.
- jsz numbers use **ReleaseSafe** (what releases ship) with the JIT off —
  the default configuration a user gets.

## Known gaps the suite deliberately exposes

- `sort.js` is capped at 5k elements because jsz's `Array.prototype.sort`
  is currently **O(n²)** (insertion-style). 10k elements already cost ~6 s.
  The workload stays small so the table stays runnable, but the gap remains
  visible until the sort is rewritten (planned: pdq/merge hybrid).

## Bugs this suite has already caught

- `JSON.parse` segfault: nursery GC during recursive descent collected
  container objects reachable only from the native parser frame
  (use-after-free in `obj.set`). Found the first time `json.js` ran locally;
  fixed by rooting containers via `heap.addRoot` for the duration of the
  parse, with a tiny-nursery regression test in
  `src/test/integration/core.zig`.
