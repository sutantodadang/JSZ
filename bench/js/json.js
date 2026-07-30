// JSON stringify + parse roundtrip on a synthetic tree.
function mk(depth, width) {
  var o = { d: depth, items: [] };
  for (var i = 0; i < width; i++) {
    o.items.push(depth === 0
      ? { id: i, name: "leaf-" + i, on: (i & 1) === 0, v: i * 1.5 }
      : mk(depth - 1, width));
  }
  return o;
}
var tree = mk(4, 6);
JSON.parse(JSON.stringify({ warm: 1 }));
var t0 = Date.now();
var acc = 0;
for (var r = 0; r < 20; r++) {
  var s = JSON.stringify(tree);
  var back = JSON.parse(s);
  acc += s.length + back.items.length;
}
var t1 = Date.now();
console.log("json," + (t1 - t0) + "," + acc);
