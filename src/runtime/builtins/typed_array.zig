// SPDX-License-Identifier: Apache-2.0
//! Milestone 15: ArrayBuffer / TypedArrays / DataView.
//!
//! Storage model (mirrors Date/Map: internal_kind + arena-allocated internal_slot):
//!   ArrayBuffer       internal_kind = .array_buffer  slot -> ArrayBufferData
//!   <Kind>Array       internal_kind = .typed_array   slot -> TypedArrayData
//!   DataView          internal_kind = .data_view     slot -> DataViewData
//!
//! Integer-indexed element get/set is handled at the VM property chokepoints
//! (bc_vm.getProp/setProp) via `canonicalIndex` + `taLoad`/`taStoreNumber`.
//! `.length`/`.byteLength`/`.byteOffset`/`.buffer`/`.BYTES_PER_ELEMENT` are stored
//! as own data properties at construction (functionally correct; full spec keeps
//! them as prototype getters — a deliberate MVP simplification).
const std = @import("std");
const builtin = @import("builtin");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const realm_mod = @import("../realm.zig");
const function_proto = @import("function_proto.zig");
const intrinsics = @import("intrinsics.zig");

/// R1: install ArrayBuffer / %TypedArray% / per-kind ctors / DataView and bind globals.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const object_proto = ctx.object_proto;
    const fn_proto_obj = ctx.function_proto.?;

    // ArrayBuffer
    const ab_proto = try JsObject.create(arena, object_proto);
    try ab_proto.set("slice", try val_mod.makeNativeFunction(arena, nativeArrayBufferSlice));
    active_arraybuffer_proto = ab_proto;
    const ab_ctor = try JsObject.create(arena, null);
    try ab_ctor.set("prototype", try val_mod.makeObject(arena, ab_proto));
    try ab_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeArrayBufferCtor));
    try ab_ctor.set("isView", try val_mod.makeNativeFunction(arena, nativeArrayBufferIsView));
    try ab_proto.set("constructor", try val_mod.makeObject(arena, ab_ctor));
    try ctx.env.define("ArrayBuffer", try val_mod.makeObject(arena, ab_ctor));

    // %TypedArray%.prototype — shared methods.
    const ta_proto = try JsObject.create(arena, object_proto);
    const ta_methods = .{
        .{ "fill", nativeTaFill },
        .{ "subarray", nativeTaSubarray },
        .{ "slice", nativeTaSlice },
        .{ "set", nativeTaSet },
        .{ "indexOf", nativeTaIndexOf },
        .{ "includes", nativeTaIncludes },
        .{ "join", nativeTaJoin },
        .{ "toString", nativeTaToString },
        .{ "reverse", nativeTaReverse },
        .{ "at", nativeTaAt },
        .{ "forEach", nativeTaForEach },
        .{ "map", nativeTaMap },
        .{ "reduce", nativeTaReduce },
        .{ "values", nativeTaValues },
        .{ "keys", nativeTaKeys },
        .{ "entries", nativeTaEntries },
        .{ "@@iterator", nativeTaValues },
    };
    inline for (ta_methods) |pair| {
        try ta_proto.set(pair[0], try val_mod.makeNativeFunction(arena, pair[1]));
    }
    active_typedarray_proto = ta_proto;

    // Instance accessor getters live on %TypedArray%.prototype.
    try defineGetter(arena, ta_proto, "length", taGetLength);
    try defineGetter(arena, ta_proto, "byteLength", taGetByteLength);
    try defineGetter(arena, ta_proto, "byteOffset", taGetByteOffset);
    try defineGetter(arena, ta_proto, "buffer", taGetBuffer);

    // %TypedArray% intrinsic constructor (abstract).
    const ta_ctor = try JsObject.create(arena, fn_proto_obj);
    try ta_ctor.set("prototype", try val_mod.makeObject(arena, ta_proto));
    try ta_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeTaAbstractCtor));
    try ta_ctor.set("from", try val_mod.makeNativeFunction(arena, nativeTaFrom));
    try ta_ctor.set("of", try val_mod.makeNativeFunction(arena, nativeTaOf));
    try ta_proto.set("constructor", try val_mod.makeObject(arena, ta_ctor));

    // TypedArray iterator prototype.
    const ta_iter_proto = try JsObject.create(arena, object_proto);
    try ta_iter_proto.set("next", try val_mod.makeNativeFunction(arena, nativeTaIterNext));
    try ta_iter_proto.set("@@iterator", try val_mod.makeNativeFunction(arena, nativeIterSelf));
    active_ta_iter_proto = ta_iter_proto;

    // Per-kind constructors + prototypes (inherit %TypedArray% / its prototype).
    inline for (all_kinds) |kind| {
        const kp = try JsObject.create(arena, ta_proto);
        active_ta_protos[@intFromEnum(kind)] = kp;
        const kctor = try JsObject.create(arena, ta_ctor);
        active_ta_ctors[@intFromEnum(kind)] = kctor;
        try kctor.set("prototype", try val_mod.makeObject(arena, kp));
        try kctor.set("__call__", try val_mod.makeNativeFunction(arena, taCtor(kind)));
        try kctor.set("from", try val_mod.makeNativeFunction(arena, nativeTaFrom));
        try kctor.set("of", try val_mod.makeNativeFunction(arena, nativeTaOf));
        try kctor.set("BYTES_PER_ELEMENT", try val_mod.makeNumber(arena, @floatFromInt(kind.elemSize())));
        try kp.set("BYTES_PER_ELEMENT", try val_mod.makeNumber(arena, @floatFromInt(kind.elemSize())));
        try kp.set("constructor", try val_mod.makeObject(arena, kctor));
        try ctx.env.define(kind.ctorName(), try val_mod.makeObject(arena, kctor));
    }

    // DataView
    const dv_proto = try JsObject.create(arena, object_proto);
    try dv_proto.set("getInt8", try val_mod.makeNativeFunction(arena, dvGet(i8, false)));
    try dv_proto.set("getUint8", try val_mod.makeNativeFunction(arena, dvGet(u8, false)));
    try dv_proto.set("getInt16", try val_mod.makeNativeFunction(arena, dvGet(i16, false)));
    try dv_proto.set("getUint16", try val_mod.makeNativeFunction(arena, dvGet(u16, false)));
    try dv_proto.set("getInt32", try val_mod.makeNativeFunction(arena, dvGet(i32, false)));
    try dv_proto.set("getUint32", try val_mod.makeNativeFunction(arena, dvGet(u32, false)));
    try dv_proto.set("getFloat32", try val_mod.makeNativeFunction(arena, dvGet(f32, true)));
    try dv_proto.set("getFloat64", try val_mod.makeNativeFunction(arena, dvGet(f64, true)));
    try dv_proto.set("setInt8", try val_mod.makeNativeFunction(arena, dvSet(i8, false)));
    try dv_proto.set("setUint8", try val_mod.makeNativeFunction(arena, dvSet(u8, false)));
    try dv_proto.set("setInt16", try val_mod.makeNativeFunction(arena, dvSet(i16, false)));
    try dv_proto.set("setUint16", try val_mod.makeNativeFunction(arena, dvSet(u16, false)));
    try dv_proto.set("setInt32", try val_mod.makeNativeFunction(arena, dvSet(i32, false)));
    try dv_proto.set("setUint32", try val_mod.makeNativeFunction(arena, dvSet(u32, false)));
    try dv_proto.set("setFloat32", try val_mod.makeNativeFunction(arena, dvSet(f32, true)));
    try dv_proto.set("setFloat64", try val_mod.makeNativeFunction(arena, dvSet(f64, true)));
    active_dataview_proto = dv_proto;
    const dv_ctor = try JsObject.create(arena, null);
    try dv_ctor.set("prototype", try val_mod.makeObject(arena, dv_proto));
    try dv_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeDataViewCtor));
    try dv_proto.set("constructor", try val_mod.makeObject(arena, dv_ctor));
    try ctx.env.define("DataView", try val_mod.makeObject(arena, dv_ctor));
}

