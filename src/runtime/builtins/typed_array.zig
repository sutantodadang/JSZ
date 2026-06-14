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
const obj_mod = @import("../../object/object.zig");
const JsObject = obj_mod.JsObject;
const PropAttr = obj_mod.PropAttr;
const realm_mod = @import("../realm.zig");
const function_proto = @import("function_proto.zig");
const intrinsics = @import("intrinsics.zig");
const coercion = @import("coercion.zig");
const coll = @import("es2015_collections.zig");

/// R1: install ArrayBuffer / %TypedArray% / per-kind ctors / DataView and bind globals.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const object_proto = ctx.object_proto;
    const fn_proto_obj = ctx.function_proto.?;

    // ArrayBuffer
    const ab_proto = try JsObject.create(arena, object_proto);
    try intrinsics.setMethods(arena, ab_proto, .{
        .{ "slice", nativeArrayBufferSlice },
        .{ "transfer", nativeAbTransfer },
        .{ "transferToFixedLength", nativeAbTransferToFixedLength },
        .{ "resize", nativeAbResize },
    });
    try defineGetter(arena, ab_proto, "detached", abGetDetached);
    try defineGetter(arena, ab_proto, "byteLength", abGetByteLength);
    try defineGetter(arena, ab_proto, "resizable", abGetResizable);
    try defineGetter(arena, ab_proto, "maxByteLength", abGetMaxByteLength);
    active_arraybuffer_proto = ab_proto;
    const ab_ctor = try JsObject.create(arena, null);
    try ab_ctor.set("prototype", try val_mod.makeObject(arena, ab_proto));
    try ab_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeArrayBufferCtor));
    try ab_ctor.set("isView", try val_mod.makeNativeFunctionNamed(arena, nativeArrayBufferIsView, "isView", 1));
    _ = try ab_ctor.defineOwnData("name", try val_mod.makeString(arena, "ArrayBuffer"),
        .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ab_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1),
        .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try ab_proto.defineOwnData("constructor", try val_mod.makeObject(arena, ab_ctor),
        .{ .writable = true, .enumerable = false, .configurable = true });
    try ctx.env.define("ArrayBuffer", try val_mod.makeObject(arena, ab_ctor));

    // %TypedArray%.prototype — shared methods with spec-correct .length values (ES2023 §22.2.3).
    const ta_proto = try JsObject.create(arena, object_proto);
    // Each tuple: .{ js_name, fn_ptr, spec_length }
    const ta_methods = .{
        .{ "fill",        nativeTaFill,        @as(u8, 1) },
        .{ "subarray",    nativeTaSubarray,    @as(u8, 2) },
        .{ "slice",       nativeTaSlice,       @as(u8, 2) },
        .{ "set",         nativeTaSet,         @as(u8, 1) },
        .{ "indexOf",     nativeTaIndexOf,     @as(u8, 1) },
        .{ "includes",    nativeTaIncludes,    @as(u8, 1) },
        .{ "join",        nativeTaJoin,        @as(u8, 1) },
        .{ "toString",    nativeTaToString,    @as(u8, 0) },
        .{ "reverse",     nativeTaReverse,     @as(u8, 0) },
        .{ "at",          nativeTaAt,          @as(u8, 1) },
        .{ "forEach",     nativeTaForEach,     @as(u8, 1) },
        .{ "map",         nativeTaMap,         @as(u8, 1) },
        .{ "reduce",      nativeTaReduce,      @as(u8, 1) },
        .{ "values",      nativeTaValues,      @as(u8, 0) },
        .{ "keys",        nativeTaKeys,        @as(u8, 0) },
        .{ "entries",     nativeTaEntries,     @as(u8, 0) },
        .{ "sort",        nativeTaSort,        @as(u8, 1) },
        .{ "find",        nativeTaFind,        @as(u8, 1) },
        .{ "findIndex",   nativeTaFindIndex,   @as(u8, 1) },
        .{ "filter",      nativeTaFilter,      @as(u8, 1) },
        .{ "every",       nativeTaEvery,       @as(u8, 1) },
        .{ "some",        nativeTaSome,        @as(u8, 1) },
        .{ "copyWithin",  nativeTaCopyWithin,  @as(u8, 2) },
        .{ "reduceRight",     nativeTaReduceRight,    @as(u8, 1) },
        .{ "lastIndexOf",     nativeTaLastIndexOf,    @as(u8, 1) },
        .{ "toLocaleString",  nativeTaToLocaleString, @as(u8, 0) },
        .{ "findLast",        nativeTaFindLast,       @as(u8, 1) },
        .{ "findLastIndex",   nativeTaFindLastIndex,  @as(u8, 1) },
        .{ "toReversed",      nativeTaToReversed,     @as(u8, 0) },
        .{ "toSorted",        nativeTaToSorted,       @as(u8, 1) },
        .{ "with",            nativeTaWith,           @as(u8, 2) },
    };
    // Spec §17: built-in methods are { writable:true, enumerable:false, configurable:true }.
    const m_attr: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    inline for (ta_methods) |m| {
        _ = try ta_proto.defineOwnData(m[0], try val_mod.makeNativeFunctionNamed(arena, m[1], m[0], m[2]), m_attr);
    }
    // @@iterator shares the same fn as values (length 0, no string name needed).
    _ = try ta_proto.defineOwnData("@@iterator", try val_mod.makeNativeFunctionNamed(arena, nativeTaValues, "values", 0), m_attr);
    active_typedarray_proto = ta_proto;

    // Instance accessor getters live on %TypedArray%.prototype.
    try defineGetter(arena, ta_proto, "length", taGetLength);
    try defineGetter(arena, ta_proto, "byteLength", taGetByteLength);
    try defineGetter(arena, ta_proto, "byteOffset", taGetByteOffset);
    try defineGetter(arena, ta_proto, "buffer", taGetBuffer);

    // %TypedArray% intrinsic constructor (abstract).
    const ta_ctor = try JsObject.create(arena, fn_proto_obj);
    // §22.2.1: %TypedArray%.name is "TypedArray", .length is 0 (both
    // non-writable, non-enumerable, configurable).
    const nlen_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    _ = try ta_ctor.defineOwnData("name", try val_mod.makeString(arena, "TypedArray"), nlen_attr);
    _ = try ta_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 0), nlen_attr);
    // .prototype: non-writable, non-enumerable, non-configurable (ctor → proto link).
    _ = try ta_ctor.defineOwnData("prototype", try val_mod.makeObject(arena, ta_proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try ta_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeTaAbstractCtor));
    _ = try ta_ctor.defineOwnData("from", try val_mod.makeNativeFunctionNamed(arena, nativeTaFrom, "from", 1), m_attr);
    _ = try ta_ctor.defineOwnData("of", try val_mod.makeNativeFunctionNamed(arena, nativeTaOf, "of", 0), m_attr);
    // %TypedArray%.prototype.constructor: writable, non-enumerable, configurable.
    _ = try ta_proto.defineOwnData("constructor", try val_mod.makeObject(arena, ta_ctor), m_attr);
    active_typedarray_ctor = ta_ctor;

    // TypedArray iterators share the %ArrayIteratorPrototype% (built by
    // es2015_collections.initArrayIteratorProto at realm init).

    // Per-kind constructors + prototypes (inherit %TypedArray% / its prototype).
    inline for (all_kinds) |kind| {
        const kp = try JsObject.create(arena, ta_proto);
        active_ta_protos[@intFromEnum(kind)] = kp;
        const kctor = try JsObject.create(arena, ta_ctor);
        active_ta_ctors[@intFromEnum(kind)] = kctor;
        // .prototype: non-writable, non-enumerable, non-configurable.
        _ = try kctor.defineOwnData("prototype", try val_mod.makeObject(arena, kp), .{ .writable = false, .enumerable = false, .configurable = false });
        try kctor.set("__call__", try val_mod.makeNativeFunction(arena, taCtor(kind)));
        _ = try kctor.defineOwnData("from", try val_mod.makeNativeFunctionNamed(arena, nativeTaFrom, "from", 1), m_attr);
        _ = try kctor.defineOwnData("of", try val_mod.makeNativeFunctionNamed(arena, nativeTaOf, "of", 0), m_attr);
        // BYTES_PER_ELEMENT: non-writable, non-enumerable, non-configurable (ES spec §22.2.5.1)
        const bpe_val = try val_mod.makeNumber(arena, @floatFromInt(kind.elemSize()));
        const bpe_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = false };
        _ = try kctor.defineOwnData("BYTES_PER_ELEMENT", bpe_val, bpe_attr);
        _ = try kp.defineOwnData("BYTES_PER_ELEMENT", bpe_val, bpe_attr);
        // name: non-writable, non-enumerable, configurable (matches Function.name)
        _ = try kctor.defineOwnData("name", try val_mod.makeString(arena, kind.ctorName()),
            .{ .writable = false, .enumerable = false, .configurable = true });
        // length: non-writable, non-enumerable, configurable (matches Function.length)
        _ = try kctor.defineOwnData("length", try val_mod.makeNumber(arena, 3),
            .{ .writable = false, .enumerable = false, .configurable = true });
        // constructor: non-enumerable, writable, configurable (spec-correct)
        _ = try kp.defineOwnData("constructor", try val_mod.makeObject(arena, kctor),
            .{ .writable = true, .enumerable = false, .configurable = true });
        try ctx.env.define(kind.ctorName(), try val_mod.makeObject(arena, kctor));
    }

    // DataView
    const dv_proto = try JsObject.create(arena, object_proto);
    // DataView.prototype methods — non-enumerable via setMethods.
    // dvGet/dvSet are comptime-generated; can't use setMethods directly, use defineOwnData.
    const dv_fn_attr: PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    // get*(byteOffset[, littleEndian]) → length 1; set*(byteOffset, value[, littleEndian]) → length 2.
    inline for ([_]struct { []const u8, val_mod.NativeFnPtr, u8 }{
        .{ "getInt8",    dvGet(i8,  false), 1 }, .{ "getUint8",    dvGet(u8,  false), 1 },
        .{ "getInt16",   dvGet(i16, false), 1 }, .{ "getUint16",   dvGet(u16, false), 1 },
        .{ "getInt32",   dvGet(i32, false), 1 }, .{ "getUint32",   dvGet(u32, false), 1 },
        .{ "getFloat32", dvGet(f32, true),  1 }, .{ "getFloat64",  dvGet(f64, true),  1 },
        .{ "setInt8",    dvSet(i8,  false), 2 }, .{ "setUint8",    dvSet(u8,  false), 2 },
        .{ "setInt16",   dvSet(i16, false), 2 }, .{ "setUint16",   dvSet(u16, false), 2 },
        .{ "setInt32",   dvSet(i32, false), 2 }, .{ "setUint32",   dvSet(u32, false), 2 },
        .{ "setFloat32", dvSet(f32, true),  2 }, .{ "setFloat64",  dvSet(f64, true),  2 },
    }) |pair| {
        _ = try dv_proto.defineOwnData(pair[0],
            try val_mod.makeNativeFunctionNamed(arena, pair[1], pair[0], pair[2]), dv_fn_attr);
    }
    active_dataview_proto = dv_proto;
    try defineGetter(arena, dv_proto, "byteLength", dvGetByteLength);
    try defineGetter(arena, dv_proto, "byteOffset", dvGetByteOffset);
    const dv_ctor = try JsObject.create(arena, null);
    try dv_ctor.set("prototype", try val_mod.makeObject(arena, dv_proto));
    try dv_ctor.set("__call__", try val_mod.makeNativeFunction(arena, nativeDataViewCtor));
    _ = try dv_ctor.defineOwnData("name", try val_mod.makeString(arena, "DataView"),
        .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try dv_ctor.defineOwnData("length", try val_mod.makeNumber(arena, 1),
        .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try dv_proto.defineOwnData("constructor", try val_mod.makeObject(arena, dv_ctor),
        .{ .writable = true, .enumerable = false, .configurable = true });

    try ctx.env.define("DataView", try val_mod.makeObject(arena, dv_ctor));
}

/// Called after Symbol well-known values are captured, wires @@toStringTag and
/// @@species onto already-registered TypedArray/ArrayBuffer/DataView objects.
pub fn registerSymbols(arena: std.mem.Allocator) !void {
    // @@toStringTag on prototypes: non-writable, non-enumerable, configurable (ES spec).
    const tag_attr: PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    if (realm_mod.active_sym_to_string_tag) |tag_sym| {
        if (active_arraybuffer_proto) |p| try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "ArrayBuffer"), tag_attr);
        if (active_dataview_proto) |p| try p.setSymAttr(tag_sym, try val_mod.makeString(arena, "DataView"), tag_attr);
        // %TypedArray%.prototype[@@toStringTag] is an accessor getter returning the
        // constructor name (or undefined when `this` has no [[TypedArrayName]]).
        // Per-kind prototypes inherit it (no own @@toStringTag).
        if (active_typedarray_proto) |p| try defineSymGetter(arena, p, tag_sym, taGetToStringTag, "get [Symbol.toStringTag]");
    }
    // @@species: an accessor getter on %TypedArray% (the abstract constructor),
    // returning `this`. Per-kind constructors inherit it (no own @@species).
    if (realm_mod.active_sym_species) |spec_sym| {
        if (active_typedarray_ctor) |c|
            try defineSymGetter(arena, c, spec_sym, taGetSpecies, "get [Symbol.species]");
    }
    // @@iterator on %TypedArray%.prototype — wire the real Symbol.iterator sym-key
    // to the same function stored under the string "@@iterator" convention.
    if (realm_mod.active_sym_iterator) |iter_sym| {
        if (active_typedarray_proto) |tp| {
            if (tp.get("@@iterator")) |iter_fn| {
                try tp.setSymAttr(iter_sym, iter_fn, .{ .writable = true, .enumerable = false, .configurable = true });
            }
        }
    }
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
    bytes: []u8, // capacity (== max_byte_length when resizable, else byte_length)
    byte_length: usize = 0, // current logical length
    max_byte_length: ?usize = null, // set => resizable
    detached: bool = false,
    shared: bool = false,
};

