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


// ---- Phase 8: native ES module syntax (desugared onto require/exports) ----

test "esm: export const + export function" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; export const x=5; export function f(){return 9;} exports.x + exports.f()");
    try std.testing.expectEqual(@as(f64, 14), v);
}


test "esm: export named list with rename" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; var a=1; var b=2; export {a, b as c}; exports.a*10 + exports.c");
    try std.testing.expectEqual(@as(f64, 12), v);
}


test "esm: export {a} list is a live binding" {
    const v = try evalToF64(std.testing.allocator, "var exports={}; var a=1; export {a}; a=7; exports.a");
    try std.testing.expectEqual(@as(f64, 7), v);
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


test "esm: import * as ns is a Module Namespace exotic object" {
    // Null [[Prototype]], non-extensible, @@toStringTag "Module".
    const v = try evalToBool(std.testing.allocator,
        "var __modules__={m:({exports:({k:3})})}; import * as ns from 'm';" ++
        " Object.getPrototypeOf(ns)===null && Object.isExtensible(ns)===false && ns[Symbol.toStringTag]==='Module'");
    try std.testing.expect(v);
}


test "esm: namespace own keys are the exports, sorted" {
    const v = try evalToString(std.testing.allocator,
        "var __modules__={m:({exports:({b:1,a:2,c:3})})}; import * as ns from 'm';" ++
        " Object.getOwnPropertyNames(ns).join(',')");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("a,b,c", v);
}


test "esm: namespace property descriptor is writable data, non-configurable" {
    const v = try evalToString(std.testing.allocator,
        "var __modules__={m:({exports:({k:3})})}; import * as ns from 'm';" ++
        " var d=Object.getOwnPropertyDescriptor(ns,'k'); d.value+'/'+d.writable+'/'+d.enumerable+'/'+d.configurable");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("3/true/true/false", v);
}


test "esm: two namespaces of the same module are identical (GetModuleNamespace)" {
    const v = try evalToBool(std.testing.allocator,
        "var __modules__={m:({exports:({k:3})})}; import * as a from 'm'; import * as b from 'm'; a===b");
    try std.testing.expect(v);
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
    const v = try evalToF64(std.testing.allocator, "var __modules__={a:function(require,module,exports){ exports.x=1; exports.getB=function(){return require('b').y;}; }, b:function(require,module,exports){ exports.y=2; exports.getA=function(){return require('a').x;}; }}; require('a').getB() + require('b').getA()");
    try std.testing.expectEqual(@as(f64, 3), v);
}


test "esm: circular require terminates with partial exports (cache-before-invoke)" {
    const v = try evalToF64(std.testing.allocator, "var __modules__={a:function(require,module,exports){ exports.fromB=require('b').val; exports.aval=10; }, b:function(require,module,exports){ var am=require('a'); exports.val=5; exports.aSeen=am.aval; }}; require('a').fromB");
    try std.testing.expectEqual(@as(f64, 5), v);
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

