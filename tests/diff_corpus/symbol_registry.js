var a = Symbol.for('k');
var b = Symbol.for('k');
var c = Symbol('k');
[a === b, a === c, Symbol.keyFor(a), String(Symbol.keyFor(c))].join('|');
