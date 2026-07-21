// Wave 45a: ES2025 RegExp modifiers `(?ims-ims:...)` rebind i/m/s for the
// enclosed disjunction only, and malformed modifier lists are Syntax Errors.
function t(src, flags) {
  try { new RegExp(src, flags || ""); return "ok"; }
  catch (e) { return "THROW " + e.constructor.name; }
}
[
  /(?i:a)b/.test("AB"), /(?i:a)b/.test("Ab"), /(?i:a)b/.test("ab"),
  /a(?i:b)c/.test("aBc"), /a(?i:b)c/.test("ABc"),
  /(?s:.)/.test("\n"), /./.test("\n"),
  /(?m:^b)/.test("a\nb"), /^b/.test("a\nb"),
  /(?-i:a)/i.test("A"), /(?-i:a)/i.test("a"),
  /(?i:[ab])c/.test("Ac"), /(?i:[ab])c/.test("AC"),
  // A modifier group must not leak into the flags reported on the RegExp.
  /(?i:a)/.ignoreCase,
  /(?i:a(?-i:b)c)/.test("AbC"), /(?i:a(?-i:b)c)/.test("ABC"),
  // `(?i-:...)` is legal: an empty remove list is fine as long as one side has flags.
  t("(?i-:a)"),
  t("(?ii:a)"), t("(?i-i:a)"), t("(?g:a)"), t("(?-:a)"), t("(?d:a)")
].join(",")