pub const TypedArrayData = struct {
    buffer_obj: *JsObject, // the ArrayBuffer JsObject (for `.buffer` + identity)
    ab: *ArrayBufferData, // cached backing store
    byte_offset: usize,
    length: usize, // live element count (refreshed by validateTypedArray; == nominal for fixed views)
    nominal_length: usize = 0, // construction-time fixed length (ignored when track_length)
    kind: TAKind,
    track_length: bool = false, // auto length-tracking: resizable buffer, no explicit length
};

pub const DataViewData = struct {
    buffer_obj: *JsObject,
    ab: *ArrayBufferData,
    byte_offset: usize,
    byte_length: usize, // nominal (fixed views); ignored when track_length
    track_length: bool = false, // auto length-tracking: resizable buffer, no explicit byteLength
};

// ---------------------------------------------------------------- module protos ---

pub var active_arraybuffer_proto: ?*JsObject = null;
pub var active_dataview_proto: ?*JsObject = null;
pub var active_typedarray_proto: ?*JsObject = null; // %TypedArray%.prototype
pub var active_typedarray_ctor: ?*JsObject = null; // %TypedArray% (abstract ctor)
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

fn throwSyntaxError(arena: std.mem.Allocator, msg: []const u8) anyerror {
    const obj = try newObject(arena, realm_mod.error_proto_SyntaxError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "SyntaxError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

// ----------------------------------------------- spec-faithful coercions ---
// Throwing variants of ToNumber/ToIndex/ToBigInt that run user `valueOf`/
// `@@toPrimitive` via the VM (coercion.toPrimitive) and PROPAGATE throws.
// Symbol/BigInt → TypeError, negative/out-of-range index → RangeError.

/// ToNumber that throws on Symbol/BigInt and runs object coercion hooks.
fn toNumberThrowing(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    if (v.bits == 0) return std.math.nan(f64); // undefined
    switch (v.unbox()) {
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
        .bigint => return throwTypeError(arena, "Cannot convert a BigInt to a number"),
        .object => {
            const prim = (try coercion.toPrimitive(arena, v, .number)) orelse v;
            // Re-dispatch on the primitive (a Symbol/BigInt prim still throws).
            if (prim.bits == 0) return std.math.nan(f64);
            switch (prim.unbox()) {
                .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a number"),
                .bigint => return throwTypeError(arena, "Cannot convert a BigInt to a number"),
                .object => return std.math.nan(f64), // toPrimitive guarantees non-object; defensive
                else => return toNum(prim),
            }
        },
        else => return toNum(v),
    }
}

/// ToIndex: ToIntegerOrInfinity then bound to [0, 2^53-1], throwing RangeError.
fn toIndexThrowing(arena: std.mem.Allocator, v: Value) anyerror!usize {
    if (v.bits == 0 or v.unbox() == .undefined_) return 0;
    const n = try toNumberThrowing(arena, v);
    // ToIntegerOrInfinity: NaN/±0 → 0, else truncate toward zero.
    const i: f64 = if (std.math.isNan(n)) 0 else @trunc(n);
    if (i < 0) return throwRangeError(arena, "Invalid typed array length or offset");
    // Bound-check in f64 BEFORE @intFromFloat to avoid a conversion panic.
    if (!std.math.isFinite(i) or i > 9007199254740991.0)
        return throwRangeError(arena, "Invalid typed array length or offset");
    return @intFromFloat(i);
}

/// ToIntegerOrInfinity via throwing ToNumber: NaN/±0 → 0, ±Inf preserved,
/// else truncate toward zero. For relative-index args (negatives allowed).
fn toIntegerThrowing(arena: std.mem.Allocator, v: Value) anyerror!f64 {
    if (v.bits == 0 or v.unbox() == .undefined_) return 0;
    const n = try toNumberThrowing(arena, v);
    if (std.math.isNan(n)) return 0;
    if (!std.math.isFinite(n)) return n;
    return @trunc(n);
}

/// ToBigInt: throws TypeError for Number/Symbol/undefined/null, SyntaxError for
/// unparseable strings. Returns a `.bigint` Value.
fn toBigIntThrowing(arena: std.mem.Allocator, v: Value) anyerror!Value {
    if (v.bits == 0) return throwTypeError(arena, "Cannot convert undefined to a BigInt");
    switch (v.unbox()) {
        .bigint => return v,
        .boolean => |b| return val_mod.makeBigIntFromI64(arena, if (b) 1 else 0),
        .string => |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            const lit = if (t.len == 0) "0" else t;
            return val_mod.makeBigIntFromLiteral(arena, lit) catch
                return throwSyntaxError(arena, "Cannot convert string to a BigInt");
        },
        .number => return throwTypeError(arena, "Cannot convert a Number to a BigInt"),
        .symbol => return throwTypeError(arena, "Cannot convert a Symbol value to a BigInt"),
        .undefined_ => return throwTypeError(arena, "Cannot convert undefined to a BigInt"),
        .null_ => return throwTypeError(arena, "Cannot convert null to a BigInt"),
        .object => {
            const prim = (try coercion.toPrimitive(arena, v, .number)) orelse
                return throwTypeError(arena, "Cannot convert object to a BigInt");
            // prim is guaranteed primitive; recurse (object case won't re-hit).
            return toBigIntThrowing(arena, prim);
        },
        else => return throwTypeError(arena, "Cannot convert value to a BigInt"),
    }
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

/// Canonical numeric index string (ES2023 §7.1.21): returns the number value
/// if `key` is a canonical numeric index string (a string that round-trips via
/// ToNumber→ToString), or null otherwise. Covers "0","1","-0","1.5",
/// "NaN","Infinity","-Infinity","-1", etc. Non-numeric keys return null.
pub fn canonicalNumericIndexString(key: []const u8) ?f64 {
    if (key.len == 0) return null;
    if (std.mem.eql(u8, key, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, key, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, key, "NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, key, "-0")) return -0.0;
    const n = std.fmt.parseFloat(f64, key) catch return null;
    // Round-trip check: ToString(ToNumber(key)) must equal key.
    const rendered = val_mod.formatNumber(std.heap.page_allocator, n) catch return null;
    if (!std.mem.eql(u8, rendered, key)) return null;
    return n;
}

/// IsValidIntegerIndex(O, idx): true iff buffer not detached, idx is a
/// mathematical integer, idx != -0, and 0 <= idx < O.length.
pub fn isValidIntegerIndex(td: *const TypedArrayData, idx: f64) bool {
    if (td.ab.detached) return false;
    if (std.math.isNan(idx)) return false;
    if (idx == 0.0 and std.math.signbit(idx)) return false;
    if (@trunc(idx) != idx) return false; // non-integer (also rejects nothing for ±Inf: handled below)
    if (idx < 0) return false;
    if (taIsOob(td)) return false;
    // Bound-check in f64 BEFORE @intFromFloat — rejects +Inf and any value
    // >= length without an out-of-range integer cast (which would panic).
    if (idx >= @as(f64, @floatFromInt(taCurrentLen(td)))) return false;
    return true;
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

/// Full [[Get]] of a string-keyed property via the VM bridge: fires accessor
/// getters, Proxy traps, and array-index/length reads, walking the proto chain.
/// Falls back to a raw own-property read when no Context is active.
fn vmGet(arena: std.mem.Allocator, obj_val: Value, key: []const u8) anyerror!Value {
    if (realm_mod.active_context) |ctx| return ctx.getProp(arena, obj_val, key);
    if (obj_val.bits != 0 and obj_val.unbox() == .object)
        return obj_val.toPtr().object.get(key) orelse Value{};
    return Value{};
}

/// Observable symbol-keyed [[Get]] (fires accessor getters / Proxy traps).
fn vmGetSym(arena: std.mem.Allocator, obj_val: Value, sym_key: Value) anyerror!Value {
    if (realm_mod.active_context) |ctx| return ctx.getPropSym(arena, obj_val, sym_key);
    if (obj_val.bits != 0 and obj_val.unbox() == .object)
        return obj_val.toPtr().object.getSym(sym_key) orelse Value{};
    return Value{};
}

/// GetPrototypeFromConstructor at the constructor's spec-precise point: read
/// `? Get(pending_new_target,"prototype")` (fires getters, throws propagate),
/// set `this_obj`'s prototype when it is an object, and CONSUME the pending
/// NewTarget so the dispatcher does not re-apply it. No-op when none pending.
fn applyNewTargetProto(arena: std.mem.Allocator, this_obj: *JsObject) anyerror!void {
    const nt = realm_mod.pending_new_target;
    if (nt.bits == 0) return;
    realm_mod.pending_new_target = Value{}; // consume before the (throwing) Get
    const pv = try vmGet(arena, nt, "prototype");
    if (pv.bits != 0 and pv.unbox() == .object) this_obj.proto = pv.toPtr().object;
}

// ---------------------------------------------------------------- element IO ---

pub fn taLoad(arena: std.mem.Allocator, td: *const TypedArrayData, i: usize) !Value {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    // A whole-view-OOB fixed-length view (resizable buffer shrunk below it) reads
    // EVERY index as undefined — IsValidIntegerIndex checks IsTypedArrayOutOfBounds
    // first. Length-tracking views are never OOB; their per-element bound below
    // returns undefined past the (shrunk) live length.
    if (taIsOob(td)) return val_mod.makeUndefined(arena);
    // Bound against the CURRENT logical byte_length (not capacity): a resizable
    // buffer shrunk during a callback must read OOB indices as undefined, and a
    // detached buffer (byte_length 0) makes every index OOB.
    if (base + sz > td.ab.byte_length) return val_mod.makeUndefined(arena);
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
    if (base + sz > td.ab.byte_length) return;
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

/// Low 64 bits (mod 2^64) of a BigInt, as the raw bits stored by BigInt64/
/// BigUint64Array — i.e. ToBigInt64/ToBigUint64. The magnitude's low 64 bits are
/// limbs[0] (usize = 64-bit on our targets, little-endian); negatives take the
/// two's complement. Values outside ±2^63 wrap, matching SetValueInBuffer.
fn bigintLow64(c: std.math.big.int.Const) u64 {
    const mag_low: u64 = if (c.limbs.len > 0) @intCast(c.limbs[0]) else 0;
    return if (c.positive) mag_low else 0 -% mag_low;
}

pub fn taStoreBig(td: *const TypedArrayData, i: usize, v: Value) void {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    if (base + sz > td.ab.byte_length) return;
    const p = b[base..];
    var u: u64 = 0;
    if (v.bits != 0 and v.unbox() == .bigint) {
        u = bigintLow64(v.toPtr().bigint.toConst());
    }
    std.mem.writeInt(u64, p[0..8], u, native_endian);
}

// ---------------------------------------------------------------- ArrayBuffer ---

const AbResult = struct { obj: *JsObject, data: *ArrayBufferData };

fn makeArrayBuffer(arena: std.mem.Allocator, byte_len: usize) !AbResult {
    const bytes = try arena.alloc(u8, byte_len);
    @memset(bytes, 0);
    const data = try arena.create(ArrayBufferData);
    data.* = .{ .bytes = bytes, .byte_length = byte_len };
    const obj = try newObject(arena, active_arraybuffer_proto);
    obj.internal_kind = .array_buffer;
    obj.internal_slot = data;
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
    const len: usize = if (args.len > 0) try toIndexThrowing(arena, args[0]) else 0;
    // GetArrayBufferMaxByteLengthOption: options.maxByteLength (ToIndex) marks resizable.
    var max_bl: ?usize = null;
    if (args.len > 1 and args[1].bits != 0 and args[1].unbox() == .object) {
        const opts = args[1].toPtr().object;
        if (opts.get("maxByteLength")) |mv| {
            if (mv.bits != 0 and mv.unbox() != .undefined_)
                max_bl = try toIndexThrowing(arena, mv);
        }
    }
    if (max_bl) |m| {
        if (len > m) return throwRangeError(arena, "ArrayBuffer length exceeds maxByteLength");
    }
    const cap = max_bl orelse len;
    const bytes = try arena.alloc(u8, cap);
    @memset(bytes, 0);
    const data = try arena.create(ArrayBufferData);
    data.* = .{ .bytes = bytes, .byte_length = len, .max_byte_length = max_bl };
    const obj = this_val.toPtr().object;
    // GetPrototypeFromConstructor runs in AllocateArrayBuffer, after ToIndex(length)
    // + the maxByteLength option (so a primitive-length throw precedes proto access).
    try applyNewTargetProto(arena, obj);
    obj.internal_kind = .array_buffer;
    obj.internal_slot = data;
    return this_val;
}

/// ArrayBuffer.prototype.resize(newLength): grow/shrink a resizable buffer
/// within [0, maxByteLength]; zero-fills exposed bytes on grow.
pub fn nativeAbResize(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "ArrayBuffer.prototype.resize called on non-ArrayBuffer");
    const max = ab.max_byte_length orelse return throwTypeError(arena, "ArrayBuffer is not resizable");
    const new_len = try toIndexThrowing(arena, if (args.len > 0) args[0] else Value{});
    if (ab.detached) return throwTypeError(arena, "Cannot resize a detached ArrayBuffer");
    if (new_len > max) return throwRangeError(arena, "ArrayBuffer resize length exceeds maxByteLength");
    if (new_len > ab.byte_length) @memset(ab.bytes[ab.byte_length..new_len], 0);
    ab.byte_length = new_len;
    return val_mod.makeUndefined(arena);
}

pub fn abGetResizable(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "get resizable called on non-ArrayBuffer");
    return val_mod.makeBool(arena, ab.max_byte_length != null);
}

pub fn abGetMaxByteLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "get maxByteLength called on non-ArrayBuffer");
    if (ab.detached) return val_mod.makeNumber(arena, 0);
    return val_mod.makeNumber(arena, @floatFromInt(ab.max_byte_length orelse ab.byte_length));
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
    const len = ab.byte_length;
    const start = relIndex(if (args.len > 0) toNum(args[0]) else 0, len);
    const end = relIndex(if (args.len > 1 and args[1].bits != 0 and args[1].unbox() != .undefined_) toNum(args[1]) else @floatFromInt(len), len);
    const new_len = if (end > start) end - start else 0;
    const res = try makeArrayBuffer(arena, new_len);
    @memcpy(res.data.bytes[0..new_len], ab.bytes[start .. start + new_len]);
    return val_mod.makeObject(arena, res.obj);
}

pub fn abGetDetached(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "not an ArrayBuffer");
    return val_mod.makeBool(arena, ab.detached);
}

pub fn abGetByteLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "get byteLength called on non-ArrayBuffer");
    if (ab.detached) return val_mod.makeNumber(arena, 0);
    return val_mod.makeNumber(arena, @floatFromInt(ab.byte_length));
}

