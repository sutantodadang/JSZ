// Wave 15: Intl.ListFormat — en-US conjunction / disjunction / unit.
[
  new Intl.ListFormat("en-US", { type: "conjunction" }).format(["A", "B", "C"]),
  new Intl.ListFormat("en-US", { type: "disjunction" }).format(["A", "B", "C"]),
  new Intl.ListFormat("en-US").format(["A", "B"]),
  new Intl.ListFormat("en-US").format(["A"]),
  "[" + new Intl.ListFormat("en-US").format([]) + "]",
  new Intl.ListFormat("en-US", { type: "unit" }).format(["A", "B", "C"]),
  new Intl.ListFormat("en-US", { type: "unit" }).format(["A", "B"])
].join(" | ")
