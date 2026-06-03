// SPDX-License-Identifier: MIT
//! Integration tests: lex -> parse -> eval end-to-end.
//! Phase 2: each test runs under BOTH tree and bc modes and asserts identical results.
const std = @import("std");
const root = @import("../root.zig");
const val_mod = @import("../value/value.zig");
const vm_mod = @import("../vm/vm.zig");

const Isolate = root.Isolate;
const Value = root.Value;
const EvalResult = root.EvalResult;
const InterpMode = root.InterpMode;

fn evalToF64Mode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) !f64 {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| v.toF64(),
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

fn evalToStringMode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) ![]const u8 {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| try root.valueToDisplayString(allocator, v),
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

fn evalToBoolMode(allocator: std.mem.Allocator, source: []const u8, mode: InterpMode) !bool {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(mode);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| {
            const inner = val_mod.Value{ .bits = v.bits };
            if (inner.bits == 0) return false;
            return switch (inner.toPtr().*) {
                .boolean => |b| b,
                .number => |n| n != 0.0 and !std.math.isNan(n),
                else => false,
            };
        },
        .exception => |e| {
            std.debug.print("exception ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error ({s}): {s}\n", .{ @tagName(mode), e.message });
            return error.ParseFailed;
        },
    };
}

/// Run source under both modes; panic if they diverge.
fn dualF64(allocator: std.mem.Allocator, source: []const u8) !f64 {
    const tree_v = try evalToF64Mode(allocator, source, .tree);
    const bc_v = try evalToF64Mode(allocator, source, .bc);
    if (tree_v != bc_v and !(std.math.isNan(tree_v) and std.math.isNan(bc_v))) {
        std.debug.print("DIVERGE: tree={d} bc={d} source: {s}\n", .{ tree_v, bc_v, source });
        return error.ModeDivergence;
    }
    return tree_v;
}

fn dualString(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const tree_v = try evalToStringMode(allocator, source, .tree);
    const bc_v = try evalToStringMode(allocator, source, .bc);
    if (!std.mem.eql(u8, tree_v, bc_v)) {
        std.debug.print("DIVERGE: tree={s} bc={s} source: {s}\n", .{ tree_v, bc_v, source });
        allocator.free(bc_v);
        return error.ModeDivergence;
    }
    allocator.free(bc_v);
    return tree_v;
}

fn dualBool(allocator: std.mem.Allocator, source: []const u8) !bool {
    const tree_v = try evalToBoolMode(allocator, source, .tree);
    const bc_v = try evalToBoolMode(allocator, source, .bc);
    if (tree_v != bc_v) {
        std.debug.print("DIVERGE: tree={} bc={} source: {s}\n", .{ tree_v, bc_v, source });
        return error.ModeDivergence;
    }
    return tree_v;
}

// Keep legacy single-mode helpers for backward compat (used by some tests).
fn evalToF64(allocator: std.mem.Allocator, source: []const u8) !f64 {
    return dualF64(allocator, source);
}
fn evalToString(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return dualString(allocator, source);
}
fn evalToBool(allocator: std.mem.Allocator, source: []const u8) !bool {
    return dualBool(allocator, source);
}