pub fn nativeAbTransfer(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const ab = getAbData(this_val) orelse return throwTypeError(arena, "not an ArrayBuffer");
    if (ab.detached) return throwTypeError(arena, "ArrayBuffer is detached");
    const new_len: usize = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() != .undefined_) toIndex(toNum(args[0])) else ab.byte_length;
    const res = try makeArrayBuffer(arena, new_len);
    const copy_len = @min(new_len, ab.byte_length);
    @memcpy(res.data.bytes[0..copy_len], ab.bytes[0..copy_len]);
    ab.detached = true;
    ab.bytes = &[_]u8{};
    ab.byte_length = 0;
    return val_mod.makeObject(arena, res.obj);
}

pub fn nativeAbTransferToFixedLength(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    return nativeAbTransfer(arena, this_val, args);
}

/// Detach an ArrayBuffer: mark detached, zero the backing bytes.
/// Idempotent. SharedArrayBuffer and non-ArrayBuffer objects are ignored.
pub fn detachArrayBuffer(buf_val: Value) void {
    if (buf_val.bits == 0 or buf_val.unbox() != .object) return;
    const o = buf_val.toPtr().object;
    if (o.internal_kind != .array_buffer) return;
    if (o.internal_slot == null) return;
    const ab: *ArrayBufferData = @ptrCast(@alignCast(o.internal_slot.?));
    if (ab.shared) return; // SharedArrayBuffer is not detachable
    if (ab.detached) return; // idempotent
    ab.detached = true;
    ab.bytes = &[_]u8{};
    ab.byte_length = 0;
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

pub fn getTd(v: Value) ?*TypedArrayData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    if (o.internal_kind != .typed_array) return null;
    if (o.internal_slot == null) return null;
    return @ptrCast(@alignCast(o.internal_slot.?));
}

