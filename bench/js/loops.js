// Raw dispatch: nested integer loop with arithmetic.
var warm = 0;
for (var w = 0; w < 100000; w++) warm += w & 7;
var t0 = Date.now();
var sum = 0;
for (var i = 0; i < 2000; i++) {
  for (var j = 0; j < 2000; j++) {
    sum += (i * 3 + j) & 1023;
  }
}
var t1 = Date.now();
console.log("loops," + (t1 - t0) + "," + (sum + warm));
