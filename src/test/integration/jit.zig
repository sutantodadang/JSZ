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


test "S6: JIT direct native-to-native call avoids interpreter frame" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    const result = ctx.eval(
        \\function leaf(x) { return x + 1; }
        \\function caller(f, x) { return f(x); }
        \\leaf(0);
        \\caller(leaf, 41);
    , "<jit-s6-direct-call>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };

    const profile = ctx.lastJitProfile();
    try std.testing.expectEqual(@as(f64, 42), v.toF64());
    try std.testing.expect(profile.compiled >= 2);
    try std.testing.expect(profile.direct_calls >= 1);
    try std.testing.expectEqual(@as(usize, 1), ctx.lastFrameHighWater());
}


test "S7: JIT closure correctness: outer creates inner, inner runs via interpreter correctly" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    const result = ctx.eval(
        \\function makeAdder(n) { return function(x) { return x + n; }; }
        \\makeAdder(0)(0);
        \\makeAdder(10)(32);
    , "<jit-s7-closure>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    try std.testing.expectEqual(@as(f64, 42), v.toF64());
}


test "S8: JIT fine-deopt resumes mid-function (string concat) without corrupting the caller" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    // `s + '!'` compiles (ADD accepts any operands), then the non-number operand
    // fine-deopts at the ADD; the resume must run inside a REAL callee frame —
    // the old top-frame patch corrupted the caller (index-out-of-bounds panic).
    const result = ctx.eval(
        \\function cat(s) { return s + '!'; }
        \\cat('a');
        \\cat('b');
    , "<jit-s8-fine-deopt-resume>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try root.valueToDisplayString(arena.allocator(), v);
    try std.testing.expectEqualStrings("b!", s);
    try std.testing.expect(ctx.lastJitProfile().compiled >= 1);
}


test "S8: a property store commits exactly once across an overflow fine-deopt" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    // Each call commits `o.n = o.n + 1`, then `a*b` (1e16 > 2^53) overflow
    // fine-deopts at the MUL. A coarse re-run would increment twice per call.
    const result = ctx.eval(
        \\function h(o, a, b) { o.n = o.n + 1; return a * b; }
        \\var o = { n: 0 };
        \\for (var i = 0; i < 100; i++) { h(o, 100000000, 100000000); }
        \\o.n;
    , "<jit-s8-store-once>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    try std.testing.expectEqual(@as(f64, 100), v.toF64());
}


test "S8: JIT executes accessor getters and setters natively (re-entrant helper)" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    // Accessor sites never warm the data IC; after warmup exhaustion the
    // function compiles anyway and the helper runs the getter/setter while the
    // region stays native (200 iterations > jit_warmup_max).
    const result = ctx.eval(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { get: function () { return 7; } });
        \\var bag = { v: 0 };
        \\Object.defineProperty(bag, 'y', { set: function (n) { this.v = n * 2; } });
        \\function g(p) { return p.x + 1; }
        \\function s(p, n) { p.y = n; }
        \\var r = 0;
        \\for (var i = 0; i < 200; i++) { r = g(o); s(bag, i); }
        \\r + bag.v;
    , "<jit-s8-accessor>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    // r = 8, bag.v = 199*2 = 398 → 406.
    try std.testing.expectEqual(@as(f64, 406), v.toF64());
    try std.testing.expect(ctx.lastJitProfile().compiled >= 2);
}


test "S8: a throwing getter inside a JITed function is catchable" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    const result = ctx.eval(
        \\var o = {};
        \\Object.defineProperty(o, 'x', { get: function () { throw 'boom'; } });
        \\function g(p) { return p.x; }
        \\var c = '';
        \\for (var i = 0; i < 100; i++) { try { g(o); } catch (e) { c = e; } }
        \\c;
    , "<jit-s8-throwing-getter>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try root.valueToDisplayString(arena.allocator(), v);
    try std.testing.expectEqualStrings("boom", s);
}