/// IsTypedArrayOutOfBounds: detached, or the view no longer fits the (possibly
/// resized) backing buffer.
pub fn taIsOob(td: *const TypedArrayData) bool {
    const ab = td.ab;
    if (ab.detached) return true;
    if (td.byte_offset > ab.byte_length) return true;
    if (td.track_length) return false; // offset<=byte_length already checked → fits
    return td.byte_offset + td.nominal_length * td.kind.elemSize() > ab.byte_length;
}

/// Current element length (0 when out-of-bounds). Length-tracking views derive
/// it from the live buffer byte length; fixed views return their nominal length.
pub fn taCurrentLen(td: *const TypedArrayData) usize {
    const ab = td.ab;
    if (ab.detached) return 0;
    if (td.byte_offset > ab.byte_length) return 0;
    if (td.track_length) return (ab.byte_length - td.byte_offset) / td.kind.elemSize();
    if (td.byte_offset + td.nominal_length * td.kind.elemSize() > ab.byte_length) return 0;
    return td.nominal_length;
}

fn finishTypedArray(arena: std.mem.Allocator, this_obj: *JsObject, kind: TAKind, buffer_obj: *JsObject, ab: *ArrayBufferData, byte_offset: usize, length: usize, track_length: bool) !Value {
    const td = try arena.create(TypedArrayData);
    td.* = .{ .buffer_obj = buffer_obj, .ab = ab, .byte_offset = byte_offset, .length = length, .nominal_length = length, .kind = kind, .track_length = track_length };
    this_obj.internal_kind = .typed_array;
    this_obj.internal_slot = td;
    // length/byteLength/byteOffset/buffer/BYTES_PER_ELEMENT are inherited accessor
    // getters / data props on %TypedArray%.prototype + per-kind prototype.
    return val_mod.makeObject(arena, this_obj);
}

// ---- instance accessor getters (installed on %TypedArray%.prototype) ----

pub fn taGetLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get length called on non-TypedArray");
    return val_mod.makeNumber(arena, @floatFromInt(taCurrentLen(td)));
}

pub fn taGetByteLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get byteLength called on non-TypedArray");
    return val_mod.makeNumber(arena, @floatFromInt(taCurrentLen(td) * td.kind.elemSize()));
}

pub fn taGetByteOffset(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get byteOffset called on non-TypedArray");
    if (taIsOob(td)) return val_mod.makeNumber(arena, 0);
    return val_mod.makeNumber(arena, @floatFromInt(td.byte_offset));
}

pub fn taGetBuffer(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "get buffer called on non-TypedArray");
    return val_mod.makeObject(arena, td.buffer_obj);
}

/// get %TypedArray%[@@species]: returns the `this` value (the constructor).
pub fn taGetSpecies(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    _ = arena;
    return this_val;
}

/// Install a read-only accessor (getter only) on `proto` under `key`.
pub fn defineGetter(arena: std.mem.Allocator, proto: *JsObject, key: []const u8, getter: val_mod.NativeFnPtr) !void {
    const holder = try newObject(arena, null);
    // §17: a getter's name is "get " ++ propertyKey, length 0.
    const gname = try std.fmt.allocPrint(arena, "get {s}", .{key});
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, gname, 0));
    const hv = try val_mod.makeObject(arena, holder);
    _ = try proto.defineOwnAccessor(key, hv, .{ .enumerable = false, .configurable = true, .writable = false });
}

/// Install a read-only accessor (getter only) under a symbol key on `proto`.
fn defineSymGetter(arena: std.mem.Allocator, proto: *JsObject, sym_key: Value, getter: val_mod.NativeFnPtr, name: []const u8) !void {
    const holder = try newObject(arena, null);
    try holder.set("get", try val_mod.makeNativeFunctionNamed(arena, getter, name, 0));
    try proto.setSymAttr(sym_key, try val_mod.makeObject(arena, holder), .{ .writable = false, .enumerable = false, .configurable = true, .is_accessor = true });
}

/// %TypedArray%.prototype[@@toStringTag] getter: the constructor name, or
/// undefined when `this` is not a TypedArray (no [[TypedArrayName]]).
pub fn taGetToStringTag(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, td.kind.ctorName());
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

/// GetMethod(source, @@iterator) — tri-state for the ctor/from object-arg path.
/// `.iterate`  → source has a usable iterator (real @@iterator sym, the internal
///               "@@iterator" string key used by Set/Map, or a `next` method on a
///               raw iterator/generator); use IterableToList.
/// `.array_like` → no @@iterator at all; fall back to ToLength + indexed reads.
/// error.JsException → @@iterator present but NOT callable (spec TypeError).
const IterDecision = enum { iterate, array_like };
fn detectIterable(arena: std.mem.Allocator, src: *JsObject) anyerror!IterDecision {
    // 1. Well-known Symbol.iterator (arrays + user `{[Symbol.iterator]:...}`).
    if (realm_mod.active_sym_iterator) |sym| {
        if (src.getSym(sym)) |m| {
            // GetMethod: undefined/null → treat as absent; anything else must be callable.
            if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
                if (!function_proto_isCallable(m))
                    return throwTypeError(arena, "Symbol.iterator is not a function");
                return .iterate;
            }
        }
    }
    // 2. Internal string @@iterator (Set/Map register their iterator here).
    if (src.get("@@iterator")) |m| {
        if (!(m.bits == 0 or m.unbox() == .undefined_ or m.unbox() == .null_)) {
            if (!function_proto_isCallable(m))
                return throwTypeError(arena, "Symbol.iterator is not a function");
            return .iterate;
        }
    }
    // 3. Raw iterator / generator: exposes a callable next().
    if (src.get("next")) |nx| {
        if (function_proto_isCallable(nx)) return .iterate;
    }
    return .array_like;
}

/// IterableToList(source): drive the iterator protocol via the shared collection
/// helpers, collecting each yielded `value` until done. Propagates any throw from
/// @@iterator / next / the value getter.
fn iterableToList(arena: std.mem.Allocator, source: Value) anyerror!std.ArrayList(Value) {
    var list: std.ArrayList(Value) = .empty;
    const iter = try coll.nativeGetIterator(arena, Value{}, &[_]Value{source});
    while (true) {
        const step = try coll.nativeIterStep(arena, Value{}, &[_]Value{iter});
        if (step.bits == 0 or step.unbox() != .object) break;
        const res = step.toPtr().object;
        const done = res.get("done") orelse Value{};
        if (toBool(done)) break;
        const v = res.get("value") orelse Value{};
        try list.append(arena, v);
    }
    return list;
}

fn makeTypedArray(arena: std.mem.Allocator, kind: TAKind, this_val: Value, args: []const Value) anyerror!Value {
    // [[Construct]]-only: a plain call (NewTarget undefined) must throw TypeError.
    // The native construct path sets `active_constructing`; a plain `Int8Array()`
    // call leaves it false (and passes globalThis as `this`, which is an object —
    // so the object check alone is insufficient).
    if (!realm_mod.active_constructing or this_val.bits == 0 or this_val.unbox() != .object) {
        return throwTypeError(arena, "Constructor TypedArray requires 'new'");
    }
    const this_obj = this_val.toPtr().object;
    const esize = kind.elemSize();

    // arg0 is an object → Forms 2/3/4. Everything else → Form 1 (length).
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object) {
        const a0 = args[0];
        const src = a0.toPtr().object;

        // GetPrototypeFromConstructor runs first for object arguments (before any
        // byteOffset/length coercion); a throwing NewTarget.prototype getter throws here.
        try applyNewTargetProto(arena, this_obj);

        // Form 2: new TA(buffer, byteOffset?, length?)  → view onto the buffer.
        if (src.internal_kind == .array_buffer) {
            const ab: *ArrayBufferData = @ptrCast(@alignCast(src.internal_slot.?));
            // 1. byteOffset = ToIndex(args[1]) — side-effecting valueOf runs first.
            const byte_offset = try toIndexThrowing(arena, if (args.len > 1) args[1] else Value{});
            // 2. byteOffset % elementSize != 0 → RangeError.
            if (byte_offset % esize != 0) return throwRangeError(arena, "start offset is not aligned");
            // 3. Detached check (after coercing byteOffset).
            if (ab.detached) return throwTypeError(arena, "Cannot construct a typed array from a detached ArrayBuffer");
            var length: usize = undefined;
            var track_len = false;
            if (args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_) {
                // length = ToIndex(args[2]) — another side-effecting coercion.
                length = try toIndexThrowing(arena, args[2]);
                // Re-check detached: a valueOf may have detached mid-construction.
                if (ab.detached) return throwTypeError(arena, "Cannot construct a typed array from a detached ArrayBuffer");
                if (byte_offset > ab.byte_length) return throwRangeError(arena, "byteOffset out of bounds");
                if (byte_offset + length * esize > ab.byte_length) return throwRangeError(arena, "length out of bounds");
            } else {
                if (ab.byte_length % esize != 0) return throwRangeError(arena, "buffer length not aligned");
                if (byte_offset > ab.byte_length) return throwRangeError(arena, "byteOffset out of bounds");
                length = (ab.byte_length - byte_offset) / esize;
                // No explicit length on a resizable buffer → auto length-tracking view.
                track_len = ab.max_byte_length != null;
            }
            _ = try finishTypedArray(arena, this_obj, kind, src, ab, byte_offset, length, track_len);
            return val_mod.makeObject(arena, this_obj);
        }

        // Form 3: new TA(typedArray)  → copy elements into a fresh buffer.
        if (src.internal_kind == .typed_array) {
            const std_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
            // Cross number↔bigint construction is a TypeError.
            if (std_td.kind.isBigInt() != kind.isBigInt())
                return throwTypeError(arena, "Cannot mix BigInt and non-BigInt typed arrays");
            const length = std_td.length;
            const res = try makeArrayBuffer(arena, length * esize);
            _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length, false);
            const dst = getTd(val_mod.makeObject(arena, this_obj) catch unreachable) orelse unreachable;
            var i: usize = 0;
            while (i < length) : (i += 1) {
                const ev = try taLoad(arena, std_td, i);
                if (kind.isBigInt()) taStoreBig(dst, i, ev) else taStoreNumber(dst, i, toNum(ev));
            }
            return val_mod.makeObject(arena, this_obj);
        }

        // Form 4: new TA(iterable | arrayLike).
        // Per spec, consult GetMethod(source, @@iterator) first: if a usable
        // iterator exists → IterableToList; otherwise fall back to array-like.
        if ((try detectIterable(arena, src)) == .iterate) {
            const list = try iterableToList(arena, args[0]);
            const length = list.items.len;
            const res = try makeArrayBuffer(arena, length * esize);
            _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length, false);
            const dst = getTd(val_mod.makeObject(arena, this_obj) catch unreachable) orelse unreachable;
            var i: usize = 0;
            while (i < length) : (i += 1) {
                const ev = list.items[i];
                if (kind.isBigInt()) {
                    const bv = try toBigIntThrowing(arena, ev);
                    taStoreBig(dst, i, bv);
                } else {
                    const nv = try toNumberThrowing(arena, ev);
                    taStoreNumber(dst, i, nv);
                }
            }
            return val_mod.makeObject(arena, this_obj);
        }

        // Array-like path: ToLength(? Get(source,"length")) + indexed [[Get]]s
        // (fires getters / proxy traps and propagates abrupt throws).
        const len_f = try toIntegerThrowing(arena, try vmGet(arena, args[0], "length"));
        const length: usize = if (len_f <= 0) 0 else if (len_f > 9007199254740991.0) 9007199254740991 else @intFromFloat(len_f);
        const res = try makeArrayBuffer(arena, length * esize);
        _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length, false);
        const dst = getTd(val_mod.makeObject(arena, this_obj) catch unreachable) orelse unreachable;
        var i: usize = 0;
        while (i < length) : (i += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const ev = try vmGet(arena, args[0], key);
            // Throwing element coercion: runs user valueOf, propagates throws.
            if (kind.isBigInt()) {
                const bv = try toBigIntThrowing(arena, ev);
                taStoreBig(dst, i, bv);
            } else {
                const nv = try toNumberThrowing(arena, ev);
                taStoreNumber(dst, i, nv);
            }
        }
        return val_mod.makeObject(arena, this_obj);
    }

    // Form 1: new TA(length)  (no args → length 0). Non-object arg0 coerces via
    // ToIndex, which throws on negative / Symbol / out-of-range / throwing-valueOf
    // — this runs BEFORE GetPrototypeFromConstructor for the primitive path.
    const length = try toIndexThrowing(arena, if (args.len > 0) args[0] else Value{});
    try applyNewTargetProto(arena, this_obj);
    const res = try makeArrayBuffer(arena, length * esize);
    _ = try finishTypedArray(arena, this_obj, kind, res.obj, res.data, 0, length, false);
    return val_mod.makeObject(arena, this_obj);
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
    _ = try finishTypedArray(arena, obj, kind, res.obj, res.data, 0, length, false);
    const td = getTd(val_mod.makeObject(arena, obj) catch unreachable).?;
    return .{ .obj = obj, .td = td };
}

