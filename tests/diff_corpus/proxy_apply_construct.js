// Phase 13: Proxy apply + construct traps.
var pa = new Proxy(function () {}, {
  apply: function (t, thisArg, args) {
    return args.reduce(function (a, b) { return a + b; }, 0);
  },
});
var pc = new Proxy(function () {}, {
  construct: function (t, args) { return { total: args[0] * args[1] }; },
});
[pa(1, 2, 3, 4), new pc(5, 6).total].join(",")
