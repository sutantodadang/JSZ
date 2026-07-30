// Comparator sort (stable merge sort since PR #124; was O(n^2) at 5k cap).
var warmA = [3, 1, 2].sort(function (a, b) { return a - b; })[0];
var t0 = Date.now();
var a = [];
for (var i = 0; i < 50000; i++) a.push((i * 2654435761) % 100000);
a.sort(function (x, y) { return x - y; });
var t1 = Date.now();
console.log("sort," + (t1 - t0) + "," + (a[0] + a[49999] + warmA));
