// Wave 45a: Object.prototype.valueOf must ToObject its receiver, isPrototypeOf
// must check V before ToObject(this), and @@toStringTag must be honoured on
// callables / reported for Promise + String Iterator.
function t(f) { try { return String(f()); } catch (e) { return "THROW " + e.constructor.name; } }
var ts = Object.prototype.toString;
var fn = function () {};
fn[Symbol.toStringTag] = 'test262';
[
  typeof Object.prototype.valueOf.call(true),
  typeof Object.prototype.valueOf.call(1),
  t(function () { return Object.prototype.valueOf.call(undefined); }),
  t(function () { return Object.prototype.valueOf.call(null); }),
  Object.prototype.isPrototypeOf.call(null, undefined),
  Object.prototype.isPrototypeOf.call(null, 10),
  t(function () { return Object.prototype.isPrototypeOf.call(null, {}); }),
  ts.call(fn),
  ts.call(Promise.resolve()),
  ts.call(""[Symbol.iterator]()),
  ts.call([][Symbol.iterator]())
].join("|")
