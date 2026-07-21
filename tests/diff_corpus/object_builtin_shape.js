// Built-in constructor `prototype` slots are locked, %Object.prototype% has an
// immutable [[Prototype]], and the native `__call__` machinery slot stays
// invisible to reflection.
//
// NOT covered: §20.2.3 also makes %Function.prototype% a callable built-in
// (`typeof` "function", returns undefined, "[object Function]"). jsz models it
// as a plain object -- see the note in realm.zig setupFunctionProto: the only
// [[Call]] hook is a `__call__` slot found by a prototype-chain walk, so making
// it callable would also make every object inheriting from it (bound functions,
// %GeneratorFunction.prototype%) look callable and could pre-empt bound-function
// dispatch. Fixing it needs a per-object callable brand at each IsCallable site.
var out = [];
function attrs(o, k) {
  var d = Object.getOwnPropertyDescriptor(o, k);
  return [d.writable, d.enumerable, d.configurable].join(',');
}
out.push(attrs(Object, 'prototype'));
out.push(attrs(Function, 'prototype'));
out.push(attrs(Array, 'prototype'));
out.push(attrs(RegExp, 'prototype'));
out.push(Object.getOwnPropertyNames(Object).indexOf('__call__'));
out.push(Object.keys(Object).length);

var np = Object.create(null);
try { Object.setPrototypeOf(Object.prototype, np); out.push('ok'); } catch (e) { out.push(e.constructor.name); }
out.push(Reflect.setPrototypeOf(Object.prototype, np));
out.push(Reflect.setPrototypeOf(Object.prototype, null));

out.push(Object.is(undefined));
try { Object.getOwnPropertySymbols(undefined); out.push('ok'); } catch (e) { out.push(e.constructor.name); }
out.join('|');
