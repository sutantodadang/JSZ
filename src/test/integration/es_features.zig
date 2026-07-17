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

const captureDebugHook = helpers.captureDebugHook;


// ---- Phase 8: ES2016/ES2017 builtins ----

test "es2016: Array.prototype.includes finds value" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "[1,2,3].includes(2)"));
}


test "es2016: Array.prototype.includes missing value" {
    try std.testing.expect(!try evalToBool(std.testing.allocator, "[1,2,3].includes(4)"));
}


test "es2016: Array.prototype.includes matches NaN (SameValueZero)" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "[1,NaN,3].includes(NaN)"));
}


test "es2017: String.prototype.padStart" {
    const s = try evalToString(std.testing.allocator, "'5'.padStart(3,'0')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("005", s);
}


test "es2017: String.prototype.padEnd" {
    const s = try evalToString(std.testing.allocator, "'5'.padEnd(3,'-')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("5--", s);
}


test "es2017: String.prototype.padStart no-op when long enough" {
    const s = try evalToString(std.testing.allocator, "'abcd'.padStart(2,'0')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abcd", s);
}


test "es2017: Object.entries" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify(Object.entries({a:1,b:2}))");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[[\"a\",1],[\"b\",2]]", s);
}


test "es2019: Array.prototype.flat default depth 1" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify([1,[2,3],[4]].flat())");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[1,2,3,4]", s);
}


test "es2019: Array.prototype.flat is shallow by default" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify([1,[2,[3]]].flat())");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[1,2,[3]]", s);
}


test "es2019: Array.prototype.flatMap" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify([1,2,3].flatMap(function(x){return [x,x*2];}))");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[1,2,2,4,3,6]", s);
}


test "es2019: String.prototype.trimStart" {
    const s = try evalToString(std.testing.allocator, "'  hi  '.trimStart() + '|'");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hi  |", s);
}


test "es2019: String.prototype.trimEnd" {
    const s = try evalToString(std.testing.allocator, "'|' + '  hi  '.trimEnd()");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("|  hi", s);
}


test "es2019: Object.fromEntries round-trips Object.entries" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify(Object.fromEntries(Object.entries({a:1,b:2})))");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", s);
}


// NOTE: strictness is per-function (the directive must be in the function's own
// body â€” this engine does not inherit strictness from the enclosing scope), so
// the `'use strict'` prologue lives inside each tail-recursive function.

test "tco: strict tail recursion returns correct result (tree+bc)" {
    // Accumulator-style tail recursion: sum(1..n). Small n so the tree-walker
    // (no TCO, native recursion) does not overflow â€” correctness parity check.
    const src = "function sum(n, acc){ 'use strict'; if (n === 0) return acc; return sum(n - 1, acc + n); } sum(100, 0)";
    const v = try dualF64(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 5050), v);
}


test "tco: strict tail recursion keeps call stack O(1) in bc mode" {
    const src = "function sum(n, acc){ 'use strict'; if (n === 0) return acc; return sum(n - 1, acc + n); } sum(20000, 0)";
    const r = try evalBcWithFrames(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 200010000), r.value);
    // Top-level frame + one reused callee frame. PTC must not grow per call.
    try std.testing.expect(r.frames <= 4);
}


test "tco: non-strict recursion is NOT tail-optimized (stack grows)" {
    // Same shape, sloppy mode: PTC does not apply, so frames grow with depth.
    const src = "function sum(n, acc){ if (n === 0) return acc; return sum(n - 1, acc + n); } sum(4000, 0)";
    const r = try evalBcWithFrames(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 8002000), r.value);
    try std.testing.expect(r.frames > 1000);
}


test "tco: mutual tail recursion (strict) terminates" {
    const src =
        "function isEven(n){ 'use strict'; if (n === 0) return true; return isOdd(n - 1); }" ++
        "function isOdd(n){ 'use strict'; if (n === 0) return false; return isEven(n - 1); }" ++
        "isEven(50000) ? 1 : 0";
    const r = try evalBcWithFrames(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 1), r.value);
    try std.testing.expect(r.frames <= 4);
}