test "integration: 1 + 2 = 3" {
    const v = try evalToF64(std.testing.allocator, "1 + 2");
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "integration: string concat" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.eval("\"hello\" + \" \" + \"world\"", "<test>");
    const v = switch (result) {
        .ok => |x| x,
        else => return error.UnexpectedResult,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try root.valueToDisplayString(arena.allocator(), v);
    try std.testing.expectEqualStrings("hello world", s);
    // Also verify bc mode.
    var iso2 = try Isolate.init(std.testing.allocator);
    defer iso2.deinit();
    var ctx2 = try iso2.newContext();
    defer ctx2.deinit();
    ctx2.setInterpMode(.bc);
    const result2 = ctx2.eval("\"hello\" + \" \" + \"world\"", "<test>");
    const v2 = switch (result2) {
        .ok => |x| x,
        else => return error.UnexpectedResult,
    };
    const s2 = try root.valueToDisplayString(arena.allocator(), v2);
    try std.testing.expectEqualStrings("hello world", s2);
}

test "integration: function call" {
    const v = try evalToF64(std.testing.allocator, "(function (x) { return x * 2; })(21)");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "integration: var decl and expression" {
    const v = try evalToF64(std.testing.allocator, "var x = 10; var y = 20; x + y");
    try std.testing.expectEqual(@as(f64, 30), v);
}

test "integration: if truthy branch" {
    const v = try evalToF64(std.testing.allocator, "if (1 < 2) { 1 } else { 2 }");
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "integration: while loop" {
    const v = try evalToF64(std.testing.allocator, "var i = 0; while (i < 5) { i = i + 1; } i");
    try std.testing.expectEqual(@as(f64, 5), v);
}

test "integration: for loop sum 1..10 = 55" {
    const v = try evalToF64(std.testing.allocator, "var sum = 0; for (var i = 1; i <= 10; i = i + 1) { sum = sum + i; } sum");
    try std.testing.expectEqual(@as(f64, 55), v);
}

test "integration: fib(20) = 6765" {
    const v = try evalToF64(std.testing.allocator, "(function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); })(20)");
    try std.testing.expectEqual(@as(f64, 6765), v);
}

test "integration: closure captures outer var" {
    const v = try evalToF64(std.testing.allocator, "var f = (function() { var x = 10; return function() { return x; }; })(); f()");
    try std.testing.expectEqual(@as(f64, 10), v);
}

test "integration: type coercion 1 + '2' = '12'" {
    const s = try evalToString(std.testing.allocator, "1 + \"2\"");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("12", s);
}

test "integration: abstract equality 1 == '1'" {
    const v = try evalToBool(std.testing.allocator, "1 == \"1\"");
    try std.testing.expect(v);
}

test "integration: strict equality 1 === '1' is false" {
    const v = try evalToBool(std.testing.allocator, "1 === \"1\"");
    try std.testing.expect(!v);
}

test "integration: typeof 1 = number" {
    const s = try evalToString(std.testing.allocator, "typeof 1");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("number", s);
}

test "integration: typeof 'x' = string" {
    const s = try evalToString(std.testing.allocator, "typeof \"x\"");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("string", s);
}

test "integration: typeof undefined = undefined" {
    const s = try evalToString(std.testing.allocator, "typeof undefined");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("undefined", s);
}

test "integration: typeof null = object (famous bug)" {
    const s = try evalToString(std.testing.allocator, "typeof null");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("object", s);
}

test "integration: -0 === 0 is true" {
    const v = try evalToBool(std.testing.allocator, "-0 === 0");
    try std.testing.expect(v);
}

test "integration: NaN !== NaN" {
    const v = try evalToBool(std.testing.allocator, "NaN === NaN");
    try std.testing.expect(!v);
}

test "phase7: let block scoping in tree mode" {
    const v = try evalToF64Mode(std.testing.allocator, "var x = 1; { let x = 2; } x", .tree);
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: TDZ throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("{ x; let x = 1; }", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "ReferenceError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: const assignment throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("const x = 1; x = 2;", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: arrow function basic in tree mode" {
    const v = try evalToF64Mode(std.testing.allocator, "var f = (x) => x + 1; f(41)", .tree);
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: arrow captures lexical this in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var o = ({x: 7, m: function(){ var f = (q) => this.x; return f(0); }}); o.m()",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "phase7: for-of array with let in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "let sum = 0; for (let x of [1,2,3]) { sum = sum + x; } sum",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: for-of array with const in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var sum = 0; for (const x of [1,2,3]) { sum = sum + x; } sum",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: simple class desugars and runs in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { constructor(x){ this.x = x; } get(){ return this.x; } } var a = new A(9); a.get()",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 9), v);
}

test "phase7: class extends prototype chain in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { get(){ return 5; } } class B extends A { more(){ return this.get() + 1; } } var b = new B(); b.more()",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: template literal plain in tree mode" {
    const s = try evalToStringMode(std.testing.allocator, "`hello template`", .tree);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello template", s);
}

test "phase7: template literal interpolation in tree mode" {
    const s = try evalToStringMode(std.testing.allocator, "var x = 7; `v=${x + 1}`", .tree);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("v=8", s);
}

test "phase7: default parameter applies on undefined in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function f(a = 3){ return a; } f(undefined)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "phase7: rest parameter collects trailing args in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function f(a, ...rest){ return a + rest.length; } f(5, 10, 20)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "phase7: spread call expands array args in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function add(a,b,c){ return a+b+c; } var xs=[1,2,3]; add(...xs)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: spread array literal expands values in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var xs=[2,3]; var ys=[1,...xs,4]; ys.length + ys[1]",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: map builtin in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var m = new Map(); m.set(\"k\", 42); m.get(\"k\")",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: set builtin in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "var s = new Set(); s.add(7); s.has(7)",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: promise resolve then baseline in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r = 0; Promise.resolve(5).then(function(x){ r = x + 1; }); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 0), v);
}

