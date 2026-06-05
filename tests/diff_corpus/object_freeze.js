var o = { a: 1, b: 2 };
Object.freeze(o);
o.a = 10;
o.c = 3;
delete o.b;
[o.a, o.b, o.c, Object.isFrozen(o), Object.isExtensible(o), Object.keys(o).join(',')].join('|');