fn elemToNumber(ev: Value) f64 {
    return toNum(ev);
}

/// IntegerIndexedElementSet: coerce `value` via spec ToBigInt/ToNumber (runs
/// user valueOf, propagates abrupt throws), then store only when the index is
/// still valid (resize/detach-safe). Used by [[Set]]/[[DefineOwnProperty]].
pub fn setElementThrowing(arena: std.mem.Allocator, td: *TypedArrayData, idx_f: f64, value: Value) anyerror!void {
    if (td.kind.isBigInt()) {
        const bv = try toBigIntThrowing(arena, value);
        if (isValidIntegerIndex(td, idx_f)) taStoreBig(td, @intFromFloat(idx_f), bv);
    } else {
        const nv = try toNumberThrowing(arena, value);
        if (isValidIntegerIndex(td, idx_f)) taStoreNumber(td, @intFromFloat(idx_f), nv);
    }
}

/// ES2023 §22.2.4.7 TypedArraySpeciesCreate(exemplar, argumentList).
/// Returns the result Value (a TypedArray) or propagates JsException.
fn typedArraySpeciesCreate(arena: std.mem.Allocator, exemplar_td: *const TypedArrayData, exemplar_this: Value, species_args: []const Value) anyerror!Value {
    _ = exemplar_td; // kind used only to locate defaultCtor below

    // 1. defaultCtor = intrinsic ctor for exemplar's kind.
    const kind = blk: {
        if (exemplar_this.bits != 0 and exemplar_this.unbox() == .object) {
            const o = exemplar_this.toPtr().object;
            if (o.internal_kind == .typed_array and o.internal_slot != null) {
                const td: *TypedArrayData = @ptrCast(@alignCast(o.internal_slot.?));
                break :blk td.kind;
            }
        }
        break :blk TAKind.u8;
    };
    const default_ctor_obj = active_ta_ctors[@intFromEnum(kind)] orelse
        return throwTypeError(arena, "TypedArray intrinsic constructor not found");
    const default_ctor = try val_mod.makeObject(arena, default_ctor_obj);

    // 2. SpeciesConstructor(exemplar_this, defaultCtor) — spec-observable.
    //    a. C ← ? Get(exemplar, "constructor")  (fires a custom getter).
    //    b. If C is undefined, return defaultCtor.
    //    c. If C is not an Object, throw TypeError.
    //    d. S ← ? Get(C, @@species)  (fires a custom getter).
    //    e. If S is undefined/null, return defaultCtor.
    //    f. If IsConstructor(S), return S; else throw TypeError.
    var C = default_ctor;
    if (exemplar_this.bits != 0 and exemplar_this.unbox() == .object) {
        const ctor_v = try vmGet(arena, exemplar_this, "constructor");
        if (ctor_v.bits != 0 and ctor_v.unbox() != .undefined_) {
            if (ctor_v.unbox() != .object) {
                return throwTypeError(arena, "TypedArray constructor property is not an object");
            }
            if (realm_mod.active_sym_species) |spec_sym| {
                const S = try vmGetSym(arena, ctor_v, spec_sym);
                if (S.bits == 0 or S.unbox() == .undefined_ or S.unbox() == .null_) {
                    // @@species absent/null/undefined → use defaultCtor (already set).
                } else if (isConstructor(S)) {
                    C = S;
                } else {
                    return throwTypeError(arena, "@@species is not a constructor");
                }
            }
        }
        // "constructor" undefined → use defaultCtor (already set).
    }

    // 3. Construct(C, species_args).
    const ctx = realm_mod.active_context orelse return throwTypeError(arena, "no active context");
    const result = try ctx.construct(arena, C, species_args);

    // 4. Validate result is a TypedArray.
    const res_td = getTd(result) orelse
        return throwTypeError(arena, "TypedArray[@@species] result is not a TypedArray");

    // 5. Detached check.
    if (res_td.ab.detached)
        return throwTypeError(arena, "TypedArray[@@species] result has detached buffer");

    // 6. If a length argument was passed (single numeric arg), check result.length >= that length.
    if (species_args.len == 1 and species_args[0].bits != 0 and species_args[0].unbox() == .number) {
        const required: usize = toIndex(species_args[0].unbox().number);
        if (res_td.length < required)
            return throwTypeError(arena, "TypedArray[@@species] result is too short");
    }

    return result;
}

/// IsConstructor: true if value is callable with [[Construct]] (function or
/// object with __call__, excluding arrow-function markers).
fn isConstructor(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function => true,
        .native_function => true,
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function,
        else => false,
    };
}

/// ValidateTypedArray: throw TypeError if the TA's buffer is detached or the
/// view is out-of-bounds (resizable buffer shrunk past it). Also refreshes the
/// live `length` cache so method bodies read the current element count.
fn validateTypedArray(arena: std.mem.Allocator, td: *TypedArrayData) anyerror!void {
    if (td.ab.detached) return throwTypeError(arena, "Cannot perform %TypedArray%.prototype operation on a detached ArrayBuffer");
    if (taIsOob(td)) return throwTypeError(arena, "Cannot perform %TypedArray%.prototype operation on an out-of-bounds TypedArray");
    td.length = taCurrentLen(td);
}

pub fn nativeTaFill(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const raw_v = if (args.len > 0) args[0] else Value{};
    var fill_num: f64 = 0;
    var fill_big: Value = Value{};
    if (td.kind.isBigInt()) {
        fill_big = try toBigIntThrowing(arena, raw_v);
    } else {
        fill_num = try toNumberThrowing(arena, raw_v);
    }
    const start = relIndex(try toIntegerThrowing(arena, if (args.len > 1) args[1] else Value{}), td.length);
    const end_v: Value = if (args.len > 2) args[2] else Value{};
    const end = if (end_v.bits != 0 and end_v.unbox() != .undefined_)
        relIndex(try toIntegerThrowing(arena, end_v), td.length)
    else
        td.length;
    // Step 10: detach during coercion → TypeError.
    if (td.ab.detached) return throwTypeError(arena, "Cannot fill a detached ArrayBuffer");
    var i = start;
    while (i < end) : (i += 1) {
        if (td.kind.isBigInt()) taStoreBig(td, i, fill_big) else taStoreNumber(td, i, fill_num);
    }
    return this_val;
}

pub fn nativeTaSubarray(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const begin = relIndex(try toIntegerThrowing(arena, if (args.len > 0) args[0] else Value{}), td.length);
    const end_v: Value = if (args.len > 1) args[1] else Value{};
    const end = if (end_v.bits != 0 and end_v.unbox() != .undefined_)
        relIndex(try toIntegerThrowing(arena, end_v), td.length)
    else
        td.length;
    const new_len = if (end > begin) end - begin else 0;
    // Build subarray args: (buffer, beginByteOffset, newLength) for species ctor.
    const buf_val = try val_mod.makeObject(arena, td.buffer_obj);
    const begin_byte_offset = td.byte_offset + begin * td.kind.elemSize();
    const byte_off_val = try val_mod.makeNumber(arena, @floatFromInt(begin_byte_offset));
    const new_len_val = try val_mod.makeNumber(arena, @floatFromInt(new_len));
    const species_args = [_]Value{ buf_val, byte_off_val, new_len_val };
    return typedArraySpeciesCreate(arena, td, this_val, &species_args);
}

