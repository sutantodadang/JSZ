// Wave 45a: ValidateAndApplyPropertyDescriptor compares with SameValue, so
// redefining a non-writable -0 as +0 must throw and leave -0 in place, while
// NaN -> NaN is a no-op. Plus Number/String.prototype.toLocaleString exist.
function t(f) { try { f(); return "no throw"; } catch (e) { return "THROW " + e.constructor.name; } }
var a = {}; Object.defineProperty(a, "x", { value: -0 });
var b = {}; Object.defineProperty(b, "y", { value: NaN });
var c = {}; Object.defineProperty(c, "z", { value: 1 });
[
  t(function () { Object.defineProperty(a, "x", { value: +0 }); }),
  1 / a.x,
  t(function () { Object.defineProperty(b, "y", { value: NaN }); }),
  t(function () { Object.defineProperty(c, "z", { value: 2 }); }),
  Object.prototype.hasOwnProperty.call(Number.prototype, "toLocaleString"),
  // String.prototype has no own toLocaleString -- it inherits Object.prototype's.
  Object.prototype.hasOwnProperty.call(String.prototype, "toLocaleString"),
  (1234.5).toLocaleString(),
  "abc".toLocaleString(),
  Object.getOwnPropertyDescriptor(Number.prototype, "toLocaleString").writable
].join("|")
