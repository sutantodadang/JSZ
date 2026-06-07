// Phase 13: Proxy get trap intercepts reads and logs accessed keys.
var calls = [];
var p = new Proxy({ x: 5, y: 9 }, {
  get: function (t, k) { calls.push(k); return t[k]; },
});
var r = p.x + p.y;
calls.join(",") + "=" + r