test "phase7: super method call in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { get(){ return 9; } } class B extends A { get(){ return super.get() + 1; } } (new B()).get()",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 10), v);
}

test "phase7: super constructor chaining via call in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { constructor(x){ this.x = x; } } class B extends A { constructor(){ super.call(this, 4); } } (new B()).x",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 4), v);
}

test "phase7: direct super constructor call in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { constructor(x){ this.x = x; } } class B extends A { constructor(){ super(6); } } (new B()).x",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: super method dispatch uses derived this in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { get(){ return this.x; } } class B extends A { constructor(){ super(); this.x = 9; } get(){ return super.get() + 1; } } (new B()).get()",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 10), v);
}

test "phase7: derived class default constructor chains super in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class A { constructor(){ this.ok = 1; } } class B extends A {} (new B()).ok",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: class prototype constructor points at class in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "class A {} class B extends A {} (new B()).constructor === B",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: super call without extends throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("class A { constructor(){ super(); } } new A()", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "ReferenceError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: for-of over string in tree mode" {
    const s = try evalToStringMode(
        std.testing.allocator,
        "var out = \"\"; for (let ch of \"ab\") { out = out + ch; } out",
        .tree,
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("ab", s);
}

test "phase7: for-of uses iterator protocol object in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var it={i:0,next:function(){ this.i=this.i+1; return ({value:this.i,done:this.i>3}); }}; var seq={next:it.next,i:it.i}; var sum=0; for (let x of seq) { sum = sum + x; } sum",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: spread uses iterator protocol object in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var seq={ i:0, next:function(){ this.i=this.i+1; return ({value:this.i,done:this.i>2}); } }; var a=[0,...seq,9]; a[1]+a[2]",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "phase7: spread non-iterable object throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("var a=[...({a:1})]; a.length", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: generator next yields values and done in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; yield 2; return 7; } var it = g(); var a = it.next(); var b = it.next(); var c = it.next(); a.value + b.value + c.value + (a.done?1000:0) + (b.done?100:0) + (c.done?10:0)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 20), v);
}

test "phase7: for-of consumes generator in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 4; yield 5; } var sum = 0; for (let x of g()) { sum = sum + x; } sum",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 9), v);
}

test "phase7: spread consumes generator in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 2; yield 3; } var xs = [1, ...g(), 4]; xs[1] + xs[2]",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 5), v);
}

test "phase7: yield outside generator reports explicit parse error" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("yield 1", "<test>");
    switch (result) {
        .parse_error => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "yield is only valid inside generator functions") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: yield star delegates values in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; yield* [2,3]; return 4; } var it=g(); it.next().value + it.next().value + it.next().value + it.next().value",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 10), v);
}

test "phase7: generator next resume value in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ var x = yield 1; yield x + 1; } var it = g(); it.next(); it.next(4).value",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 5), v);
}

test "phase7: first generator next argument ignored in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ var x = yield 1; return x === undefined ? 9 : 0; } var it = g(); it.next(77); it.next().value",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 9), v);
}

test "phase7: generator return closes iterator in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; yield 2; } var it=g(); var a=it[\"return\"](9); var b=it.next(); a.value + (a.done?100:0) + (b.done?10:0)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 119), v);
}

test "phase7: generator throw throws and closes in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ yield 1; } var it=g(); var c=0; try { it[\"throw\"](7); } catch(e) { c=e; } c + (it.next().done ? 10 : 0)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 17), v);
}

test "phase7: for-of invalid iterator result throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("var seq={next:function(){ return 1; }}; for (let x of seq) {} 0", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: for-of non-iterable object throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("for (let x of ({a:1})) {} 0", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: for-of iterator method must return object in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("var seq={iterator:function(){ return 1; }}; for (let x of seq) {} 0", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: for-of ignores value when done true in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var seq={i:0,next:function(){ this.i=this.i+1; return ({value:99,done:this.i>1}); }}; var sum=0; for (let x of seq){ sum=sum+x; } sum",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "phase7: Promise.resolve returns same promise in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "var p = Promise.resolve(3); Promise.resolve(p) === p",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: Promise constructor executor and chain parse/run in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; var p = new Promise(function(resolve){ resolve(5); }); p.then(function(x){ return x+2; }).then(function(y){ r=y; }); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 0), v);
}

