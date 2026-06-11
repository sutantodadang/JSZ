// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const helpers = @import("./helpers.zig");
const evalToF64Mode = helpers.evalToF64Mode;
const evalToStringMode = helpers.evalToStringMode;
const evalToBoolMode = helpers.evalToBoolMode;
const dualF64 = helpers.dualF64;
const dualString = helpers.dualString;
const dualBool = helpers.dualBool;
const evalToF64 = helpers.evalToF64;
const evalToString = helpers.evalToString;
const evalToBool = helpers.evalToBool;
const evalBcWithFrames = helpers.evalBcWithFrames;
const expectDualParseError = helpers.expectDualParseError;
const evalExperimental = helpers.evalExperimental;
const root = helpers.root;
const build_options = helpers.build_options;
const Isolate = root.Isolate;
const InterpMode = helpers.InterpMode;


test "W2 unification: promise microtasks closure side effects (both modes)" {
    // Was tree-only; bc reaction queue now matches.
    const v = try dualF64(
        std.testing.allocator,
        "var r=0; Promise.resolve(5).then(function(x){ r = x + 1; }); __runMicrotasks__(); r",
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "W2 unification: class constructor field init (both modes)" {
    // Was tree-only (bc constructor gap); bc now has real new/prototype.
    const v = try dualF64(
        std.testing.allocator,
        "class C { constructor(){ this.n = 7; } } (new C()).n",
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}


test "W2 unification: class methods + extends + super (both modes)" {
    const v = try dualF64(
        std.testing.allocator,
        "class A{ constructor(x){ this.x=x; } m(){ return this.x; } } class B extends A{ constructor(){ super(5); } m(){ return super.m()+1; } } (new B()).m()",
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "W2 unification: instanceof across class hierarchy (bc; Node=11)" {
    // bc only: the tree-walker has a latent bug here (returns 0 â€” instanceof
    // across a default-constructor `extends` chain), but bc matches Node (11).
    // The tree engine is being retired, so this is asserted against bc directly.
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A{} class B extends A{} var b=new B(); (b instanceof B ? 1 : 0) + (b instanceof A ? 10 : 0)",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 11), v);
}


test "W2 unification: plain constructor function + prototype method (both modes)" {
    const v = try dualF64(
        std.testing.allocator,
        "function C(v){ this.v=v; } C.prototype.get=function(){ return this.v+2; }; (new C(10)).get()",
    );
    try std.testing.expectEqual(@as(f64, 12), v);
}


test "W2: generator next yields values and done in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; yield 2; return 7; } var it = g(); var a = it.next(); var b = it.next(); var c = it.next(); a.value + b.value + c.value + (a.done?1000:0) + (b.done?100:0) + (c.done?10:0)",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 20), v); // 1+2+7 + c.done*10
}


test "W2: generator receives sent value via next(v) in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ var x = yield 1; return x + 5; } var it = g(); it.next(); it.next(10).value",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 15), v);
}


test "W2: generator return() finishes the generator in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; yield 2; } var it=g(); var a=it[\"return\"](9); var b=it.next(); a.value + (a.done?100:0) + (b.done?10:0)",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 119), v); // 9 + 100 + 10
}


test "W2: generator throw() propagates in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; } var it=g(); var c=0; try { it[\"throw\"](7); } catch(e) { c=e; } c + (it.next().done ? 10 : 0)",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 17), v); // 7 + 10
}


test "W2: for-of over a generator in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 4; yield 5; } var s=0; for (var x of g()) { s = s + x; } s",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 9), v);
}


test "W2: for-of over an array in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var s=0; for (var x of [10,20,30]) { s = s + x; } s",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 60), v);
}


test "W2: yield* delegation in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* inner(){ yield 1; yield 2; yield 3; } function* outer(){ yield* inner(); } var s=0; for (var x of outer()) s = s + x; s",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}


// ---------------------------------------------------------- W2-async: async/await ---
// Real reaction-driven async/await in bc mode. Top-level `await` drains the
// microtask queue, so an awaited async-fn result observes its settled value.

test "W2-async: await of a plain value resumes in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "async function f(){ return (await 10) + 5; } await f()",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 15), v);
}


test "W2-async: sequential awaits accumulate in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "async function f(){ var a = await 1; var b = await 2; var c = await 3; return a+b+c; } await f()",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "W2-async: async function returns a thenable in bc mode" {
    const s = try evalToStringMode(
        std.testing.allocator,
        "async function f(){ return 7; } typeof f().then",
        .bc,
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("function", s);
}


test "W2-async: await of a resolved promise in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "async function f(){ return (await Promise.resolve(41)) + 1; } await f()",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}


test "W2-async: rejected await is caught by try/catch in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "async function f(){ try { await Promise.reject(99); return 0; } catch(e){ return e + 1; } } await f()",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 100), v); // 99 caught + 1
}


test "W2-async: async arrow function awaits in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var g = async (x) => (await x) + 3; await g(5)",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 8), v);
}


test "W2-async: awaited async calls compose in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "async function inc(x){ return (await x) + 1; } async function f(){ return await inc(await inc(10)); } await f()",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 12), v);
}


// ---- Phase 8: top-level await (synchronous-drain) ----

test "await: resolves a fulfilled promise" {
    const v = try evalToF64(std.testing.allocator, "var r = await Promise.resolve(41); r + 1");
    try std.testing.expectEqual(@as(f64, 42), v);
}


test "await: chained then" {
    const v = try evalToF64(std.testing.allocator, "await Promise.resolve(3).then(function(x){ return x * 10; })");
    try std.testing.expectEqual(@as(f64, 30), v);
}


test "await: rejection is catchable" {
    const v = try evalToF64(std.testing.allocator, "var r = 0; try { await Promise.reject(5); } catch (e) { r = e + 1; } r");
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "await: non-promise passes through" {
    const v = try evalToF64(std.testing.allocator, "await 99");
    try std.testing.expectEqual(@as(f64, 99), v);
}


test "promise: then callback runs under microtask drain (tree+bc)" {
    const v = try evalToF64(std.testing.allocator, "var r=0; Promise.resolve(3).then(function(x){ return x*10; }).then(function(y){ r=y; }); __runMicrotasks__(); r");
    try std.testing.expectEqual(@as(f64, 30), v);
}

