// BigInt() constructor, toString radix, valueOf, and ToString coercion.
[
  BigInt(42),
  BigInt('99'),
  BigInt('0x1f'),
  BigInt(true),
  (255n).toString(),
  (255n).toString(16),
  (255n).toString(2),
  (7n).valueOf(),
  String(1n),
  '' + 255n,
  `v=${12n}`,
  [1n, 2n].join(','),
  Number(9n),
  Boolean(0n),
  Boolean(1n)
].join('|');