const native_endian = builtin.cpu.arch.endian();

// ---------------------------------------------------------------- element kinds ---

pub const TAKind = enum(u8) {
    i8,
    u8,
    u8clamped,
    i16,
    u16,
    i32,
    u32,
    f32,
    f64,
    i64big,
    u64big,

    pub fn elemSize(self: TAKind) usize {
        return switch (self) {
            .i8, .u8, .u8clamped => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .f64, .i64big, .u64big => 8,
        };
    }

    pub fn isBigInt(self: TAKind) bool {
        return self == .i64big or self == .u64big;
    }

    pub fn ctorName(self: TAKind) []const u8 {
        return switch (self) {
            .i8 => "Int8Array",
            .u8 => "Uint8Array",
            .u8clamped => "Uint8ClampedArray",
            .i16 => "Int16Array",
            .u16 => "Uint16Array",
            .i32 => "Int32Array",
            .u32 => "Uint32Array",
            .f32 => "Float32Array",
            .f64 => "Float64Array",
            .i64big => "BigInt64Array",
            .u64big => "BigUint64Array",
        };
    }
};

pub const all_kinds = [_]TAKind{ .i8, .u8, .u8clamped, .i16, .u16, .i32, .u32, .f32, .f64, .i64big, .u64big };

// ---------------------------------------------------------------- backing data ---

pub const ArrayBufferData = struct {
    bytes: []u8,
    detached: bool = false,
    shared: bool = false,
};

pub const TypedArrayData = struct {
    buffer_obj: *JsObject, // the ArrayBuffer JsObject (for `.buffer` + identity)
    ab: *ArrayBufferData, // cached backing store
    byte_offset: usize,
    length: usize, // element count
    kind: TAKind,
};

pub const DataViewData = struct {
    buffer_obj: *JsObject,
    ab: *ArrayBufferData,
    byte_offset: usize,
    byte_length: usize,
};

// ---------------------------------------------------------------- module protos ---

pub var active_arraybuffer_proto: ?*JsObject = null;
pub var active_dataview_proto: ?*JsObject = null;
pub var active_typedarray_proto: ?*JsObject = null; // %TypedArray%.prototype
pub var active_ta_protos: [all_kinds.len]?*JsObject = .{null} ** all_kinds.len;
pub var active_ta_ctors: [all_kinds.len]?*JsObject = .{null} ** all_kinds.len;
pub var active_ta_iter_proto: ?*JsObject = null;

// ---------------------------------------------------------------- helpers ---

