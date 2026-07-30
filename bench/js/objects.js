// Property access, shape transitions, method calls, prototype chain.
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.dist2 = function () { return this.x * this.x + this.y * this.y; };
var warmP = new Point(1, 2).dist2();
var t0 = Date.now();
var acc = 0;
var objs = [];
for (var i = 0; i < 50000; i++) {
  var p = new Point(i & 255, (i * 7) & 255);
  if ((i & 15) === 0) p.tag = i; // shape split on a subset
  objs.push(p);
}
for (var r = 0; r < 10; r++) {
  for (var k = 0; k < objs.length; k++) acc += objs[k].dist2();
}
var t1 = Date.now();
console.log("objects," + (t1 - t0) + "," + (acc % 1000000 + warmP));
