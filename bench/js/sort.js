// Comparator sort. Deliberately small (5k): jsz's Array.prototype.sort is
// currently O(n^2); this workload exists to keep that gap visible in the
// comparison table until the sort is rewritten.
var warmA = [3, 1, 2].sort(function (a, b) { return a - b; })[0];
var t0 = Date.now();
var a = [];
for (var i = 0; i < 5000; i++) a.push((i * 2654435761) % 100000);
a.sort(function (x, y) { return x - y; });
var t1 = Date.now();
console.log("sort," + (t1 - t0) + "," + (a[0] + a[4999] + warmA));