pub fn nativeTaSlice(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const start = relIndex(try toIntegerThrowing(arena, if (args.len > 0) args[0] else Value{}), td.length);
    const end_v: Value = if (args.len > 1) args[1] else Value{};
    const end = if (end_v.bits != 0 and end_v.unbox() != .undefined_)
        relIndex(try toIntegerThrowing(arena, end_v), td.length)
    else
        td.length;
    const new_len = if (end > start) end - start else 0;
    const len_arg = [_]Value{try val_mod.makeNumber(arena, @floatFromInt(new_len))};
    const result = try typedArraySpeciesCreate(arena, td, this_val, &len_arg);
    const a_td = getTd(result) orelse return throwTypeError(arena, "species result not a TypedArray");
    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        const ev = try taLoad(arena, td, start + i);
        if (td.kind.isBigInt()) taStoreBig(a_td, i, ev) else taStoreNumber(a_td, i, toNum(ev));
    }
    return result;
}

pub fn nativeTaSet(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const target_len = td.length;
    const target_lf: f64 = @floatFromInt(target_len);
    // targetOffset = ToIntegerOrInfinity(offset) (runs valueOf, propagates throws);
    // negative → RangeError. May be +Inf (caught by the bounds check below).
    const off_f = try toIntegerThrowing(arena, if (args.len > 1) args[1] else Value{});
    if (off_f < 0) return throwRangeError(arena, "Invalid typed array set offset");
    if (args.len == 0 or args[0].bits == 0 or args[0].unbox() != .object) return val_mod.makeUndefined(arena);
    const src = args[0].toPtr().object;
    if (src.internal_kind == .typed_array) {
        const src_td: *TypedArrayData = @ptrCast(@alignCast(src.internal_slot.?));
        // Cross number↔bigint set is a TypeError.
        if (src_td.kind.isBigInt() != td.kind.isBigInt())
            return throwTypeError(arena, "Cannot mix BigInt and non-BigInt typed arrays");
        const src_len = taCurrentLen(src_td);
        if (off_f > target_lf or @as(f64, @floatFromInt(src_len)) + off_f > target_lf)
            return throwRangeError(arena, "offset out of bounds");
        const offset: usize = @intFromFloat(off_f);
        // Read all source elements first (overlap-safe when source and target
        // share a backing ArrayBuffer).
        const tmp = try arena.alloc(Value, src_len);
        var i: usize = 0;
        while (i < src_len) : (i += 1) tmp[i] = try taLoad(arena, src_td, i);
        i = 0;
        while (i < src_len) : (i += 1) {
            if (!isValidIntegerIndex(td, @floatFromInt(offset + i))) continue;
            if (td.kind.isBigInt()) taStoreBig(td, offset + i, tmp[i]) else taStoreNumber(td, offset + i, toNum(tmp[i]));
        }
    } else {
        // Array-like: srcLength = ToLength(? Get(src,"length")) — full [[Get]] fires
        // a length getter / valueOf and propagates abrupt throws.
        const len_f = try toIntegerThrowing(arena, try vmGet(arena, args[0], "length"));
        const src_len: usize = if (len_f <= 0) 0 else if (len_f > 9007199254740991.0) 9007199254740991 else @intFromFloat(len_f);
        if (off_f > target_lf or @as(f64, @floatFromInt(src_len)) + off_f > target_lf)
            return throwRangeError(arena, "offset out of bounds");
        const offset: usize = @intFromFloat(off_f);
        var i: usize = 0;
        while (i < src_len) : (i += 1) {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            const ev = try vmGet(arena, args[0], key);
            // Throwing element coercion (user valueOf runs); guard each store so a
            // resize/detach during coercion makes out-of-bounds writes no-ops.
            if (td.kind.isBigInt()) {
                const bv = try toBigIntThrowing(arena, ev);
                if (isValidIntegerIndex(td, @floatFromInt(offset + i))) taStoreBig(td, offset + i, bv);
            } else {
                const nv = try toNumberThrowing(arena, ev);
                if (isValidIntegerIndex(td, @floatFromInt(offset + i))) taStoreNumber(td, offset + i, nv);
            }
        }
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeTaIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0) return val_mod.makeNumber(arena, -1);
    const is_big = td.kind.isBigInt();
    const target = toNum(args[0]);
    const want_big: ?i128 = if (is_big) bigintSearch(args[0]) else null;
    var k: usize = 0;
    if (args.len > 1) {
        const n = try toIntegerThrowing(arena, args[1]);
        if (n >= @as(f64, @floatFromInt(td.length))) return val_mod.makeNumber(arena, -1);
        var s = n;
        if (s < 0) {
            s += @floatFromInt(td.length);
            if (s < 0) s = 0;
        }
        k = @intFromFloat(s);
    }
    var i: usize = k;
    while (i < td.length) : (i += 1) {
        if (is_big) {
            if (want_big != null and taBigRaw(td, i) == want_big.?) return val_mod.makeNumber(arena, @floatFromInt(i));
        } else {
            const ev = try taLoad(arena, td, i);
            if (toNum(ev) == target) return val_mod.makeNumber(arena, @floatFromInt(i));
        }
    }
    return val_mod.makeNumber(arena, -1);
}

pub fn nativeTaIncludes(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0) return val_mod.makeBool(arena, false);
    const is_big = td.kind.isBigInt();
    const target = toNum(args[0]);
    const want_nan = std.math.isNan(target);
    const want_big: ?i128 = if (is_big) bigintSearch(args[0]) else null;
    var k: usize = 0;
    if (args.len > 1) {
        const n = try toIntegerThrowing(arena, args[1]);
        var s = n;
        if (s < 0) {
            s += @floatFromInt(td.length);
            if (s < 0) s = 0;
        }
        if (s >= @as(f64, @floatFromInt(td.length))) return val_mod.makeBool(arena, false);
        k = @intFromFloat(s);
    }
    var i: usize = k;
    while (i < td.length) : (i += 1) {
        if (is_big) {
            if (want_big != null and taBigRaw(td, i) == want_big.?) return val_mod.makeBool(arena, true);
        } else {
            const ev = try taLoad(arena, td, i);
            const n = toNum(ev);
            if (n == target or (want_nan and std.math.isNan(n))) return val_mod.makeBool(arena, true);
        }
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeTaJoin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const sep: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string) args[0].toPtr().string else ",";
    var buf = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, sep);
        const ev = try taLoad(arena, td, i);
        const s = if (td.kind.isBigInt())
            try val_mod.bigIntToString(arena, ev.unbox().bigint)
        else
            try val_mod.formatNumber(arena, toNum(ev));
        try buf.appendSlice(arena, s);
    }
    return val_mod.makeString(arena, buf.items);
}

pub fn nativeTaToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return nativeTaJoin(arena, this_val, &[_]Value{});
}

pub fn nativeTaReverse(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
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
    try validateTypedArray(arena, td);
    const rel = try toIntegerThrowing(arena, if (args.len > 0) args[0] else Value{});
    var idx: f64 = rel;
    if (idx < 0) idx += @floatFromInt(td.length);
    if (idx < 0 or idx >= @as(f64, @floatFromInt(td.length))) return val_mod.makeUndefined(arena);
    return taLoad(arena, td, @intFromFloat(idx));
}

pub fn nativeTaForEach(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
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
    try validateTypedArray(arena, td);
    if (args.len == 0) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    const len_arg = [_]Value{try val_mod.makeNumber(arena, @floatFromInt(td.length))};
    const result = try typedArraySpeciesCreate(arena, td, this_val, &len_arg);
    const a_td = getTd(result) orelse return throwTypeError(arena, "species result not a TypedArray");
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (td.kind.isBigInt()) taStoreBig(a_td, i, r) else taStoreNumber(a_td, i, toNum(r));
    }
    return result;
}

pub fn nativeTaReduce(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    var acc: Value = undefined;
    var i: usize = 0;
    if (!function_proto_isCallable(cb)) return throwTypeError(arena, "callback is not a function");
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

/// Build a TypedArray iterator backed by the shared %ArrayIteratorPrototype%
/// (es2015_collections). The iterator state stores the TA value (not the `td`),
/// so each `next` re-reads the live [[ArrayLength]] — resize/detach mid-iteration
/// is observed per spec.
fn makeTAIterator(arena: std.mem.Allocator, this_val: Value, kind: coll.SeqIterKind) !Value {
    const d = try arena.create(coll.SeqIterData);
    d.* = .{ .seq = this_val, .is_typed = true, .kind = kind };
    return coll.makeSeqIterator(arena, d);
}

/// Iterator `@@iterator` returns the iterator itself (for-of over an iterator).
pub fn nativeIterSelf(_: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return this_val;
}

pub fn nativeTaValues(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    return makeTAIterator(arena, this_val, .value);
}

pub fn nativeTaKeys(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    return makeTAIterator(arena, this_val, .key);
}

pub fn nativeTaEntries(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    return makeTAIterator(arena, this_val, .entry);
}

// ---------------------------------------------------------------- TA static ---

/// `%TypedArray%.of` — kind is taken from the `this` constructor (so
/// `Int8Array.of(...)` and an explicit-receiver call both resolve correctly).
/// IsConstructor for a `this`-value receiver of `from`/`of`. Built-in TA ctors
/// are objects with `__call__`; user functions/classes are bc_functions.
fn isCtor(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .bc_function => true,
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function or o.internal_kind == .proxy,
        else => false,
    };
}