test "JIT double INC/DEC: increment a double stays numeric" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    const result = ctx.eval(
        \\function inc(x) { return x + 1; }
        \\inc(0.5);
        \\inc(0.5);
    , "<jit-inc-double>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    try std.testing.expectEqual(@as(f64, 1.5), v.toF64());
}


test "JIT double compare: compare doubles gives correct numeric result" {
    if (!build_options.jit_enabled) return error.SkipZigTest;

    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    ctx.setJitMode(.experimental);

    const result = ctx.eval(
        \\function clamp(x) { if (x < 1.5) { return 0; } return x; }
        \\clamp(0.5);
        \\clamp(2.5);
    , "<jit-cmp-double>");
    const v = switch (result) {
        .ok => |x| x,
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse_error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    };
    try std.testing.expectEqual(@as(f64, 2.5), v.toF64());
}


test "Phase 9: experimental JIT fast-forwards a hot counter loop and matches the interpreter" {
    const a = std.testing.allocator;
    const src = "var i = 0; while (i < 6000) { i = i + 1; } i;";
    // Interpreter baseline.
    try std.testing.expectEqual(@as(f64, 6000), try evalToF64Mode(a, src, .bc));
    // Experimental JIT: same answer, and the loop was actually fast-forwarded.
    var compiled: usize = 0;
    try std.testing.expectEqual(@as(f64, 6000), try evalExperimental(a, src, &compiled));
    try std.testing.expect(compiled >= 1);
}


test "Phase 9: experimental JIT leaves non-matching loops to the interpreter (correct, no fast-forward)" {
    const a = std.testing.allocator;
    // Body has an extra statement (s = s + i), so the template does not match.
    const src = "var i = 0, s = 0; while (i < 3000) { i = i + 1; s = s + i; } s;";
    const baseline = try evalToF64Mode(a, src, .bc);
    var compiled: usize = 0;
    const jit = try evalExperimental(a, src, &compiled);
    try std.testing.expectEqual(baseline, jit);
    try std.testing.expectEqual(@as(usize, 0), compiled); // no loop fast-forwarded
}


test "Phase 9: experimental JIT fast-forwards a hot loop over a function-local induction var" {
    const a = std.testing.allocator;
    // `i` is a function local (GET_LOCAL/SET_LOCAL), not a global.
    const src = "function f(){ var i = 0; while (i < 6000) { i = i + 1; } return i; } f();";
    try std.testing.expectEqual(@as(f64, 6000), try evalToF64Mode(a, src, .bc));
    var compiled: usize = 0;
    try std.testing.expectEqual(@as(f64, 6000), try evalExperimental(a, src, &compiled));
    try std.testing.expect(compiled >= 1);
}


test "Phase 9: experimental JIT fast-forwards a hot accumulator loop (s = s + i)" {
    const a = std.testing.allocator;
    const src = "var i = 0, s = 0; while (i < 6000) { s = s + i; i = i + 1; } s;";
    const expected: f64 = 6000.0 * 5999.0 / 2.0; // sum 0..5999
    try std.testing.expectEqual(expected, try evalToF64Mode(a, src, .bc));
    var compiled: usize = 0;
    try std.testing.expectEqual(expected, try evalExperimental(a, src, &compiled));
    try std.testing.expect(compiled >= 1);
}


test "Phase 9: experimental JIT fast-forwards a hot loop with two accumulators" {
    const a = std.testing.allocator;
    const src = "var i = 0, s = 0, t = 0; while (i < 6000) { s = s + i; t = t + i; i = i + 1; } s + t;";
    const expected: f64 = 2.0 * (6000.0 * 5999.0 / 2.0); // s == t == sum 0..5999
    try std.testing.expectEqual(expected, try evalToF64Mode(a, src, .bc));
    var compiled: usize = 0;
    try std.testing.expectEqual(expected, try evalExperimental(a, src, &compiled));
    try std.testing.expect(compiled >= 1);
}

