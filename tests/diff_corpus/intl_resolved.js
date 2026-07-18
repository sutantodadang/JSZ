// Wave 14: Intl resolvedOptions across NumberFormat / Collator / DateTimeFormat (en-US).
var nf = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).resolvedOptions();
var nf2 = new Intl.NumberFormat("en-US").resolvedOptions();
var cr = new Intl.Collator("en-US").resolvedOptions();
var dr = new Intl.DateTimeFormat("en-US").resolvedOptions();
[
  nf.locale, nf.numberingSystem, nf.style, nf.currency, nf.minimumFractionDigits, nf.maximumFractionDigits, nf.minimumIntegerDigits, nf.useGrouping,
  nf2.style, nf2.useGrouping, nf2.minimumFractionDigits, nf2.maximumFractionDigits,
  cr.locale, cr.usage, cr.sensitivity, cr.ignorePunctuation, cr.collation, cr.numeric, cr.caseFirst,
  dr.locale, dr.calendar, dr.numberingSystem, dr.year, dr.month, dr.day
].join(",")