test "tco: member-position tail recursion keeps stack O(1) in bc mode" {
    // `return o.sum(...)` is a member-position tail call (TAIL_METHOD_CALL).
    const src = "var o = { sum: function(n, acc){ 'use strict'; if (n === 0) return acc; return o.sum(n - 1, acc + n); } }; o.sum(20000, 0)";
    const r = try evalBcWithFrames(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 200010000), r.value);
    try std.testing.expect(r.frames <= 4);
}


test "tco: call in try is not a tail call (correctness preserved)" {
    // `return f()` inside try must still run finally and return correctly.
    const src =
        "function inner(){ return 7; }" ++
        "function outer(){ 'use strict'; try { return inner(); } finally { } }" ++
        "outer()";
    const v = try dualF64(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 7), v);
}


test "debugger: `debugger;` statement is a no-op without a hook (tree+bc)" {
    const v = try dualF64(std.testing.allocator, "function f(){ debugger; return 9; } f()");
    try std.testing.expectEqual(@as(f64, 9), v);
}


test "debugger: DEBUGGER opcode fires the installed hook (bc)" {
    helpers.dbg_hits = 0;
    helpers.dbg_last_fn = "";
    root.debug.installHook(captureDebugHook, null);
    defer root.debug.clearHook();

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    _ = ctx.eval("function f(){ debugger; return 1; } f()", "<test>");

    try std.testing.expect(helpers.dbg_hits >= 1);
    try std.testing.expectEqualStrings("f", helpers.dbg_last_fn);
}


test "source map: emits functions, mappings, and line info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try root.sourceMap(arena.allocator(), "function add(a,b){ return a+b; } add(1,2)", "<sm>", &w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"functions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"<sm>\"") != null);
}


test "es2020: nullish coalescing basic" {
    try std.testing.expectEqual(@as(f64, 5), try dualF64(std.testing.allocator, "null ?? 5"));
    try std.testing.expectEqual(@as(f64, 7), try dualF64(std.testing.allocator, "undefined ?? 7"));
    // 0 and "" are NOT nullish â€” left operand is kept.
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "0 ?? 5"));
    try std.testing.expectEqual(@as(f64, 1), try dualF64(std.testing.allocator, "(false ?? 9) ? 2 : 1"));
}


test "es2020: nullish coalescing short-circuits RHS" {
    // f() must not run when the left operand is non-nullish.
    const src = "var c=0; function f(){c=1; return 9;} var x = 3 ?? f(); x*10+c";
    try std.testing.expectEqual(@as(f64, 30), try dualF64(std.testing.allocator, src));
    // ...but it does run when the left operand is nullish.
    const src2 = "var c=0; function f(){c=1; return 9;} var x = null ?? f(); x*10+c";
    try std.testing.expectEqual(@as(f64, 91), try dualF64(std.testing.allocator, src2));
}


test "es2020: nullish lower precedence than parenthesized or" {
    // (a || b) ?? c  -> a||b is 1, not nullish, result 1.
    try std.testing.expectEqual(@as(f64, 1), try dualF64(std.testing.allocator, "(0 || 1) ?? 5"));
}


test "es2020: mixing ?? with || or && is a SyntaxError" {
    try expectDualParseError("1 || 2 ?? 3");
    try expectDualParseError("1 ?? 2 || 3");
    try expectDualParseError("1 && 2 ?? 3");
    try expectDualParseError("1 ?? 2 && 3");
    // Statement-starting-with-identifier path (parseExprFromIdent).
    try expectDualParseError("var a=1,b=2,c=3; a || b ?? c");
    try expectDualParseError("var a=1,b=2,c=3; a ?? b && c");
}