fn alloc(arena: std.mem.Allocator) std.mem.Allocator {
    return arena;
}

fn newObject(arena: std.mem.Allocator, proto: ?*JsObject) !*JsObject {
    if (realm_mod.active_heap) |heap| return JsObject.createOnHeap(heap, proto);
    return JsObject.create(arena, proto);
}

/// Raise a TypeError from this module (realm.throwTypeError is private).
fn throwTypeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = try newObject(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

fn throwRangeError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = try newObject(arena, realm_mod.error_proto_RangeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "RangeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

/// A canonical non-negative array index ("0","1",...,"4294967294"): all digits,
/// no leading zero (except "0"), round-trips through formatting. Returns the
/// index or null. Other numeric-index strings ("-0","1.5","NaN") return null and
/// fall through to ordinary property handling (MVP simplification).
pub fn canonicalIndex(key: []const u8) ?usize {
    if (key.len == 0) return null;
    if (key.len > 1 and key[0] == '0') return null; // no leading zeros
    for (key) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseUnsigned(usize, key, 10) catch null;
}

fn makeBigU64(arena: std.mem.Allocator, v: u64) !Value {
    var m = try std.math.big.int.Managed.initSet(arena, v);
    return val_mod.makeBigInt(arena, m.toConst());
}

/// Numeric coercion for element/argument values (ToNumber without valueOf —
/// object `this`/args go through the VM path; here operands are primitives).
fn toNum(v: Value) f64 {
    if (v.bits == 0) return std.math.nan(f64);
    return switch (v.unbox()) {
        .undefined_ => std.math.nan(f64),
        .null_ => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| strToNum(s),
        else => std.math.nan(f64),
    };
}

fn strToNum(s: []const u8) f64 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return 0;
    return std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
}

/// `length` of an array-like source. Arrays special-case `length` (get("length")
/// returns null), so read the cached array length directly.
fn arrayLikeLen(o: *JsObject) usize {
    if (o.is_array) return o.getArrayLength();
    return toIndex(toNum(o.get("length") orelse Value{}));
}

// ---------------------------------------------------------------- element IO ---

pub fn taLoad(arena: std.mem.Allocator, td: *const TypedArrayData, i: usize) !Value {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    if (base + sz > b.len) return val_mod.makeUndefined(arena);
    const p = b[base..];
    return switch (td.kind) {
        .i8 => val_mod.makeNumber(arena, @floatFromInt(@as(i8, @bitCast(p[0])))),
        .u8, .u8clamped => val_mod.makeNumber(arena, @floatFromInt(p[0])),
        .i16 => val_mod.makeNumber(arena, @floatFromInt(std.mem.readInt(i16, p[0..2], native_endian))),
        .u16 => val_mod.makeNumber(arena, @floatFromInt(std.mem.readInt(u16, p[0..2], native_endian))),
        .i32 => val_mod.makeNumber(arena, @floatFromInt(std.mem.readInt(i32, p[0..4], native_endian))),
        .u32 => val_mod.makeNumber(arena, @floatFromInt(std.mem.readInt(u32, p[0..4], native_endian))),
        .f32 => val_mod.makeNumber(arena, @as(f32, @bitCast(std.mem.readInt(u32, p[0..4], native_endian)))),
        .f64 => val_mod.makeNumber(arena, @as(f64, @bitCast(std.mem.readInt(u64, p[0..8], native_endian)))),
        .i64big => val_mod.makeBigIntFromI64(arena, std.mem.readInt(i64, p[0..8], native_endian)),
        .u64big => makeBigU64(arena, std.mem.readInt(u64, p[0..8], native_endian)),
    };
}

/// Modular reduction to an N-bit unsigned (ToUint8/16/32 per spec).
fn wrapUnsigned(comptime UT: type, x: f64) UT {
    if (!std.math.isFinite(x)) return 0;
    const bits = @typeInfo(UT).int.bits;
    const modulus = std.math.pow(f64, 2.0, @floatFromInt(bits));
    const m = @mod(@trunc(x), modulus); // [0, modulus)
    return @intFromFloat(m);
}

/// Uint8ClampedArray conversion: clamp to [0,255] with round-half-to-even.
fn clampU8(x: f64) u8 {
    if (std.math.isNan(x)) return 0;
    if (x <= 0) return 0;
    if (x >= 255) return 255;
    const f = @floor(x);
    const diff = x - f;
    if (diff < 0.5) return @intFromFloat(f);
    if (diff > 0.5) return @intFromFloat(f + 1);
    const fi: u8 = @intFromFloat(f);
    return if (fi % 2 == 0) fi else fi + 1;
}

pub fn taStoreNumber(td: *const TypedArrayData, i: usize, x: f64) void {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    if (base + sz > b.len) return;
    const p = b[base..];
    switch (td.kind) {
        .i8, .u8 => p[0] = wrapUnsigned(u8, x),
        .u8clamped => p[0] = clampU8(x),
        .i16, .u16 => std.mem.writeInt(u16, p[0..2], wrapUnsigned(u16, x), native_endian),
        .i32, .u32 => std.mem.writeInt(u32, p[0..4], wrapUnsigned(u32, x), native_endian),
        .f32 => std.mem.writeInt(u32, p[0..4], @bitCast(@as(f32, @floatCast(x))), native_endian),
        .f64 => std.mem.writeInt(u64, p[0..8], @bitCast(x), native_endian),
        .i64big, .u64big => {}, // big kinds handled via taStoreBig
    }
}

pub fn taStoreBig(td: *const TypedArrayData, i: usize, v: Value) void {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    if (base + sz > b.len) return;
    const p = b[base..];
    var u: u64 = 0;
    if (v.bits != 0 and v.unbox() == .bigint) {
        const c = v.toPtr().bigint.toConst();
        u = c.toInt(u64) catch blk: {
            const iv = c.toInt(i64) catch 0;
            break :blk @bitCast(iv);
        };
    }
    std.mem.writeInt(u64, p[0..8], u, native_endian);
}

// ---------------------------------------------------------------- ArrayBuffer ---

const AbResult = struct { obj: *JsObject, data: *ArrayBufferData };

fn makeArrayBuffer(arena: std.mem.Allocator, byte_len: usize) !AbResult {
    const bytes = try arena.alloc(u8, byte_len);
    @memset(bytes, 0);
    const data = try arena.create(ArrayBufferData);
    data.* = .{ .bytes = bytes };
    const obj = try newObject(arena, active_arraybuffer_proto);
    obj.internal_kind = .array_buffer;
    obj.internal_slot = data;
    try obj.set("byteLength", try val_mod.makeNumber(arena, @floatFromInt(byte_len)));
    return .{ .obj = obj, .data = data };
}

fn toIndex(x: f64) usize {
    if (!std.math.isFinite(x) or x <= 0) return 0;
    return @intFromFloat(@trunc(x));
}

pub fn nativeArrayBufferCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return throwTypeError(arena, "Constructor ArrayBuffer requires 'new'");
    }
    const len: usize = if (args.len > 0) toIndex(toNum(args[0])) else 0;
    const bytes = try arena.alloc(u8, len);
    @memset(bytes, 0);
    const data = try arena.create(ArrayBufferData);
    data.* = .{ .bytes = bytes };
    const obj = this_val.toPtr().object;
    obj.internal_kind = .array_buffer;
    obj.internal_slot = data;
    try obj.set("byteLength", try val_mod.makeNumber(arena, @floatFromInt(len)));
    return this_val;
}

