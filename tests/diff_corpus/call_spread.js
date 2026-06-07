// Phase 13: call-argument spread f(...args) (mixed fixed + multiple spreads,
// method-call this-binding, and a native callee).
function g(a, b, c, d, e) { return [a, b, c, d, e].join(","); }
var obj = {
  base: 10,
  sum: function (a, b, c) { return this.base + a + b + c; },
};
[
  g(1, ...[2, 3], 4, ...[5]),
  obj.sum(...[1, 2, 3]),
  Math.max(...[3, 7, 2, 9, 1]),
].join("|")