test "es2020: nullish coalescing on identifier target" {
    // Exercises the parseExprFromIdent `??` path.
    try std.testing.expectEqual(@as(f64, 9), try dualF64(std.testing.allocator, "var a; a ?? 9"));
    try std.testing.expectEqual(@as(f64, 4), try dualF64(std.testing.allocator, "var a=4; a ?? 9"));
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var a=0; a ?? 9"));
}


test "es2020: optional chaining member access" {
    try std.testing.expectEqual(@as(f64, 5), try dualF64(std.testing.allocator, "var o={a:{b:5}}; o?.a?.b"));
    // nullish base short-circuits the whole chain to undefined.
    try std.testing.expect(try dualBool(std.testing.allocator, "var o=null; (o?.a?.b) === undefined"));
    // optional link on a null intermediate short-circuits (no TypeError).
    try std.testing.expect(try dualBool(std.testing.allocator, "var o={a:null}; (o?.a?.b) === undefined"));
}


test "es2020: optional computed index" {
    try std.testing.expectEqual(@as(f64, 20), try dualF64(std.testing.allocator, "var o={arr:[10,20]}; o?.arr?.[1]"));
    try std.testing.expect(try dualBool(std.testing.allocator, "var o=null; (o?.arr?.[0]) === undefined"));
}


test "es2020: optional call forms" {
    // method call present.
    try std.testing.expectEqual(@as(f64, 42), try dualF64(std.testing.allocator, "var o={f:function(){return 42;}}; o.f?.()"));
    // optional method call on missing method short-circuits.
    try std.testing.expect(try dualBool(std.testing.allocator, "var o={}; (o.g?.()) === undefined"));
    // optional call on nullish callee short-circuits.
    try std.testing.expect(try dualBool(std.testing.allocator, "var f=null; (f?.(1,2)) === undefined"));
}


test "es2020: optional chaining short-circuits rest of chain" {
    // o is null: `?.a` short-circuits so the `[c=5]` index is never evaluated.
    const src = "var c=0; var o=null; var r = o?.a[(c=5)]; c";
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, src));
    // o is null: optional method args are not evaluated either.
    const src2 = "var c=0; function f(){c=1; return 0;} var o=null; o?.m(f()); c";
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, src2));
}


test "es2020: ?. before a digit is the ternary operator" {
    // `x?.5:9` parses as `x ? .5 : 9`.
    try std.testing.expectEqual(@as(f64, 0.5), try dualF64(std.testing.allocator, "var x=1; x?.5:9"));
    try std.testing.expectEqual(@as(f64, 9), try dualF64(std.testing.allocator, "var x=0; x?.5:9"));
}


test "es2021: logical-and assignment" {
    try std.testing.expectEqual(@as(f64, 2), try dualF64(std.testing.allocator, "var x=1; x &&= 2; x"));
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var x=0; x &&= 2; x"));
}


test "es2021: logical-or assignment" {
    try std.testing.expectEqual(@as(f64, 5), try dualF64(std.testing.allocator, "var x=0; x ||= 5; x"));
    try std.testing.expectEqual(@as(f64, 3), try dualF64(std.testing.allocator, "var x=3; x ||= 5; x"));
}


test "es2021: nullish assignment" {
    try std.testing.expectEqual(@as(f64, 8), try dualF64(std.testing.allocator, "var x=null; x ??= 8; x"));
    try std.testing.expectEqual(@as(f64, 4), try dualF64(std.testing.allocator, "var x=4; x ??= 8; x"));
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var x=0; x ??= 8; x"));
}


test "es2021: logical assignment short-circuits RHS" {
    // x truthy -> ||= does NOT evaluate f().
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var c=0; function f(){c=1;return 1;} var x=5; x ||= f(); c"));
    // x non-nullish -> ??= does NOT evaluate f().
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var c=0; function f(){c=1;return 1;} var x=5; x ??= f(); c"));
    // x falsy -> &&= does NOT evaluate f().
    try std.testing.expectEqual(@as(f64, 0), try dualF64(std.testing.allocator, "var c=0; function f(){c=1;return 1;} var x=0; x &&= f(); c"));
}


