var ok = Intl.getCanonicalLocales(["EN", "de-gregory", "en-u-ca-gregory", "zh-CN", "sr-Thai-RS", "DE-1996-1901", "en", "EN"]);
var bad = ["", "i", "x", "419", "hans-cmn-cn", "de-gregory-gregory", "de-*", "pl-PL-pl", "de-u", "x-foo", "de_DE"];
var errs = bad.map(function (t) {
  try { Intl.getCanonicalLocales(t); return t + ":none"; } catch (e) { return e.constructor.name; }
});
[ok.join("|"), errs.join(",")].join("\n");
