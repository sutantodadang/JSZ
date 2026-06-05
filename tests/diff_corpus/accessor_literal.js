var o = {
  _v: 5,
  get x() { return this._v; },
  set x(n) { this._v = n + 1; }
};
var a = o.x;
o.x = 10;
var d = Object.getOwnPropertyDescriptor(o, 'x');
[a, o.x, typeof d.get, typeof d.set].join('|');
