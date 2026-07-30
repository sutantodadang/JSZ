// Regex: test/exec/replace over generated text.
var lines = [];
for (var i = 0; i < 5000; i++) {
  lines.push("user" + i + "@host" + (i % 50) + ".example.com level=" + (i % 5));
}
var text = lines.join("\n");
/x/.test("wx"); // warmup
var t0 = Date.now();
var emailRe = /([a-z]+[0-9]+)@([a-z]+[0-9]+)\.example\.com/;
var hits = 0;
for (var k = 0; k < lines.length; k++) {
  if (emailRe.test(lines[k])) hits++;
}
var m = text.match(/level=4/g);
var cleaned = text.replace(/level=[0-9]/g, "L").length;
var t1 = Date.now();
console.log("regex," + (t1 - t0) + "," + (hits + (m ? m.length : 0) + cleaned % 1000));
