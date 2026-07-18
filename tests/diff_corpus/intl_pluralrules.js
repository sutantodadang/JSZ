// Wave 15: Intl.PluralRules — en-US cardinal & ordinal categories.
var c = new Intl.PluralRules("en-US");
var o = new Intl.PluralRules("en-US", { type: "ordinal" });
[
  c.select(0), c.select(1), c.select(2), c.select(5),
  o.select(1), o.select(2), o.select(3), o.select(4),
  o.select(11), o.select(21), o.select(22), o.select(23), o.select(111),
  new Intl.PluralRules("en-US", { type: "ordinal" }).resolvedOptions().pluralCategories.join("/")
].join(",")
