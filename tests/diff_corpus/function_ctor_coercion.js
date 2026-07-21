// Wave 45a: CreateDynamicFunction ToString's every argument (a non-string
// parameter name used to be dropped, leaving a stray comma in the source);
// a bound function is tagged "[object Function]"; Object.create accepts a
// callable as the prototype.
function t(f) { try { return String(f()); } catch (e) { return "THROW " + e.constructor.name; } }
var i = 0;
var p = { toString: function () { return "a" + (++i); } };
var target = {};
function foo() {}
function g() {}
[
  t(function () {
    Function(p, "a2,a3", "this.shifted=a1;").apply(target, ["nine", "inch", "nails"]);
    return target.shifted;
  }),
  t(function () { return Function(1, "return a" + "1;")(7); }),
  Object.prototype.toString.call(foo.bind({})),
  Object.prototype.toString.call(foo),
  // Object.create(callable) links the chain instead of throwing. NOTE: the
  // resulting [[Prototype]] is the function's backing object, so
  // `getPrototypeOf(o) === g` is still false here -- a pre-existing gap that
  // also affects Object.setPrototypeOf and class static chains, so it is not
  // asserted.
  typeof Object.create(g).apply,
  Object.create(g) instanceof Function
].join("|")