pub fn nativeArrayBufferIsView(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) {
        return val_mod.makeBool(arena, false);
    }
    const k = args[0].toPtr().object.internal_kind;
    return val_mod.makeBool(arena, k == .typed_array or k == .data_view);
}

fn getAbData(v: Value) ?*ArrayBufferData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    if (o.internal_kind != .array_buffer) return null;
    if (o.internal_slot == null) return null;
    return @ptrCast(@alignCast(o.internal_slot.?));
}

pub fn nativeArrayBufferSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "ArrayBuffer.prototype.slice called on non-ArrayBuffer");
    const len = ab.bytes.len;
    const start = relIndex(if (args.len > 0) toNum(args[0]) else 0, len);
    const end = relIndex(if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) toNum(args[1]) else @floatFromInt(len), len);
    const new_len = if (end > start) end - start else 0;
    const res = try makeArrayBuffer(arena, new_len);
    @memcpy(res.data.bytes[0..new_len], ab.bytes[start .. start + new_len]);
    return val_mod.makeObject(arena, res.obj);
}

/// Resolve a relative index (negative = from end), clamped to [0, len].
fn relIndex(x: f64, len: usize) usize {
    if (std.math.isNan(x)) return 0;
    const flen: f64 = @floatFromInt(len);
    const v = @trunc(x);
    if (v < 0) {
        const r = flen + v;
        return if (r < 0) 0 else @intFromFloat(r);
    }
    return if (v > flen) len else @intFromFloat(v);
}

// ---------------------------------------------------------------- TypedArray ctor ---

fn getTd(v: Value) ?*TypedArrayData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    if (o.internal_kind != .typed_array) return null;
    if (o.internal_slot == null) return null;
    return @ptrCast(@alignCast(o.internal_slot.?));
}

fn finishTypedArray(arena: std.mem.Allocator, this_obj: *JsObject, kind: TAKind, buffer_obj: *JsObject, ab: *ArrayBufferData, byte_offset: usize, length: usize) !Value {
    const td = try arena.create(TypedArrayData);
    td.* = .{ .buffer_obj = buffer_obj, .ab = ab, .byte_offset = byte_offset, .length = length, .kind = kind };
    this_obj.internal_kind = .typed_array;
    this_obj.internal_slot = td;
    // length/byteLength/byteOffset/buffer/BYTES_PER_ELEMENT are inherited accessor
    // getters / data props on %TypedArray%.prototype + per-kind prototype.
    return val_mod.makeObject(arena, this_obj);
}

// ---- instance accessor getters (installed on %TypedArray%.prototype) ----

pub fn taGetLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get length called on non-TypedArray");
    return val_mod.makeNumber(arena, @floatFromInt(td.length));
}

pub fn taGetByteLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get byteLength called on non-TypedArray");
    return val_mod.makeNumber(arena, @floatFromInt(td.length * td.kind.elemSize()));
}

pub fn taGetByteOffset(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get byteOffset called on non-TypedArray");
    return val_mod.makeNumber(arena, @floatFromInt(td.byte_offset));
}

