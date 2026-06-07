// Phase 13: RegExp \p{} / \P{} property escapes under /u (ASCII categories).
[
  /\p{L}+/u.test("abc"),
  "a1b2".replace(/\p{N}/gu, "#"),
  /^\p{Lu}/u.test("Hello"),
  /\P{L}/u.test("5"),
  "foo bar".replace(/\p{L}+/gu, "X"),
].join("|")
