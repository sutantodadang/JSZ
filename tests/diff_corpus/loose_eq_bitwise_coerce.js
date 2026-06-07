// Phase 13: == loose-equality ToPrimitive + bitwise object coercion.
var o = { valueOf: function () { return 6; } };
var s = { toString: function () { return "hi"; } };
[
  o == 6, o == 7, 6 == o, o != 7,
  s == "hi",
  o & 3, o | 1, o ^ 2, o << 1, o >> 1, o >>> 1, ~o,
].join(",")
