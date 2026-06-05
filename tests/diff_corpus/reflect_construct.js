function Point(x, y) { this.x = x; this.y = y; }
var p = Reflect.construct(Point, [3, 4]);
function Box(n) { this.n = n * 2; }
var b = Reflect.construct(Box, [5]);
function Empty() {}
var e = Reflect.construct(Empty, []);
[p.x, p.y, p instanceof Point, b.n, b instanceof Box, e instanceof Empty].join('|');
