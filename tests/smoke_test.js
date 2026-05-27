// Smoke tests for Phase 4c
var results = [];

function check(name, val, expected) {
    var sv = "" + val;
    var se = "" + expected;
    var pass = sv === se;
    results.push(name + ": " + (pass ? "PASS" : "FAIL (got: " + sv + " expected: " + se + ")"));
}

check("basic test", /abc/.test("zabcd"), true);
check("anchor start false", /^abc/.test("xabc"), false);
check("quantifier plus exec", /a+/.exec("aaab")[0], "aaa");
check("capture group 2", /(\d+)-(\d+)/.exec("12-34")[2], "34");
check("match", "hello".match(/l+/)[0], "ll");
check("split by regex", "a,b,c".split(/,/).length, 3);
check("replace global", "hello".replace(/l/g, "L"), "heLLo");
check("search", "abc123".search(/\d/), 3);
check("ignore case", /foo/i.test("FOO"), true);
check("quantifier range", /\d{2,4}/.exec("a1234b")[0], "1234");
check("alternation", /cat|dog/.test("I like dogs"), true);
check("new RegExp", new RegExp("\\d+").test("abc7"), true);
var syntaxErrName; try{new RegExp("[")}catch(e){syntaxErrName=e.name}
check("SyntaxError", syntaxErrName, "SyntaxError");
check("replace captures", "a1b2c3".replace(/(\w)(\d)/g, "$2$1"), "1a2b3c");
check("lazy quantifier", /<.+?>/.exec("<a><b>")[0], "<a>");
check("multiline", /^bar/m.test("foo\nbar"), true);
check("anchor end", /abc$/.test("xabc"), true);
check("word boundary", /\bfoo\b/.test("foo bar"), true);

for (var i = 0; i < results.length; i++) {
    results[i];
}
results.join("\n");
