// Recursive call overhead. Self-timed; prints "name,ms,checksum".
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
fib(18); // warmup
var t0 = Date.now();
var r = fib(25);
var t1 = Date.now();
console.log("fib," + (t1 - t0) + "," + r);
