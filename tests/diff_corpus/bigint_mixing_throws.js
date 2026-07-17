// BigInt must not mix with Number in arithmetic: TypeError. Unary + also throws.
function t(f) { try { f(); return 'no-throw'; } catch (e) { return e.constructor.name; } }
[
  t(function(){ return 1n + 1; }),
  t(function(){ return 1 + 1n; }),
  t(function(){ return 1n - 1; }),
  t(function(){ return 1n * 2; }),
  t(function(){ return 1n / 2; }),
  t(function(){ return 1n % 2; }),
  t(function(){ return 2n ** 2; }),
  t(function(){ return +1n; }),
  t(function(){ return 1n / 0n; }),
  t(function(){ return 2n ** -1n; }),
  t(function(){ return BigInt('abc'); }),
  t(function(){ return BigInt(1.5); }),
  // allowed: string concat, relational compare, unary negate
  t(function(){ return 1n + 'x'; }),
  t(function(){ return 1n < 2; }),
  t(function(){ return -1n; })
].join('|');
