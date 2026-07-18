// Wave 14: Intl.Locale — BCP-47 subtag parsing + canonicalization (en-US scope).
var a = new Intl.Locale("zh-Hant-CN");
var b = new Intl.Locale("EN-us");
var c = new Intl.Locale("de-Latn-DE");
[
  a.language, a.script, a.region, a.baseName, a.toString(),
  b.language, b.region, b.baseName,
  c.language, c.script, c.region, c.baseName
].join("|")
