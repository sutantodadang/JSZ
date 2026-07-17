// Arbitrary-precision arithmetic: +, -, *, /, %, ** (incl. beyond 2^53).
var big = 2n ** 100n;
[
  2n + 3n,
  2n - 5n,
  111111111n * 111111111n,
  7n / 2n,
  (-7n) / 2n,
  7n % 2n,
  (-7n) % 2n,
  2n ** 64n,
  big,
  big + 1n,
  9007199254740993n * 9007199254740993n
].join('|');
