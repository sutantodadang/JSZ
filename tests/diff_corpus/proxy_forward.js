// Phase 13: a handler with no traps forwards every operation to the target.
var p = new Proxy({ a: 1, b: 2 }, {});
p.c = 3;
p.a + p.b + p.c