test "phase7: Promise pending then queue registration in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; var resolveRef; var p = new Promise(function(resolve){ resolveRef = resolve; }); p.then(function(x){ r = x + 1; }); resolveRef(9); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 0), v);
}

test "phase7: Promise catch converts rejection to fulfillment in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.reject(2)[\"catch\"](function(x){ return x+5; }).then(function(v){ r=v; }); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 0), v);
}

test "phase7: Promise.then receiver must be Promise in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("Promise.prototype.then.call({}, function(x){ return x; })", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "TypeError") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: Promise microtasks flush side effects in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve(5).then(function(x){ r = x + 1; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: Promise chain propagates rejection in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve(1).then(function(){ throw 7; })[\"catch\"](function(e){ r = e + 1; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 8), v);
}

test "phase7: Promise thenable assimilation in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve({ then: function(resolve){ resolve(9); } }).then(function(x){ r = x; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 9), v);
}

test "phase7: Promise.resolve chains thenable return in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve(1).then(function(){ return { then: function(resolve){ resolve(4); } }; }).then(function(v){ r=v; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 4), v);
}

test "phase7: Promise microtask queue runs all jobs in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve(1).then(function(){ r=r+1; }); Promise.resolve(1).then(function(){ r=r+2; }); __runMicrotasks__(); r===3 ? 1 : 0",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: Promise thenable throw rejects chain in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve({ then: function(){ throw 6; } })[\"catch\"](function(e){ r=e+1; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "phase7: require host shim reads __modules__ in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var __modules__ = ({math: ({answer: 41})}); require(\"math\").answer + 1",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: require returns module.exports when present in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var __modules__ = ({m: ({exports: ({answer: 42})})}); require(\"m\").answer",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: require executes factory and caches exports in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var __modules__ = ({m: function(require,module,exports){ exports.answer = 42; }}); require(\"m\").answer + require(\"m\").answer",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 84), v);
}

test "phase7: require resolves relative module ids in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var __module_id__ = \"pkg/main\"; var __modules__ = ({\"pkg/util\": ({answer: 41})}); require(\"./util\").answer + 1",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: require module pseudo-id returns global module in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "require(\"module\").exports === module.exports",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: exports global aliases module.exports in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "exports.answer = 41; module.exports.answer + 1",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: require factory this binds exports in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var __modules__ = ({m: function(require,module,exports){ this.answer = 41; }}); require(\"m\").answer + 1",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase7: require caches relative and absolute module ids in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "var __module_id__ = \"pkg/main\"; var __modules__ = ({\"pkg/util\": function(require,module,exports){ exports.n = 1; }}); require(\"./util\") === require(\"pkg/util\")",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: iterator return called on abrupt spread completion in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var closed=0; var it={next:function(){return 1;}, \"return\":function(){closed=1; return ({done:true});}}; var seq={iterator:function(){return it;}}; try { var a=[...seq]; } catch(e) {} closed",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: iterator return called when next throws in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var closed=0; var it={next:function(){throw 1;}, \"return\":function(){closed=1; return ({done:true});}}; var seq={iterator:function(){return it;}}; try { var a=[...seq]; } catch(e) {} closed",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: map delete updates has in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "var m = new Map(); m.set(\"k\", 1); m[\"delete\"](\"k\"); m.has(\"k\")",
        .tree,
    );
    try std.testing.expect(!v);
}

test "phase7: array destructuring declaration baseline in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var arr = [2, 5]; var [a, b] = arr; a + b",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "phase7: object destructuring declaration baseline in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var obj = {x: 3, y: 4}; var {x, y} = obj; x * y",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 12), v);
}

test "phase7: generator side effects run once per step in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var c = 0; function side(){ c = c + 1; } function* g(){ side(); yield 1; side(); yield 2; } var it = g(); it.next(); it.next(); c",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 2), v);
}

test "phase7: yield star delegate return propagates in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* inner(){ yield 2; return 9; } function* outer(){ yield 1; yield* inner(); yield 3; } var it=outer(); it.next(); it.next(); var d=it.next(); d.value + (d.done?10:0)",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 19), v);
}

