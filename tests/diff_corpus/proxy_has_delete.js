// Phase 13: Proxy has + deleteProperty traps (via the `in`/`delete` operators).
var log = [];
var p = new Proxy({ a: 1 }, {
  has: function (t, k) { return k === "magic" || k in t; },
  deleteProperty: function (t, k) { log.push("del:" + k); delete t[k]; return true; },
});
var r1 = "magic" in p;
var r2 = "a" in p;
var r3 = "nope" in p;
var r4 = delete p.a;
[r1, r2, r3, r4, log.join(","), "a" in p].join("|")
