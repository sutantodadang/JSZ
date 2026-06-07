// Phase 13: array-literal spread over a Set and a generator.
function* g() { yield 3; yield 4; }
var s = new Set([1, 2, 2]);
[...s, ...g()].join(",")
