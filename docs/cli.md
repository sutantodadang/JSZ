# jsz CLI Reference

Reference for the `jsz` command-line tool (`src/main.zig`). The CLI is a thin
wrapper over the embedding API documented in [api.md](api.md) — every flag
below maps to a `Context` method or field. For build instructions see
[building.md](building.md); for engine internals see
[architecture.md](architecture.md).

Build the CLI with `zig build` (binary at `zig-out/bin/jsz` /
`zig-out/bin/jsz.exe`) or run it in place with `zig build run -- [args]`.

---

## Usage

```
jsz [options] [script.js]
```

With no arguments and no flags, `jsz` prints help and exits with status `1`.
Exactly one of `-e`, `-i`/`--interactive`, `--run-bytecode <path>`, or a
positional script path selects the run mode; the last positional non-flag
argument wins as the script path if more than one is given (arguments are
parsed left to right; each recognized flag is `continue`d over).

---

## Flags

### `-h`, `--help`

Print usage and exit. Checked first — if `-h`/`--help` appears anywhere in
argv, all other flags are ignored, help is printed, and the process exits `0`
(exit `1` only for the true zero-argument case below).

### `--version`

Print `jsz <version>` (currently `jsz 0.0.0-phase9-scaffold`, from
`jsz.version`) to stdout and exit `0`.

### `-e <expr>`

Evaluate `<expr>` as a script (source name `<eval>`) and print the result via
`valueToDisplayString`. Requires an argument; if `<expr>` is missing, falls
back to help mode.

```
$ jsz -e "1 + 1"
2
```

### `-i`, `--interactive`

Start an interactive REPL. Reads lines from stdin, prints a `>> ` prompt,
evaluates each line as a script against a single persistent `Context` (so
`var`/function declarations persist across lines), and prints the result.
`.exit` quits; blank lines are skipped; EOF (Ctrl-D / closed stdin) also
quits. Exceptions and parse errors print their message but do not exit the
REPL.

```
$ jsz -i
>> var x = 21
undefined
>> x * 2
42
>> .exit
```

### `--module`

Run the entry (script file or `-e` expression) as an ES module: strict mode,
`import`/`export` desugaring via `Context.evalModule`. Implies `--interp=bc`.

### `--interp=bc`

Select the bytecode VM. This is the default and, as of this version, the
**only** interpreter (`jsz.InterpMode` has a single variant, `bc`) — the flag
exists for forward compatibility and has no observable effect today.

### `--debug`

Attach a stub debugger: installs a hook (`jsz.debug.installHook`) that prints
a line to stderr whenever a `debugger;` statement executes in the bytecode
VM. Implies `--interp=bc` (the `DEBUGGER` opcode only fires there). Output
format:

```
[debugger] paused at <source>:<line>:<col> in <function> (pc=<n>)
```

### `--dump-bytecode`

Compile-only mode: compile the source, disassemble it via
`jsz.dumpBytecode`, print to stdout, and exit — the script is never run. On a
syntax error, prints `SyntaxError: <message> (line L:C)` instead.

### `--source-map`

Compile-only mode: compile the source and print a bytecode-to-source JSON
source map via `jsz.sourceMap`, then exit without running the script.

### `--emit-bytecode <path>`

Compile the source to a bytecode snapshot (`Context.compileSnapshot`) and
write the resulting bytes to `<path>`, then exit without running the script.
Prints `wrote <n> bytes to <path>` to stderr.

### `--run-bytecode <path>`

Load a bytecode snapshot from `<path>` (via `Context.evalSnapshot`) and run
it in the bytecode VM. Mutually selects run mode `run_bytecode`; ignores any
positional script argument. Exits `1` if the file cannot be read.

```
$ jsz -e "6 * 7" --emit-bytecode out.jbc
wrote 214 bytes to out.jbc
$ jsz --run-bytecode out.jbc
42
```

### `--gc-stats`

After evaluating, print cumulative GC counters (`Context.gcStats()`):

```
=== GC stats ===
collections: 0
bytes_allocated: 1024
bytes_freed: 0
objects_alive: 12
```

### `--gc-after-eval`

Trigger one GC cycle (`Context.gc()`) before printing stats. Only meaningful
combined with `--gc-stats`; on its own it still runs the collection but has
no visible output.

### `--ic-stats`

Enable inline-cache instrumentation (`Context.setIcStats(true)`) and print
hit-rate stats after eval. Implies `--interp=bc`.

```
=== IC stats ===
own_hits: 40
proto_hits: 8
misses: 2
hit_rate: 96.0%
```

`hit_rate` is only printed when at least one lookup occurred
(`own_hits + proto_hits + misses > 0`).

### `--jit=off|count|experimental`

Set the JIT profiling mode (`Context.setJitMode`; see `jsz.JitMode` in
[api.md](api.md#jitmode-experimental)). `off` is the default and has no
effect. `count` and `experimental` both imply `--interp=bc`. After eval,
prints:

```
=== JIT profile ===
mode: experimental
hot_sites: 3
compiled: 1
deopts: 0
```

`experimental` only compiles native code if the binary was built with
`-Djit=true` (see [building.md](building.md)); without it, `compiled` stays
`0` and the pure-Zig interpreter runs unchanged.

### `--mem-limit=<bytes>`

Cap live heap+arena bytes (`Limits.mem_bytes`). An over-budget eval throws
(`EvalResult.exception`) instead of crashing. `0` (unset) means unlimited.
Enforced in all interpreter modes.

### `--gas-limit=<n>`

Cap executed bytecode instructions (`Limits.gas`). Implies `--interp=bc`
(enforced only in the bytecode VM).

### `--time-limit=<ms>`

Cap wall-clock execution time in milliseconds (`Limits.time_ms`). Implies
`--interp=bc`.

```
$ jsz -e "while(true){}" --gas-limit=100000
Uncaught <gas/time limit message>
```

(Exact message text comes from the VM's limit-check error path; treat it as
opaque and match on `EvalResult.exception` rather than string contents when
embedding.)

---

## Positional argument: script path

Any argument not starting with `-` is treated as a script path. The file is
read (up to 10 MiB), wrapped as a CommonJS module via the filesystem module
loader (`jsz.module_loader.buildBundle`, resolving relative `require`/`import`
specifiers on disk), and evaluated with `source_name` set to the script path.
A leading `#!` shebang line is stripped (replaced by `//` to preserve line
numbers) before wrapping. Set `JSZ_DUMP_BUNDLE=1` in the environment to print
the wrapped bundle to stderr for debugging.

```
$ jsz script.js
$ jsz --module esm-entry.mjs
```

If the file cannot be read, prints `jsz: cannot read '<path>': <error>` to
stderr and exits `1`.

---

## Exit codes

| Condition | Exit code |
|---|---|
| `--version`, successful `--help` with args present | `0` |
| Help with **zero** arguments (`jsz` alone) | `1` |
| Uncaught exception or syntax error during eval/script/snapshot run | `1` |
| Script file or snapshot file unreadable | `1` |
| Otherwise | `0` |

---

## Examples

```
$ jsz --version
jsz 0.0.0-phase9-scaffold

$ jsz -e "1 + 1"
2

$ jsz -e "1 + 1" --interp=bc
2

$ jsz script.js

$ jsz -e "JSON.stringify({a:1})"
{"a":1}

$ jsz -e "throw new Error('boom')"
Uncaught boom
$ echo $?
1
```

See also: [api.md](api.md) for the embedding API each flag drives,
[cookbook.md](cookbook.md) for equivalent patterns from Zig host code, and
[building.md](building.md) for building the CLI itself (including
`-Djit=true`).
