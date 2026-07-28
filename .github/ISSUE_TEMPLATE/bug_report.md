---
name: Bug report
about: Report incorrect behavior or a crash
title: "[BUG] "
labels: bug
assignees: ''
---

## Does this crash the engine?

- [ ] Yes — jsz segfaults, panics, or otherwise aborts (this is always
      high priority: **the engine must never segfault on any input**)
- [ ] No — wrong output / wrong error / hang under a resource limit

## Reproducer

Paste the minimal JS script that triggers the bug:

```js
// script.js
```

## jsz version / commit

```
jsz --version
```

If you built from source, include the commit: `git rev-parse HEAD`.

## Expected behavior

Describe what you expected. Include `node -e` output if applicable:

```
node -e "..."
```

## Actual behavior

What jsz actually did (output, crash, error message, exit code):

```
jsz -e "..."
```

## Platform

- OS + arch (e.g. `ubuntu-22.04 x86_64`, `windows-11 x86_64`, `macos-14 arm64`):
- Zig version (`zig version`):
- Optimize mode (Debug / ReleaseSafe / ReleaseFast):
- Built with `-Djit=true`? (yes/no):