pub fn taGetBuffer(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get buffer called on non-TypedArray");
    return val_mod.makeObject(arena, td.buffer_obj);
}

/// Install a read-only accessor (getter only) on `proto` under `key`.
pub fn defineGetter(arena: std.mem.Allocator, proto: *JsObject, key: []const u8, getter: val_mod.NativeFnPtr) !void {
    const holder = try newObject(arena, null);
    try holder.set("get", try val_mod.makeNativeFunction(arena, getter));
    const hv = try val_mod.makeObject(arena, holder);
    _ = try proto.defineOwnAccessor(key, hv, .{ .enumerable = false, .configurable = true, .writable = false });
}

/// Resolve a TypedArray kind from its constructor object (for generic from/of).
fn kindFromCtor(v: Value) ?TAKind {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    for (active_ta_ctors, 0..) |c, idx| {
        if (c) |cc| if (cc == o) return @enumFromInt(idx);
    }
    return null;
}

/// `new TypedArray()` — abstract, not directly constructable.
pub fn nativeTaAbstractCtor(arena: std.mem.Allocator, _: Value, _: []const Value) anyerror!Value {
    return throwTypeError(arena, "Abstract class TypedArray not directly constructable");
}

fn makeTypedArray(arena: std.mem.Allocator, kind: TAKind, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return throwTypeError(arena, "Constructor TypedArray requires 'new'");
    }
    const this_obj = this_val.toPtr().object;
    const esize = kind.elemSize();

    // Form 1: new TA(length)  (no args → length 0)
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() == .number or args[0].unbox() == .undefined_) {
        const length: usize = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .number)
            toIndex(args[0].unbox().number)
        else
            0;
        const res = try makeArrayBuffer(arena, length * esize);
        _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length);
        return val_mod.makeObject(arena, this_obj);
    }

    // arg0 is an object.
    const a0 = args[0];
    if (a0.unbox() == .object) {
        const src = a0.toPtr().object;

        // Form 2: new TA(buffer, byteOffset?, length?)  → view onto the buffer.
        if (src.internal_kind == .array_buffer) {
            const ab: *ArrayBufferData = @ptrCast(@alignCast(src.internal_slot.?));
            const byte_offset: usize = if (args.len > 1) toIndex(toNum(args[1])) else 0;
            if (byte_offset % esize != 0) return throwRangeError(arena, "start offset is not aligned");
            if (byte_offset > ab.bytes.len) return throwRangeError(arena, "byteOffset out of bounds");
            var length: usize = undefined;
            if (args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_) {
                length = toIndex(toNum(args[2]));
            } else {
                if ((ab.bytes.len - byte_offset) % esize != 0) return throwRangeError(arena, "buffer length not aligned");
                length = (ab.bytes.len - byte_offset) / esize;
            }
            if (byte_offset + length * esize > ab.bytes.len) return throwRangeError(arena, "length out of bounds");
            _ = try finishTypedArray(arena, this_obj, kind, src, ab, byte_offset, length);
            return val_mod.makeObject(arena, this_obj);
        }

        // Form 3: new TA(typedArray)  → copy elements into a fresh buffer.
        if (src.internal_kind == .typed_array) {
            const std_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
            const length = std_td.length;
            const res = try makeArrayBuffer(arena, length * esize);
            const newtd_v = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length);
            _ = newtd_v;
            const dst = getTd(val_mod.makeObject(arena, this_obj) catch unreachable) orelse unreachable;
            var i: usize = 0;
            while (i < length) : (i += 1) {
                const ev = try taLoad(arena, std_td, i);
                if (kind.isBigInt()) taStoreBig(dst, i, ev) else taStoreNumber(dst, i, toNum(ev));
            }
            return val_mod.makeObject(arena, this_obj);
        }

        // Form 4: new TA(arrayLike)  → read .length and index props.
        const length = arrayLikeLen(src);
        const res = try makeArrayBuffer(arena, length * esize);
        _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length);
        const dst = getTd(val_mod.makeObject(arena, this_obj) catch unreachable) orelse unreachable;
        var i: usize = 0;
        while (i < length) : (i += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const ev = src.get(key) orelse Value{};
            if (kind.isBigInt()) taStoreBig(dst, i, ev) else taStoreNumber(dst, i, toNum(ev));
        }
        return val_mod.makeObject(arena, this_obj);
    }

    return throwTypeError(arena, "invalid TypedArray constructor argument");
}

/// Produce a distinct native ctor fn per kind (comptime specialization).
pub fn taCtor(comptime kind: TAKind) val_mod.NativeFnPtr {
    return struct {
        fn f(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
            return makeTypedArray(arena, kind, this_val, args);
        }
    }.f;
}

// ---------------------------------------------------------------- TA prototype ---

/// Allocate a fresh TypedArray object of `kind` with `length` elements (new buffer).
fn allocTA(arena: std.mem.Allocator, kind: TAKind, length: usize) !struct { obj: *JsObject, td: *TypedArrayData } {
    const proto = active_ta_protos[@intFromEnum(kind)];
    const obj = try newObject(arena, proto);
    const res = try makeArrayBuffer(arena, length * kind.elemSize());
    _ = try finishTypedArray(arena, obj, kind, res.obj, res.data, 0, length);
    const td = getTd(val_mod.makeObject(arena, obj) catch unreachable).?;
    return .{ .obj = obj, .td = td };
}