test "es2021: logical assignment on member targets" {
    try std.testing.expectEqual(@as(f64, 7), try dualF64(std.testing.allocator, "var o={x:0}; o.x ||= 7; o.x"));
    try std.testing.expectEqual(@as(f64, 3), try dualF64(std.testing.allocator, "var o={}; o.y ??= 3; o.y"));
    try std.testing.expectEqual(@as(f64, 9), try dualF64(std.testing.allocator, "var o={}; var k='z'; o[k] ||= 9; o.z"));
    // member ??= keeps existing non-nullish value.
    try std.testing.expectEqual(@as(f64, 2), try dualF64(std.testing.allocator, "var o={x:2}; o.x ??= 9; o.x"));
}


// ---- Phase 8 catch-up: ES2017â€“2022 builtins (dual tree+bc) ----

test "es2020: globalThis is self-referential and exposes Math" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "globalThis === globalThis"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "globalThis === global"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "globalThis.Math === Math"));
}


test "es2017: Object.getOwnPropertyDescriptors" {
    const s = try evalToString(std.testing.allocator, "JSON.stringify(Object.getOwnPropertyDescriptors({a:1,b:2}).a)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("{\"value\":1,\"writable\":true,\"enumerable\":true,\"configurable\":true}", s);
}


test "es2021: String.prototype.replaceAll string pattern" {
    const s = try evalToString(std.testing.allocator, "'a-b-a'.replaceAll('a','x')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("x-b-x", s);
}


test "es2022: Array.prototype.at positive and negative" {
    try std.testing.expectEqual(@as(f64, 2), try dualF64(std.testing.allocator, "[1,2,3].at(1)"));
    try std.testing.expectEqual(@as(f64, 1), try dualF64(std.testing.allocator, "[1,2,3].at(-3)"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "[1,2,3].at(99) === undefined"));
}


test "es2022: Array.prototype.findLast and findLastIndex" {
    try std.testing.expectEqual(@as(f64, 3), try dualF64(std.testing.allocator, "[1,2,3,4,3].findLast(function(x){ return x > 2; })"));
    try std.testing.expectEqual(@as(f64, 4), try dualF64(std.testing.allocator, "[1,2,3,4,3].findLastIndex(function(x){ return x > 2; })"));
}


test "es2020: Promise.allSettled mixed outcomes" {
    const v = try evalToF64(std.testing.allocator, "var a=0,b=0; Promise.allSettled([Promise.resolve(5), Promise.reject(7)]).then(function(rs){ a=rs[0].value; b=rs[1].reason; }); __runMicrotasks__(); a+b");
    try std.testing.expectEqual(@as(f64, 12), v);
}


test "es2020: Promise.allSettled preserves order" {
    const s = try evalToString(std.testing.allocator, "var s=''; Promise.allSettled([Promise.resolve(1), 2, Promise.reject(3)]).then(function(rs){ s=rs[0].status+rs[1].status+rs[2].status; }); __runMicrotasks__(); s");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("fulfilledfulfilledrejected", s);
}



// --------------------------------------------------------------- BigInt (ES2020)

test "es2020: BigInt typeof and literal forms" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "typeof 123n === 'bigint'"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "typeof BigInt(1) === 'bigint'"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "typeof 1 === 'number'"));
    // 0x/0o/0b literal prefixes carry over to BigInt literals.
    try std.testing.expect(try evalToBool(std.testing.allocator, "0xffn === 255n && 0b1011n === 11n && 0o17n === 15n"));
}

test "es2020: BigInt arithmetic is arbitrary precision" {
    const s = try evalToString(std.testing.allocator, "(2n ** 100n).toString()");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1267650600228229401496703205376", s);
    // Exact past 2^53, where f64 would lose precision.
    const p = try evalToString(std.testing.allocator, "(9007199254740993n * 9007199254740993n).toString()");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("81129638414606699710187514626049", p);
    // Division truncates toward zero; remainder takes the dividend's sign.
    try std.testing.expect(try evalToBool(std.testing.allocator, "7n / 2n === 3n && -7n / 2n === -3n && -7n % 2n === -1n"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "2n + 3n === 5n && 2n - 5n === -3n && 4n * 5n === 20n"));
}