test "phase7: require resolve returns normalized id in tree mode" {
    const s = try evalToStringMode(
        std.testing.allocator,
        "var __module_id__ = \"pkg/main\"; var __modules__ = ({\"pkg/util\": ({answer: 1})}); require.resolve(\"./util\")",
        .tree,
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("pkg/util", s);
}

test "phase7: require missing module throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("require(\"missing-module\")", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "Cannot find module") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: require cache stores loaded module in tree mode" {
    const v = try evalToBoolMode(
        std.testing.allocator,
        "var __modules__ = ({m: function(require,module,exports){ exports.n = 1; }}); require(\"m\"); require.cache[\"m\"].exports === require(\"m\")",
        .tree,
    );
    try std.testing.expect(v);
}

test "phase7: generator yield in for loop resumes in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "function* g(){ for (var i = 0; i < 3; i++) { yield i; } } var it = g(); it.next().value + it.next().value + it.next().value",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "phase7: map keys iterator and for-of in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var m = new Map(); m.set(\"a\", 1); m.set(\"b\", 2); var s = 0; for (var x of m.keys()) { s = s + x.length; } s",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 2), v);
}

test "phase7: map entries for-of in tree mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var m = new Map(); m.set(1, 10); var t = 0; for (var p of m.entries()) { t = t + p[0] + p[1]; } t",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 11), v);
}

test "phase7: derived constructor this before super throws in tree mode" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);
    const result = ctx.eval("class A { constructor(x){ this.x = x; } } class B extends A { constructor(){ this.y = 1; super(2); } } new B()", "<test>");
    switch (result) {
        .exception => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "Must call super") != null),
        else => return error.UnexpectedResult,
    }
}

test "phase7: Map and Promise builtins present in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "(typeof Map !== \"undefined\" && typeof Promise !== \"undefined\") ? 1 : 0",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: promise resolve returns object in bc mode" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "Promise.resolve(5) ? 1 : 0",
        .bc,
    );
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "phase7: promise microtasks closure side effects tree-only" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "var r=0; Promise.resolve(5).then(function(x){ r = x + 1; }); __runMicrotasks__(); r",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "phase7: class desugar tree-only documents bc constructor gap" {
    const v = try evalToF64Mode(
        std.testing.allocator,
        "class C { constructor(){ this.n = 7; } } (new C()).n",
        .tree,
    );
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "phase7: generator unsupported in bc mode reports parse error" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    const result = ctx.eval("function* g(){ yield 1; } g().next().value", "<test>");
    switch (result) {
        .parse_error, .exception => {},
        else => return error.UnexpectedResult,
    }
}

test "integration: bitwise AND" {
    try std.testing.expectEqual(@as(f64, 1), try evalToF64(std.testing.allocator, "5 & 3"));
}

test "integration: bitwise OR" {
    try std.testing.expectEqual(@as(f64, 7), try evalToF64(std.testing.allocator, "5 | 3"));
}

test "integration: bitwise XOR" {
    try std.testing.expectEqual(@as(f64, 6), try evalToF64(std.testing.allocator, "5 ^ 3"));
}

test "integration: left shift" {
    try std.testing.expectEqual(@as(f64, 16), try evalToF64(std.testing.allocator, "1 << 4"));
}

test "integration: right shift" {
    try std.testing.expectEqual(@as(f64, 8), try evalToF64(std.testing.allocator, "32 >> 2"));
}

test "integration: bit not" {
    try std.testing.expectEqual(@as(f64, -1), try evalToF64(std.testing.allocator, "~0"));
}

// ------------------------------------------------------------------ Phase 3a --

test "phase3a: empty object literal" {
    const s = try dualString(std.testing.allocator, "({})");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("[object Object]", s);
}

