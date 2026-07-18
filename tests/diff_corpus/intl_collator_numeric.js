// Wave 17: Intl.Collator numeric collation + bound (detachable) compare.
var n = new Intl.Collator("en-US", { numeric: true });
var p = new Intl.Collator("en-US");
[
  n.compare("10", "2"), n.compare("2", "10"), n.compare("a2", "a10"),
  n.compare("file9", "file10"), n.compare("2", "2"), n.compare("item20", "item3"),
  p.compare("10", "2"),
  new Intl.Collator("en-US", { sensitivity: "base" }).compare("Apple", "apple"),
  ["10", "2", "1", "20", "3"].sort(n.compare).join(""),
  ["file10", "file2", "file1"].sort(n.compare).join(",")
].join("|")
