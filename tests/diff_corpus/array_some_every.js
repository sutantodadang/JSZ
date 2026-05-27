var s = [1, 2, 3].some(function(x) { return x > 2; });
var e = [1, 2, 3].every(function(x) { return x > 0; });
s === true && e === true ? "ok" : "fail"