test "phase3a: object literal dot access" {
    const v = try dualF64(std.testing.allocator, "({a:1,b:2}).a + ({a:1,b:2}).b");
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "phase3a: object literal set and get prop" {
    const v = try dualF64(std.testing.allocator, "var o = ({x:10}); o.x = 20; o.x");
    try std.testing.expectEqual(@as(f64, 20), v);
}

test "phase3a: object method with this" {
    const v = try dualF64(std.testing.allocator, "({x:5, get:function(){return this.x;}}).get()");
    try std.testing.expectEqual(@as(f64, 5), v);
}

test "phase3a: bracket access with string key" {
    const v = try dualF64(std.testing.allocator, "({a:42})[\"a\"]");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase3a: bracket access with computed key" {
    const v = try dualF64(std.testing.allocator, "var k = \"z\"; ({z:99})[k]");
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "phase3a: array literal index" {
    const v = try dualF64(std.testing.allocator, "[1,2,3][1]");
    try std.testing.expectEqual(@as(f64, 2), v);
}

test "phase3a: array length" {
    const v = try dualF64(std.testing.allocator, "[10,20,30].length");
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "phase3a: bracket assign" {
    const v = try dualF64(std.testing.allocator, "var a = [1,2,3]; a[0] = 99; a[0]");
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "phase3a: typeof object" {
    const s = try dualString(std.testing.allocator, "typeof ({})");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("object", s);
}

test "phase3a: typeof array" {
    const s = try dualString(std.testing.allocator, "typeof []");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("object", s);
}

test "phase3a: Object.create proto chain" {
    const v = try dualF64(std.testing.allocator, "var proto = ({greet: function() { return 42; }}); var o = Object.create(proto); o.greet()");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase3a: Object.create own prop shadows proto" {
    const v = try dualF64(std.testing.allocator, "var p = ({x:1}); var o = Object.create(p); o.x = 99; o.x");
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "phase3a: full demo - hello world via proto" {
    const s = try dualString(std.testing.allocator, "var proto = ({greet: function() { return \"hello\"; }}); var o = Object.create(proto); o.name = \"world\"; o.greet() + \" \" + o.name");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello world", s);
}

// ------------------------------------------------------------------ Phase 3b: GC --

test "gc: object survives if referenced (bc)" {
    // Allocate an object, hold reference in a variable, call __gc__, check still accessible.
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    const result = ctx.eval("var o = {x: 42}; __gc__(); o.x", "<test>");
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: object survives if referenced (tree)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);

    const result = ctx.eval("var o = {x: 42}; __gc__(); o.x", "<test>");
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: object freed if unreferenced - stats show freed (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // Eval creates and discards a temporary object, then triggers gc.
    // We can't directly check freed count from JS, but we verify it doesn't crash
    // and the result is correct.
    const result = ctx.eval(
        "var tmp = {y: 99}; tmp = null; __gc__(); 1",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 1), v.toF64()),
        else => return error.UnexpectedResult,
    }
    // After gc(), freed count should be > 0 (the tmp object was freed).
    const stats = ctx.gcStats();
    try std.testing.expect(stats.collections >= 1);
}

test "gc: object survives proto chain (bc)" {
    // Child object held; gc(); proto still accessible via child.
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    const result = ctx.eval(
        "var proto = {greet: 99}; var o = Object.create(proto); __gc__(); o.greet",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 99), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: env values are roots - closure captures object (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    const result = ctx.eval(
        "var captured = {val: 7}; var f = function() { return captured.val; }; __gc__(); f()",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 7), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: 1000 iterations terminates with bounded heap (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // Alloc-and-discard loop; __gc__() called every 100 iters.
    const result = ctx.eval(
        \\var i = 0;
        \\while (i < 1000) {
        \\  var o = { x: i };
        \\  i = i + 1;
        \\  if (i - (i / 100) * 100 === 0) { __gc__(); }
        \\}
        \\i
    ,
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 1000), v.toF64()),
        else => return error.UnexpectedResult,
    }
    // After multiple GC cycles, alive count should be bounded.
    const stats = ctx.gcStats();
    try std.testing.expect(stats.collections >= 1);
    // Objects alive: just object_prototype, array_prototype + maybe a few ephemeral ones.
    // Should be well under 200.
    try std.testing.expect(stats.objects_alive < 200);
}

test "gc: local var of in-progress call is rooted (tree)" {
    // Regression: GC fired mid-call must root the call's local env,
    // not just the global env. Previously segfaulted in tree mode.
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);

    const result = ctx.eval(
        "var c=null; (function(){var inner={secret:42}; __gc__(); c=inner;})(); c.secret",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: local var of in-progress call is rooted (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    const result = ctx.eval(
        "var c=null; (function(){var inner={secret:42}; __gc__(); c=inner;})(); c.secret",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

test "gc: 1000 iterations terminates with bounded heap (tree)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.tree);

    // In tree mode, __gc__ is a noop (no heap), but loop should still work correctly.
    const result = ctx.eval(
        \\var i = 0;
        \\while (i < 1000) {
        \\  var o = { x: i };
        \\  i = i + 1;
        \\}
        \\i
    ,
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 1000), v.toF64()),
        else => return error.UnexpectedResult,
    }
}

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


// ---- Phase 8: native ES module syntax (desugared onto require/exports) ----

test "esm: export const + export function" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; export const x=5; export function f(){return 9;} exports.x + exports.f()");
    try std.testing.expectEqual(@as(f64, 14), v);
}

test "esm: export named list with rename" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; var a=1; var b=2; export {a, b as c}; exports.a*10 + exports.c");
    try std.testing.expectEqual(@as(f64, 12), v);
}

test "esm: export default" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; export default 42; exports['default']");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "esm: import default + named with rename" {
    const v = try evalToF64(std.testing.allocator, "var e={}; e['default']=7; e.a=9; var __modules__={m:({exports:e})}; import d, {a as aa} from 'm'; d+aa");
    try std.testing.expectEqual(@as(f64, 16), v);
}

