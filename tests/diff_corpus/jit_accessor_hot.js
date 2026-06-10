// Phase 12 S8: hot accessor get/set + store-then-overflow fine-deopt.
// Under a -Djit build the differential harness runs this with the experimental
// JIT enabled, so Node parity gates the re-entrant property helper and the
// exact-once store across an overflow fine-deopt.
var o = {};
Object.defineProperty(o, 'x', { get: function () { return 7; }, set: function (v) { this.v = v * 2; } });
function g(p) { return p.x + 1; }
function st(p, v) { p.x = v; }
function h(b, a, c) { b.n = b.n + 1; return a * c; }
var r = 0;
for (var i = 0; i < 200; i++) { r = g(o); st(o, i); }
var bag = { n: 0 };
var big = 0;
for (var j = 0; j < 100; j++) { big = h(bag, 100000000, 100000000); }
r + "|" + o.v + "|" + bag.n + "|" + (big === 1e16);
