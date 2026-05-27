# Changelog

All notable changes to jsz will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: 0.x — anything may break. 1.0 = strict semver.

---

## [Unreleased] - Phase 0 scaffold complete.

### Added
- `src/root.zig`: public API stubs (`Isolate`, `Context`, `Value`, `EvalResult`, `NativeFn`, `NativeResult`)
- `src/main.zig`: CLI with `--version`, `--help`, `-e <expr>`, `-i`, positional script path
- Full module directory tree: `value/`, `gc/`, `lexer/`, `parser/`, `bytecode/`, `vm/`, `runtime/`, `builtins/`, `regex/`, `test/`
- Fuzz harnesses: `src/test/fuzz/parser_fuzz.zig`, `src/test/fuzz/vm_fuzz.zig`
- Test262 runner stub: `src/test/test262_runner.zig`
- Node.js differential harness stub: `src/test/differential.zig`
- `examples/hello.zig`: embed hello-world, matches README
- `build.zig`: added `fuzz`, `conformance`, `differential`, `example-hello`, `docs`, `bench` steps
- CI workflows: `ci.yml` (matrix: Linux/macOS/Windows x Debug/ReleaseSafe), `fuzz.yml` (nightly)
- Docs scaffold: `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `docs/EMBEDDING.md`, `docs/API.md`, `docs/COOKBOOK.md`, `docs/CONTRIBUTING/adding-a-builtin.md`
- GitHub issue templates + PR template
- `.gitignore`
- `LICENSE` (MIT)
