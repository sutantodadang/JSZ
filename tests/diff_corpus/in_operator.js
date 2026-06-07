// Phase 13: the `in` operator (own + inherited + array index/length).
[
  "a" in { a: 1 },
  "z" in { a: 1 },
  0 in [10, 20],
  5 in [10, 20],
  "length" in [1, 2],
  "push" in [],
].join(",")
