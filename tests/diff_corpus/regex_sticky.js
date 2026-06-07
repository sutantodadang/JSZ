// Phase 13: the `y` (sticky) flag anchors the match at lastIndex.
var r = /\d/y;
r.lastIndex = 2;
var a = r.test("ab3");
var end = r.lastIndex;
r.lastIndex = 0;
var b = r.test("ab3");
[a, end, b].join(",")
