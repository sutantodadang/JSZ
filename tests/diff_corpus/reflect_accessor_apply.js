var o = {};
Reflect.defineProperty(o, 'x', { get: function () { return 10; }, configurable: true });
function add(a, b) { return a + b + this.base; }
var r = Reflect.apply(add, { base: 100 }, [2, 3]);
[Reflect.get(o, 'x'), r, typeof Reflect.getOwnPropertyDescriptor(o, 'x').get].join('|');
