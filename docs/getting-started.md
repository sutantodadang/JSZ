# Getting Started

This tutorial takes you from zero to a working jsz embed. You will install
Zig, build the CLI, run a script, use the REPL, then embed the engine in a
small Zig program of your own.

Total time: about 15 minutes.

---

## 1. Install Zig 0.15.2

jsz pins its minimum Zig version in `build.zig.zon`. Install exactly 0.15.2
(or newer within the same major line) from
[ziglang.org/download](https://ziglang.org/download/).

Verify:

```sh
$ zig version
0.15.2
```

If you see a different version, install 0.15.2 before continuing — jsz uses
standard library APIs that changed between Zig releases.

---

## 2. Clone and build

```sh
$ git clone https://github.com/sutantodadang/JSZ jsz
$ cd jsz
$ zig build
```

The first build compiles the parser, bytecode compiler, VM, and CLI. It
produces no output on success and takes under a minute on a typical machine.
The binary lands at `zig-out/bin/jsz` (`zig-out/bin/jsz.exe` on Windows).

---

## 3. Run your first expression

```sh
$ zig-out/bin/jsz -e "1+1"
2
```

`-e` evaluates a single expression and prints its result. This is the
fastest way to sanity-check a build or try a language feature.

Check the version and flag list while you're here:

```sh
$ zig-out/bin/jsz --version
jsz 0.0.0-phase9-scaffold
$ zig-out/bin/jsz --help
```

`--help` lists every flag, including the resource-limit and JIT-profiling
options covered in [docs/cli.md](cli.md).

---

## 4. Write and run a script

Create `hello.js`:

```js
function greet(name) {
  return "Hello, " + name + "!";
}

console.log(greet("jsz"));
```

Run it:

```sh
$ zig-out/bin/jsz hello.js
Hello, jsz!
true
```

jsz runs a script file as a CommonJS module (so `require`/`module.exports`
work — see [docs/cookbook.md](cookbook.md)). `console.log` writes to stdout;
the trailing `true` is a completion signal printed after the module finishes
without throwing, not your script's return value. To inspect an expression
value directly, use `-e` (previous step) or the REPL (next step). To see a
script fail loudly, introduce a bug:

```sh
$ zig-out/bin/jsz -e "null.x"
Uncaught Cannot read properties of null (reading 'x')
```

`jsz` exits with status 1 on an uncaught exception or a syntax error.

---

## 5. Try the REPL

```sh
$ zig-out/bin/jsz -i
>> 1 + 2
3
>> const xs = [1, 2, 3];
undefined
>> xs.map(x => x * 2)
2,4,6
>> .exit
```

Each line is evaluated independently and its result is printed immediately —
this is the quickest way to explore the language interactively. Type
`.exit` (or close the terminal) to leave.

---

## 6. Embed jsz in your own Zig project

Now embed the engine instead of using the CLI. Create a new directory
outside the jsz repo:

```sh
$ mkdir my-embed && cd my-embed
$ zig init
```

### 6.1 Add jsz as a dependency

```sh
$ zig fetch --save https://github.com/sutantodadang/JSZ/archive/refs/heads/main.tar.gz
```

This adds a `.jsz` entry (url + content hash) to your `build.zig.zon`. While
jsz is pre-1.0 and you want to track a local checkout instead, use a path
dependency in `build.zig.zon` instead of `zig fetch`:

```zig
.dependencies = .{
    .jsz = .{ .path = "../jsz" },
},
```

Either way, wire the module into your executable in `build.zig`:

```zig
const jsz_dep = b.dependency("jsz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jsz", jsz_dep.module("jsz"));
```

### 6.2 Write the embed

Replace `src/main.zig` with the canonical embed pattern — Isolate, then
Context, then eval:

```zig
const std = @import("std");
const jsz = @import("jsz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One Isolate per process (owns heap, GC, atom table).
    var iso = try jsz.Isolate.init(allocator);
    defer iso.deinit();

    // One Context per execution environment (owns the global object).
    var ctx = try iso.newContext();
    defer ctx.deinit();

    switch (ctx.eval("1 + 2", "<inline>")) {
        .ok => |v| std.debug.print("result = {d}\n", .{v.toF64()}),
        .exception => |e| std.debug.print("uncaught: {s}\n", .{e.message}),
        .parse_error => |e| std.debug.print("syntax: {s}\n", .{e.message}),
    }
}
```

### 6.3 Build and run

```sh
$ zig build run
result = 3
```

Six calls got you from an empty project to running JavaScript inside a Zig
binary: `Isolate.init`, `iso.newContext`, `ctx.eval`, and unpacking the
three-armed `EvalResult`. jsz's own copy of this pattern lives at
`examples/embed.zig` in the jsz repo and adds a host function via
`registerNativeFn` — the next document below walks through it.

---

## What you built

- A working jsz CLI (`zig-out/bin/jsz`) built from source.
- A `.js` script run standalone and interactively via the REPL.
- A separate Zig project embedding jsz as a library, evaluating JavaScript
  and reading the result back into Zig.

## Where to go next

- [docs/embedding.md](embedding.md) — host functions, resource limits, GC
  control, snapshots, modules, multiple contexts.
- [docs/api.md](api.md) — the full stable-vs-experimental API surface.
- [docs/cli.md](cli.md) — every CLI flag, including `--gas-limit`,
  `--jit=`, and bytecode snapshot flags.
