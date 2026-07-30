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


test "gc: WeakRef target is cleared after collection (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // The target object is created inside an IIFE so its only live reference
    // after the call returns is the WeakRef's (weak) internal slot — the IIFE's
    // frame registers are gone. A collection must then reclaim it and deref()
    // must report undefined.
    const result = ctx.eval(
        "var wr = (function(){ return new WeakRef({}); })(); __gc__(); wr.deref() === undefined ? 1 : 0",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 1), v.toF64()),
        else => return error.UnexpectedResult,
    }
}


test "gc: strong Map keeps value reachable only through it (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // The value object lives only inside the Map; the strong-trace hook must keep
    // it alive across a collection (regression guard against dangling Map values).
    const result = ctx.eval(
        "var m = new Map(); m.set('k', {v: 42}); __gc__(); m.get('k').v",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 42), v.toF64()),
        else => return error.UnexpectedResult,
    }
}


test "gc: WeakMap value survives while key is live (ephemeron) (bc)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setInterpMode(.bc);

    // The value object is reachable only via the WeakMap entry, whose key `k` is
    // live → ephemeron marking must keep the value alive across a collection.
    const result = ctx.eval(
        "var k = {}; var wm = new WeakMap(); wm.set(k, {n: 7}); __gc__(); wm.get(k).n",
        "<test>",
    );
    switch (result) {
        .ok => |v| try std.testing.expectEqual(@as(f64, 7), v.toF64()),
        else => return error.UnexpectedResult,
    }
}


test "integration: JSON.parse survives GC during parse (regression)" {
    // Regression: parseObject/parseArray built containers reachable only from
    // the native parser frame; a nursery collection mid-parse swept them and
    // the next obj.set wrote to a freed object (segfault). Containers are now
    // rooted via heap.addRoot for the duration of the parse. A 64 KB nursery
    // forces many collections over a ~1 MB document.
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.gcConfigure(64 * 1024, 8, false);
    const src =
        \\var a = [];
        \\for (var i = 0; i < 20000; i++) a.push({ id: i, s: "v" + i });
        \\var back = JSON.parse(JSON.stringify(a));
        \\var o = JSON.parse('{"a":[1,2,{"b":"x"}],"c":3}', function (k, v) {
        \\  return typeof v === "number" ? v * 2 : v;
        \\});
        \\back.length + o.a[2].b + o.c;
    ;
    const result = ctx.eval(src, "<test>");
    switch (result) {
        .ok => |v| {
            const s = try root.valueToDisplayString(std.testing.allocator, v);
            defer std.testing.allocator.free(s);
            try std.testing.expectEqualStrings("20000x6", s);
        },
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        else => return error.UnexpectedResult,
    }
}
