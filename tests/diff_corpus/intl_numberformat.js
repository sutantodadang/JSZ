// Phase 13: Intl.NumberFormat (en-US explicit — host default locale may differ).
[
  new Intl.NumberFormat("en-US").format(1234567.891),
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(-1234.5),
  new Intl.NumberFormat("en-US", { style: "percent" }).format(0.255),
  new Intl.NumberFormat("en-US", { minimumFractionDigits: 2 }).format(5),
  new Intl.NumberFormat("en-US").format(1000),
].join(" | ")