/// TypedArrayCreate(C, [len]): Construct the receiver with one length argument,
/// returning the created object (a custom subclass / arbitrary constructor).
fn taCreateViaConstruct(arena: std.mem.Allocator, ctor: Value, len: usize) anyerror!Value {
    if (!isCtor(ctor)) return throwTypeError(arena, "TypedArray.from/of requires a constructor receiver");
    const ctx = realm_mod.active_context orelse return throwTypeError(arena, "no active context for TypedArrayCreate");
    const result = try ctx.construct(arena, ctor, &[_]Value{try val_mod.makeNumber(arena, @floatFromInt(len))});
    // ValidateTypedArray: the constructor MUST return a (non-detached) TypedArray,
    // and when a length was passed the result must be at least that long.
    const td = getTd(result) orelse return throwTypeError(arena, "TypedArrayCreate: constructor did not return a TypedArray");
    try validateTypedArray(arena, td);
    if (taCurrentLen(td) < len) return throwTypeError(arena, "TypedArrayCreate: derived TypedArray is too small");
    return result;
}

pub fn nativeTaOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    if (kindFromCtor(this_val)) |kind| {
        const a = try allocTA(arena, kind, args.len);
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (kind.isBigInt()) taStoreBig(a.td, i, args[i]) else taStoreNumber(a.td, i, toNum(args[i]));
        }
        return val_mod.makeObject(arena, a.obj);
    }
    // Generic %TypedArray%.of over a custom constructor: TypedArrayCreate then
    // Set each item through the target's [[Set]] (fires exotic/ordinary write).
    const target = try taCreateViaConstruct(arena, this_val, args.len);
    const ctx = realm_mod.active_context.?;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        try ctx.setProp(arena, target, key, args[i]);
    }
    return target;
}

/// `%TypedArray%.from` — kind from the `this` constructor.
pub fn nativeTaFrom(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const kind_opt = kindFromCtor(this_val);
    if (kind_opt == null and !isCtor(this_val))
        return throwTypeError(arena, "TypedArray.from requires a constructor receiver");
    // mapfn, if supplied (non-undefined), MUST be callable — else TypeError,
    // and this check happens before any iteration/array-like reads.
    const map_present = args.len > 1 and !(args[1].bits == 0 or args[1].unbox() == .undefined_);
    if (map_present and !function_proto_isCallable(args[1]))
        return throwTypeError(arena, "TypedArray.from: mapfn is not a function");
    const this_arg: Value = if (args.len > 2) args[2] else Value{};

    // Collect source: iterable → pre-materialized list; array-like → object + len.
    var list_items: []const Value = &[_]Value{};
    var arr_src: ?*JsObject = null;
    var length: usize = 0;
    if (args.len >= 1 and args[0].bits != 0 and args[0].unbox() == .object) {
        const src = args[0].toPtr().object;
        if ((try detectIterable(arena, src)) == .iterate) {
            const list = try iterableToList(arena, args[0]);
            list_items = list.items;
            length = list.items.len;
        } else {
            arr_src = src;
            length = arrayLikeLen(src);
        }
    }

    // TypedArrayCreate(C, [length]): fast path for built-in kinds, else Construct
    // the custom receiver (TA subclass / arbitrary ctor) with the length.
    var ta_td: ?*TypedArrayData = null;
    var target: Value = undefined;
    if (kind_opt) |kind| {
        const a = try allocTA(arena, kind, length);
        ta_td = a.td;
        target = try val_mod.makeObject(arena, a.obj);
    } else {
        target = try taCreateViaConstruct(arena, this_val, length);
    }

    var i: usize = 0;
    while (i < length) : (i += 1) {
        var ev = if (arr_src) |s| blk: {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            break :blk src_get: {
                break :src_get s.get(key) orelse Value{};
            };
        } else list_items[i];
        if (map_present) {
            const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
            ev = try function_proto.invokeCallback(arena, this_arg, args[1], &[_]Value{ ev, idx_v });
        }
        if (ta_td) |td| {
            if (kind_opt.?.isBigInt()) taStoreBig(td, i, try toBigIntThrowing(arena, ev)) else taStoreNumber(td, i, try toNumberThrowing(arena, ev));
        } else {
            const key = try std.fmt.allocPrint(arena, "{d}", .{i});
            try realm_mod.active_context.?.setProp(arena, target, key, ev);
        }
    }
    return target;
}

fn function_proto_isCallable(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .function, .bc_function, .native_function => true,
        .object => |o| o.get("__call__") != null or o.internal_kind == .bound_function,
        else => false,
    };
}

fn toBool(v: Value) bool {
    if (v.bits == 0) return false;
    return switch (v.unbox()) {
        .undefined_, .null_ => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        else => true,
    };
}

/// Raw signed/unsigned 64-bit element value for default bigint ordering
/// (BigInt64Array/BigUint64Array elements fit in i128). Avoids bigint-Value
/// decode in the hot compare path; only valid for bigint kinds.
fn taBigRaw(td: *const TypedArrayData, i: usize) i128 {
    const sz = td.kind.elemSize();
    const base = td.byte_offset + i * sz;
    const b = td.ab.bytes;
    if (base + sz > b.len) return 0;
    const p = b[base..];
    return switch (td.kind) {
        .i64big => @as(i128, std.mem.readInt(i64, p[0..8], native_endian)),
        .u64big => @as(i128, std.mem.readInt(u64, p[0..8], native_endian)),
        else => 0,
    };
}

/// SameValueZero/StrictEquality search value for a BigInt TypedArray: the exact
/// i128 value of `v` when `v` is a BigInt that fits in i128 (every i64/u64
/// element does), else null → matches nothing. Used by indexOf/includes/
/// lastIndexOf on BigInt64Array/BigUint64Array (toNum would yield NaN).
fn bigintSearch(v: Value) ?i128 {
    if (v.bits == 0 or v.unbox() != .bigint) return null;
    return v.toPtr().bigint.toConst().toInt(i128) catch null;
}

pub fn nativeTaSort(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const n = td.length;
    if (n < 2) return this_val;
    const cmp_fn = if (args.len > 0 and function_proto_isCallable(args[0])) args[0] else Value{};
    const undef = try val_mod.makeUndefined(arena);
    // Insertion sort (n usually small; avoids needing a stack for quicksort).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = try taLoad(arena, td, j - 1);
            const b = try taLoad(arena, td, j);
            // Compare: > 0 means a should come after b (swap).
            const should_swap = blk: {
                if (cmp_fn.bits != 0) {
                    const r = try function_proto.invokeCallback(arena, undef, cmp_fn, &[_]Value{ a, b });
                    const rv = toNum(r);
                    break :blk rv > 0;
                }
                if (td.kind.isBigInt()) break :blk taBigRaw(td, j - 1) > taBigRaw(td, j);
                break :blk toNum(a) > toNum(b);
            };
            if (should_swap) {
                if (td.kind.isBigInt()) {
                    taStoreBig(td, j - 1, b);
                    taStoreBig(td, j, a);
                } else {
                    taStoreNumber(td, j - 1, toNum(b));
                    taStoreNumber(td, j, toNum(a));
                }
            } else break;
        }
    }
    return this_val;
}

pub fn nativeTaFind(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) return ev;
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeTaFindIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1);
}

pub fn nativeTaFilter(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    // First pass: collect kept elements into a temporary allocTA (same kind, max size).
    const tmp = try allocTA(arena, td.kind, td.length);
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) {
            if (td.kind.isBigInt()) taStoreBig(tmp.td, out_len, ev) else taStoreNumber(tmp.td, out_len, toNum(ev));
            out_len += 1;
        }
    }
    // Second pass: create result via species with the exact count.
    const len_arg = [_]Value{try val_mod.makeNumber(arena, @floatFromInt(out_len))};
    const result = try typedArraySpeciesCreate(arena, td, this_val, &len_arg);
    const res_td = getTd(result) orelse return throwTypeError(arena, "species result not a TypedArray");
    var j: usize = 0;
    while (j < out_len) : (j += 1) {
        const ev = try taLoad(arena, tmp.td, j);
        if (td.kind.isBigInt()) taStoreBig(res_td, j, ev) else taStoreNumber(res_td, j, toNum(ev));
    }
    return result;
}

pub fn nativeTaEvery(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (!toBool(r)) return val_mod.makeBool(arena, false);
    }
    return val_mod.makeBool(arena, true);
}

pub fn nativeTaSome(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

pub fn nativeTaCopyWithin(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const len = td.length;
    const target = relIndex(try toIntegerThrowing(arena, if (args.len > 0) args[0] else Value{}), len);
    const start = relIndex(try toIntegerThrowing(arena, if (args.len > 1) args[1] else Value{}), len);
    const end_v: Value = if (args.len > 2) args[2] else Value{};
    const end = if (end_v.bits != 0 and end_v.unbox() != .undefined_)
        relIndex(try toIntegerThrowing(arena, end_v), len)
    else
        len;
    if (td.ab.detached) return this_val; // detached during coercion → no-op
    const count = if (end > start) end - start else 0;
    if (count == 0 or target >= len) return this_val;
    const actual_count = @min(count, len - target);
    if (start < target and target < start + count) {
        var i = actual_count;
        while (i > 0) : (i -= 1) {
            const src_idx = start + i - 1;
            const dst_idx = target + i - 1;
            const ev = try taLoad(arena, td, src_idx);
            if (td.kind.isBigInt()) taStoreBig(td, dst_idx, ev) else taStoreNumber(td, dst_idx, toNum(ev));
        }
    } else {
        var i: usize = 0;
        while (i < actual_count) : (i += 1) {
            const ev = try taLoad(arena, td, start + i);
            if (td.kind.isBigInt()) taStoreBig(td, target + i, ev) else taStoreNumber(td, target + i, toNum(ev));
        }
    }
    return this_val;
}

pub fn nativeTaReduceRight(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    // §3: IsCallable(callbackfn) check precedes the len/initialValue check, so a
    // non-callable still throws even on a 1-element array (loop never runs).
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    var acc: Value = undefined;
    var i: usize = td.length;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (td.length == 0) return throwTypeError(arena, "Reduce of empty array with no initial value");
        i = td.length - 1;
        acc = try taLoad(arena, td, i);
    }
    while (i > 0) {
        i -= 1;
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        acc = try function_proto.invokeCallback(arena, Value{}, cb, &[_]Value{ acc, ev, idx_v, this_val });
    }
    return acc;
}

