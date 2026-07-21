// Wave 45a: a derived class replaces `prototype` with Object.create(...),
// so its `constructor` back-link must be DEFINED non-enumerable rather than
// plainly assigned -- otherwise it leaks into for-in over every instance.
var RES = [];
class A {}
class B extends Array {}
function F() {}
var dA = Object.getOwnPropertyDescriptor(A.prototype, "constructor");
var dB = Object.getOwnPropertyDescriptor(B.prototype, "constructor");
var dF = Object.getOwnPropertyDescriptor(F.prototype, "constructor");
function s(d) { return d ? JSON.stringify({ w: d.writable, e: d.enumerable, c: d.configurable }) : "MISSING"; }
RES.push("class A:", s(dA));
RES.push("class B extends:", s(dB));
RES.push("function F:", s(dF));
var keys = [];
for (var k in new A()) keys.push(k);
RES.push("for-in new A():", JSON.stringify(keys));
// methods on class prototypes must also be non-enumerable
class C { m() {} get g() { return 1; } static st() {} }
RES.push("C.prototype.m:", s(Object.getOwnPropertyDescriptor(C.prototype, "m")));
RES.push("C.prototype.g:", s(Object.getOwnPropertyDescriptor(C.prototype, "g")));
RES.push("C.st:", s(Object.getOwnPropertyDescriptor(C, "st")));
var ck = []; for (var k2 in new C()) ck.push(k2);
RES.push("for-in new C():", JSON.stringify(ck));

// The regression this guards: for-in over a typed-array subclass instance must
// yield only the indices, with no inherited `constructor`.
class MyU8 extends Uint8Array {}
var tk = [];
for (var k3 in new MyU8(new ArrayBuffer(8), 0, 3)) tk.push(k3);
RES.push("for-in subclass TA:", tk.join(","));

RES.join(" | ")
