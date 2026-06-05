// Depth-2 proto-chain IC parity: b.x found at depth-1 (A.prototype),
// b.y found at depth-2 (Base.prototype -> A.prototype chain). Sync-comparable.
function Base() {}
Base.prototype.y = 99;
function A() { this.v = 1; }
A.prototype = new Base();
A.prototype.x = 7;
var a = new A();
var out = "";
for (var i = 0; i < 1000; i++) {
  out = a.x + "|" + a.y;
}
out;