fn elemToNumber(ev: Value) f64 {
    return toNum(ev);
}

pub fn nativeTaFill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    const start = relIndex(if (args.len > 1) toNum(args[1]) else 0, td.length);
    const end = relIndex(if (args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_) toNum(args[2]) else @floatFromInt(td.length), td.length);
    const v = if (args.len > 0) args[0] else Value{};
    var i = start;
    while (i < end) : (i += 1) {
        if (td.kind.isBigInt()) taStoreBig(td, i, v) else taStoreNumber(td, i, toNum(v));
    }
    return this_val;
}

pub fn nativeTaSubarray(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    const begin = relIndex(if (args.len > 0) toNum(args[0]) else 0, td.length);
    const end = relIndex(if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) toNum(args[1]) else @floatFromInt(td.length), td.length);
    const new_len = if (end > begin) end - begin else 0;
    const proto = active_ta_protos[@intFromEnum(td.kind)];
    const obj = try newObject(arena, proto);
    _ = try finishTypedArray(arena, obj, td.kind, td.buffer_obj, td.ab, td.byte_offset + begin * td.kind.elemSize(), new_len);
    return val_mod.makeObject(arena, obj);
}

pub fn nativeTaSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    const start = relIndex(if (args.len > 0) toNum(args[0]) else 0, td.length);
    const end = relIndex(if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) toNum(args[1]) else @floatFromInt(td.length), td.length);
    const new_len = if (end > start) end - start else 0;
    const a = try allocTA(arena, td.kind, new_len);
    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        const ev = try taLoad(arena, td, start + i);
        if (td.kind.isBigInt()) taStoreBig(a.td, i, ev) else taStoreNumber(a.td, i, toNum(ev));
    }
    return val_mod.makeObject(arena, a.obj);
}

pub fn nativeTaSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeUndefined(arena);
    const offset: usize = if (args.len > 1) toIndex(toNum(args[1])) else 0;
    const src = args[0].toPtr().object;
    if (src.internal_kind == .typed_array) {
        const src_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
        if (offset + src_td.length > td.length) return throwRangeError(arena, "offset out of bounds");
        var i: usize = 0;
        while (i < src_td.length) : (i += 1) {
            const ev = try taLoad(arena, src_td, i);
            if (td.kind.isBigInt()) taStoreBig(td, offset + i, ev) else taStoreNumber(td, offset + i, toNum(ev));
        }
    } else {
        const len = arrayLikeLen(src);
        if (offset + len > td.length) return throwRangeError(arena, "offset out of bounds");
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const ev = src.get(key) orelse Value{};
            if (td.kind.isBigInt()) taStoreBig(td, offset + i, ev) else taStoreNumber(td, offset + i, toNum(ev));
        }
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeTaIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0) return val_mod.makeNumber(arena, -1);
    const target = toNum(args[0]);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        if (toNum(ev) == target) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1);
}

pub fn nativeTaIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const target = toNum(args[0]);
    const want_nan = std.math.isNan(target);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const n = toNum(ev);
        if (n == target or (want_nan and std.math.isNan(n))) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeTaJoin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    const sep: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) args[0].toPtr().string else ",";
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, sep);
        const ev = try taLoad(arena, td, i);
        const n = toNum(ev);
        const s = try val_mod.formatNumber(arena, n);
        try buf.appendSlice(arena, s);
    }
    return val_mod.makeString(arena, buf.items);
}

pub fn nativeTaToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return nativeTaJoin(arena, this_val, &[_]Value{});
}

pub fn nativeTaReverse(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (td.length < 2) return this_val;
    var lo: usize = 0;
    var hi: usize = td.length - 1;
    while (lo < hi) : ({
        lo += 1;
        hi -= 1;
    }) {
        const a = try taLoad(arena, td, lo);
        const b = try taLoad(arena, td, hi);
        if (td.kind.isBigInt()) {
            taStoreBig(td, lo, b);
            taStoreBig(td, hi, a);
        } else {
            taStoreNumber(td, lo, toNum(b));
            taStoreNumber(td, hi, toNum(a));
        }
    }
    return this_val;
}

pub fn nativeTaAt(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    var idx: i64 = if (args.len > 0) @intFromFloat(@trunc(toNum(args[0]))) else 0;
    if (idx < 0) idx += @intCast(td.length);
    if (idx < 0 or idx >= @as(i64, @intCast(td.length))) return val_mod.makeUndefined(arena);
    return taLoad(arena, td, @intCast(idx));
}

pub fn nativeTaForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        _ = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeTaMap(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    const a = try allocTA(arena, td.kind, td.length);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (td.kind.isBigInt()) taStoreBig(a.td, i, r) else taStoreNumber(a.td, i, toNum(r));
    }
    return val_mod.makeObject(arena, a.obj);
}

pub fn nativeTaReduce(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    if (args.len == 0) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    var acc: Value = undefined;
    var i: usize = 0;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (td.length == 0) return throwTypeError(arena, "Reduce of empty array with no initial value");
        acc = try taLoad(arena, td, 0);
        i = 1;
    }
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        acc = try function_proto.invokeCallback(arena, Value{}, cb, &[_]Value{ acc, ev, idx_v, this_val });
    }
    return acc;
}

