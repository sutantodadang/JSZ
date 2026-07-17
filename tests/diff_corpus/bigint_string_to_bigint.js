// StringToBigInt: whitespace trim, optional sign on the decimal form only,
// empty/all-whitespace => 0n, and rejection of decimal points / exponents.
function t(s) { try { return String(BigInt(s)); } catch (e) { return e.constructor.name; } }
[
  t('-10'), t('+7'), t('   7   '), t('     '), t(''),
  t('   0b1111'), t('0x1f'), t('18446744073709551616'),
  t('-18446744073709551616'),
  // sign is not allowed on a radix-prefixed form
  t('-0x1f'),
  // no decimal point, exponent, or Infinity
  t('1.5'), t('1e3'), t('Infinity'), t('-'), t('abc')
].join('|');
