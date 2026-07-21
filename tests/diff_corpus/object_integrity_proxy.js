// SetIntegrityLevel / TestIntegrityLevel on a Proxy run the traps rather than
// the ordinary-object shortcut.
var out = [];
var sym = Symbol();
var target = {};
target[sym] = 1;
target.foo = 2;
target[0] = 3;

var seen = [];
var p1 = new Proxy(target, {
  getOwnPropertyDescriptor: function (t, k) { seen.push(String(k)); return Reflect.getOwnPropertyDescriptor(t, k); }
});
Object.freeze(p1);
out.push(seen.join(','));
out.push(Object.isFrozen(p1));
out.push(Object.isSealed(p1));

var p2 = new Proxy({}, { preventExtensions: function () { return false; } });
try { Object.freeze(p2); out.push('ok'); } catch (e) { out.push(e.constructor.name); }
try { Object.seal(p2); out.push('ok'); } catch (e) { out.push(e.constructor.name); }

var p3 = new Proxy({}, { preventExtensions: function () { throw new RangeError('x'); } });
try { Object.freeze(p3); out.push('ok'); } catch (e) { out.push(e.constructor.name); }

var descs = {};
var p4 = new Proxy({ get foo() {}, set foo(v) {} }, {
  defineProperty: function (t, k, d) { descs[k] = d; return Reflect.defineProperty(t, k, d); }
});
Object.freeze(p4);
out.push(Object.keys(descs.foo).join(','));
out.join('|');
