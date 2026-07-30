// GC churn workload for the CI valgrind memcheck job.
// Exercises nursery collections, old-to-young write barriers, ephemerons
// (WeakMap), string/array/object allocation, and property-shape transitions.
// Keep the iteration counts modest: this runs under valgrind (~30x slowdown).

var survivors = [];
var wm = new WeakMap();
var map = new Map();

for (var round = 0; round < 40; round++) {
  // Nursery garbage: short-lived objects, arrays, strings, closures.
  var junk = null;
  for (var i = 0; i < 2000; i++) {
    junk = {
      idx: i,
      pad: "str-" + i + "-" + round,
      arr: [i, i + 1, { nested: i }],
      fn: (function (n) { return function () { return n + 1; }; })(i),
    };
    if ((i & 63) === 0) junk.extra = i; // shape transition on a subset
  }

  // Promote a few per round; point old objects at fresh young ones so the
  // old-to-young remembered set / write barrier path is exercised.
  var kept = { round: round, ref: junk, list: [] };
  for (var k = 0; k < 20; k++) kept.list.push({ v: k, s: "keep" + k });
  survivors.push(kept);
  if (survivors.length > 8) {
    var old = survivors.shift();
    old.ref = { fresh: round }; // old object -> young object store
  }

  // Ephemeron churn: keys that die each round plus a few that survive.
  for (var e = 0; e < 100; e++) {
    var key = { e: e };
    wm.set(key, { payload: "ephemeral" + e });
    if (e < 3) kept.list.push(key);
  }

  map.set("round" + round, kept);
  if (map.size > 10) map.delete("round" + (round - 10));
}

var sum = 0;
for (var s = 0; s < survivors.length; s++) sum += survivors[s].list.length;
console.log("churn done: " + survivors.length + " survivors, sum=" + sum + ", map=" + map.size);
