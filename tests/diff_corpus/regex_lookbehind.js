// Phase 13: RegExp lookbehind (?<=...) and (?<!...).
[
  "1foo2bar".replace(/(?<=\d)[a-z]+/g, "-"),
  "price: 5".match(/(?<=: )\d+/)[0],
  /(?<!\d)[a-z]+/.test("abc"),
  "a1b2c3".replace(/(?<![a-z])\d/g, "#"),
].join("|")
