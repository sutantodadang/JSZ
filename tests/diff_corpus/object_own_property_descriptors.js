// getOwnPropertyDescriptors runs [[OwnPropertyKeys]] + [[GetOwnProperty]], so it
// sees symbols, string primitives and Proxy traps in spec order.
var out = [];
var sym = Symbol('s');
var o = { x: 1 };
o[sym] = 2;
Object.defineProperty(o, 'g', { get: function () { return 3; }, configurable: true });
var d = Object.getOwnPropertyDescriptors(o);
out.push(Object.getOwnPropertyNames(d).join(','));
out.push(Object.getOwnPropertySymbols(d).length);
out.push(Object.keys(d.g).sort().join(','));
out.push(Object.getOwnPropertyNames(Object.getOwnPropertyDescriptors('ab')).join(','));
out.push(JSON.stringify(Object.getOwnPropertyDescriptor('abc', 1)));
out.push(JSON.stringify(Object.getOwnPropertyDescriptor('abc', 'length')));

var log = [];
var proxy = new Proxy({ a: 1, b: 2 }, {
  ownKeys: function (t) { log.push('ownKeys'); return Object.getOwnPropertyNames(t); },
  getOwnPropertyDescriptor: function (t, k) { log.push('gOPD:' + k); return Object.getOwnPropertyDescriptor(t, k); }
});
Object.getOwnPropertyDescriptors(proxy);
out.push(log.join('>'));

try { Object.getOwnPropertyDescriptors(null); out.push('ok'); } catch (e) { out.push(e.constructor.name); }
out.join('|');
