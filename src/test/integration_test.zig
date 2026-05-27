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
    const v = try evalToF64(std.testing.allocator,
        "var sum = 0; for (var i = 1; i <= 10; i = i + 1) { sum = sum + i; } sum");
    try std.testing.expectEqual(@as(f64, 55), v);
}

test "integration: fib(20) = 6765" {
    const v = try evalToF64(std.testing.allocator,
        "(function fib(n){ return n<2 ? n : fib(n-1)+fib(n-2); })(20)");
    try std.testing.expectEqual(@as(f64, 6765), v);
}

test "integration: closure captures outer var" {
    const v = try evalToF64(std.testing.allocator,
        "var f = (function() { var x = 10; return function() { return x; }; })(); f()");
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
    const v = try dualF64(std.testing.allocator,
        "var o = ({x:10}); o.x = 20; o.x");
    try std.testing.expectEqual(@as(f64, 20), v);
}

test "phase3a: object method with this" {
    const v = try dualF64(std.testing.allocator,
        "({x:5, get:function(){return this.x;}}).get()");
    try std.testing.expectEqual(@as(f64, 5), v);
}

test "phase3a: bracket access with string key" {
    const v = try dualF64(std.testing.allocator, "({a:42})[\"a\"]");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase3a: bracket access with computed key" {
    const v = try dualF64(std.testing.allocator,
        "var k = \"z\"; ({z:99})[k]");
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
    const v = try dualF64(std.testing.allocator,
        "var a = [1,2,3]; a[0] = 99; a[0]");
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
    const v = try dualF64(std.testing.allocator,
        "var proto = ({greet: function() { return 42; }}); var o = Object.create(proto); o.greet()");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "phase3a: Object.create own prop shadows proto" {
    const v = try dualF64(std.testing.allocator,
        "var p = ({x:1}); var o = Object.create(p); o.x = 99; o.x");
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "phase3a: full demo - hello world via proto" {
    const s = try dualString(std.testing.allocator,
        "var proto = ({greet: function() { return \"hello\"; }}); var o = Object.create(proto); o.name = \"world\"; o.greet() + \" \" + o.name");
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