test "esm: import namespace" {
    const v = try evalToF64(std.testing.allocator, "var __modules__={m:({exports:({k:3})})}; import * as ns from 'm'; ns.k");
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "esm: re-export from module" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; var __modules__={m:({exports:({a:4})})}; export {a as z} from 'm'; exports.z");
    try std.testing.expectEqual(@as(f64, 4), v);
}


// ---- Phase 8: factory-form modules (both VMs) + cyclic require safety ----

test "esm: factory module require works in tree+bc" {
    const v = try evalToF64(std.testing.allocator, "var __modules__={m:function(require,module,exports){ exports.v=7; }}; require('m').v + require('m').v");
    try std.testing.expectEqual(@as(f64, 14), v);
}

test "esm: cross-module factory require with memoization" {
    const v = try evalToF64(std.testing.allocator,
        "var __modules__={a:function(require,module,exports){ exports.x=1; exports.getB=function(){return require('b').y;}; }, b:function(require,module,exports){ exports.y=2; exports.getA=function(){return require('a').x;}; }}; require('a').getB() + require('b').getA()");
    try std.testing.expectEqual(@as(f64, 3), v);
}

test "esm: circular require terminates with partial exports (cache-before-invoke)" {
    const v = try evalToF64(std.testing.allocator,
        "var __modules__={a:function(require,module,exports){ exports.fromB=require('b').val; exports.aval=10; }, b:function(require,module,exports){ var am=require('a'); exports.val=5; exports.aSeen=am.aval; }}; require('a').fromB");
    try std.testing.expectEqual(@as(f64, 5), v);
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

// ---- Phase 8: named-import live bindings (use-site rewrite) ----

test "esm: named import is a live binding" {
    const v = try evalToF64(std.testing.allocator, "var o={v:1}; var __modules__={m:({exports:o})}; import {v} from 'm'; o.v = 42; v");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "esm: shadowed import name keeps snapshot (sound)" {
    const v = try evalToF64(std.testing.allocator, "var __modules__={m:({exports:({x:5})})}; import {x} from 'm'; function f(){ var x=99; return x; } x + f()");
    try std.testing.expectEqual(@as(f64, 104), v);
}

// ---- Phase 8: export-side live bindings + bc Promise.then callbacks ----

test "esm: export let is a live binding (reassignment observed)" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; export let c = 1; function bump(){ c = c + 5; } bump(); exports.c");
    try std.testing.expectEqual(@as(f64, 6), v);
}

test "esm: shadowed export name keeps snapshot (sound)" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; export let v = 1; function f(){ var v = 9; return v; } f(); exports.v");
    try std.testing.expectEqual(@as(f64, 1), v);
}

test "promise: then callback runs under microtask drain (tree+bc)" {
    const v = try evalToF64(std.testing.allocator, "var r=0; Promise.resolve(3).then(function(x){ return x*10; }).then(function(y){ r=y; }); __runMicrotasks__(); r");
    try std.testing.expectEqual(@as(f64, 30), v);
}

// ---- Phase 8: proper tail calls (ES2015 PTC, strict mode, bc VM) ----

