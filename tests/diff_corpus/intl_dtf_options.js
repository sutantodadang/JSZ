// Wave 14: Intl.DateTimeFormat component options (UTC, deterministic).
var d = new Date(Date.UTC(2020, 0, 5, 13, 7, 9));
[
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", year: "numeric", month: "long", day: "numeric", weekday: "long" }).format(d),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", hour: "numeric", minute: "2-digit", second: "2-digit" }).format(d),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC" }).format(d),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", month: "2-digit", day: "2-digit", year: "2-digit" }).format(d),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", weekday: "short", month: "numeric", day: "numeric", year: "numeric" }).format(d)
].join(" | ")
