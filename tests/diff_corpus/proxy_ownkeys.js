// Phase 13: Proxy ownKeys + getOwnPropertyDescriptor traps.
var p = new Proxy({}, {
  ownKeys: function (t) { return ["a", "b", "c"]; },
  getOwnPropertyDescriptor: function (t, k) {
    return { enumerable: true, configurable: true, value: k };
  },
});
Object.keys(p).join(",") + "|" + Object.getOwnPropertyNames(p).join(",")
