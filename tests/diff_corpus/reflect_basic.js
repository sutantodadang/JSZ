var o = { a: 1 };
Reflect.set(o, 'b', 2);
var got = Reflect.get(o, 'a') + Reflect.get(o, 'b');
var has = Reflect.has(o, 'a') && !Reflect.has(o, 'zzz');
var del = Reflect.deleteProperty(o, 'a');
[got, has, del, Reflect.ownKeys(o).join(','), Reflect.getPrototypeOf(o) === Object.prototype].join('|');
