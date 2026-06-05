var a = [10, 20, 30];
var it = a[Symbol.iterator]();
var r = it.next();
var sum = 0;
for (var v of a) sum += v;
[typeof a[Symbol.iterator], r.value, r.done, sum].join('|');
