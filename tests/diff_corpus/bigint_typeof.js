// typeof + literal radix forms.
[
  typeof 123n,
  typeof BigInt(1),
  typeof 0n,
  typeof 1,
  0xffn,
  0b1011n,
  0o17n,
  123n
].join('|');