// ---------------------------------------------------------------- TA iterator ---

const TAIterKind = enum { keys, values, entries };
const TAIterData = struct { td: *TypedArrayData, index: usize, kind: TAIterKind, host: Value };

fn makeIterResult(arena: std.mem.Allocator, value: Value, done: bool) !Value {
    const obj = try newObject(arena, realm_mod.active_object_proto);
    try obj.set("value", value);
    try obj.set("done", try val_mod.makeBool(arena, done));
    return val_mod.makeObject(arena, obj);
}

fn makeTAIterator(arena: std.mem.Allocator, td: *TypedArrayData, kind: TAIterKind, host: Value) !Value {
    const it = try arena.create(TAIterData);
    it.* = .{ .td = td, .index = 0, .kind = kind, .host = host };
    const obj = try newObject(arena, active_ta_iter_proto);
    obj.internal_kind = .generator; // reuse a discriminator; slot type is TAIterData
    obj.internal_slot = it;
    return val_mod.makeObject(arena, obj);
}

pub fn nativeTaIterNext(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) return makeIterResult(arena, try val_mod.makeUndefined(arena), true);
    const obj = this_val.toPtr().object;
    if (obj.internal_slot == null) return makeIterResult(arena, try val_mod.makeUndefined(arena), true);
    const it: *TAIterData = @ptrCast(@alignCast(obj.internal_slot.?));
    if (it.index >= it.td.length) return makeIterResult(arena, try val_mod.makeUndefined(arena), true);
    const idx = it.index;
    it.index += 1;
    switch (it.kind) {
        .keys => return makeIterResult(arena, try val_mod.makeNumber(arena, @floatFromInt(idx)), false),
        .values => return makeIterResult(arena, try taLoad(arena, it.td, idx), false),
        .entries => {
            const pair = try newObject(arena, realm_mod.active_array_proto);
            pair.is_array = true;
            try pair.set("0", try val_mod.makeNumber(arena, @floatFromInt(idx)));
            try pair.set("1", try taLoad(arena, it.td, idx));
            pair.array_length = 2;
            return makeIterResult(arena, try val_mod.makeObject(arena, pair), false);
        },
    }
}

pub fn nativeTaValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    return makeTAIterator(arena, td, .values, this_val);
}

/// Iterator `@@iterator` returns the iterator itself (for-of over an iterator).
pub fn nativeIterSelf(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

pub fn nativeTaKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    return makeTAIterator(arena, td, .keys, this_val);
}

pub fn nativeTaEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    return makeTAIterator(arena, td, .entries, this_val);
}

// ---------------------------------------------------------------- TA static ---

/// `%TypedArray%.of` — kind is taken from the `this` constructor (so
/// `Int8Array.of(...)` and an explicit-receiver call both resolve correctly).
pub fn nativeTaOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const kind = kindFromCtor(this_val) orelse return throwTypeError(arena, "TypedArray.of requires a TypedArray constructor as receiver");
    const a = try allocTA(arena, kind, args.len);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (kind.isBigInt()) taStoreBig(a.td, i, args[i]) else taStoreNumber(a.td, i, toNum(args[i]));
    }
    return val_mod.makeObject(arena, a.obj);
}

/// `%TypedArray%.from` — kind from the `this` constructor.
pub fn nativeTaFrom(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const kind = kindFromCtor(this_val) orelse return throwTypeError(arena, "TypedArray.from requires a TypedArray constructor as receiver");
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) {
        const a = try allocTA(arena, kind, 0);
        return val_mod.makeObject(arena, a.obj);
    }
    const src = args[0].toPtr().object;
    const has_cb = args.len > 1 and args[1].bits != 0 and function_proto_isCallable(args[1]);
    const length: usize = blk: {
        if (src.internal_kind == .typed_array) {
            const std_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
            break :blk std_td.length;
        }
        break :blk arrayLikeLen(src);
    };
    const a = try allocTA(arena, kind, length);
    var i: usize = 0;
    while (i < length) : (i += 1) {
        var ev: Value = undefined;
        if (src.internal_kind == .typed_array) {
            const std_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
            ev = try taLoad(arena, std_td, i);
        } else {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            ev = src.get(key) orelse Value{};
        }
        if (has_cb) {
            const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
            ev = try function_proto.invokeCallback(arena, Value{}, args[1], &[_]Value{ ev, idx_v });
        }
        if (kind.isBigInt()) taStoreBig(a.td, i, ev) else taStoreNumber(a.td, i, toNum(ev));
    }
    return val_mod.makeObject(arena, a.obj);
}

fn function_proto_isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function,
        else => false,
    };
}

// ---------------------------------------------------------------- DataView ---

fn getDvData(v: Value) ?*DataViewData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    if (o.internal_kind != .data_view) return null;
    if (o.internal_slot == null) return null;
    return @ptrCast(@alignCast(o.internal_slot.?));
}

