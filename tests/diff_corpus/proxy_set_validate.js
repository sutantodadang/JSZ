// Phase 13: a validating set trap throws, and the throw is catchable.
var p = new Proxy({}, {
  set: function (t, k, v) {
    if (typeof v !== "number") throw new TypeError("number required");
    t[k] = v;
    return true;
  },
});
var out = [];
p.n = 3;
out.push(p.n);
try { p.s = "hi"; } catch (e) { out.push(e.name); }
out.join(",")
