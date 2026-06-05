var s = Symbol('k');
var o = {};
o[s] = 42;
var s2 = Symbol('k');
[o[s], String(o[s2]), Object.keys(o).length, Object.getOwnPropertySymbols(o).length, Object.getOwnPropertySymbols(o)[0] === s].join('|');