pub fn nativeDataViewCtor(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (this_val.bits == 0 or this_val.unbox() != .object) {
        return throwTypeError(arena, "Constructor DataView requires 'new'");
    }
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object or args[0].toPtr().object.internal_kind != .array_buffer) {
        return throwTypeError(arena, "First argument to DataView constructor must be an ArrayBuffer");
    }
    const buf_obj = args[0].toPtr().object;
    const ab: *ArrayBufferData = @ptrCast(@alignCast(buf_obj.internal_slot.?));
    const byte_offset: usize = if (args.len > 1) toIndex(toNum(args[1])) else 0;
    if (byte_offset > ab.bytes.len) return throwRangeError(arena, "byteOffset out of bounds");
    const byte_length: usize = if (args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_)
        toIndex(toNum(args[2]))
    else
        ab.bytes.len - byte_offset;
    if (byte_offset + byte_length > ab.bytes.len) return throwRangeError(arena, "Invalid DataView length");
    const dv = try arena.create(DataViewData);
    dv.* = .{ .buffer_obj = buf_obj, .ab = ab, .byte_offset = byte_offset, .byte_length = byte_length };
    const obj = this_val.toPtr().object;
    obj.internal_kind = .data_view;
    obj.internal_slot = dv;
    try obj.set("byteLength", try val_mod.makeNumber(arena, @floatFromInt(byte_length)));
    try obj.set("byteOffset", try val_mod.makeNumber(arena, @floatFromInt(byte_offset)));
    try obj.set("buffer", try val_mod.makeObject(arena, buf_obj));
    return this_val;
}

fn dvLittleEndian(args: []const Value, idx: usize) bool {
    if (idx >= args.len) return false;
    const v = args[idx];
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .boolean => |b| b,
        .undefined_, .null_ => false,
        .number => |n| n != 0,
        else => true,
    };
}

pub fn dvGet(comptime T: type, comptime is_float: bool) val_mod.NativeFnPtr {
    return struct {
        fn f(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
            const dv = getDvData(this_val) orelse return throwTypeError(arena, "not a DataView");
            const off: usize = if (args.len > 0) toIndex(toNum(args[0])) else 0;
            const size = @sizeOf(T);
            if (off + size > dv.byte_length) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
            const le = dvLittleEndian(args, 1);
            const endian: std.builtin.Endian = if (le) .little else .big;
            const base = dv.byte_offset + off;
            const p = dv.ab.bytes[base..];
            if (is_float) {
                if (T == f32) {
                    const bits = std.mem.readInt(u32, p[0..4], endian);
                    return val_mod.makeNumber(arena, @as(f32, @bitCast(bits)));
                } else {
                    const bits = std.mem.readInt(u64, p[0..8], endian);
                    return val_mod.makeNumber(arena, @as(f64, @bitCast(bits)));
                }
            } else {
                const n = std.mem.readInt(T, p[0..size], endian);
                return val_mod.makeNumber(arena, @floatFromInt(n));
            }
        }
    }.f;
}

pub fn dvSet(comptime T: type, comptime is_float: bool) val_mod.NativeFnPtr {
    return struct {
        fn f(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
            const dv = getDvData(this_val) orelse return throwTypeError(arena, "not a DataView");
            const off: usize = if (args.len > 0) toIndex(toNum(args[0])) else 0;
            const size = @sizeOf(T);
            if (off + size > dv.byte_length) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
            const x = if (args.len > 1) toNum(args[1]) else std.math.nan(f64);
            const le = dvLittleEndian(args, 2);
            const endian: std.builtin.Endian = if (le) .little else .big;
            const base = dv.byte_offset + off;
            const p = dv.ab.bytes[base..];
            if (is_float) {
                if (T == f32) {
                    std.mem.writeInt(u32, p[0..4], @bitCast(@as(f32, @floatCast(x))), endian);
                } else {
                    std.mem.writeInt(u64, p[0..8], @bitCast(x), endian);
                }
            } else {
                const UT = std.meta.Int(.unsigned, @bitSizeOf(T));
                std.mem.writeInt(UT, p[0..size], wrapUnsigned(UT, x), endian);
            }
            return val_mod.makeUndefined(arena);
        }
    }.f;
}

// ------------------------------------------------------------------- tests ---

test "canonicalIndex" {
    try std.testing.expectEqual(@as(?usize, 0), canonicalIndex("0"));
    try std.testing.expectEqual(@as(?usize, 42), canonicalIndex("42"));
    try std.testing.expectEqual(@as(?usize, null), canonicalIndex("01"));
    try std.testing.expectEqual(@as(?usize, null), canonicalIndex("-1"));
    try std.testing.expectEqual(@as(?usize, null), canonicalIndex("1.5"));
    try std.testing.expectEqual(@as(?usize, null), canonicalIndex(""));
}

test "wrapUnsigned modular" {
    try std.testing.expectEqual(@as(u8, 0), wrapUnsigned(u8, 256.0));
    try std.testing.expectEqual(@as(u8, 255), wrapUnsigned(u8, -1.0));
    try std.testing.expectEqual(@as(u8, 1), wrapUnsigned(u8, 257.0));
    try std.testing.expectEqual(@as(u32, 4294967295), wrapUnsigned(u32, -1.0));
}

test "clampU8 half-to-even" {
    try std.testing.expectEqual(@as(u8, 0), clampU8(-5));
    try std.testing.expectEqual(@as(u8, 255), clampU8(300));
    try std.testing.expectEqual(@as(u8, 2), clampU8(2.5));
    try std.testing.expectEqual(@as(u8, 4), clampU8(3.5));
    try std.testing.expectEqual(@as(u8, 3), clampU8(2.6));
}
