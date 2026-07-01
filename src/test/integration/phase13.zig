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


// ---------------------------------------------------------------- Phase 13 ---
// ToPrimitive (Symbol.toPrimitive / valueOf / toString) + array-literal spread.

test "phase13: valueOf drives + arithmetic" {
    const v = try evalToF64(std.testing.allocator, "var o={valueOf:function(){return 5}}; o+1");
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "phase13: toString drives string concatenation" {
    const s = try dualString(std.testing.allocator, "var o={toString:function(){return 'x'}}; ''+o");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("x", s);
}


test "phase13: Symbol.toPrimitive hint dispatch" {
    const s = try dualString(std.testing.allocator, "var o={}; o[Symbol.toPrimitive]=function(h){return h}; (''+o)+'|'+String(o)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("default|string", s);
}


test "phase13: valueOf drives relational comparison" {
    const b = try dualBool(std.testing.allocator, "var o={valueOf:function(){return 10}}; o<20 && o>=10 && !(o>20)");
    try std.testing.expect(b);
}


test "phase13: plain object still coerces to [object Object]" {
    const s = try dualString(std.testing.allocator, "''+{}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[object Object]", s);
}


test "phase13: array spread over array literal (mixed)" {
    const s = try dualString(std.testing.allocator, "[0,...[1,2],3,...[4,5]].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("0,1,2,3,4,5", s);
}


test "phase13: array spread over string and Set" {
    const s = try dualString(std.testing.allocator, "var st=new Set([1,2,2]); [...'ab',...st].join('-')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("a-b-1-2", s);
}


test "phase13: array spread over a generator" {
    const s = try dualString(std.testing.allocator, "function* g(){yield 1;yield 2;yield 3;} [...g()].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,2,3", s);
}


test "phase13: spread of a non-iterable throws a catchable TypeError" {
    const s = try dualString(std.testing.allocator, "try{var x=[...5];'no'}catch(e){e.name}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("TypeError", s);
}


test "phase13: Proxy get trap intercepts reads" {
    const s = try dualString(std.testing.allocator, "var p=new Proxy({a:1},{get:function(t,k){return 'g:'+k;}}); p.anything");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("g:anything", s);
}


test "phase13: Proxy set trap transforms values" {
    const v = try evalToF64(std.testing.allocator, "var p=new Proxy({},{set:function(t,k,v){t[k]=v*2;return true;}}); p.a=5; p.a");
    try std.testing.expectEqual(@as(f64, 10), v);
}


test "phase13: Proxy with empty handler forwards to target" {
    const v = try evalToF64(std.testing.allocator, "var p=new Proxy({a:1,b:2},{}); p.c=3; p.a+p.b+p.c");
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "phase13: new Proxy with non-object throws TypeError" {
    const s = try dualString(std.testing.allocator, "try{var p=new Proxy(42,{});'no'}catch(e){e.name}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("TypeError", s);
}


test "phase13: throwing getter is catchable in try/catch" {
    const s = try dualString(std.testing.allocator, "var o={}; Object.defineProperty(o,'x',{get:function(){throw new TypeError('boom');}}); try{o.x}catch(e){e.message}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("boom", s);
}


test "phase13: throwing Proxy set trap is catchable" {
    const s = try dualString(std.testing.allocator, "var p=new Proxy({},{set:function(t,k,v){throw new TypeError('no');}}); try{p.a=1;'unreached'}catch(e){e.message}");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("no", s);
}


test "phase13: in operator (own/inherited/array)" {
    const s = try dualString(std.testing.allocator, "[('a' in {a:1}), (0 in [1,2]), (5 in [1,2]), ('length' in [1]), ('push' in [])].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true,true,false,true,true", s);
}


test "phase13: delete operator removes own property" {
    const s = try dualString(std.testing.allocator, "var o={a:1,b:2}; var r=delete o.a; r+'|'+('a' in o)+'|'+('b' in o)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true|false|true", s);
}


test "phase13: Proxy has trap drives the in operator" {
    const s = try dualString(std.testing.allocator, "var p=new Proxy({a:1},{has:function(t,k){return k==='magic';}}); ('magic' in p)+'|'+('a' in p)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true|false", s);
}


test "phase13: Proxy deleteProperty trap drives the delete operator" {
    const s = try dualString(std.testing.allocator, "var seen=''; var p=new Proxy({a:1},{deleteProperty:function(t,k){seen=k;delete t[k];return true;}}); var r=delete p.a; r+'|'+seen+'|'+('a' in p)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true|a|false", s);
}


test "phase13: == coerces object via valueOf" {
    const b = try dualBool(std.testing.allocator, "var o={valueOf:function(){return 5}}; o==5 && 5==o && !(o==6)");
    try std.testing.expect(b);
}


test "phase13: bitwise operators coerce object via valueOf" {
    const v = try evalToF64(std.testing.allocator, "var o={valueOf:function(){return 6}}; (o&3)+(o|1)+(~o)");
    // 6&3=2, 6|1=7, ~6=-7  => 2+7-7 = 2
    try std.testing.expectEqual(@as(f64, 2), v);
}


test "phase13: call-argument spread into named params" {
    const s = try dualString(std.testing.allocator, "function g(a,b,c,d,e){return [a,b,c,d,e].join(',');} g(1,...[2,3],4,...[5])");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,2,3,4,5", s);
}


test "phase13: spread call preserves method this-binding" {
    const v = try evalToF64(std.testing.allocator, "var o={base:10,add:function(a,b,c){return this.base+a+b+c;}}; o.add(...[1,2,3])");
    try std.testing.expectEqual(@as(f64, 16), v);
}


test "phase13: Proxy apply trap" {
    const v = try evalToF64(std.testing.allocator, "var p=new Proxy(function(){},{apply:function(t,th,a){return a[0]+a[1]+a[2];}}); p(1,2,3)");
    try std.testing.expectEqual(@as(f64, 6), v);
}


test "phase13: Proxy apply forwards when no trap" {
    const v = try evalToF64(std.testing.allocator, "function add(a,b){return a+b;} var p=new Proxy(add,{}); p(3,4)");
    try std.testing.expectEqual(@as(f64, 7), v);
}


test "phase13: Proxy construct trap" {
    const v = try evalToF64(std.testing.allocator, "var p=new Proxy(function(){},{construct:function(t,a){return {sum:a[0]+a[1]};}}); (new p(5,6)).sum");
    try std.testing.expectEqual(@as(f64, 11), v);
}


test "phase13: Proxy construct forwards when no trap" {
    const v = try evalToF64(std.testing.allocator, "function C(x){this.x=x;} var p=new Proxy(C,{}); (new p(42)).x");
    try std.testing.expectEqual(@as(f64, 42), v);
}


test "phase13: Proxy ownKeys trap drives Object.keys" {
    const s = try dualString(std.testing.allocator, "var p=new Proxy({},{ownKeys:function(){return ['x','y','z'];},getOwnPropertyDescriptor:function(t,k){return {enumerable:true,configurable:true,value:1};}}); Object.keys(p).join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("x,y,z", s);
}


test "phase13: Proxy getOwnPropertyDescriptor trap" {
    const s = try dualString(std.testing.allocator, "var p=new Proxy({},{getOwnPropertyDescriptor:function(t,k){return {value:'V_'+k,enumerable:true,configurable:true};}}); Object.getOwnPropertyDescriptor(p,'foo').value");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("V_foo", s);
}


test "phase13: regex /s dotAll flag" {
    const s = try dualString(std.testing.allocator, "[/a.b/.test('a\\nb'), /a.b/s.test('a\\nb')].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("false,true", s);
}


test "phase13: regex /y sticky flag anchors at lastIndex" {
    const s = try dualString(std.testing.allocator, "var r=/\\d/y; r.lastIndex=2; var a=r.test('ab3'); r.lastIndex=0; var b=r.test('ab3'); [a,b].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true,false", s);
}


test "phase13: regex /u flag is accepted" {
    const b = try dualBool(std.testing.allocator, "/\\d+/u.test('123') && /abc/u.test('xabcx')");
    try std.testing.expect(b);
}


test "phase13: regex flag accessor properties" {
    const s = try dualString(std.testing.allocator, "var r=/x/gsyu; [r.global,r.dotAll,r.sticky,r.unicode,r.flags].join(',')");
    defer std.testing.allocator.free(s);
    // `flags` returns the canonical order d,g,i,m,s,u,v,y per spec (RegExp.prototype.flags),
    // so `gsyu` source order normalizes to `gsuy`.
    try std.testing.expectEqualStrings("true,true,true,true,gsuy", s);
}


test "phase13: Intl.NumberFormat decimal grouping (en-US)" {
    const s = try dualString(std.testing.allocator, "new Intl.NumberFormat('en-US').format(1234567.891)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,234,567.891", s);
}


test "phase13: Intl.NumberFormat currency (en-US)" {
    const s = try dualString(std.testing.allocator, "new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(-1234.5)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("-$1,234.50", s);
}


test "phase13: Intl.NumberFormat percent (en-US)" {
    const s = try dualString(std.testing.allocator, "new Intl.NumberFormat('en-US',{style:'percent'}).format(0.255)");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("26%", s);
}


test "phase13: Intl.Collator compares same-case ASCII" {
    const v = try evalToF64(std.testing.allocator, "new Intl.Collator('en').compare('apple','banana')");
    try std.testing.expectEqual(@as(f64, -1), v);
}


test "phase13: regex lookbehind positive + negative" {
    const s = try dualString(std.testing.allocator, "'1foo2bar'.replace(/(?<=\\d)[a-z]+/g,'-') + '|' + '5'.replace(/(?<!\\d)\\d/g,'#')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1-2-|#", s);
}


test "phase13: regex property escapes under /u" {
    const s = try dualString(std.testing.allocator, "[/\\p{L}+/u.test('abc'), 'a1b2'.replace(/\\p{N}/gu,'#'), /\\P{L}/u.test('5')].join(',')");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("true,a#b#,true", s);
}

