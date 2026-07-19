# Wave 23 — RegExp Pike VM (non-backtracking)

## Objective

Replace the recursive backtracking RegExp matcher with a Thompson-NFA / Pike-VM
execution engine for patterns that do not contain backreferences. This guarantees
O(n × m) time per anchored match — no catastrophic backtracking.

## Implementation

### Pike VM Architecture

- **`Inst`** (union enum): 12 instruction types — `char`, `class`, `any_char`,
  `match`, `jmp`, `split`, `save`, `assert_bol`, `assert_eol`, `assert_wb`,
  `assert_nwb`, `look`.
- **`Program`**: flat instruction array + capture slot count.
- **`ProgBuilder`**: incremental emitter with `emit`/`patch`/`here` and a
  `MAX_PROG_LEN` (32K) size cap; patterns exceeding the cap fall back to the
  backtracking engine.
- **`PikeVM`**: reusable execution state with two thread lists (SoA: pcs + caps),
  generation-stamped seen-set for epsilon-closure dedup, and a scratch capture
  vector.

### Compilation (`buildProgram`)

The AST is compiled to a flat instruction stream:

| AST node   | Pike VM output                              |
|------------|---------------------------------------------|
| `literal`  | `char(u21)`                                 |
| `char_class` | `class(*CharClass)`                      |
| `dot`      | `any_char`                                  |
| `anchor_*` | `assert_bol` / `assert_eol`                |
| `\b` / `\B` | `assert_wb` / `assert_nwb`               |
| `seq`      | sequential emit                             |
| `alt`      | `split arm, next; arm; jmp end`             |
| `group`    | `save(start); body; save(end)`             |
| `quant`    | unrolled: `{n}` copies, `{n,m}` as `?` chain |
| `look*`    | `look(*RegexNode)` — delegates to matchNode |

Greedy vs lazy: `split` arm order (body-first = greedy, exit-first = lazy).

### Execution (`PikeVM.runAnchored`)

BFS over NFA states using the classic Pike VM algorithm:

1. **Seed**: current thread list = epsilon-closure(start, pos=0).
2. **Consume**: for each thread at a consuming instruction (char/class/any_char),
   try to advance by one codepoint; on success, add to the next list.
3. **Match**: when a `match` instruction is reached, record it as the best match
   and discard remaining threads (leftmost-first priority).
4. **Swap**: current ← next; advance input position.
5. **Repeat** until no threads remain or match found.

### Integration

- `compileRegex` now calls `hasBackref(&root)` to detect backreferences, then
  `buildProgram` to produce the Pike VM program when eligible.
- `matchAt` checks `regex.program` — if non-null, uses `PikeVM.runAnchored`;
  otherwise falls back to the recursive `matchNode` backtracker.
- PikeVM state is lazily initialized and cached in `CompiledRegex.pike_vm`.

## Test Results

- `zig build test` — 0 failures
- `zig build differential` — 167/167 pass
- `zig build conformance-delta` — 0 unexpected pass/fail flips (1278/1278)