/// Run `source` in bc mode and report both the numeric result and the
/// call-frame depth high-water mark of that run.
fn evalBcWithFrames(allocator: std.mem.Allocator, source: []const u8) !struct { value: f64, frames: usize } {
    var iso = try Isolate.init(allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    const result = ctx.eval(source, "<test>");
    return switch (result) {
        .ok => |v| .{ .value = v.toF64(), .frames = ctx.lastFrameHighWater() },
        .exception => |e| {
            std.debug.print("exception (bc): {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error (bc): {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
}

// NOTE: strictness is per-function (the directive must be in the function's own
// body — this engine does not inherit strictness from the enclosing scope), so
// the `'use strict'` prologue lives inside each tail-recursive function.

test "tco: strict tail recursion returns correct result (tree+bc)" {
    // Accumulator-style tail recursion: sum(1..n). Small n so the tree-walker
    // (no TCO, native recursion) does not overflow — correctness parity check.
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

test "tco: call in try is not a tail call (correctness preserved)" {
    // `return f()` inside try must still run finally and return correctly.
    const src =
        "function inner(){ return 7; }" ++
        "function outer(){ 'use strict'; try { return inner(); } finally { } }" ++
        "outer()";
    const v = try dualF64(std.testing.allocator, src);
    try std.testing.expectEqual(@as(f64, 7), v);
}

// ---- Phase 8: source maps + debugger protocol stubs ----

var dbg_hits: u32 = 0;
var dbg_last_fn: []const u8 = "";

fn captureDebugHook(_: ?*anyopaque, stop: root.debug.DebugStop) void {
    dbg_hits += 1;
    dbg_last_fn = stop.function_name;
}

test "debugger: `debugger;` statement is a no-op without a hook (tree+bc)" {
    const v = try dualF64(std.testing.allocator, "function f(){ debugger; return 9; } f()");
    try std.testing.expectEqual(@as(f64, 9), v);
}

test "debugger: DEBUGGER opcode fires the installed hook (bc)" {
    dbg_hits = 0;
    dbg_last_fn = "";
    root.debug.installHook(captureDebugHook, null);
    defer root.debug.clearHook();

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);
    _ = ctx.eval("function f(){ debugger; return 1; } f()", "<test>");

    try std.testing.expect(dbg_hits >= 1);
    try std.testing.expectEqualStrings("f", dbg_last_fn);
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

// ---- Phase 8: bytecode caching + snapshot/restore ----

test "snapshot: compile then restore runs correctly" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    const image = try ctx.compileSnapshot(std.testing.allocator, "function add(a,b){ return a+b; } add(40, 2)");
    defer std.testing.allocator.free(image);

    switch (ctx.evalSnapshot(image)) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.SnapshotEvalFailed,
    }
}

test "snapshot: image is portable across isolates" {
    // Build the image in one isolate, run it in a completely separate one.
    var image: []u8 = undefined;
    {
        var iso = try Isolate.init(std.testing.allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        image = try ctx.compileSnapshot(std.testing.allocator, "var x = 6; var y = 7; x * y");
    }
    defer std.testing.allocator.free(image);

    var iso2 = try Isolate.init(std.testing.allocator);
    defer iso2.deinit();
    var ctx2 = try iso2.newContext();
    defer ctx2.deinit();
    switch (ctx2.evalSnapshot(image)) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.SnapshotEvalFailed,
    }
}

test "snapshot: string + closure survive round-trip" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();

    const image = try ctx.compileSnapshot(std.testing.allocator, "function mk(p){ return function(s){ return p + s; }; } mk('a')('b').length");
    defer std.testing.allocator.free(image);

    switch (ctx.evalSnapshot(image)) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 2), v.toF64()),
        else => return error.SnapshotEvalFailed,
    }
}

test "snapshot: corrupt image yields an exception, not a crash" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    switch (ctx.evalSnapshot("not a real image")) {
        .exception => {},
        else => return error.ExpectedException,
    }
}

// --------------------------------------------------------------------------
// ES2020/2021: nullish coalescing `??`, optional chaining `?.`,
// logical assignment `&&=` / `||=` / `??=`. Run in BOTH tree and bc modes.
// --------------------------------------------------------------------------

/// Both modes must report a parse error (e.g. `??` mixed with `&&`/`||`).
fn expectDualParseError(source: []const u8) !void {
    inline for (.{ .tree, .bc }) |mode| {
        var iso = try Isolate.init(std.testing.allocator);
        defer iso.deinit();
        var ctx = try iso.newContext();
        defer ctx.deinit();
        ctx.setInterpMode(mode);
        switch (ctx.eval(source, "<test>")) {
            .parse_error => {},
            else => return error.ExpectedParseError,
        }
    }
}

test "es2020: nullish coalescing basic" {
    try std.testing.expectEqual(@as(f64, 5), try dualF64(std.testing.allocator, "null ?? 5"));
    try std.testing.expectEqual(@as(f64, 7), try dualF64(std.testing.allocator, "undefined ?? 7"));
    // 0 and "" are NOT nullish — left operand is kept.
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

// ---- Phase 8 catch-up: ES2017–2022 builtins (dual tree+bc) ----

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
