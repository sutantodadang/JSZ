// Comparisons: BigInt/BigInt and mixed BigInt/Number are both allowed.
[
  1n < 2n, 2n > 1n, 2n <= 2n, 2n >= 3n,
  1n == 1, 1n === 1, 1n == 1n, 1n === 1n,
  1n != 2, 1n !== 1,
  1n < 2, 2 > 1n, 1n == '1',
  0n == false, 2n > 1.5
].join('|');
