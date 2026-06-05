function C() {}
C.prototype.tag = 7;
var c = new C();
[Object.getPrototypeOf(c) === C.prototype, Object.getPrototypeOf(c).tag, typeof Object.getPrototypeOf({})].join('|');
