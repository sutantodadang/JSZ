var s = Symbol('m');
var proto = {};
proto[s] = 'hi';
function C() {}
C.prototype = proto;
var c = new C();
[c[s], Object.getOwnPropertySymbols(c).length, Object.getOwnPropertySymbols(proto).length].join('|');
