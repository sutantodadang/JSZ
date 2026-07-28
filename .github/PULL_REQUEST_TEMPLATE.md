## Summary

<!-- What does this PR do, and why? 1-3 bullet points. -->

-
-
-

## Checklist

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details on each item.

- [ ] `zig build test` passes
- [ ] `zig fmt src/` — no formatting diffs
- [ ] CHANGELOG entry added to `[Unreleased]`
- [ ] New public API has `///` doc comments
- [ ] `zig build conformance-delta` is clean (paste output below, or write
      "N/A — no JS execution changes"). If it flips a known-failing entry
      on purpose, the PR also reseeds `tests/test262_known_failing*.txt`
      and explains the flip.
- [ ] No obvious algorithmic regression (e.g. an accidental O(n²) on a hot
      path), or it's justified below

```
<!-- paste `zig build conformance-delta` output here -->
```
