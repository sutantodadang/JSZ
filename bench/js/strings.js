// String building, search, split, replace.
var warmS = "ab" + "cd";
var t0 = Date.now();
var parts = [];
for (var i = 0; i < 20000; i++) parts.push("item-" + i + "-x");
var big = parts.join(";");
var hits = 0;
for (var k = 0; k < 200; k++) {
  if (big.indexOf("item-" + (k * 97) + "-x") !== -1) hits++;
}
var re = big.split(";");
var repl = big.replace("item-500-x", "REPLACED").length;
var t1 = Date.now();
console.log("strings," + (t1 - t0) + "," + (hits + re.length + repl + warmS.length));
