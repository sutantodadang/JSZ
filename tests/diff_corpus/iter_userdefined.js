var o = {};
o[Symbol.iterator] = function () {
  var i = 0;
  return {
    next: function () {
      return i < 3 ? { value: i++, done: false } : { value: undefined, done: true };
    }
  };
};
var out = [];
for (var x of o) out.push(x);
out.join(',');
