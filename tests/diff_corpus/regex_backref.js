// Phase 4d: regex backreferences \1
var r1 = /(\w)\1/.exec("hello");
var r2 = /(\w)\1/.exec("abc");
r1[0] + "|" + (r2 === null ? "null" : "WRONG")
