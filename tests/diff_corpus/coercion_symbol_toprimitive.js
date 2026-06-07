// Phase 13: Symbol.toPrimitive hint dispatch (number / string / default).
var o = {};
o[Symbol.toPrimitive] = function (hint) {
  return hint === "number" ? 10 : hint === "string" ? "S" : "D";
};
[o + 1, "" + o, String(o), Number(o)].join("|")