pub fn nativeTaLastIndexOf(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or td.length == 0) return val_mod.makeNumber(arena, -1);
    const is_big = td.kind.isBigInt();
    const target = toNum(args[0]);
    const want_big: ?i128 = if (is_big) bigintSearch(args[0]) else null;
    var from: i64 = @intCast(td.length - 1);
    if (args.len > 1) {
        const fi = try toIntegerThrowing(arena, args[1]);
        if (std.math.isNan(fi)) return val_mod.makeNumber(arena, -1);
        // Clamp to i64 range before conversion to avoid panic on Inf/huge values.
        if (fi >= 9.007199254740992e15) {
            // +Inf or very large positive: clamp to length-1 (already set as default)
        } else if (fi < -9.007199254740992e15) {
            return val_mod.makeNumber(arena, -1);
        } else {
            from = @intFromFloat(fi);
            if (from < 0) from += @intCast(td.length);
            if (from < 0) return val_mod.makeNumber(arena, -1);
            if (from >= @as(i64, @intCast(td.length))) from = @intCast(td.length - 1);
        }
    }
    var i: usize = @intCast(from);
    while (true) {
        if (is_big) {
            if (want_big != null and taBigRaw(td, i) == want_big.?) return val_mod.makeNumber(arena, @floatFromInt(i));
        } else {
            const ev = try taLoad(arena, td, i);
            if (toNum(ev) == target) return val_mod.makeNumber(arena, @floatFromInt(i));
        }
        if (i == 0) break;
        i -= 1;
    }
    return val_mod.makeNumber(arena, -1);
}

pub fn nativeTaToLocaleString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    return nativeTaJoin(arena, this_val, &[_]Value{});
}

pub fn nativeTaFindLast(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    if (td.length == 0) return val_mod.makeUndefined(arena);
    var i: usize = td.length;
    while (i > 0) {
        i -= 1;
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) return ev;
    }
    return val_mod.makeUndefined(arena);
}

pub fn nativeTaFindLastIndex(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len == 0 or !function_proto_isCallable(args[0])) return throwTypeError(arena, "callback is not a function");
    const cb = args[0];
    const this_arg = if (args.len > 1) args[1] else Value{};
    if (td.length == 0) return val_mod.makeNumber(arena, -1);
    var i: usize = td.length;
    while (i > 0) {
        i -= 1;
        const ev = try taLoad(arena, td, i);
        const idx_v = try val_mod.makeNumber(arena, @floatFromInt(i));
        const r = try function_proto.invokeCallback(arena, this_arg, cb, &[_]Value{ ev, idx_v, this_val });
        if (toBool(r)) return val_mod.makeNumber(arena, @floatFromInt(i));
    }
    return val_mod.makeNumber(arena, -1);
}

pub fn nativeTaToReversed(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const a = try allocTA(arena, td.kind, td.length);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const src_idx = td.length - 1 - i;
        const ev = try taLoad(arena, td, src_idx);
        if (td.kind.isBigInt()) taStoreBig(a.td, i, ev) else taStoreNumber(a.td, i, toNum(ev));
    }
    return val_mod.makeObject(arena, a.obj);
}

pub fn nativeTaToSorted(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    const a = try allocTA(arena, td.kind, td.length);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        const ev = try taLoad(arena, td, i);
        if (td.kind.isBigInt()) taStoreBig(a.td, i, ev) else taStoreNumber(a.td, i, toNum(ev));
    }
    const n = td.length;
    if (n < 2) return val_mod.makeObject(arena, a.obj);
    const cmp_fn = if (args.len > 0 and function_proto_isCallable(args[0])) args[0] else Value{};
    const undef = try val_mod.makeUndefined(arena);
    i = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const aa = try taLoad(arena, a.td, j - 1);
            const b = try taLoad(arena, a.td, j);
            const should_swap = blk: {
                if (cmp_fn.bits != 0) {
                    const r = try function_proto.invokeCallback(arena, undef, cmp_fn, &[_]Value{ aa, b });
                    const rv = toNum(r);
                    break :blk rv > 0;
                }
                if (td.kind.isBigInt()) break :blk taBigRaw(a.td, j - 1) > taBigRaw(a.td, j);
                break :blk toNum(aa) > toNum(b);
            };
            if (should_swap) {
                if (td.kind.isBigInt()) {
                    taStoreBig(a.td, j - 1, b);
                    taStoreBig(a.td, j, aa);
                } else {
                    taStoreNumber(a.td, j - 1, toNum(b));
                    taStoreNumber(a.td, j, toNum(aa));
                }
            } else break;
        }
    }
    return val_mod.makeObject(arena, a.obj);
}

pub fn nativeTaWith(arena: std.mem.Allocator, this_val: Value, args: []const Value) anyerror!Value {
    const td = getTd(this_val) orelse return throwTypeError(arena, "not a TypedArray");
    try validateTypedArray(arena, td);
    if (args.len < 2) return throwTypeError(arena, "with requires 2 arguments");
    const idx_f = try toIntegerThrowing(arena, args[0]);
    var idx: f64 = idx_f;
    if (idx < 0) idx += @floatFromInt(td.length);
    if (idx < 0 or idx >= @as(f64, @floatFromInt(td.length)))
        return throwRangeError(arena, "Invalid typed array index");
    const final_idx: usize = @intFromFloat(idx);
    var new_num: f64 = 0;
    var new_big: Value = Value{};
    if (td.kind.isBigInt()) new_big = try toBigIntThrowing(arena, args[1]) else new_num = try toNumberThrowing(arena, args[1]);
    const a = try allocTA(arena, td.kind, td.length);
    var i: usize = 0;
    while (i < td.length) : (i += 1) {
        if (i == final_idx) {
            if (td.kind.isBigInt()) taStoreBig(a.td, i, new_big) else taStoreNumber(a.td, i, new_num);
        } else {
            const ev = try taLoad(arena, td, i);
            if (td.kind.isBigInt()) taStoreBig(a.td, i, ev) else taStoreNumber(a.td, i, toNum(ev));
        }
    }
    return val_mod.makeObject(arena, a.obj);
}

// ---------------------------------------------------------------- DataView ---

fn getDvData(v: Value) ?*DataViewData {
    if (v.bits == 0 or v.unbox() != .object) return null;
    const o = v.toPtr().object;
    if (o.internal_kind != .data_view) return null;
    if (o.internal_slot == null) return null;
    return @ptrCast(@alignCast(o.internal_slot.?));
}

/// IsViewOutOfBounds: detached, or the view no longer fits the resized buffer.
fn dvIsOob(dv: *const DataViewData) bool {
    const ab = dv.ab;
    if (ab.detached) return true;
    if (dv.byte_offset > ab.byte_length) return true;
    if (dv.track_length) return false;
    return dv.byte_offset + dv.byte_length > ab.byte_length;
}

/// GetViewByteLength: live byte length (caller must ensure not out-of-bounds).
fn dvCurrentByteLen(dv: *const DataViewData) usize {
    if (dv.track_length) return dv.ab.byte_length - dv.byte_offset;
    return dv.byte_length;
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
    // Spec: ToNumber(byteOffset) runs before the detached check.
    const byte_offset: usize = if (args.len > 1) try toIndexThrowing(arena, args[1]) else 0;
    const has_len = args.len > 2 and args[2].bits != 0 and args[2].unbox() != .undefined_;
    const explicit_len: usize = if (has_len) try toIndexThrowing(arena, args[2]) else 0;
    if (ab.detached) return throwTypeError(arena, "Cannot perform operation on a detached ArrayBuffer");
    if (byte_offset > ab.byte_length) return throwRangeError(arena, "byteOffset out of bounds");
    // No explicit byteLength on a resizable buffer → length-tracking view.
    const track_length = !has_len and ab.max_byte_length != null;
    const byte_length: usize = if (has_len) explicit_len else ab.byte_length - byte_offset;
    if (has_len and byte_offset + byte_length > ab.byte_length) return throwRangeError(arena, "Invalid DataView length");
    const obj = this_val.toPtr().object;
    // GetPrototypeFromConstructor runs after offset/length coercion + bounds checks.
    try applyNewTargetProto(arena, obj);
    const dv = try arena.create(DataViewData);
    dv.* = .{ .buffer_obj = buf_obj, .ab = ab, .byte_offset = byte_offset, .byte_length = byte_length, .track_length = track_length };
    obj.internal_kind = .data_view;
    obj.internal_slot = dv;
    try obj.set("buffer", try val_mod.makeObject(arena, buf_obj));
    return this_val;
}

pub fn dvGetByteLength(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dv = getDvData(this_val) orelse return throwTypeError(arena, "get byteLength called on non-DataView");
    if (dvIsOob(dv)) return throwTypeError(arena, "Cannot perform operation on an out-of-bounds DataView");
    return val_mod.makeNumber(arena, @floatFromInt(dvCurrentByteLen(dv)));
}

pub fn dvGetByteOffset(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    const dv = getDvData(this_val) orelse return throwTypeError(arena, "get byteOffset called on non-DataView");
    if (dvIsOob(dv)) return throwTypeError(arena, "Cannot perform operation on an out-of-bounds DataView");
    return val_mod.makeNumber(arena, @floatFromInt(dv.byte_offset));
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
            // Spec: ToIndex(requestIndex) runs BEFORE the detached check.
            const raw_off = if (args.len > 0) toNum(args[0]) else 0;
            if (!std.math.isFinite(raw_off) or raw_off < 0) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
            const off: usize = toIndex(raw_off);
            if (dvIsOob(dv)) return throwTypeError(arena, "Cannot perform operation on an out-of-bounds DataView");
            const size = @sizeOf(T);
            if (off + size > dvCurrentByteLen(dv)) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
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
            // Spec: ToIndex(requestIndex) runs BEFORE the detached check.
            const raw_off = if (args.len > 0) toNum(args[0]) else 0;
            if (!std.math.isFinite(raw_off) or raw_off < 0) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
            const off: usize = toIndex(raw_off);
            if (dvIsOob(dv)) return throwTypeError(arena, "Cannot perform operation on an out-of-bounds DataView");
            const size = @sizeOf(T);
            if (off + size > dvCurrentByteLen(dv)) return throwRangeError(arena, "Offset is outside the bounds of the DataView");
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
