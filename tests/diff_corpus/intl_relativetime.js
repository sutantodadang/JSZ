// Wave 15: Intl.RelativeTimeFormat — en-US numeric always / auto.
var r = new Intl.RelativeTimeFormat("en-US", { numeric: "always" });
var a = new Intl.RelativeTimeFormat("en-US", { numeric: "auto" });
[
  r.format(-1, "day"), r.format(1, "day"), r.format(-2, "hour"), r.format(3, "month"), r.format(0, "day"),
  a.format(-1, "day"), a.format(0, "day"), a.format(1, "day"),
  a.format(-1, "week"), a.format(0, "second"), a.format(0, "hour"), a.format(-2, "month")
].join("|")
