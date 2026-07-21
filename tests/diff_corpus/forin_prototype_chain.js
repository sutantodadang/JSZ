// Wave 45a: for-in must walk the prototype chain (EnumerateObjectProperties),
// skip keys already seen lower down (so a non-enumerable own property shadows
// an enumerable inherited one), and ToObject a primitive string operand.
function A() { this.a = 1; }
A.prototype.b = 2;
A.prototype.c = 3;
var keys = [];
for (var k in new A()) keys.push(k);

var p = {};
Object.defineProperty(p, "s", { value: 1, enumerable: true });
var shadowed = Object.create(p);
Object.defineProperty(shadowed, "s", { value: 2, enumerable: false });
var shadowKeys = [];
for (var k2 in shadowed) shadowKeys.push(k2);

// An enumerable inherited property does show through when not shadowed.
var visible = Object.create(p);
var visibleKeys = [];
for (var k3 in visible) visibleKeys.push(k3);

function collect(o) { var r = []; for (var k in o) r.push(k); return r.join(""); }
[
  keys.join(","),
  shadowKeys.length,
  visibleKeys.join(","),
  collect([1, 2]),
  collect("ab"),
  collect(new String("ab")),
  collect(5),
  collect(new Date()),
  collect({ q: 1 })
].join("|")
