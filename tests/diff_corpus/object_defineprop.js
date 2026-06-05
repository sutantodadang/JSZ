var o = {};
Object.defineProperty(o, 'x', { value: 42, writable: false, enumerable: false, configurable: false });
var d = Object.getOwnPropertyDescriptor(o, 'x');
var keys = Object.keys(o).length;
var names = Object.getOwnPropertyNames(o).join(',');
o.x = 99;
[o.x, d.value, d.writable, d.enumerable, d.configurable, keys, names].join('|');
