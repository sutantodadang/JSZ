// Phase 13: the `delete` operator removes own properties.
var o = { a: 1, b: 2, c: 3 };
var r1 = delete o.b;
var r2 = delete o["c"];
[r1, r2, Object.keys(o).join(","), "b" in o].join("|")
