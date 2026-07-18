// Wave 16: Intl.NumberFormat signDisplay + Intl.getCanonicalLocales (en-US).
var r = [];
["auto", "always", "exceptZero", "never"].forEach(function (sd) {
  var f = new Intl.NumberFormat("en-US", { signDisplay: sd });
  r.push(sd + ":" + f.format(5) + "," + f.format(-5) + "," + f.format(0));
});
r.push(Intl.getCanonicalLocales(["EN-us", "Fr-FR", "de", "en-US"]).join(","));
r.push(Intl.getCanonicalLocales("zh-hant-cn").join(","));
r.push(new Intl.NumberFormat("en-US", { signDisplay: "always" }).resolvedOptions().signDisplay);
r.join(" | ")
