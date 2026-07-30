// Array workload: fill + map/filter/reduce pipeline.
// (sort lives in sort.js — jsz's sort is currently O(n^2), see docs/benchmarks.md)
var warmA = [3, 1, 2].map(function (v) { return v + 1; })[0];
var t0 = Date.now();
var a = [];
for (var i = 0; i < 100000; i++) a.push((i * 2654435761) % 100000);
var mapped = a.map(function (v) { return v + 1; });
var odd = mapped.filter(function (v) { return (v & 1) === 1; });
var total = odd.reduce(function (s, v) { return s + v; }, 0);
var t1 = Date.now();
console.log("arrays," + (t1 - t0) + "," + (total % 1000000 + a[0] + warmA));
