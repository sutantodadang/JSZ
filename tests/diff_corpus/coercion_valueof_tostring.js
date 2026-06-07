// Phase 13: ToPrimitive via user valueOf / toString in arithmetic and concat.
var a = { valueOf: function () { return 7; } };
var b = { toString: function () { return "hi"; } };
[a * 2, a - 1, a < 10, "" + b].join("|")
