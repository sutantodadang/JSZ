// SPDX-License-Identifier: Apache-2.0
//! Integration tests for TypedArray constructors and shared %TypedArray%.prototype methods.
const std = @import("std");
const helpers = @import("./helpers.zig");
const evalToF64 = helpers.evalToF64;
const evalToString = helpers.evalToString;
const evalToBool = helpers.evalToBool;

// ---- Constructors: length argument ----

test "typedarray: new Int8Array(10) has correct length" {
    const n = try evalToF64(std.testing.allocator, "new Int8Array(10).length");
    try std.testing.expectEqual(@as(f64, 10), n);
}

test "typedarray: new Int8Array(10) is zero-filled" {
    const n = try evalToF64(std.testing.allocator, "new Int8Array(10)[0]");
    try std.testing.expectEqual(@as(f64, 0), n);
}

test "typedarray: new Uint32Array([1,2,3]) reads back correctly" {
    const n = try evalToF64(std.testing.allocator,
        "var b = new Uint32Array([1,2,3]); b[0]*1000 + b[1]*100 + b[2]");
    try std.testing.expectEqual(@as(f64, 1203), n);
}

test "typedarray: new Uint32Array([1,2,3]) has length 3" {
    const n = try evalToF64(std.testing.allocator, "new Uint32Array([1,2,3]).length");
    try std.testing.expectEqual(@as(f64, 3), n);
}

// ---- All 9 required constructors are in scope ----

test "typedarray: all 9 constructors are defined" {
    const s = try evalToString(std.testing.allocator,
        \\[Int8Array,Uint8Array,Uint8ClampedArray,
        \\ Int16Array,Uint16Array,
        \\ Int32Array,Uint32Array,
        \\ Float32Array,Float64Array].map(function(C){return C.name}).join(",")
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(
        "Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,Int32Array,Uint32Array,Float32Array,Float64Array",
        s,
    );
}

// ---- Element-size clamping / type coercion ----

test "typedarray: Uint8ClampedArray clamps overflow to 255" {
    const n = try evalToF64(std.testing.allocator, "new Uint8ClampedArray([300])[0]");
    try std.testing.expectEqual(@as(f64, 255), n);
}

test "typedarray: Int8Array wraps overflow" {
    const n = try evalToF64(std.testing.allocator, "new Int8Array([200])[0]");
    try std.testing.expectEqual(@as(f64, -56), n);
}

test "typedarray: Float64Array preserves fractional values" {
    const n = try evalToF64(std.testing.allocator, "new Float64Array([3.14])[0]");
    try std.testing.expect(@abs(n - 3.14) < 1e-10);
}

// ---- Shared %TypedArray%.prototype methods ----

test "typedarray: at() with negative index" {
    const n = try evalToF64(std.testing.allocator, "new Uint8Array([1,2,3,4,5]).at(-1)");
    try std.testing.expectEqual(@as(f64, 5), n);
}

test "typedarray: copyWithin" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3,4,5]).copyWithin(2,0,2).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,2,1,2,5", s);
}

test "typedarray: entries iterator" {
    const s = try evalToString(std.testing.allocator,
        \\var a = new Uint8Array([10,20]);
        \\var out = [];
        \\for (var e of a.entries()) { out.push(e[0] + ":" + e[1]); }
        \\out.join(",")
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("0:10,1:20", s);
}

test "typedarray: every" {
    const b = try evalToBool(std.testing.allocator, "new Uint8Array([2,4,6]).every(function(x){return x%2===0})");
    try std.testing.expect(b);
}

test "typedarray: fill" {
    const s = try evalToString(std.testing.allocator, "new Int32Array(3).fill(7).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("7,7,7", s);
}

test "typedarray: filter" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3,4,5]).filter(function(x){return x>2}).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("3,4,5", s);
}

test "typedarray: find" {
    const n = try evalToF64(std.testing.allocator,
        "new Uint8Array([1,2,3,4]).find(function(x){return x>2})");
    try std.testing.expectEqual(@as(f64, 3), n);
}

test "typedarray: findIndex" {
    const n = try evalToF64(std.testing.allocator,
        "new Uint8Array([1,2,3,4]).findIndex(function(x){return x>2})");
    try std.testing.expectEqual(@as(f64, 2), n);
}

test "typedarray: forEach iterates all elements" {
    const n = try evalToF64(std.testing.allocator,
        "var sum=0; new Uint8Array([1,2,3]).forEach(function(x){sum+=x}); sum");
    try std.testing.expectEqual(@as(f64, 6), n);
}

test "typedarray: includes" {
    const b = try evalToBool(std.testing.allocator, "new Uint8Array([1,2,3]).includes(2)");
    try std.testing.expect(b);
}

test "typedarray: indexOf" {
    const n = try evalToF64(std.testing.allocator, "new Uint8Array([10,20,30]).indexOf(20)");
    try std.testing.expectEqual(@as(f64, 1), n);
}

test "typedarray: join" {
    const s = try evalToString(std.testing.allocator, "new Uint8Array([1,2,3]).join(\"-\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1-2-3", s);
}

test "typedarray: keys iterator" {
    const s = try evalToString(std.testing.allocator,
        \\var out=[]; for(var k of new Uint8Array([10,20,30]).keys()){out.push(k);} out.join(",")
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("0,1,2", s);
}

test "typedarray: lastIndexOf" {
    const n = try evalToF64(std.testing.allocator, "new Uint8Array([1,2,1,2]).lastIndexOf(1)");
    try std.testing.expectEqual(@as(f64, 2), n);
}

test "typedarray: map" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3]).map(function(x){return x*2}).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2,4,6", s);
}

test "typedarray: reduce" {
    const n = try evalToF64(std.testing.allocator,
        "new Uint8Array([1,2,3,4]).reduce(function(acc,x){return acc+x},0)");
    try std.testing.expectEqual(@as(f64, 10), n);
}

test "typedarray: reduceRight" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3]).reduceRight(function(acc,x){return acc+\",\"+x})");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("3,2,1", s);
}

test "typedarray: reverse" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3]).reverse().join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("3,2,1", s);
}

test "typedarray: set from array" {
    const s = try evalToString(std.testing.allocator,
        "var t=new Uint8Array(5); t.set([9,8],2); t.join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("0,0,9,8,0", s);
}

test "typedarray: slice" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3,4,5]).slice(1,3).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2,3", s);
}

test "typedarray: some" {
    const b = try evalToBool(std.testing.allocator,
        "new Uint8Array([1,2,3]).some(function(x){return x>2})");
    try std.testing.expect(b);
}

test "typedarray: sort" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([3,1,2]).sort().join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,2,3", s);
}

test "typedarray: subarray shares backing buffer" {
    const s = try evalToString(std.testing.allocator,
        "new Uint8Array([1,2,3,4,5]).subarray(1,4).join(\",\")");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2,3,4", s);
}

test "typedarray: values iterator" {
    const s = try evalToString(std.testing.allocator,
        \\var out=[]; for(var v of new Uint8Array([7,8,9]).values()){out.push(v);} out.join(",")
    );
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("7,8,9", s);
}

test "typedarray: toString" {
    const s = try evalToString(std.testing.allocator, "new Uint8Array([1,2,3]).toString()");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1,2,3", s);
}
