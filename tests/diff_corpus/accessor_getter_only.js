var o = {};
Object.defineProperty(o, 'r', { get: function () { return 42; }, configurable: true });
o.r = 99;
[o.r, typeof Object.getOwnPropertyDescriptor(o, 'r').set].join('|');
