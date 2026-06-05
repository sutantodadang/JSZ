// Regression: a constructor ending in an object/array expression must return
// `this`, not the trailing expression value; functions must not leak their last
// expression-statement value as the return.
function Box() { this.items = []; this.meta = { n: 1 }; }
var b = new Box();
b.items.push(10);
b.items.push(20);
b.meta.n = 5;
function plain() { 99; }
function withObjTail() { this; ({ a: 1 }); }
var w = new withObjTail();
[b.items.join(','), b.meta.n, Array.isArray(b.items), String(plain()), typeof w].join('|');
