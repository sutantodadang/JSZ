var o = { a: 1, get b() { return this.a * 2; } };
o.b = 99;
[o.a, o.b, typeof Object.getOwnPropertyDescriptor(o, 'b').set, Object.keys(o).join(',')].join('|');
