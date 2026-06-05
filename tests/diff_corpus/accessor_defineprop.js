var o = {};
Object.defineProperty(o, 'x', {
  get: function () { return this._x === undefined ? 0 : this._x; },
  set: function (v) { this._x = v * 2; },
  enumerable: true,
  configurable: true
});
var before = o.x;
o.x = 5;
var d = Object.getOwnPropertyDescriptor(o, 'x');
[before, o.x, typeof d.get, typeof d.set, d.enumerable, ('value' in d)].join('|');
