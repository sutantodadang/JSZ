var s1 = Symbol('a');
var s2 = Symbol('a');
[typeof s1, s1 === s1, s1 === s2, s1.toString(), String(typeof Symbol.iterator)].join('|');
