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


// ---- M16 Phase 4: TLA (top-level await desugaring) ----

test "tla: await on a plain value returns the value" {
    const v = try evalToF64(std.testing.allocator, "__await__(42)");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "tla: await on an already-fulfilled Promise returns its value" {
    const v = try evalToF64(std.testing.allocator,
        "var p = Promise.resolve(99); __await__(p)");
    try std.testing.expectEqual(@as(f64, 99), v);
}

test "tla: await on a thenable resolves via then()" {
    const v = try evalToF64(std.testing.allocator,
        "__await__({ then: function(resolve) { resolve(7); } })");
    try std.testing.expectEqual(@as(f64, 7), v);
}

test "tla: await on a rejecting thenable propagates the rejection" {
    const err = std.testing.expectError(error.JsException,
        evalToF64(std.testing.allocator,
            "__await__({ then: function(_, reject) { reject(new Error('boom')); } })"));
    try err;
}

test "tla: new await is a SyntaxError in module context" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    switch (ctx.evalModule("new await Promise.resolve(1)", "<test>")) {
        .parse_error => {},
        else => return error.ExpectedParseError,
    }
}

// ---- M16 Phase 3: dynamic import() + import.meta ----

test "esm: dynamic import() resolves to the module namespace" {
    const v = try evalToF64(std.testing.allocator,
        "var __modules__={m:({exports:({k:42})})}; var r=0;" ++
        " import('m').then(function(ns){ r = ns.k; }); __runMicrotasks__(); r");
    try std.testing.expectEqual(@as(f64, 42), v);
}

test "esm: dynamic import() result is a Module Namespace exotic object" {
    const v = try evalToBool(std.testing.allocator,
        "var __modules__={m:({exports:({k:3})})}; var ok=false;" ++
        " import('m').then(function(ns){ ok = Object.getPrototypeOf(ns)===null" ++
        " && ns[Symbol.toStringTag]==='Module' && ns.k===3; }); __runMicrotasks__(); ok");
    try std.testing.expect(v);
}

test "esm: dynamic import() returns a fresh Promise each call" {
    const v = try evalToBool(std.testing.allocator,
        "var __modules__={m:({exports:({k:1})})}; var p1=import('m'); var p2=import('m');" ++
        " p1!==p2 && Object.getPrototypeOf(p1)===Promise.prototype");
    try std.testing.expect(v);
}

test "esm: dynamic import() of a missing module rejects (no synchronous throw)" {
    const v = try evalToString(std.testing.allocator,
        "var __modules__={}; var s='pending';" ++
        " import('nope').then(function(){ s='fulfilled'; }, function(){ s='rejected'; });" ++
        " __runMicrotasks__(); s");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("rejected", v);
}

test "esm: dynamic import() specifier is evaluated synchronously (abrupt propagates)" {
    // A throwing specifier expression must throw at the call site, not reject.
    try std.testing.expectError(error.JsException, evalToF64(std.testing.allocator,
        "var __modules__={}; var o={get s(){ throw 1; }}; import(o.s)"));
}

test "esm: import.meta is an ordinary object with a url" {
    const v = try evalToBool(std.testing.allocator,
        "typeof import.meta==='object' && import.meta!==null" ++
        " && Object.getPrototypeOf(import.meta)===null" ++
        " && typeof import.meta.url==='string' && Object.isExtensible(import.meta)");
    try std.testing.expect(v);
}

test "esm: import.meta is the same object across references" {
    const v = try evalToBool(std.testing.allocator,
        "var a=import.meta; var b=(function(){ return import.meta; })(); a===b && a===import.meta");
    try std.testing.expect(v);
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

// ---- instn-local-bndng: module declarations must NOT appear on globalThis ----

test "esm: module var does not pollute globalThis (instn-local-bndng-var)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.evalModule(
        \\var test262 = 1;
        \\if (Object.getOwnPropertyDescriptor(globalThis, 'test262') !== undefined)
        \\    throw new Error('var leaked to globalThis');
    , "<mod>");
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "esm: module function decl does not pollute globalThis (instn-local-bndng-func)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.evalModule(
        \\function test262() {}
        \\if (Object.getOwnPropertyDescriptor(globalThis, 'test262') !== undefined)
        \\    throw new Error('function decl leaked to globalThis');
    , "<mod>");
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "esm: module let does not pollute globalThis (instn-local-bndng-let)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.evalModule(
        \\let test262 = 1;
        \\if (Object.getOwnPropertyDescriptor(globalThis, 'test262') !== undefined)
        \\    throw new Error('let leaked to globalThis');
    , "<mod>");
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "esm: module const does not pollute globalThis (instn-local-bndng-const)" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    const result = ctx.evalModule(
        \\const test262 = 1;
        \\if (Object.getOwnPropertyDescriptor(globalThis, 'test262') !== undefined)
        \\    throw new Error('const leaked to globalThis');
    , "<mod>");
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

test "esm: module var is accessible inside module but not on globalThis" {
    var iso = try Isolate.init(std.testing.allocator);
    defer iso.deinit();
    var ctx = try iso.newContext();
    defer ctx.deinit();
    // var is in global_env (accessible by name) but NOT on globalThis object
    const result = ctx.evalModule(
        \\var test262 = 42;
        \\if (test262 !== 42) throw new Error('var not accessible');
        \\if (Object.getOwnPropertyDescriptor(globalThis, 'test262') !== undefined)
        \\    throw new Error('var leaked to globalThis');
    , "<mod>");
    switch (result) {
        .ok => {},
        .exception => |e| {
            std.debug.print("exception: {s}\n", .{e.message});
            return error.JsException;
        },
        .parse_error => |e| {
            std.debug.print("parse error: {s}\n", .{e.message});
            return error.ParseFailed;
        },
    }
}