test "es2020: BigInt comparisons" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "1n < 2n && 2n > 1n && 2n <= 2n && !(2n >= 3n)"));
    // Loose equality crosses the Number/BigInt boundary; strict does not.
    try std.testing.expect(try evalToBool(std.testing.allocator, "1n == 1 && !(1n === 1) && 1n === 1n"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "1n < 2 && 2 > 1n"));
}

test "es2020: BigInt conversion — ctor, toString, valueOf, ToString/ToBoolean" {
    try std.testing.expect(try evalToBool(std.testing.allocator, "BigInt(42) === 42n && BigInt('99') === 99n && BigInt(true) === 1n"));
    const r = try evalToString(std.testing.allocator, "(255n).toString(16)");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("ff", r);
    try std.testing.expect(try evalToBool(std.testing.allocator, "(7n).valueOf() === 7n"));
    // ToString must NOT carry the `n` suffix (that is console-inspect syntax).
    try std.testing.expect(try evalToBool(std.testing.allocator, "String(1n) === '1' && (1n + 'x') === '1x' && ('' + 255n) === '255'"));
    // 0n is the only falsy BigInt.
    try std.testing.expect(try evalToBool(std.testing.allocator, "Boolean(0n) === false && Boolean(1n) === true && !0n && !!(-1n)"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "(0n ? 1 : 2) === 2"));
}

test "es2020: BigInt cannot mix with Number in arithmetic" {
    const src =
        \\function t(f) { try { f(); return 'no'; } catch (e) { return e.name; } }
        \\[t(function(){return 1n+1;}), t(function(){return 1+1n;}),
        \\ t(function(){return 1n-1;}), t(function(){return 1n*2;}),
        \\ t(function(){return 1n/2;}), t(function(){return 1n%2;}),
        \\ t(function(){return 2n**2;}), t(function(){return +1n;})].join(',')
    ;
    const s = try evalToString(std.testing.allocator, src);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError", s);
    // String concat and relational compare stay legal across the boundary.
    try std.testing.expect(try evalToBool(std.testing.allocator, "(1n + 'x') === '1x' && (1n < 2) === true"));
}

test "es2020: BigInt division by zero and bad conversions throw" {
    const src =
        \\function t(f) { try { f(); return 'no'; } catch (e) { return e.name; } }
        \\[t(function(){return 1n/0n;}), t(function(){return 1n%0n;}),
        \\ t(function(){return 2n**-1n;}), t(function(){return BigInt('abc');}),
        \\ t(function(){return BigInt(1.5);})].join(',')
    ;
    const s = try evalToString(std.testing.allocator, src);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("RangeError,RangeError,RangeError,SyntaxError,RangeError", s);
}

test "es2020: BigInt StringToBigInt handles sign, whitespace, and empty" {
    // A signed decimal string is valid input even though `-10n` as a literal is
    // really unary minus applied to `10n`.
    try std.testing.expect(try evalToBool(std.testing.allocator, "BigInt('-10') === -10n && BigInt('+7') === 7n"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "BigInt('   7   ') === 7n && BigInt('     ') === 0n && BigInt('') === 0n"));
    try std.testing.expect(try evalToBool(std.testing.allocator, "BigInt('   0b1111') === 15n && BigInt('0x1f') === 31n"));
    const src =
        \\function t(s) { try { BigInt(s); return 'no'; } catch (e) { return e.name; } }
        \\// A sign is legal only on the decimal form; no points/exponents/Infinity.
        \\[t('-0x1f'), t('1.5'), t('1e3'), t('Infinity'), t('-'), t('abc')].join(',')
    ;
    const s = try evalToString(std.testing.allocator, src);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError,SyntaxError", s);
}
