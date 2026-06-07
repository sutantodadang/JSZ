// Phase 13: Proxy set trap transforms stored values; no-trap reads forward.
var p = new Proxy({}, {
  set: function (t, k, v) { t[k] = v * 2; return true; },
});
p.a = 5;
p.b = 10;
[p.a, p.b].join(",")
